import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = process.argv[2];
if (!root) throw new Error('repository root is required');

function extractScript(workflowPath) {
  const lines = fs.readFileSync(workflowPath, 'utf8').split('\n');
  const marker = lines.findIndex((line) => /^\s+script: \|$/.test(line));
  if (marker === -1) throw new Error(`github-script body not found in ${workflowPath}`);
  return lines
    .slice(marker + 1)
    .map((line) => (line.startsWith('            ') ? line.slice(12) : line))
    .join('\n');
}

const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
const dependabotScript = new AsyncFunction(
  'github',
  'context',
  'core',
  extractScript(path.join(root, 'workflows/dependabot-auto-merge.yml')),
);
const linkedIssueScript = new AsyncFunction(
  'github',
  'context',
  'core',
  extractScript(path.join(root, 'workflows/require-linked-issue.yml')),
);
const context = { repo: { owner: 'f5-sales-demo', repo: 'example' } };

async function testDependabotSelection() {
  const reviewCalls = [];
  const mergeCalls = [];
  const pulls = [
    {
      number: 1,
      user: { id: 49699333, login: 'dependabot[bot]' },
      head: { sha: 'dependabot-head' },
      node_id: 'PR_dependabot',
      auto_merge: null,
    },
    {
      number: 2,
      user: { id: 1000, login: 'dependabot[bot]' },
      head: { sha: 'spoofed-head' },
      node_id: 'PR_spoofed',
      auto_merge: null,
    },
    {
      number: 3,
      user: { id: 2000, login: 'human' },
      head: { sha: 'human-head' },
      node_id: 'PR_human',
      auto_merge: null,
    },
  ];
  const list = async () => pulls;
  const listReviews = async () => [];
  const github = {
    paginate: async (endpoint, params) => endpoint(params),
    graphql: async (_query, variables) => mergeCalls.push(variables),
    rest: {
      pulls: {
        list,
        listReviews,
        createReview: async (params) => reviewCalls.push(params),
      },
    },
  };

  await dependabotScript(github, context, {});
  assert.deepEqual(
    reviewCalls.map((call) => [call.pull_number, call.commit_id, call.event]),
    [[1, 'dependabot-head', 'APPROVE']],
  );
  assert.deepEqual(mergeCalls, [{ pullRequestId: 'PR_dependabot' }]);
}

async function testDependabotIdempotence() {
  const sideEffects = [];
  const pull = {
    number: 4,
    user: { id: 49699333, login: 'dependabot[bot]' },
    head: { sha: 'already-approved' },
    node_id: 'PR_existing',
    auto_merge: { enabled_by: { login: 'github-actions[bot]' } },
  };
  const github = {
    paginate: async (endpoint, params) => endpoint(params),
    graphql: async () => sideEffects.push('merge'),
    rest: {
      pulls: {
        list: async () => [pull],
        listReviews: async () => [
          {
            user: { id: 41898282 },
            state: 'APPROVED',
            commit_id: pull.head.sha,
          },
        ],
        createReview: async () => sideEffects.push('review'),
      },
    },
  };

  await dependabotScript(github, context, {});
  assert.deepEqual(sideEffects, []);
}

function linkedIssueHarness(
  pulls,
  linkedByNumber = new Map(),
  errorsByNumber = new Map(),
  statusErrorsBySha = new Map(),
) {
  const statuses = [];
  const statusAttempts = [];
  const comments = [];
  const coreErrors = [];
  const coreWarnings = [];
  const failures = [];
  const listPulls = async () => pulls;
  const getPull = async ({ pull_number }) => {
    const pull = pulls.find(({ number }) => number === pull_number);
    if (!pull) throw new Error(`pull request ${pull_number} not found`);
    return { data: pull };
  };
  const listComments = async () => [];
  const github = {
    paginate: async (endpoint, params) => endpoint(params),
    graphql: async (_query, variables) => {
      if (errorsByNumber.has(variables.number)) throw errorsByNumber.get(variables.number);
      return {
        repository: {
          pullRequest: {
            closingIssuesReferences: { nodes: linkedByNumber.get(variables.number) ?? [] },
          },
        },
      };
    },
    rest: {
      pulls: { list: listPulls, get: getPull },
      repos: {
        createCommitStatus: async (params) => {
          statusAttempts.push(params);
          if (statusErrorsBySha.has(params.sha)) throw statusErrorsBySha.get(params.sha);
          statuses.push(params);
        },
      },
      issues: {
        listComments,
        createComment: async (params) => comments.push(params),
      },
    },
  };
  const core = {
    info: () => {},
    error: (message) => coreErrors.push(message),
    warning: (message) => coreWarnings.push(message),
    setFailed: (message) => failures.push(message),
  };
  return { github, core, statuses, statusAttempts, comments, coreErrors, coreWarnings, failures };
}

async function testLinkedIssueTargetedDispatch() {
  const pull = { number: 30, state: 'closed', head: { ref: 'sync/exact-caller', sha: 'a'.repeat(40) } };
  const harness = linkedIssueHarness([pull]);
  const dispatchContext = {
    ...context,
    eventName: 'workflow_dispatch',
    payload: {
      inputs: {
        pull_request_number: '30',
        expected_head_sha: pull.head.sha,
      },
    },
  };

  await linkedIssueScript(harness.github, dispatchContext, harness.core);

  assert.deepEqual(
    harness.statuses.map(({ sha, state }) => [sha, state]),
    [
      [pull.head.sha, 'pending'],
      [pull.head.sha, 'success'],
    ],
  );
}

async function testLinkedIssueTargetedDispatchRejectsHeadDrift() {
  const pull = { number: 31, state: 'closed', head: { ref: 'sync/exact-caller', sha: 'b'.repeat(40) } };
  const harness = linkedIssueHarness([pull]);
  const dispatchContext = {
    ...context,
    eventName: 'workflow_dispatch',
    payload: {
      inputs: {
        pull_request_number: '31',
        expected_head_sha: 'c'.repeat(40),
      },
    },
  };

  await assert.rejects(
    linkedIssueScript(harness.github, dispatchContext, harness.core),
    /head changed before linked-issue evaluation/,
  );
  assert.deepEqual(harness.statuses, []);
}

async function testLinkedIssueOutcomes() {
  const pulls = [
    { number: 10, head: { ref: 'dependabot/npm/pkg', sha: 'exempt-head' } },
    { number: 11, head: { ref: 'feature/linked', sha: 'linked-head' } },
    { number: 12, head: { ref: 'feature/missing', sha: 'missing-head' } },
  ];
  const harness = linkedIssueHarness(pulls, new Map([[11, [{ number: 1094 }]]]));
  await linkedIssueScript(harness.github, context, harness.core);

  const statesBySha = {};
  for (const status of harness.statuses) {
    if (!statesBySha[status.sha]) statesBySha[status.sha] = [];
    statesBySha[status.sha].push(status);
  }
  assert.deepEqual(
    statesBySha['exempt-head'].map((status) => status.state),
    ['pending', 'success'],
  );
  assert.deepEqual(
    statesBySha['linked-head'].map((status) => status.state),
    ['pending', 'success'],
  );
  assert.deepEqual(
    statesBySha['missing-head'].map((status) => status.state),
    ['pending', 'failure'],
  );
  assert.deepEqual(
    harness.comments.map((comment) => comment.issue_number),
    [12],
  );
  assert.equal(harness.comments[0].body.includes('<!-- require-linked-issue -->'), true);
  assert.deepEqual(harness.coreErrors, []);
  assert.deepEqual(harness.failures, []);
}

async function testLinkedIssueApiFailure() {
  const pull = { number: 20, head: { ref: 'feature/error', sha: 'error-head' } };
  const harness = linkedIssueHarness([pull], new Map(), new Map([[20, new Error('GraphQL unavailable')]]));
  await linkedIssueScript(harness.github, context, harness.core);

  assert.deepEqual(
    harness.statuses.map((status) => status.state),
    ['pending', 'failure'],
  );
  assert.equal(harness.coreErrors.length, 1);
  assert.equal(harness.failures.length, 1);
  assert.match(harness.failures[0], /20/);
}

async function testScheduledLinkedIssueSkipsExhaustedHistoricalStatus() {
  const historical = { number: 40, head: { ref: 'feature/historical', sha: 'historical-head' } };
  const current = { number: 41, head: { ref: 'feature/current', sha: 'current-head' } };
  const exhausted = Object.assign(new Error('Validation Failed'), {
    status: 422,
    response: {
      data: { errors: 'Validation failed: This SHA and context has reached the maximum number of statuses.' },
    },
  });
  const harness = linkedIssueHarness(
    [historical, current],
    new Map([[41, [{ number: 1593 }]]]),
    new Map(),
    new Map([[historical.head.sha, exhausted]]),
  );
  await linkedIssueScript(harness.github, { ...context, eventName: 'schedule' }, harness.core);

  assert.deepEqual(
    harness.statusAttempts.filter((status) => status.sha === historical.head.sha).map((status) => status.state),
    ['pending'],
  );
  assert.deepEqual(
    harness.statuses.filter((status) => status.sha === current.head.sha).map((status) => status.state),
    ['pending', 'success'],
  );
  assert.equal(harness.coreWarnings.length, 1);
  assert.deepEqual(harness.coreErrors, []);
  assert.deepEqual(harness.failures, []);
}

async function testTargetedLinkedIssueFailsOnExhaustedStatus() {
  const pull = { number: 42, head: { ref: 'feature/current', sha: 'd'.repeat(40) } };
  const exhausted = Object.assign(new Error('Validation Failed'), {
    status: 422,
    response: {
      data: { errors: 'Validation failed: This SHA and context has reached the maximum number of statuses.' },
    },
  });
  const harness = linkedIssueHarness([pull], new Map(), new Map(), new Map([[pull.head.sha, exhausted]]));
  const dispatchContext = {
    ...context,
    eventName: 'workflow_dispatch',
    payload: { inputs: { pull_request_number: '42', expected_head_sha: pull.head.sha } },
  };
  await assert.rejects(linkedIssueScript(harness.github, dispatchContext, harness.core), /Validation Failed/);
}

await testDependabotSelection();
await testDependabotIdempotence();
await testLinkedIssueOutcomes();
await testLinkedIssueApiFailure();
await testScheduledLinkedIssueSkipsExhaustedHistoricalStatus();
await testTargetedLinkedIssueFailsOnExhaustedStatus();
await testLinkedIssueTargetedDispatch();
await testLinkedIssueTargetedDispatchRejectsHeadDrift();
console.log('PASS: privileged PR workflow behavior is deterministic and idempotent');
