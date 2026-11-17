const { parseArgs } = require('node:util');
const { ApiQueue } = require('./fleet-reconciler.cjs');

function binding(repository, source, head) {
  if (
    !/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_.-]+$/.test(repository) ||
    ['.', '..'].includes(repository.split('/')[1]) ||
    !/^[0-9a-f]{40}$/.test(source) ||
    !/^[0-9a-f]{40}$/.test(head)
  )
    throw new Error('Manifest issue binding requires a repository and exact source/head identities');
  return `<!-- manifest-linked-issue repo=${repository} source=${source} head=${head} -->`;
}
function validateIssue(issue, actor, title, marker, repository) {
  if (
    !Number.isSafeInteger(actor?.id) ||
    actor.id < 1 ||
    !Number.isSafeInteger(issue?.number) ||
    issue.number < 1 ||
    issue.state !== 'open' ||
    issue.pull_request !== undefined ||
    issue.repository_url !== `https://api.github.com/repos/${repository}` ||
    issue.user?.id !== actor.id ||
    issue.title !== title ||
    typeof issue.body !== 'string' ||
    issue.body.split('\n').filter((line) => line.startsWith('<!-- manifest-linked-issue ')).length !== 1 ||
    !issue.body.split('\n').includes(marker)
  )
    throw new Error('Manifest linked-issue owner, state, or immutable binding differs');
  return issue;
}
async function ensureManifestIssue({ api, repository, source, head }) {
  const marker = binding(repository, source, head);
  const title = `Publish managed manifest @ ${source}`;
  const metadata = await api.request(`repos/${repository}`);
  if (metadata.full_name !== repository || metadata.private !== false || metadata.archived !== false)
    throw new Error('Manifest issue publication requires the exact public active repository');
  const actor = await api.request('user');
  if (!Number.isSafeInteger(actor.id) || actor.id < 1) throw new Error('Manifest publisher identity is unavailable');
  const candidates = [];
  const inventoryNumbers = new Set();
  for (let page = 1; ; page += 1) {
    const batch = await api.request(`repos/${repository}/issues?state=all&per_page=100&page=${page}`);
    if (!Array.isArray(batch) || batch.length > 100) throw new Error('Manifest issue inventory is incomplete');
    for (const issue of batch) {
      if (!Number.isSafeInteger(issue?.number) || issue.number < 1 || inventoryNumbers.has(issue.number))
        throw new Error('Manifest issue inventory has malformed or duplicate identities');
      inventoryNumbers.add(issue.number);
      if (
        issue.title === title ||
        (typeof issue.body === 'string' &&
          issue.body.includes(`<!-- manifest-linked-issue repo=${repository} source=${source} `))
      )
        candidates.push(issue);
    }
    if (batch.length < 100) break;
  }
  if (candidates.length > 1) throw new Error('Duplicate manifest issue bindings block publication');
  const body = `${marker}\n\n## Problem\n\nThe managed-file source changed and requires a current generated manifest.\n\n## Scope\n\nPublish only .github/config/managed-files-manifest.json from protected source ${source}, using exact candidate head ${head}. Preserve unrelated files and immutable ownership.\n\n## Acceptance criteria\n\n- The linked PR changes only the generated manifest and contains Closes for this issue.\n- Full manifest source, blob, mode, size and state-digest checks pass.\n- Required review and exact-head CI pass before merge.\n- Merged main contains the verified manifest bytes.\n`;
  let issue;
  if (candidates.length === 1) issue = validateIssue(candidates[0], actor, title, marker, repository);
  else
    issue = validateIssue(
      await api.request(`repos/${repository}/issues`, {
        method: 'POST',
        body: { title, body },
        operationName: 'create exact owned manifest publication issue',
      }),
      actor,
      title,
      marker,
      repository,
    );
  const fresh = validateIssue(
    await api.request(`repos/${repository}/issues/${issue.number}`),
    actor,
    title,
    marker,
    repository,
  );
  if (fresh.body !== issue.body) throw new Error('Manifest issue changed before PR publication');
  return {
    number: issue.number,
    marker,
    pullRequestBody: `${marker}\n\nPublish the generated managed-file manifest for protected source ${source} and exact candidate head ${head}. Required receipt and CI checks remain mandatory.\n\nCloses #${issue.number}\n`,
  };
}
async function validateManifestPrIssue({ api, repository, source, head, pullNumber, issueNumber }) {
  const marker = binding(repository, source, head);
  if (!Number.isSafeInteger(pullNumber) || pullNumber < 1 || !Number.isSafeInteger(issueNumber) || issueNumber < 1)
    throw new Error('Manifest PR number is invalid');
  const pull = await api.request(`repos/${repository}/pulls/${pullNumber}`);
  const matches = [...(pull.body || '').matchAll(/^Closes #([1-9][0-9]*)$/gm)];
  if (
    pull.state !== 'open' ||
    pull.head?.repo?.full_name !== repository ||
    pull.base?.repo?.full_name !== repository ||
    pull.base?.ref !== 'main' ||
    pull.head?.ref !== `sync/manifest-${source}` ||
    pull.head?.sha !== head ||
    matches.length !== 1 ||
    Number(matches[0][1]) !== issueNumber
  )
    throw new Error('Manifest PR closing-issue binding differs');
  const issue = await api.request(`repos/${repository}/issues/${matches[0][1]}`);
  validateIssue(issue, pull.user, `Publish managed manifest @ ${source}`, marker, repository);
  return { number: issue.number, marker };
}
if (require.main === module) {
  const { values } = parseArgs({
    options: {
      repository: { type: 'string' },
      source: { type: 'string' },
      head: { type: 'string' },
      'pull-number': { type: 'string' },
      'issue-number': { type: 'string' },
    },
  });
  const token = process.env.GH_TOKEN;
  if (!token) throw new Error('Manifest issue publisher credential is required');
  const args = {
    api: new ApiQueue({ token }),
    repository: values.repository,
    source: values.source,
    head: values.head,
  };
  const operation =
    values['pull-number'] === undefined
      ? ensureManifestIssue(args)
      : validateManifestPrIssue({
          ...args,
          pullNumber: Number(values['pull-number']),
          issueNumber: Number(values['issue-number']),
        });
  operation
    .then((result) => process.stdout.write(`${JSON.stringify(result)}\n`))
    .catch((error) => {
      process.stderr.write(`${error.message}\n`);
      process.exitCode = 1;
    });
}
module.exports = { binding, ensureManifestIssue, validateManifestPrIssue };
