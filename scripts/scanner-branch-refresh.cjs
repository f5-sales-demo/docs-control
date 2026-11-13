#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { requireSha, readManagedTree, contentDiff } = require('./fleet-reconciler.cjs');
const { desiredScopedEntries } = require('./scoped-managed-content.cjs');
const { SCANNER_PATHS, sourceEvidence, ScannerApiQueue } = require('./scanner-reconciler.cjs');
const canonical = (value) =>
  Array.isArray(value)
    ? value.map(canonical)
    : value && typeof value === 'object'
      ? Object.fromEntries(
          Object.keys(value)
            .sort()
            .map((key) => [key, canonical(value[key])]),
        )
      : value;
const digest = (value) =>
  crypto
    .createHash('sha256')
    .update(JSON.stringify(canonical(value)))
    .digest('hex');
const equal = (a, b) => digest(a) === digest(b);
const fail = (message) => {
  throw Error(message);
};
const name = (value) => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(value);
const branch = (value) =>
  typeof value === 'string' &&
  /^[A-Za-z0-9._/-]+$/.test(value) &&
  value !== 'main' &&
  !value.startsWith('governance/') &&
  !value.includes('..') &&
  value.split('/').every((part) => part && !part.startsWith('.') && !part.endsWith('.lock'));
function desired(options, repo) {
  const value = desiredScopedEntries(options.config, options.manifest, repo, { paths: [...SCANNER_PATHS] });
  if (value.deletes.length) fail('Scanner branch refresh cannot delete paths');
  return value;
}
function refs(pr) {
  return {
    pullRequest: pr.number,
    headSha: pr.head?.sha,
    ref: pr.head?.ref,
    baseSha: pr.base?.sha,
    baseRef: pr.base?.ref,
    draft: pr.draft,
  };
}
function scoped(tree, wanted) {
  if (tree?.truncated !== false || !Array.isArray(tree.tree)) fail('Scanner branch tree incomplete');
  return wanted.files.map((entry) => {
    const rows = tree.tree.filter((row) => row.path === entry.path);
    if (rows.length > 1) fail('Scanner branch path duplicated');
    return rows.length
      ? { path: entry.path, sha: rows[0].sha, mode: rows[0].mode, type: rows[0].type }
      : { path: entry.path, absent: true };
  });
}
async function inspect(options, target) {
  const { api, owner } = options,
    prefix = `repos/${owner}/${target.repo}`;
  const metadata = await api.request(prefix);
  if (metadata?.private !== false || metadata.archived !== false || metadata.default_branch !== 'main')
    fail('Private, archived or ambiguous scanner target refused');
  const pr = await api.request(`${prefix}/pulls/${target.pullRequest}`);
  if (
    pr?.number !== target.pullRequest ||
    pr.state !== 'open' ||
    pr.head?.repo?.full_name !== `${owner}/${target.repo}` ||
    !branch(pr.head.ref) ||
    typeof pr.draft !== 'boolean' ||
    !(pr.base?.ref === 'main' || branch(pr.base?.ref))
  )
    fail('Scanner branch PR ownership differs');
  requireSha(pr.head.sha);
  requireSha(pr.base.sha);
  const ref = await api.request(`${prefix}/git/ref/heads/${encodeURIComponent(pr.head.ref)}`);
  if (ref?.object?.sha !== pr.head.sha) fail('Scanner branch ref differs from PR');
  return { pr, prefix };
}
async function prepare(options) {
  if (
    !name(options.owner) ||
    !Array.isArray(options.inventory) ||
    new Set(options.inventory).size !== options.inventory.length ||
    options.inventory.some((n) => !name(n))
  )
    fail('Scanner branch inventory differs');
  requireSha(options.sourceSha);
  return sourceEvidence(options);
}
function targetsValid(options, targets) {
  if (
    !Array.isArray(targets) ||
    !targets.length ||
    targets.length > 100 ||
    new Set(targets.map((t) => `${t.repo}/${t.pullRequest}`)).size !== targets.length
  )
    fail('Scanner branch target selection differs');
  for (const target of targets) {
    if (
      !name(target.repo) ||
      !options.inventory.includes(target.repo) ||
      !Number.isSafeInteger(target.pullRequest) ||
      target.pullRequest < 1
    )
      fail('Scanner branch target identity unresolved');
    requireSha(target.headSha);
  }
}
async function planBranchRefresh(options) {
  await prepare(options);
  targetsValid(options, options.targets);
  const rows = [];
  for (const target of options.targets) {
    const { pr } = await inspect(options, target);
    if (pr.head.sha !== target.headSha) fail('Scanner branch changed before planning');
    const wanted = desired(options, target.repo),
      tree = await readManagedTree(options.api, options.owner, target.repo, pr.head.sha, wanted);
    const fresh = await inspect(options, target);
    if (!equal(refs(pr), refs(fresh.pr))) fail('Scanner branch changed during planning');
    rows.push({
      repo: target.repo,
      ...refs(pr),
      before: scoped(tree, wanted),
      desiredSha256: digest(wanted),
      changes: contentDiff(tree, wanted),
    });
  }
  const draft = {
    schemaVersion: 1,
    kind: 'scanner-branch-refresh-plan',
    owner: options.owner,
    sourceSha: options.sourceSha,
    manifestStateDigest: options.manifest.state_digest,
    scope: [...SCANNER_PATHS],
    targets: rows,
  };
  return { ...draft, planSha256: digest(draft) };
}
async function fullTree(api, prefix, ref) {
  const tree = await api.request(`${prefix}/git/trees/${ref}?recursive=1`);
  if (
    tree?.truncated !== false ||
    !Array.isArray(tree.tree) ||
    new Set(tree.tree.map((e) => e.path)).size !== tree.tree.length
  )
    fail('Full scanner branch tree incomplete');
  for (const entry of tree.tree) {
    if (
      typeof entry.path !== 'string' ||
      !entry.path ||
      entry.path.startsWith('/') ||
      entry.path.split('/').some((part) => !part || part === '..') ||
      !['blob', 'tree', 'commit'].includes(entry.type) ||
      !/^[0-7]{6}$/.test(entry.mode)
    )
      fail('Full scanner branch entries malformed');
    requireSha(entry.sha);
  }
  return tree.tree;
}
function signature(entries) {
  return new Map(
    entries.filter((entry) => entry.type !== 'tree').map((entry) => [entry.path, [entry.type, entry.mode, entry.sha]]),
  );
}
async function verifyRefresh(options, row, head, wanted, message) {
  const { api } = options,
    prefix = `repos/${options.owner}/${row.repo}`;
  const commit = await api.request(`${prefix}/git/commits/${head}`);
  if (
    commit.sha !== head ||
    commit.message !== message ||
    !Array.isArray(commit.parents) ||
    commit.parents.length !== 1 ||
    commit.parents[0].sha !== row.headSha
  )
    fail('Scanner refresh commit provenance differs');
  const before = signature(await fullTree(api, prefix, row.headSha)),
    after = signature(await fullTree(api, prefix, head));
  const changed = [...new Set([...before.keys(), ...after.keys()])]
    .filter((p) => !equal(before.get(p) || null, after.get(p) || null))
    .sort();
  if (!equal(changed, row.changes.map((e) => e.path).sort())) fail('Scanner refresh changed unrelated feature content');
  const tree = await readManagedTree(api, options.owner, row.repo, head, wanted);
  if (contentDiff(tree, wanted).length) fail('Scanner refresh canonical blobs differ');
  const current = await inspect(options, row);
  if (
    current.pr.head.sha !== head ||
    !equal(
      { ...refs(current.pr), headSha: row.headSha },
      (({ repo, before, desiredSha256, changes, ...identity }) => identity)(row),
    )
  )
    fail('Scanner refresh PR state or identity differs');
  return scoped(tree, wanted);
}
async function executeBranchRefresh(options, plan) {
  const buffers = await prepare(options);
  if (!['dry-run', 'pilot', 'full'].includes(options.mode)) fail('Scanner refresh execution mode differs');
  const { planSha256, ...draft } = plan || {};
  if (
    plan?.schemaVersion !== 1 ||
    plan.kind !== 'scanner-branch-refresh-plan' ||
    planSha256 !== digest(draft) ||
    plan.owner !== options.owner ||
    plan.sourceSha !== options.sourceSha ||
    plan.manifestStateDigest !== options.manifest.state_digest ||
    !equal(plan.scope, SCANNER_PATHS)
  )
    fail('Reviewed scanner plan binding differs');
  targetsValid(options, plan.targets);
  if (options.mode === 'pilot' && plan.targets.length !== 1) fail('Scanner refresh pilot must select one reviewed PR');
  const prepared = [];
  for (const row of plan.targets) {
    const wanted = desired(options, row.repo);
    if (row.desiredSha256 !== digest(wanted)) fail('Reviewed scanner desired scope differs');
    const { pr, prefix } = await inspect(options, row);
    const identity = (({ repo, before, desiredSha256, changes, ...value }) => value)(row);
    const message = `chore: refresh canonical scanners @ ${options.sourceSha}\n\nscanner-branch-refresh v=1 plan=${planSha256} parent=${row.headSha} pr=${row.pullRequest}`;
    if (pr.head.sha !== row.headSha) {
      if (!equal({ ...refs(pr), headSha: row.headSha }, identity)) fail('Foreign scanner target changed');
      const after = await verifyRefresh(options, row, pr.head.sha, wanted, message);
      prepared.push({ row, wanted, prefix, message, recovered: true, head: pr.head.sha, after });
      continue;
    }
    if (!equal(refs(pr), identity)) fail('Reviewed scanner PR identity changed');
    const tree = await readManagedTree(options.api, options.owner, row.repo, row.headSha, wanted);
    if (!equal(scoped(tree, wanted), row.before) || !equal(contentDiff(tree, wanted), row.changes))
      fail('Reviewed scanner branch source changed');
    prepared.push({ row, wanted, prefix, message, recovered: false });
  }
  const results = [];
  for (const item of prepared) {
    const { row, wanted, prefix, message } = item;
    if (item.recovered) {
      results.push({
        repo: row.repo,
        pullRequest: row.pullRequest,
        status: 'recovered',
        headSha: item.head,
        after: item.after,
      });
      continue;
    }
    if (!row.changes.length) {
      results.push({ repo: row.repo, pullRequest: row.pullRequest, status: 'noop', headSha: row.headSha });
      continue;
    }
    if (options.mode === 'dry-run') {
      results.push({
        repo: row.repo,
        pullRequest: row.pullRequest,
        status: 'would-refresh',
        headSha: row.headSha,
        changes: row.changes,
      });
      continue;
    }
    const current = await inspect(options, row);
    if (!equal(refs(current.pr), (({ repo, before, desiredSha256, changes, ...v }) => v)(row)))
      fail('Scanner branch changed before writes');
    const parent = await options.api.request(`${prefix}/git/commits/${row.headSha}`);
    requireSha(parent.tree?.sha);
    for (const change of row.changes) {
      if (change.action === 'delete' || !wanted.files.some((e) => e.path === change.path))
        fail('Scanner refresh path is out of scope');
      const bytes = buffers.get(change.src);
      if (!bytes) fail('Scanner canonical bytes unavailable');
      const blob = await options.api.request(`${prefix}/git/blobs`, {
        method: 'POST',
        body: { content: bytes.toString('base64'), encoding: 'base64' },
      });
      if (blob?.sha !== change.sha) fail('Scanner canonical blob upload differs');
    }
    const tree = await options.api.request(`${prefix}/git/trees`, {
      method: 'POST',
      body: {
        base_tree: parent.tree.sha,
        tree: row.changes.map((e) => ({ path: e.path, sha: e.sha, mode: e.mode || '100644', type: 'blob' })),
      },
    });
    requireSha(tree?.sha);
    const commit = await options.api.request(`${prefix}/git/commits`, {
      method: 'POST',
      body: { message, tree: tree.sha, parents: [row.headSha] },
    });
    requireSha(commit?.sha);
    const fresh = await inspect(options, row);
    if (!equal(refs(fresh.pr), refs(current.pr))) fail('Scanner branch changed before ref update');
    await options.api.request(`${prefix}/git/refs/heads/${encodeURIComponent(row.ref)}`, {
      method: 'PATCH',
      body: { sha: commit.sha, force: false },
    });
    const after = await verifyRefresh(options, row, commit.sha, wanted, message);
    results.push({
      repo: row.repo,
      pullRequest: row.pullRequest,
      status: 'refreshed',
      previousHeadSha: row.headSha,
      headSha: commit.sha,
      after,
    });
  }
  for (const result of results) {
    const row = plan.targets.find((target) => target.repo === result.repo && target.pullRequest === result.pullRequest);
    const current = await inspect(options, row);
    const identity = (({ repo, before, desiredSha256, changes, ...value }) => value)(row);
    if (current.pr.head.sha !== result.headSha || !equal({ ...refs(current.pr), headSha: row.headSha }, identity))
      fail('Scanner target changed before final result');
  }
  return {
    schemaVersion: 1,
    kind: 'scanner-branch-refresh-result',
    sourceSha: options.sourceSha,
    planSha256,
    mode: options.mode,
    targets: results,
  };
}
async function main() {
  const root = process.env.GITHUB_WORKSPACE || process.cwd(),
    read = (p) => JSON.parse(fs.readFileSync(path.join(root, p), 'utf8'));
  if (!process.env.GH_TOKEN || !process.env.BRANCH_REFRESH_INPUT)
    fail('Explicit scanner branch input and credentials required');
  const input = JSON.parse(process.env.BRANCH_REFRESH_INPUT),
    manifest = read('.github/config/managed-files-manifest.json');
  const options = {
    api: new ScannerApiQueue({ token: process.env.GH_TOKEN }),
    owner: (process.env.GITHUB_REPOSITORY || 'f5-sales-demo/docs-control').split('/')[0],
    sourceSha: input.sourceSha || manifest.source_commit,
    sourceRoot: root,
    manifest,
    config: read('.github/config/repo-settings.json'),
    inventory: read('.github/config/downstream-repos.json'),
    targets: input.targets,
    mode: process.env.BRANCH_REFRESH_MODE || 'dry-run',
  };
  const plan = input.plan || (await planBranchRefresh(options));
  if (input.plan) console.log(JSON.stringify(await executeBranchRefresh(options, plan), null, 2));
  else console.log(JSON.stringify(plan, null, 2));
}
if (require.main === module)
  main().catch(() => {
    console.error('Scanner branch refresh failed; preserve original reviewed state');
    process.exitCode = 1;
  });
module.exports = { planBranchRefresh, executeBranchRefresh };
