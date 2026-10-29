const PREFIX = 'ci/retarget-execution/';
const KIND = 'bitkit-retarget-execution-v1';
const SHA = /^[0-9a-f]{40}$/;
const ownedRef = /^refs\/heads\/ci\/retarget-execution\/pr-(\d+)-(\d+)-(\d+)$/;

async function readRef(github, repo, branch) {
  try {
    return (await github.rest.git.getRef({...repo, ref: `heads/${branch}`})).data;
  } catch (error) {
    if (error.status === 404) return null;
    throw error;
  }
}

function metadata(commit) {
  try {
    return JSON.parse(commit.commit.message.split('\n\n').slice(1).join('\n\n'));
  } catch {
    return null;
  }
}

function verify(commit, expected, tree) {
  const recorded = metadata(commit);
  if (!SHA.test(commit.sha || '') || commit.parents?.length !== 1 || commit.parents[0].sha !== expected.sourceSha ||
      commit.commit.tree.sha !== tree || !commit.commit.verification?.verified || commit.commit.verification.reason !== 'valid' ||
      commit.author?.login !== expected.owner || JSON.stringify(recorded) !== JSON.stringify(expected)) {
    throw new Error('Execution commit identity, signature, metadata, parent or tree did not verify');
  }
}

async function prepareExecutionRef({github, context, number, generation, sourceRef}) {
  if (!/^\d+-\d+$/.test(generation) || !/^\d+$/.test(String(number)) || !sourceRef || sourceRef.replace(/^refs\/heads\//, '').startsWith(PREFIX)) throw new Error('Invalid execution source or generation');
  const {viewer} = await github.graphql('query { viewer { login } }');
  const branch = `${PREFIX}pr-${number}-${generation}`;
  let ref = await readRef(github, context.repo, branch);
  if (ref) {
    const {data: existing} = await github.rest.repos.getCommit({...context.repo, ref: ref.object.sha});
    const recorded = metadata(existing);
    if (recorded?.kind === KIND && recorded.repository === `${context.repo.owner}/${context.repo.repo}` && recorded.pr === Number(number) &&
        recorded.generation === generation && recorded.sourceRef === sourceRef && recorded.owner === viewer.login && SHA.test(recorded.sourceSha || '')) {
      const {data: parent} = await github.rest.repos.getCommit({...context.repo, ref: recorded.sourceSha});
      verify(existing, recorded, parent.commit.tree.sha);
      return {ref: branch, sha: existing.sha, sourceSha: recorded.sourceSha};
    }
  }
  const {data: source} = await github.rest.repos.getCommit({...context.repo, ref: sourceRef});
  if (!viewer?.login || !SHA.test(source.sha || '') || !SHA.test(source.commit?.tree?.sha || '')) throw new Error('Could not resolve the workflow source identity');
  const expected = {kind: KIND, repository: `${context.repo.owner}/${context.repo.repo}`, pr: Number(number), generation, sourceSha: source.sha, sourceRef, owner: viewer.login};
  const created = !ref;
  if (!ref) {
    try {
      ({data: ref} = await github.rest.git.createRef({...context.repo, ref: `refs/heads/${branch}`, sha: source.sha}));
    } catch (error) {
      ref = await readRef(github, context.repo, branch);
      if (!ref) throw error;
    }
  }
  if (ref.object.sha === source.sha) {
    try {
      // This API signs as the authenticated GitHub identity; never use unsigned Git database creation.
      await github.graphql(`mutation($input: CreateCommitOnBranchInput!) {
        createCommitOnBranch(input: $input) { commit { oid } }
      }`, {input: {branch: {repositoryNameWithOwner: expected.repository, branchName: branch}, expectedHeadOid: source.sha,
        message: {headline: `ci: isolated retarget validation for PR #${number} [skip ci]`, body: JSON.stringify(expected)}}});
    } catch (error) {
      // A timeout may have committed successfully. Reconcile instead of appending again.
      ref = await readRef(github, context.repo, branch);
      if (!ref || ref.object.sha === source.sha) {
        if (created && ref) {
          try {await github.rest.git.deleteRef({...context.repo, ref: `heads/${branch}`});} catch { /* Retain an uncertain ref for inspection. */ }
        }
        throw error;
      }
    }
  }
  ref = await readRef(github, context.repo, branch);
  if (!ref) throw new Error('Execution ref disappeared before dispatch');
  const {data: execution} = await github.rest.repos.getCommit({...context.repo, ref: ref.object.sha});
  verify(execution, expected, source.commit.tree.sha);
  return {ref: branch, sha: execution.sha, sourceSha: source.sha};
}

async function cleanupExecutionRefs({github, context, core, now = Date.now()}) {
  const {viewer} = await github.graphql('query { viewer { login } }');
  const refs = await github.paginate(github.rest.git.listMatchingRefs, {...context.repo, ref: `heads/${PREFIX}`});
  for (const ref of refs.slice(0, 100)) {
    const match = ownedRef.exec(ref.ref);
    if (!match || ref.object.type !== 'commit') continue;
    try {
      const {data: commit} = await github.rest.repos.getCommit({...context.repo, ref: ref.object.sha});
      const created = Date.parse(commit.commit.committer.date);
      // Actions supports reruns for 30 days. Keep an additional five-day margin.
      if (!Number.isFinite(created) || now - created < 35 * 86400000) continue;
      const recorded = metadata(commit);
      if (recorded?.kind !== KIND || recorded.repository !== `${context.repo.owner}/${context.repo.repo}` ||
          recorded.pr !== Number(match[1]) || recorded.generation !== `${match[2]}-${match[3]}` || recorded.owner !== viewer.login || !SHA.test(recorded.sourceSha || '')) continue;
      const {data: source} = await github.rest.repos.getCommit({...context.repo, ref: recorded.sourceSha});
      verify(commit, recorded, source.commit.tree.sha);
      const branch = ref.ref.slice('refs/heads/'.length);
      const {data: runs} = await github.rest.actions.listWorkflowRunsForRepo({...context.repo, branch, per_page: 100});
      if (runs.total_count > runs.workflow_runs.length || runs.workflow_runs.some(run => run.status !== 'completed')) continue;
      try {
        const {data: helper} = await github.rest.actions.getWorkflowRun({...context.repo, run_id: Number(match[2])});
        if (helper.status !== 'completed') continue;
      } catch (error) {
        if (error.status !== 404) throw error;
      }
      const current = await readRef(github, context.repo, branch);
      if (current?.object.sha !== commit.sha) continue;
      await github.rest.git.deleteRef({...context.repo, ref: `heads/${branch}`});
      core.info(`Removed expired execution ref ${branch}`);
    } catch (error) {
      core.warning(`Kept execution ref ${ref.ref}: ${error.message}`);
    }
  }
}

module.exports = {prepareExecutionRef, cleanupExecutionRefs};
