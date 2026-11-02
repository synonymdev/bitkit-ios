const test = require('node:test');
const assert = require('node:assert/strict');
const {prepareExecutionRef, cleanupExecutionRefs} = require('./retarget-execution.cjs');
const {executionFixture} = require('./test-fixtures/retarget-execution.cjs');

function fixture() {
  const f = executionFixture();
  const warnings = [], messages = [];
  return {...f, context: {repo: {owner: 'owner', repo: 'repo'}}, number: 7, generation: '200-1', sourceRef: 'master',
    core: {warning: value => warnings.push(value), info: value => messages.push(value)}, warnings, messages, now: Date.parse('2026-12-05T00:00:00Z')};
}

test('execution uses a distinct verified commit with the trusted workflow tree and parent', async () => {
  const f = fixture(); const result = await prepareExecutionRef(f);
  assert.equal(result.ref, 'ci/retarget-execution/pr-7-200-1');
  assert.notEqual(result.sha, f.SOURCE);
  const commit = f.commits.get(result.sha);
  assert.deepEqual(commit.parents, [{sha: f.SOURCE}]);
  assert.equal(commit.commit.tree.sha, f.TREE);
  assert.equal(commit.commit.verification.verified, true);
  assert.equal(commit.author.login, 'github-actions[bot]');
  assert.deepEqual(f.mutations[0].fileChanges, {additions: [], deletions: []});
});

test('an existing generation is reconciled without appending another execution commit', async () => {
  const f = fixture(); const first = await prepareExecutionRef(f);
  assert.deepEqual(await prepareExecutionRef(f), first);
  assert.equal(f.mutations.length, 1);
});

test('reconciliation retains its original snapshot after the source branch moves', async () => {
  const f = fixture(); const first = await prepareExecutionRef(f);
  const newer = 'd'.repeat(40);
  f.commits.set(newer, {sha: newer, commit: {tree: {sha: 'c'.repeat(40)}}});
  f.aliases.set('master', newer);
  assert.deepEqual(await prepareExecutionRef(f), first);
  assert.equal(f.mutations.length, 1);
});

test('a lost mutation response reconciles its signed commit instead of duplicating it', async () => {
  const f = fixture(); const request = f.github.graphql;
  f.github.graphql = async (query, variables) => {
    const result = await request(query, variables);
    if (query.includes('createCommitOnBranch')) throw new Error('Response lost');
    return result;
  };
  const result = await prepareExecutionRef(f);
  assert.ok(f.commits.has(result.sha)); assert.equal(f.mutations.length, 1);
});

test('a rejected mutation removes only its untouched preparation ref and never falls back unsigned', async () => {
  const f = fixture(); const request = f.github.graphql;
  f.github.graphql = (query, variables) => {
    if (query.includes('createCommitOnBranch')) throw new Error('Not supported');
    return request(query, variables);
  };
  await assert.rejects(prepareExecutionRef(f), /Not supported/);
  assert.equal(f.refs.size, 0); assert.equal(f.mutations.length, 0);
});

for (const [name, mutate] of [
  ['signature', c => {c.commit.verification.verified = false;}],
  ['author', c => {c.author.login = 'other';}],
  ['tree', c => {c.commit.tree.sha = 'd'.repeat(40);}],
  ['parent', c => {c.parents[0].sha = 'd'.repeat(40);}],
  ['metadata', c => {c.commit.message = 'unrelated commit';}],
]) test(`a mismatched ${name} cannot be used as an execution snapshot`, async () => {
  const f = fixture(); const result = await prepareExecutionRef(f);
  mutate(f.commits.get(result.sha));
  await assert.rejects(prepareExecutionRef(f), /did not verify/);
  assert.equal(f.mutations.length, 1);
});

test('execution source cannot be another disposable execution ref', async () => {
  for (const sourceRef of ['ci/retarget-execution/pr-7-200-1', 'refs/heads/ci/retarget-execution/pr-7-200-1']) {
    await assert.rejects(prepareExecutionRef({...fixture(), sourceRef}), /Invalid execution source/);
  }
});

test('cleanup expires only verified, owned snapshots after the rerun window', async () => {
  const f = fixture(); const result = await prepareExecutionRef(f);
  await cleanupExecutionRefs({...f, now: Date.parse('2026-11-28T00:00:00Z')});
  assert.equal(f.deleted.length, 0);
  await cleanupExecutionRefs(f);
  assert.deepEqual(f.deleted, [`heads/${result.ref}`]);
});

for (const status of ['queued', 'in_progress', 'waiting', 'pending']) test(`cleanup retains an expired ref with ${status} execution`, async () => {
  const f = fixture(); await prepareExecutionRef(f);
  f.github.rest.actions.listWorkflowRunsForRepo = async () => ({data: {total_count: 1, workflow_runs: [{status}]}});
  await cleanupExecutionRefs(f); assert.equal(f.deleted.length, 0);
});

test('cleanup retains refs whose helper is active or whose run listing is incomplete', async () => {
  const f = fixture(); await prepareExecutionRef(f);
  f.github.rest.actions.getWorkflowRun = async () => ({data: {status: 'in_progress'}});
  await cleanupExecutionRefs(f); assert.equal(f.deleted.length, 0);
  f.github.rest.actions.listWorkflowRunsForRepo = async () => ({data: {total_count: 101, workflow_runs: []}});
  await cleanupExecutionRefs(f); assert.equal(f.deleted.length, 0);
});

test('cleanup refuses changed refs, foreign metadata and unsigned commits', async () => {
  const f = fixture(); const result = await prepareExecutionRef(f);
  const commit = f.commits.get(result.sha);
  commit.commit.verification.verified = false;
  await cleanupExecutionRefs(f); assert.equal(f.deleted.length, 0);
  commit.commit.verification.verified = true;
  const original = commit.commit.message; commit.commit.message = 'foreign';
  await cleanupExecutionRefs(f); assert.equal(f.deleted.length, 0);
  commit.commit.message = original;
  const get = f.github.rest.git.getRef;
  f.github.rest.git.getRef = async params => ({data: {...(await get(params)).data, object: {sha: f.SOURCE}}});
  await cleanupExecutionRefs(f); assert.equal(f.deleted.length, 0);
});

test('retained preparation refs cannot starve a later expired execution', async () => {
  const f = fixture();
  for (let index = 0; index < 100; index++) f.refs.set(`heads/ci/retarget-execution/pr-7-${index + 1000}-1`, f.SOURCE);
  const result = await prepareExecutionRef(f);
  await cleanupExecutionRefs(f);
  assert.deepEqual(f.deleted, [`heads/${result.ref}`]);
  assert.equal(f.refs.size, 100);
});

test('cleanup bounds deletions and makes progress on the next run', async () => {
  const f = fixture();
  for (let index = 0; index < 101; index++) await prepareExecutionRef({...f, generation: `${index + 200}-1`});
  await cleanupExecutionRefs(f); assert.equal(f.deleted.length, 100); assert.equal(f.refs.size, 1);
  await cleanupExecutionRefs(f); assert.equal(f.deleted.length, 101); assert.equal(f.refs.size, 0);
});
