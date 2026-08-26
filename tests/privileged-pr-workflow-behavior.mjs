import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = process.argv[2];
if (!root) throw new Error('repository root is required');

function extractScript(workflowPath, stepName) {
  const lines = fs.readFileSync(workflowPath, 'utf8').split('\n');
  const stepMarker = lines.indexOf(`      - name: ${stepName}`);
  if (stepMarker === -1) throw new Error(`step ${stepName} not found in ${workflowPath}`);
  const marker = lines.findIndex((line, index) => index > stepMarker && line === '          script: |');
  if (marker === -1) throw new Error(`github-script body not found for ${stepName}`);
  return lines
    .slice(marker + 1)
    .filter((line) => line === '' || line.startsWith('            '))
    .map((line) => (line === '' ? line : line.slice(12)))
    .join('\n');
}

const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
const linkedIssueScript = new AsyncFunction(
  'github',
  'context',
  'core',
  extractScript(path.join(root, 'workflows/require-linked-issue.yml'), "Check this pull request's linked issues"),
);
const context = { repo: { owner: 'f5-sales-demo', repo: 'example' } };

async function testExactPullRequestQueryPasses() {
  const graphqlCalls = [];
  const info = [];
  const failures = [];
  await linkedIssueScript(
    {
      graphql: async (_query, variables) => {
        graphqlCalls.push(variables);
        return { repository: { pullRequest: { closingIssuesReferences: { nodes: [{ number: 1693 }] } } } };
      },
    },
    { ...context, payload: { pull_request: { number: 77 } } },
    {
      info: (message) => info.push(message),
      setFailed: (message) => failures.push(message),
    },
  );
  assert.deepEqual(graphqlCalls, [{ owner: 'f5-sales-demo', repo: 'example', number: 77 }]);
  assert.deepEqual(failures, []);
  assert.match(info[0], /#77 links issue #1693/);
}

async function testMissingLinkFailsWithGuidance() {
  const failures = [];
  await linkedIssueScript(
    { graphql: async () => ({ repository: { pullRequest: { closingIssuesReferences: { nodes: [] } } } }) },
    { ...context, payload: { pull_request: { number: 78 } } },
    { info: () => {}, setFailed: (message) => failures.push(message) },
  );
  assert.equal(failures.length, 1);
  assert.match(failures[0], /Closes #123/);
}

async function testGraphqlFailureFailsClosed() {
  await assert.rejects(
    linkedIssueScript(
      {
        graphql: async () => {
          throw new Error('GraphQL unavailable');
        },
      },
      { ...context, payload: { pull_request: { number: 79 } } },
      { info: () => {}, setFailed: () => {} },
    ),
    /GraphQL unavailable/,
  );
}

await testExactPullRequestQueryPasses();
await testMissingLinkFailsWithGuidance();
await testGraphqlFailureFailsClosed();
console.log('PASS: linked-issue PR behavior is deterministic and fails closed');
