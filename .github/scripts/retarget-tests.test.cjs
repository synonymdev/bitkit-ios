const test = require('node:test');
const assert = require('node:assert/strict');
const {dispatchRetargetTests, reportRetargetResult, e2eRetargetResult} = require('./retarget-tests.cjs');
const {executionFixture} = require('./test-fixtures/retarget-execution.cjs');

const HEAD = 'a'.repeat(40);
const BASE = 'b'.repeat(40);
const MERGE = 'c'.repeat(40);
const E2E = 'e2e-status';
const INTEGRATION = 'Run Integration Tests';
const inputs = (id = 1, generation = '200-1') => ({RETARGET_CHECK_RUN_ID: String(id), RETARGET_RUN: generation, RETARGET_HEAD_SHA: HEAD, RETARGET_MERGE_COMMIT: MERGE, RETARGET_PR: '7'});

function fixture() {
  const execution = executionFixture();
  const pr = {number: 7, state: 'open', draft: false, head: {sha: HEAD, ref: 'feature', repo: {full_name: 'owner/repo'}}, base: {sha: BASE, ref: 'master'}, mergeable: true, merge_commit_sha: MERGE};
  const context = {repo: {owner: 'owner', repo: 'repo'}, eventName: 'pull_request', runId: 200, serverUrl: 'https://github.com', payload: {changes: {base: {}}, pull_request: structuredClone(pr)}};
  const checks = new Map();
  const dispatches = [];
  const failures = [];
  const commits = {parents: [{sha: BASE}, {sha: HEAD}]};
  const rest = {
    pulls: {get: async () => ({data: pr})},
    git: {...execution.github.rest.git, getCommit: async () => ({data: commits})},
    repos: {...execution.github.rest.repos, compareCommits: async ({base, head}) => {
      assert.equal(head, 'master');
      return {data: {status: base === BASE ? 'identical' : 'diverged'}};
    }},
    checks: {
      create: async value => {const check = {id: checks.size + 1, ...value}; checks.set(check.id, check); return {data: check};},
      get: async value => ({data: checks.get(value.check_run_id)}),
      update: async value => {
        const check = checks.get(value.check_run_id);
        if (check.status === 'completed' && value.status !== 'completed') throw new Error('Completed check cannot reopen');
        Object.assign(check, value);
      },
    },
    actions: {createWorkflowDispatch: async value => {dispatches.push(value);}},
  };
  const github = {rest, graphql: execution.github.graphql};
  const core = {setFailed: value => failures.push(value), info: () => {}};
  return {pr, context, checks, dispatches, failures, commits, github, core, execution, attempt: '1', sleep: async () => {}};
}
const start = async f => {await dispatchRetargetTests(f); return f;};

function report(f, options = {}) {
  return reportRetargetResult({...f, name: E2E, phase: 'complete', result: 'success', inputs: inputs(), ...options});
}

test('retarget creates canonical queued checks and dispatches a pinned merge with each check ID', async () => {
  const f = await start(fixture());
  assert.deepEqual([...f.checks.values()].map(c => [c.name, c.status]), [[E2E, 'queued'], [INTEGRATION, 'queued']]);
  assert.deepEqual(f.dispatches.map(d => d.workflow_id), ['e2e-tests.yml', 'integration-tests.yml']);
  for (const [index, dispatch] of f.dispatches.entries()) assert.deepEqual(dispatch.inputs, {pr: '7', merge_commit: MERGE, head_sha: HEAD, retarget_run: '200-1', check_run_id: String(index + 1), workflow_ref: f.execution.SOURCE, helper_ref: 'master', ...(index === 0 ? {app_branch: 'feature'} : {})});
  assert.deepEqual(f.dispatches.map(d => d.ref), ['ci/retarget-execution/pr-7-200-1', 'ci/retarget-execution/pr-7-200-1']);
  assert.deepEqual(f.failures, []);
});

test('manual recovery can validate a PR with workflow definitions from a specified branch', async () => {
  const f = fixture(); f.context.eventName = 'workflow_dispatch';
  f.context.ref = 'refs/heads/ci/fix';
  f.context.payload = {inputs: {pr: '7', workflow_ref: 'ci/fix'}};
  await start(f);
  assert.ok(f.dispatches.every(d => d.ref === 'ci/retarget-execution/pr-7-200-1' && d.inputs.workflow_ref === f.execution.SOURCE && d.inputs.helper_ref === 'ci/fix'));
});

test('a later helper attempt owns distinct checks that its reporter can complete', async () => {
  const f = fixture(); f.attempt = '2'; await start(f);
  assert.deepEqual(f.dispatches.map(d => d.inputs.retarget_run), ['200-2', '200-2']);
  assert.equal(f.checks.get(1).external_id, 'retarget:200-2:e2e-status');
  await report(f, {inputs: inputs(1, '200-2')});
  assert.equal(f.checks.get(1).conclusion, 'success');
  await assert.rejects(report(f, {inputs: inputs(1, '200-1')}), /does not belong/);
});

for (const status of ['identical', 'ahead']) test(`stale PR base metadata permits a merge based on master history (${status})`, async () => {
  const f = fixture();
  f.pr.base.sha = 'd'.repeat(40);
  f.github.rest.repos.compareCommits = async ({base, head}) => {
    assert.equal(base, BASE); assert.equal(head, 'master');
    return {data: {status}};
  };
  await start(f);
  assert.equal(f.dispatches.length, 2);
  assert.ok(f.dispatches.every(d => d.inputs.merge_commit === MERGE));
  assert.deepEqual(f.failures, []);
});

for (const status of ['behind', 'diverged']) test(`a merge base outside current master history (${status}) is rejected`, async () => {
  const f = fixture();
  f.github.rest.repos.compareCommits = async () => ({data: {status}});
  await start(f);
  assert.equal(f.dispatches.length, 0);
  assert.deepEqual([...f.checks.values()].map(c => c.conclusion), ['failure', 'failure']);
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
    assert.ok(f.checks.get(1).output.summary.includes('[Open the test run](https://github.com/owner/repo/actions/runs/300)'));
  });
}

test('rerunning a completed suite requests fresh validation instead of reopening or creating checks inline', async () => {
  const f = await start(fixture());
  await report(f, {result: 'failure'});
  await report(f, {phase: 'start'});
  assert.equal(f.checks.get(1).conclusion, 'failure');
  assert.equal(f.checks.size, 2);
  assert.equal(f.dispatches[2].workflow_id, 'e2e-retarget.yml');
  assert.deepEqual(f.dispatches[2].inputs, {pr: '7', workflow_ref: 'master', suite: 'e2e'});
  assert.equal(f.failures.length, 1);
  await report(f);
  assert.equal(f.checks.get(1).conclusion, 'failure');
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

for (const [suite, name, id, otherId] of [['e2e', E2E, 1, 2], ['integration', INTEGRATION, 2, 1]]) {
  test(`recovering ${suite} preserves the other suite's completed check`, async () => {
    const f = await start(fixture());
    await report(f, {name: otherId === 1 ? E2E : INTEGRATION, inputs: inputs(otherId)});
    await report(f, {name, inputs: inputs(id), result: 'failure'});
    await report(f, {name, inputs: inputs(id), phase: 'start'});
    assert.equal(f.dispatches[2].inputs.suite, suite);
    f.context.eventName = 'workflow_dispatch'; f.context.runId = 201;
    f.context.payload = {inputs: {pr: '7', suite}};
    await start(f);
    assert.equal(f.checks.size, 3);
    assert.equal(f.checks.get(3).name, name);
    assert.equal(f.checks.get(otherId).conclusion, 'success');
    assert.equal(f.dispatches.length, 4);
    assert.equal(f.dispatches[3].workflow_id, suite === 'e2e' ? 'e2e-tests.yml' : 'integration-tests.yml');
  });
}

for (const [reason, mutate] of [
  ['draft', f => {f.pr.draft = true;}],
  ['fork', f => {f.pr.head.repo.full_name = 'fork/repo';}],
  ['other base', f => {f.pr.base.ref = 'parent';}],
  ['closed', f => {f.pr.state = 'closed';}],
  ['changed head', f => {
    const original = structuredClone(f.pr); let reads = 0;
    f.pr.head.sha = 'd'.repeat(40);
    f.github.rest.pulls.get = async () => ({data: reads++ === 0 ? original : f.pr});
  }],
]) test(`manual recovery explains an ineligible PR (${reason})`, async () => {
  const f = fixture(); f.context.eventName = 'workflow_dispatch';
  f.context.payload = {inputs: {pr: '7'}}; mutate(f); await start(f);
  assert.equal(f.dispatches.length, 0); assert.equal(f.checks.size, 0);
  assert.match(f.failures[0], /Manual recovery/);
});

test('unknown manual suites fail before creating checks', async () => {
  const f = fixture(); f.context.eventName = 'workflow_dispatch';
  f.context.payload = {inputs: {pr: '7', suite: 'typo'}};
  await assert.rejects(start(f), /Unknown retarget test suite/);
  assert.equal(f.checks.size, 0);
});

test('docs-only retargets report not required, while filter errors and failed code runs fail closed', () => {
  const jobs = {'detect-changes': {result: 'success', outputs: {code: 'false'}}, 'e2e-status': {result: 'success'}, 'build-local': {result: 'skipped'}};
  assert.equal(e2eRetargetResult(jobs), 'not_required');
  jobs['detect-changes'].result = 'failure';
  assert.equal(e2eRetargetResult(jobs), 'failure');
  jobs['detect-changes'].result = 'success'; jobs['detect-changes'].outputs.code = 'true';
  assert.equal(e2eRetargetResult(jobs), 'failure');
  jobs['build-local'].result = 'success';
  assert.equal(e2eRetargetResult(jobs), 'success');
  jobs['e2e-status'].result = 'failure'; jobs['detect-changes'].outputs.code = 'false';
  assert.equal(e2eRetargetResult(jobs), 'failure');
});

test('only E2E can report not required, with an explicit check explanation', async () => {
  const f = await start(fixture());
  await report(f, {result: 'not_required'});
  assert.equal(f.checks.get(1).conclusion, 'success');
  assert.equal(f.checks.get(1).output.title, 'No E2E code changes');
  await report(f, {name: INTEGRATION, inputs: inputs(2), result: 'not_required'});
  assert.equal(f.checks.get(2).conclusion, 'failure');
});

test('retry recovery uses the stable source, never the disposable execution ref', async () => {
  const f = await start(fixture());
  f.context.ref = 'refs/heads/ci/retarget-execution/pr-7-200-1';
  await report(f, {result: 'failure'});
  await report(f, {phase: 'start', inputs: {...inputs(), RETARGET_WORKFLOW_REF: f.execution.SOURCE, RETARGET_HELPER_REF: 'ci/fix'}});
  assert.equal(f.dispatches[2].ref, 'ci/fix');
  assert.deepEqual(f.dispatches[2].inputs, {pr: '7', workflow_ref: f.execution.SOURCE, suite: 'e2e'});
});

test('unsigned execution preparation fails both PR checks and never dispatches tests on master', async () => {
  const f = fixture(); const request = f.github.graphql;
  f.github.graphql = async (query, variables) => {
    const result = await request(query, variables);
    if (query.includes('createCommitOnBranch')) f.execution.commits.get(result.createCommitOnBranch.commit.oid).commit.verification.verified = false;
    return result;
  };
  await start(f);
  assert.equal(f.dispatches.length, 0);
  assert.deepEqual([...f.checks.values()].map(c => c.conclusion), ['failure', 'failure']);
});

for (const [suite, name, id, otherId] of [['e2e', E2E, 1, 2], ['integration', INTEGRATION, 2, 1]]) {
  for (const status of [404, 422]) test(`a deleted helper (${status}) recovers only ${suite} on master with the pinned workflow source`, async () => {
    const f = await start(fixture());
    await report(f, {name: otherId === 1 ? E2E : INTEGRATION, inputs: inputs(otherId)});
    const other = structuredClone(f.checks.get(otherId));
    await report(f, {name, inputs: inputs(id), result: 'failure'});
    const getCommit = f.github.rest.repos.getCommit;
    f.github.rest.repos.getCommit = async value => {
      if (value.ref === 'deleted-branch' && status === 404) throw Object.assign(new Error('Not found'), {status});
      return getCommit(value);
    };
    await report(f, {name, phase: 'start', inputs: {...inputs(id), RETARGET_WORKFLOW_REF: f.execution.SOURCE, RETARGET_HELPER_REF: 'deleted-branch'}});
    assert.equal(f.dispatches[2].ref, 'master');
    assert.deepEqual(f.dispatches[2].inputs, {pr: '7', workflow_ref: f.execution.SOURCE, suite});
    assert.equal(f.checks.get(id).conclusion, 'failure');
    assert.deepEqual(f.checks.get(otherId), other);
    assert.equal(f.checks.size, 2);
  });
}

for (const status of [403, 429, 500]) test(`helper lookup failure (${status}) does not silently dispatch recovery on master`, async () => {
  const f = await start(fixture());
  await report(f, {result: 'failure'});
  f.github.rest.repos.getCommit = async () => {throw Object.assign(new Error('Lookup failed'), {status});};
  await assert.rejects(report(f, {phase: 'start'}), error => error.status === status);
  assert.equal(f.dispatches.length, 2);
  assert.equal(f.checks.get(1).conclusion, 'failure');
});
