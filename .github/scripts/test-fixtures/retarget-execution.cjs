const SOURCE = 'f'.repeat(40);
const TREE = 'e'.repeat(40);

function executionFixture() {
  const owner = 'github-actions[bot]';
  const refs = new Map();
  const commits = new Map([[SOURCE, {sha: SOURCE, commit: {tree: {sha: TREE}, message: 'Workflow source', committer: {date: '2026-10-29T00:00:00Z'}}}]]);
  const aliases = new Map([['master', SOURCE], ['ci/fix', SOURCE]]);
  const mutations = [];
  const deleted = [];
  const missing = () => Object.assign(new Error('Not found'), {status: 404});
  const git = {
    getRef: async ({ref}) => {
      if (!refs.has(ref)) throw missing();
      return {data: {ref: `refs/${ref}`, object: {sha: refs.get(ref), type: 'commit'}}};
    },
    createRef: async ({ref, sha}) => {
      const key = ref.replace(/^refs\//, '');
      if (refs.has(key)) throw Object.assign(new Error('Exists'), {status: 422});
      refs.set(key, sha);
      return git.getRef({ref: key});
    },
    listMatchingRefs: async ({ref}) => ({data: [...refs].filter(([key]) => key.startsWith(ref)).map(([key, sha]) => ({ref: `refs/${key}`, object: {sha, type: 'commit'}}))}),
    deleteRef: async ({ref}) => {deleted.push(ref); refs.delete(ref);},
  };
  const repos = {getCommit: async ({ref}) => {
    const sha = aliases.get(ref) || refs.get(`heads/${ref}`) || ref;
    if (!commits.has(sha)) throw Object.assign(new Error(`No commit found for SHA: ${ref}`), {status: 422});
    return {data: structuredClone(commits.get(sha))};
  }};
  const graphql = async (query, variables) => {
    if (!query.includes('createCommitOnBranch')) return {viewer: {login: owner}};
    const input = variables.input;
    const key = `heads/${input.branch.branchName}`;
    if (refs.get(key) !== input.expectedHeadOid) throw Object.assign(new Error('Head changed'), {status: 422});
    mutations.push(input);
    const sha = mutations.length.toString(16).padStart(40, '0');
    commits.set(sha, {sha, author: {login: owner}, parents: [{sha: input.expectedHeadOid}], commit: {
      tree: {sha: commits.get(input.expectedHeadOid).commit.tree.sha}, verification: {verified: true, reason: 'valid'},
      message: `${input.message.headline}\n\n${input.message.body}`, committer: {date: '2026-10-29T00:00:00Z'},
    }});
    refs.set(key, sha);
    return {createCommitOnBranch: {commit: {oid: sha}}};
  };
  const actions = {listWorkflowRunsForRepo: async () => ({data: {total_count: 0, workflow_runs: []}}), getWorkflowRun: async () => ({data: {status: 'completed'}})};
  const github = {rest: {git, repos, actions}, graphql, paginate: async (method, params) => (await method(params)).data};
  return {github, refs, commits, mutations, deleted, aliases, SOURCE, TREE};
}

module.exports = {executionFixture};
