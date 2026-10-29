const CHECKS = [
  {suite: 'e2e', workflow: 'e2e-tests.yml', context: 'e2e-status'},
  {suite: 'integration', workflow: 'integration-tests.yml', context: 'Run Integration Tests'},
];
const runUrl = context => `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
const externalId = (generation, name) => `retarget:${generation}:${name}`;
const {prepareExecutionRef} = require('./retarget-execution.cjs');

function e2eRetargetResult(jobs) {
  if (jobs['detect-changes'].result !== 'success' || jobs['e2e-status'].result !== 'success') return 'failure';
  if (jobs['detect-changes'].outputs.code === 'false') return 'not_required';
  return Object.values(jobs).every(job => job.result === 'success') ? 'success' : 'failure';
}

async function dispatchRetargetTests({github, context, core, attempt = process.env.GITHUB_RUN_ATTEMPT || '1', sleep = ms => new Promise(resolve => setTimeout(resolve, ms))}) {
  const event = context.payload;
  const manual = context.eventName === 'workflow_dispatch';
  const suite = manual && event.inputs?.suite || 'all';
  if (!['all', ...CHECKS.map(check => check.suite)].includes(suite)) throw new Error('Unknown retarget test suite');
  const selected = CHECKS.filter(check => suite === 'all' || check.suite === suite);
  let original = event.pull_request;
  if (manual) {
    if (!/^\d+$/.test(event.inputs?.pr || '')) throw new Error('A PR number is required');
    ({data: original} = await github.rest.pulls.get({...context.repo, pull_number: Number(event.inputs.pr)}));
  }
  if ((!manual && !event.changes?.base) || original?.draft || original?.base.ref !== 'master' || original?.head.repo.full_name !== `${context.repo.owner}/${context.repo.repo}`) {
    if (manual) core.setFailed('Manual recovery requires a ready, same-repository PR targeting master');
    return;
  }
  const generation = `${context.runId}-${attempt}`;
  const {data: current} = await github.rest.pulls.get({...context.repo, pull_number: original.number});
  if (current.state !== 'open' || current.head.sha !== original.head.sha || current.base.ref !== 'master' || current.draft) {
    if (manual) core.setFailed('Manual recovery PR is closed, changed revision, draft, or no longer targets master');
    return;
  }
  const sha = current.head.sha;
  const checks = new Map();
  try {
    for (const check of selected) {
      const {data} = await github.rest.checks.create({
        ...context.repo, name: check.context, head_sha: sha,
        external_id: externalId(generation, check.context), status: 'queued', details_url: runUrl(context),
        output: {title: 'Waiting for retarget validation', summary: `[Retarget dispatcher](${runUrl(context)}) is starting tests for PR #${original.number} at ${sha}.`},
      });
      checks.set(check.context, data.id);
    }
    let merge;
    for (let attempt = 0; attempt < 10; attempt++) {
      const {data: pr} = await github.rest.pulls.get({...context.repo, pull_number: original.number});
      if (pr.state !== 'open' || pr.draft || pr.head.sha !== sha || pr.base.ref !== 'master') throw new Error('PR changed before test dispatch');
      if (pr.mergeable === false) throw new Error('PR has merge conflicts');
      if (pr.merge_commit_sha) {
        const {data: commit} = await github.rest.git.getCommit({...context.repo, commit_sha: pr.merge_commit_sha});
        if (commit.parents.length === 2 && commit.parents[1].sha === sha) {
          // PR base.sha can lag both its merge candidate and the current master tip.
          const {data: comparison} = await github.rest.repos.compareCommits({
            ...context.repo, base: commit.parents[0].sha, head: 'master',
          });
          if (['identical', 'ahead'].includes(comparison.status)) {
            merge = pr.merge_commit_sha;
            break;
          }
        }
      }
      await sleep(2000);
    }
    if (!merge) throw new Error('No verified PR merge commit is available');
    const execution = await prepareExecutionRef({github, context, number: original.number, generation,
      sourceRef: manual && event.inputs.workflow_ref || 'master'});
    const helperRef = manual ? context.ref?.replace(/^refs\/(heads|tags)\//, '') || 'master' : 'master';
    for (const check of selected) {
      try {
        await github.rest.actions.createWorkflowDispatch({
          ...context.repo, workflow_id: check.workflow, ref: execution.ref,
          inputs: {pr: String(original.number), merge_commit: merge, head_sha: sha, retarget_run: generation, check_run_id: String(checks.get(check.context)), workflow_ref: execution.sourceSha, helper_ref: helperRef, ...(check.workflow === 'e2e-tests.yml' ? {app_branch: current.head.ref} : {})},
        });
      } catch (error) {
        await github.rest.checks.update({
          ...context.repo, check_run_id: checks.get(check.context), status: 'completed', conclusion: 'failure',
          output: {title: 'Could not start tests', summary: error.message},
        });
        core.setFailed(`Could not dispatch ${check.workflow}: ${error.message}`);
      }
    }
  } catch (error) {
    for (const id of checks.values()) await github.rest.checks.update({
      ...context.repo, check_run_id: id, status: 'completed', conclusion: 'failure',
      output: {title: 'Could not start retarget validation', summary: error.message},
    });
    core.setFailed(error.message);
  }
}

async function reportRetargetResult({github, context, core, name, phase, result, inputs = process.env}) {
  const generation = inputs.RETARGET_RUN;
  if (!generation) return;
  const sha = inputs.RETARGET_HEAD_SHA;
  const merge = inputs.RETARGET_MERGE_COMMIT;
  const number = inputs.RETARGET_PR;
  const id = inputs.RETARGET_CHECK_RUN_ID;
  if (!/^\d+-\d+$/.test(generation) || !/^\d+$/.test(number || '') || !/^\d+$/.test(id || '') || !/^[0-9a-f]{40}$/.test(sha || '') || !/^[0-9a-f]{40}$/.test(merge || '') || !CHECKS.some(check => check.context === name)) throw new Error('Invalid retarget reporting inputs');
  const {data: pr} = await github.rest.pulls.get({...context.repo, pull_number: Number(number)});
  if (pr.state !== 'open' || pr.head.sha !== sha || pr.base.ref !== 'master') {
    core.info('Ignoring a result for a superseded PR revision');
    return;
  }
  const {data: commit} = await github.rest.git.getCommit({...context.repo, commit_sha: merge});
  if (commit.parents.length !== 2 || commit.parents[1].sha !== sha) throw new Error('Test merge commit does not contain the reported PR head');
  const {data: check} = await github.rest.checks.get({...context.repo, check_run_id: Number(id)});
  if (check.head_sha !== sha || check.name !== name || check.external_id !== externalId(generation, name)) throw new Error('Check does not belong to this retarget validation');
  if (check.status === 'completed') {
    if (phase === 'start') {
      // Completed checks cannot reopen; the helper owns creation of fresh checks.
      const workflowRef = inputs.RETARGET_WORKFLOW_REF || 'master';
      let helperRef = inputs.RETARGET_HELPER_REF || 'master';
      if (helperRef.replace(/^refs\/heads\//, '').startsWith('ci/retarget-execution/')) throw new Error('Recovery helper cannot use an execution ref');
      try {
        await github.rest.repos.getCommit({...context.repo, ref: helperRef});
      } catch (error) {
        if (error.status !== 404) throw error;
        helperRef = 'master';
      }
      await github.rest.actions.createWorkflowDispatch({
        ...context.repo, workflow_id: 'e2e-retarget.yml', ref: helperRef,
        inputs: {pr: number, workflow_ref: workflowRef, suite: CHECKS.find(check => check.context === name).suite},
      });
      core.setFailed('Started a fresh retarget validation; completed checks cannot be reopened.');
    }
    return;
  }
  const start = phase === 'start';
  const notRequired = name === 'e2e-status' && result === 'not_required';
  const success = result === 'success' || notRequired;
  await github.rest.checks.update({
    ...context.repo, check_run_id: Number(id), details_url: runUrl(context),
    status: start ? 'in_progress' : 'completed',
    ...(start ? {} : {conclusion: success ? 'success' : 'failure'}),
    output: {title: start ? 'Tests are running' : notRequired ? 'No E2E code changes' : success ? 'Tests passed' : 'Tests failed or did not complete', summary: `[Open the test run](${runUrl(context)}).\n\nPR #${number}, head ${sha}, merge ${merge}.`},
  });
}

module.exports = {dispatchRetargetTests, reportRetargetResult, e2eRetargetResult};
