import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = process.argv[2];
if (!root) throw new Error('repository root is required');
const lines = fs
  .readFileSync(path.join(root, '.github/workflows/attest-manifest-linked-issue.yml'), 'utf8')
  .split('\n');
const step = lines.indexOf('      - name: Validate receipts and publish exact linked-issue check');
const marker = lines.findIndex((line, index) => index > step && line === '          script: |');
if (step < 0 || marker < 0) throw new Error('attestor script not found');
const sourceText = lines
  .slice(marker + 1)
  .filter((line) => line === '' || line.startsWith('            '))
  .map((line) => (line === '' ? line : line.slice(12)))
  .join('\n');
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
const script = new AsyncFunction('github', 'context', 'core', sourceText);
const sha = (character) => character.repeat(40);
const source = sha('a');
const head = sha('b');
const owner = 'f5-sales-demo';
const repo = 'docs-control';
const repoIdentityKey = ['full', 'name'].join('_');

function candidate(overrides = {}) {
  return {
    pull: {
      number: 42,
      state: 'open',
      head: { repo: { [repoIdentityKey]: `${owner}/${repo}` }, ref: `sync/manifest-${source}`, sha: head },
      base: { repo: { [repoIdentityKey]: `${owner}/${repo}` }, ref: 'main' },
      ...overrides.pull,
    },
    main: { protected: true, commit: { sha: source }, ...overrides.main },
    commit: { sha: head, parents: [{ sha: source }], ...overrides.commit },
    commits: overrides.commits ?? [{ sha: head }],
    files: overrides.files ?? [{ filename: '.github/config/managed-files-manifest.json', status: 'modified' }],
  };
}

async function invoke({ state = candidate(), receipts = [], mutateAfterFirst = null, apiError = null } = {}) {
  process.env.PR_NUMBER = '42';
  process.env.EXPECTED_SOURCE_SHA = source;
  process.env.EXPECTED_HEAD_SHA = head;
  process.env.ATTESTOR_RUN_URL = 'https://github.example/actions/runs/7';
  let pullReads = 0;
  const creates = [];
  const infos = [];
  const failures = [];
  const maybeFail = () => {
    if (apiError) throw new Error(apiError);
  };
  const current = () => (pullReads >= 1 && mutateAfterFirst ? mutateAfterFirst : state);
  const github = {
    rest: {
      pulls: {
        get: async () => {
          maybeFail();
          const value = current().pull;
          pullReads += 1;
          return { data: value };
        },
        listCommits: async () => ({ data: current().commits }),
        listFiles: async () => ({ data: current().files }),
      },
      repos: { getBranch: async () => ({ data: current().main }) },
      git: { getCommit: async () => ({ data: current().commit }) },
      checks: {
        listForRef: async () => ({ data: { total_count: receipts.length, check_runs: receipts } }),
        create: async (request) => {
          creates.push(request);
          return { data: request };
        },
      },
    },
  };
  const core = { info: (message) => infos.push(message), setFailed: (message) => failures.push(message) };
  let error;
  try {
    await script(github, { repo: { owner, repo } }, core);
  } catch (caught) {
    error = caught;
  }
  return { creates, infos, failures, error };
}

const externalId = `manifest-receipt:${owner}/${repo}:pr:42:source:${source}:head:${head}`;
const exactReceipt = {
  name: 'Check linked issues',
  external_id: externalId,
  head_sha: head,
  status: 'completed',
  conclusion: 'success',
  app: { slug: 'github-actions' },
};

{
  const result = await invoke();
  assert.equal(result.error, undefined);
  assert.equal(result.creates.length, 1);
  assert.deepEqual(
    {
      name: result.creates[0].name,
      head_sha: result.creates[0].head_sha,
      external_id: result.creates[0].external_id,
      status: result.creates[0].status,
      conclusion: result.creates[0].conclusion,
    },
    {
      name: 'Check linked issues',
      head_sha: head,
      external_id: externalId,
      status: 'completed',
      conclusion: 'success',
    },
  );
}
{
  const result = await invoke({ receipts: [exactReceipt] });
  assert.equal(result.error, undefined);
  assert.equal(result.creates.length, 0);
  assert.match(result.infos[0], /Reusing exact successful/);
}

const invalidStates = [
  candidate({ pull: { state: 'closed' } }),
  candidate({
    pull: { head: { repo: { [repoIdentityKey]: `${owner}/${repo}` }, ref: `sync/manifest-${sha('c')}`, sha: head } },
  }),
  candidate({
    pull: { head: { repo: { [repoIdentityKey]: 'foreign/docs-control' }, ref: `sync/manifest-${source}`, sha: head } },
  }),
  candidate({
    pull: { head: { repo: { [repoIdentityKey]: `${owner}/${repo}` }, ref: `sync/manifest-${source}`, sha: sha('c') } },
  }),
  candidate({ pull: { base: { repo: { [repoIdentityKey]: `${owner}/${repo}` }, ref: 'develop' } } }),
  candidate({ main: { protected: false, commit: { sha: source } } }),
  candidate({ main: { commit: { sha: sha('c') } } }),
  candidate({ commit: { parents: [{ sha: sha('c') }] } }),
  candidate({ commit: { parents: [{ sha: source }, { sha: sha('c') }] } }),
  candidate({ commits: [{ sha: head }, { sha: sha('c') }] }),
  candidate({ files: [{ filename: 'README.md', status: 'modified' }] }),
  candidate({ files: [{ filename: '.github/config/managed-files-manifest.json', status: 'added' }] }),
];
for (const state of invalidStates) {
  const result = await invoke({ state });
  assert.match(result.error?.message ?? '', /receipt is invalid/);
  assert.equal(result.creates.length, 0);
}
for (const receipts of [
  [{ ...exactReceipt, external_id: 'foreign' }],
  [{ ...exactReceipt, conclusion: 'failure' }],
  [{ ...exactReceipt, status: 'in_progress', conclusion: null }],
  [exactReceipt, exactReceipt],
]) {
  const result = await invoke({ receipts });
  assert.ok(result.error);
  assert.equal(result.creates.length, 0);
}
{
  const result = await invoke({ mutateAfterFirst: candidate({ main: { commit: { sha: sha('c') } } }) });
  assert.ok(result.error);
  assert.equal(result.creates.length, 0);
}
{
  const result = await invoke({ apiError: 'API unavailable' });
  assert.match(result.error?.message ?? '', /API unavailable/);
  assert.equal(result.creates.length, 0);
}
for (const [key, value] of [
  ['PR_NUMBER', '0'],
  ['EXPECTED_SOURCE_SHA', 'ABC'],
  ['EXPECTED_HEAD_SHA', sha('A')],
]) {
  process.env.PR_NUMBER = '42';
  process.env.EXPECTED_SOURCE_SHA = source;
  process.env.EXPECTED_HEAD_SHA = head;
  process.env[key] = value;
  const creates = [];
  const failures = [];
  const github = { rest: { checks: { create: async (request) => creates.push(request) } } };
  await script(github, { repo: { owner, repo } }, { info: () => {}, setFailed: (message) => failures.push(message) });
  assert.equal(failures.length, 1);
  assert.equal(creates.length, 0);
}

const prLines = fs.readFileSync(path.join(root, '.github/workflows/require-linked-issue.yml'), 'utf8').split('\n');
const prStep = prLines.indexOf('      - name: Validate pull request policy');
const prMarker = prLines.findIndex((line, index) => index > prStep && line === '          script: |');
const prSource = prLines
  .slice(prMarker + 1)
  .filter((line) => line === '' || line.startsWith('            '))
  .map((line) => (line === '' ? line : line.slice(12)))
  .join('\n');
const prScript = new AsyncFunction('github', 'context', 'core', prSource);
async function invokePr(pull) {
  const failures = [];
  const infos = [];
  let graphqlCalls = 0;
  const github = {
    graphql: async () => {
      graphqlCalls += 1;
      return { repository: { pullRequest: { closingIssuesReferences: { nodes: [{ number: 1895 }] } } } };
    },
    rest: {
      git: { getCommit: async () => ({ data: { parents: [{ sha: source }] } }) },
      pulls: {
        listCommits: async () => ({ data: [{ sha: head }] }),
        listFiles: async () => ({
          data: [{ filename: '.github/config/managed-files-manifest.json', status: 'modified' }],
        }),
      },
    },
  };
  await prScript(
    github,
    { repo: { owner, repo }, payload: { pull_request: pull } },
    {
      info: (message) => infos.push(message),
      setFailed: (message) => failures.push(message),
    },
  );
  return { failures, infos, graphqlCalls };
}
const manifestPull = {
  number: 42,
  head: { ref: `sync/manifest-${source}`, sha: head, repo: { [repoIdentityKey]: `${owner}/${repo}` } },
  base: { ref: 'main', repo: { [repoIdentityKey]: `${owner}/${repo}` } },
};
{
  const result = await invokePr(manifestPull);
  assert.deepEqual(result.failures, []);
  assert.equal(result.graphqlCalls, 0);
  assert.match(result.infos[0], /untrusted shape/);
}
{
  const result = await invokePr({ ...manifestPull, head: { ...manifestPull.head, ref: `sync/manifest-${sha('c')}` } });
  assert.equal(result.failures.length, 1);
  assert.equal(result.graphqlCalls, 0);
}
{
  const result = await invokePr({ ...manifestPull, head: { ...manifestPull.head, ref: 'feature/ordinary' } });
  assert.deepEqual(result.failures, []);
  assert.equal(result.graphqlCalls, 1);
}
console.log('PASS: ordinary and manifest PR contexts remain behaviorally separated');
console.log('PASS: exact manifest attestor publishes only a unique verified receipt');
