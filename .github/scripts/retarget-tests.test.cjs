const test = require('node:test');
const assert = require('node:assert/strict');
const {dispatchRetargetTests, reportRetargetResult} = require('./retarget-tests.cjs');

const HEAD = 'a'.repeat(40);
const BASE = 'b'.repeat(40);
const MERGE = 'c'.repeat(40);
const E2E = 'e2e-status';
const INTEGRATION = 'Run Integration Tests';
const inputs = (id = 1, generation = '200-1') => ({RETARGET_CHECK_RUN_ID: String(id), RETARGET_RUN: generation, RETARGET_HEAD_SHA: HEAD, RETARGET_MERGE_COMMIT: MERGE, RETARGET_PR: '7'});

function fixture() {
  const pr = {number: 7, state: 'open', draft: false, head: {sha: HEAD, ref: 'feature', repo: {full_name: 'owner/repo'}}, base: {sha: BASE, ref: 'master'}, mergeable: true, merge_commit_sha: MERGE};
  const context = {repo: {owner: 'owner', repo: 'repo'}, eventName: 'pull_request', runId: 200, serverUrl: 'https://github.com', payload: {changes: {base: {}}, pull_request: structuredClone(pr)}};
  const checks = new Map();
  const dispatches = [];
  const failures = [];
  const commits = {parents: [{sha: BASE}, {sha: HEAD}]};
  const rest = {
    pulls: {get: async () => ({data: pr})},
    git: {getCommit: async () => ({data: commits})},
    checks: {
      create: async value => {const check = {id: checks.size + 1, ...value}; checks.set(check.id, check); return {data: check};},
      get: async value => ({data: checks.get(value.check_run_id)}),
      update: async value => {Object.assign(checks.get(value.check_run_id), value);},
    },
    actions: {createWorkflowDispatch: async value => {dispatches.push(value);}},
  };
  const github = {rest};
  const core = {setFailed: value => failures.push(value), info: () => {}};
  return {pr, context, checks, dispatches, failures, commits, github, core, sleep: async () => {}};
}
const start = async f => {await dispatchRetargetTests(f); return f;};

function report(f, options = {}) {
  return reportRetargetResult({...f, name: E2E, phase: 'complete', result: 'success', inputs: inputs(), ...options});
}

test('retarget creates canonical queued checks and dispatches a pinned merge with each check ID', async () => {
  const f = await start(fixture());
  assert.deepEqual([...f.checks.values()].map(c => [c.name, c.status]), [[E2E, 'queued'], [INTEGRATION, 'queued']]);
  assert.deepEqual(f.dispatches.map(d => d.workflow_id), ['e2e-tests.yml', 'integration-tests.yml']);
  for (const [index, dispatch] of f.dispatches.entries()) assert.deepEqual(dispatch.inputs, {pr: '7', merge_commit: MERGE, head_sha: HEAD, retarget_run: '200-1', check_run_id: String(index + 1), ...(index === 0 ? {app_branch: 'feature'} : {})});
  assert.deepEqual(f.dispatches.map(d => d.ref), ['master', 'master']);
  assert.deepEqual(f.failures, []);
});

test('manual recovery can validate a PR with workflow definitions from a specified branch', async () => {
  const f = fixture(); f.context.eventName = 'workflow_dispatch';
  f.context.payload = {inputs: {pr: '7', workflow_ref: 'ci/fix'}};
  await start(f);
  assert.deepEqual(f.dispatches.map(d => d.ref), ['ci/fix', 'ci/fix']);
});

for (const [name, mutate] of [
  ['title edit', f => {f.context.payload.changes = {title: {from: 'old'}};}],
  ['description edit', f => {f.context.payload.changes = {body: {from: 'old'}};}],
  ['draft', f => {f.context.payload.pull_request.draft = true;}],
  ['fork', f => {f.context.payload.pull_request.head.repo.full_name = 'fork/repo';}],
  ['non-master target', f => {f.context.payload.pull_request.base.ref = 'parent';}],
  ['changed head', f => {f.pr.head.sha = 'd'.repeat(40);}],
]) test(`${name} creates no checks and dispatches no tests`, async () => {
  const f = fixture(); mutate(f); await start(f);
  assert.equal(f.checks.size, 0); assert.equal(f.dispatches.length, 0);
});

test('waits for a verified merge candidate instead of testing a moving ref', async () => {
  const f = fixture(); let reads = 0;
  f.github.rest.git.getCommit = async () => ({data: ++reads === 1 ? {parents: [{sha: 'd'.repeat(40)}, {sha: HEAD}]} : f.commits});
  await start(f); assert.equal(reads, 2); assert.equal(f.dispatches.length, 2);
});

test('merge conflicts complete both checks with failure', async () => {
  const f = fixture(); f.pr.mergeable = false; await start(f);
  assert.equal(f.dispatches.length, 0);
  assert.deepEqual([...f.checks.values()].map(c => c.conclusion), ['failure', 'failure']);
  assert.equal(f.failures.length, 1);
});

test('an unverifiable merge candidate never dispatches tests', async () => {
  const f = fixture(); f.commits.parents[1].sha = 'd'.repeat(40); await start(f);
  assert.equal(f.dispatches.length, 0); assert.equal(f.failures.length, 1);
  assert.equal(f.checks.get(1).conclusion, 'failure');
});

test('one dispatch failure fails only that check and still starts the other suite', async () => {
  const f = fixture();
  f.github.rest.actions.createWorkflowDispatch = async value => {if (value.workflow_id === 'e2e-tests.yml') throw new Error('disabled'); f.dispatches.push(value);};
  await start(f);
  assert.equal(f.checks.get(1).conclusion, 'failure');
  assert.equal(f.checks.get(2).status, 'queued');
  assert.equal(f.dispatches[0].workflow_id, 'integration-tests.yml');
});

for (const [result, conclusion] of [['success', 'success'], ['failure', 'failure'], ['cancelled', 'failure'], ['skipped', 'failure'], [undefined, 'failure']]) {
  test(`completed ${result} maps to ${conclusion} and links to the actual test run`, async () => {
    const f = await start(fixture()); f.context.runId = 300;
    await report(f, {result});
    assert.equal(f.checks.get(1).conclusion, conclusion);
    assert.equal(f.checks.get(1).details_url, 'https://github.com/owner/repo/actions/runs/300');
  });
}

test('a partial rerun can mark the same check in progress and publish its new result', async () => {
  const f = await start(fixture());
  await report(f, {result: 'failure'});
  await report(f, {phase: 'start'});
  assert.equal(f.checks.get(1).status, 'in_progress');
  await report(f);
  assert.equal(f.checks.get(1).conclusion, 'success');
});

test('an older reporter racing with a newer retarget updates only its own check ID', async () => {
  const f = await start(fixture());
  const get = f.github.rest.checks.get;
  f.github.rest.checks.get = async value => {
    const old = await get(value);
    f.context.runId = 201;
    await start(f);
    return old;
  };
  await report(f);
  assert.equal(f.checks.get(1).conclusion, 'success');
  assert.equal(f.checks.get(3).status, 'queued');
  assert.equal(f.checks.get(3).conclusion, undefined);
  assert.equal(f.checks.get(4).status, 'queued');
});

for (const [name, mutate] of [
  ['head changed', f => {f.pr.head.sha = 'd'.repeat(40);}],
  ['base changed away', f => {f.pr.base.ref = 'parent';}],
  ['PR closed', f => {f.pr.state = 'closed';}],
]) test(`${name} prevents reporting an old result`, async () => {
  const f = await start(fixture()); mutate(f);
  await report(f); assert.equal(f.checks.get(1).status, 'queued');
});

test('reporter rejects a merge commit that did not test the reported head', async () => {
  const f = await start(fixture()); f.commits.parents[1].sha = 'd'.repeat(40);
  await assert.rejects(report(f), /does not contain/);
});

test('reporter cannot update the check owned by another generation or suite', async () => {
  const f = await start(fixture());
  await assert.rejects(report(f, {inputs: inputs(2)}), /does not belong/);
  await assert.rejects(report(f, {inputs: inputs(1, '201-1')}), /does not belong/);
});

test('normal runs produce no retarget checks', async () => {
  const f = fixture(); await report(f, {inputs: {}}); assert.equal(f.checks.size, 0);
});
