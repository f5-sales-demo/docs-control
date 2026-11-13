#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {
  ApiQueue,
  ACTIVE_PR_LIMIT,
  requireSha,
  readManagedTree,
  contentDiff,
  validateManifest,
} = require('./fleet-reconciler.cjs');
const { GitHubRetryDeferredError } = require('./github-api-resilience.cjs');
const { desiredScopedEntries } = require('./scoped-managed-content.cjs');
const SCANNER_PATHS = Object.freeze(
  ['.gitleaks.toml', 'scripts/check-pii.sh', 'scripts/check_pii.py', 'tests/test-check-pii.sh'].sort(),
);
const hash = (value) => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const scopeHash = hash(SCANNER_PATHS);
const fail = (message) => {
  throw Error(message);
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const safeName = (value) => typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(value);
const safePath = (value) =>
  typeof value === 'string' &&
  /^[A-Za-z0-9._/-]+$/.test(value) &&
  !value.startsWith('/') &&
  value.split('/').every((p) => p && p !== '.' && p !== '..');
class ScannerApiQueue extends ApiQueue {
  async request(endpoint, options = {}) {
    // Identity rechecks need a complete fresh body, not an ETag-only 304.
    // Keep the shared retry and write-pacing contracts without changing full reconciliation.
    this.etags.delete(endpoint);
    return super.request(endpoint, options);
  }
}
function scannerIdentity(sourceSha, repo, desired, baseSha) {
  requireSha(sourceSha);
  requireSha(baseSha);
  if (!safeName(repo)) fail('Invalid scanner repository');
  const desiredHash = hash(desired);
  return {
    branch: `governance/scanner-${sourceSha.slice(0, 12)}-${scopeHash.slice(0, 12)}-${hash(repo).slice(0, 12)}`,
    title: `Reconcile canonical scanners @ ${sourceSha.slice(0, 12)}`,
    note: `<!-- scanner-reconciler v=1 source=${sourceSha} scope=${scopeHash} desired-tree=${desiredHash} base=${baseSha} -->`,
    message: `chore: reconcile canonical scanners @ ${sourceSha}`,
  };
}
function scannerIssueBody(identity) {
  return `${identity.note}\n\nCanonical four-file scanner reconciliation.\n\nProblem: this repository differs from the immutable canonical privacy and secret scanners.\n\nScope: .gitleaks.toml, scripts/check-pii.sh, scripts/check_pii.py, tests/test-check-pii.sh, subject to manifest opt-outs. Preserve all other files, settings, controls and owners.\n\nAcceptance: the linked PR changes only the selected paths; exact canonical blob SHAs and modes match its source manifest; required review and CI pass; merged main is independently verified. CE operational and UAT acceptance remain separate.`;
}
async function listAll(api, endpoint) {
  const result = [];
  for (let page = 1; page <= 100; page++) {
    const rows = await api.request(`${endpoint}${endpoint.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    if (!Array.isArray(rows) || rows.length > 100) fail('Incomplete scanner API pagination');
    result.push(...rows);
    if (rows.length < 100) return result;
  }
  fail('Scanner API pagination exceeds bound');
}
async function optionalRef(api, prefix, branch) {
  try {
    const result = await api.request(`${prefix}/git/ref/heads/${encodeURIComponent(branch)}`);
    requireSha(result?.object?.sha, 'scanner branch SHA');
    return result.object.sha;
  } catch (error) {
    if (error.status === 404 || error.statusCode === 404) return undefined;
    throw error;
  }
}
async function sourceEvidence({ api, owner, sourceSha, sourceRoot, config, manifest }) {
  validateManifest(config, manifest);
  if (sourceSha !== manifest.source_commit || config.managed_files?.source_repo !== `${owner}/docs-control`)
    fail('Scanner source identifier differs from canonical manifest');
  const source = await api.request(`repos/${owner}/docs-control/commits/${sourceSha}`);
  if (source?.sha !== sourceSha) fail('Canonical source commit unavailable');
  const desired = { files: manifest.files.map((e) => ({ ...e, path: e.src })), deletes: [] };
  if (
    desired.files.some((e) => !safePath(e.path)) ||
    new Set(desired.files.map((e) => e.path)).size !== desired.files.length
  )
    fail('Source paths are ambiguous or unsafe');
  const tree = await readManagedTree(api, owner, 'docs-control', sourceSha, desired);
  if (contentDiff(tree, desired).length) fail('Canonical source tree does not match full manifest');
  const root = fs.realpathSync(sourceRoot),
    buffers = new Map();
  for (const entry of manifest.files) {
    const file = path.join(root, entry.src),
      info = fs.lstatSync(file);
    if (!info.isFile() || info.isSymbolicLink() || fs.realpathSync(file) !== file) fail('Source file custody differs');
    const bytes = fs.readFileSync(file);
    const blob = crypto
      .createHash('sha1')
      .update(Buffer.from(`blob ${bytes.length}\0`))
      .update(bytes)
      .digest('hex');
    if (blob !== entry.sha || bytes.length !== entry.size) fail('Source blob digest differs');
    buffers.set(entry.src, bytes);
  }
  return buffers;
}
async function stablePrFiles(api, prefix, listed) {
  const pr = await api.request(`${prefix}/pulls/${listed.number}`);
  if (
    pr?.number !== listed.number ||
    pr.head?.sha !== listed.head?.sha ||
    !Number.isSafeInteger(pr.changed_files) ||
    pr.changed_files < 0 ||
    pr.changed_files > 3000
  )
    fail('PR identity or file inventory is incomplete');
  const files = await listAll(api, `${prefix}/pulls/${pr.number}/files`);
  if (
    files.length !== pr.changed_files ||
    new Set(files.map((f) => f.filename)).size !== files.length ||
    files.some((f) => !safePath(f.filename))
  )
    fail('PR file inventory is incomplete');
  const fresh = await api.request(`${prefix}/pulls/${pr.number}`);
  if (fresh.head?.sha !== pr.head.sha || fresh.state !== pr.state) fail('Concurrent PR change blocks scanner delivery');
  return { pr, files };
}
function scannerSignature(tree) {
  if (!Array.isArray(tree?.tree) || tree.truncated !== false) fail('Incomplete scanner path tree');
  const selected = tree.tree.filter((entry) => SCANNER_PATHS.includes(entry.path));
  if (new Set(selected.map((entry) => entry.path)).size !== selected.length)
    fail('Duplicate scanner path tree entries');
  return SCANNER_PATHS.map((name) => {
    const entry = selected.find((item) => item.path === name);
    if (!entry) return null;
    requireSha(entry.sha);
    if (!['blob', 'tree', 'commit'].includes(entry.type) || !/^[0-7]{6}$/.test(entry.mode))
      fail('Malformed scanner path tree entry');
    return [entry.path, entry.sha, entry.mode, entry.type];
  });
}
function foreignPrRefs(pr) {
  return [pr.number, pr.state, pr.head?.sha, pr.base?.sha, pr.base?.ref];
}
async function unchangedLargePrPaths(api, prefix, listed, pr) {
  // The files endpoint has its own complete-inventory contract. It does not
  // qualify an introduced commit graph beyond GitHub's 250-commit limit.
  requireSha(pr.base?.sha);
  requireSha(listed.base?.sha);
  if (
    !same(foreignPrRefs(pr), foreignPrRefs(listed)) ||
    typeof pr.base.ref !== 'string' ||
    !pr.base.ref ||
    !Number.isSafeInteger(pr.changed_files) ||
    pr.changed_files < 0 ||
    pr.changed_files > 3000
  )
    fail('Large PR path snapshot is incomplete');
  const files = await listAll(api, `${prefix}/pulls/${pr.number}/files`);
  if (
    files.length !== pr.changed_files ||
    new Set(files.map((file) => file.filename)).size !== files.length ||
    files.some(
      (file) =>
        !safePath(file.filename) ||
        (file.previous_filename !== undefined && !safePath(file.previous_filename)) ||
        (file.status === 'renamed' && !safePath(file.previous_filename)),
    )
  )
    fail('Large PR path inventory is incomplete');
  const fresh = await api.request(`${prefix}/pulls/${pr.number}`);
  if (
    !same(foreignPrRefs(pr), foreignPrRefs(fresh)) ||
    fresh.commits !== pr.commits ||
    fresh.changed_files !== pr.changed_files
  )
    fail('Large PR path snapshot changed');
  return files.some((file) => SCANNER_PATHS.includes(file.filename) || SCANNER_PATHS.includes(file.previous_filename))
    ? 'unverified'
    : 'clear';
}
async function currentCanonicalPrHead(api, owner, repo, listed, wanted) {
  // The caller derives wanted only after full immutable source verification.
  if (!listed.base?.sha) return 'not-attempted';
  try {
    requireSha(listed.head?.sha);
    requireSha(listed.base.sha);
    const prefix = `repos/${owner}/${repo}`;
    const pr = await api.request(`${prefix}/pulls/${listed.number}`);
    if (pr.state !== 'open' || !same(foreignPrRefs(pr), foreignPrRefs(listed))) return 'unverified';
    const tree = await readManagedTree(api, owner, repo, pr.head.sha, wanted);
    if (contentDiff(tree, wanted).length) return 'different';
    const fresh = await api.request(`${prefix}/pulls/${pr.number}`);
    return same(foreignPrRefs(pr), foreignPrRefs(fresh)) ? 'canonical' : 'unverified';
  } catch (error) {
    if (error instanceof GitHubRetryDeferredError) throw error;
    return 'unverified';
  }
}
async function foreignScannerScope(api, owner, repo, listed) {
  const prefix = `repos/${owner}/${repo}`;
  try {
    const pr = await api.request(`${prefix}/pulls/${listed.number}`);
    if (
      pr?.number !== listed.number ||
      pr.state !== 'open' ||
      pr.head?.sha !== listed.head?.sha ||
      !Number.isSafeInteger(pr.commits) ||
      pr.commits < 1
    )
      return 'unverified';
    requireSha(pr.head.sha);
    if (pr.commits > 250) return await unchangedLargePrPaths(api, prefix, listed, pr);
    // GitHub exposes at most 250 PR commits. Require the complete introduced graph,
    // then compare only the governed paths at every immutable boundary ancestor.
    const commits = await listAll(api, `${prefix}/pulls/${pr.number}/commits`);
    const graph = new Map();
    if (commits.length !== pr.commits) return 'unverified';
    for (const commit of commits) {
      requireSha(commit.sha);
      if (!Array.isArray(commit.parents) || !commit.parents.length || commit.parents.length > 32) return 'unverified';
      const parents = commit.parents.map((parent) => requireSha(parent.sha));
      if (graph.has(commit.sha) || new Set(parents).size !== parents.length) return 'unverified';
      graph.set(commit.sha, parents);
    }
    if (!graph.has(pr.head.sha)) return 'unverified';
    const visited = new Set(),
      visiting = new Set(),
      boundaries = new Set();
    const visit = (sha) => {
      if (visiting.has(sha)) fail('Cyclic foreign commit graph');
      if (visited.has(sha)) return;
      visiting.add(sha);
      for (const parent of graph.get(sha)) {
        if (graph.has(parent)) visit(parent);
        else boundaries.add(parent);
      }
      visiting.delete(sha);
      visited.add(sha);
    };
    visit(pr.head.sha);
    if (visited.size !== graph.size || !boundaries.size || boundaries.size > 64) return 'unverified';
    const desired = { files: SCANNER_PATHS.map((name) => ({ path: name })), deletes: [] };
    const head = scannerSignature(await readManagedTree(api, owner, repo, pr.head.sha, desired));
    let result = 'clear';
    for (const boundary of boundaries) {
      const base = scannerSignature(await readManagedTree(api, owner, repo, boundary, desired));
      if (!same(head, base)) result = 'collision';
    }
    const fresh = await api.request(`${prefix}/pulls/${pr.number}`);
    if (fresh.state !== pr.state || fresh.head?.sha !== pr.head.sha || fresh.commits !== pr.commits)
      return 'unverified';
    return result;
  } catch (error) {
    if (error instanceof GitHubRetryDeferredError) throw error;
    return 'unverified';
  }
}
async function ownerEvidence(api, prefix, repo, owner, listed, sourceSha, desired) {
  const { pr, files } = await stablePrFiles(api, prefix, listed);
  const match =
    typeof pr.body === 'string' &&
    pr.body.match(
      /^<!-- scanner-reconciler v=1 source=([a-f0-9]{40}) scope=([a-f0-9]{64}) desired-tree=([a-f0-9]{64}) base=([a-f0-9]{40}) -->\n\nCloses #([1-9][0-9]*)$/,
    );
  if (!match || match[1] !== sourceSha || match[2] !== scopeHash || match[3] !== hash(desired))
    fail('Stale or foreign scanner ownership');
  const identity = scannerIdentity(sourceSha, repo, desired, match[4]);
  if (
    pr.title !== identity.title ||
    pr.head.ref !== identity.branch ||
    pr.head.repo?.full_name !== `${owner}/${repo}` ||
    pr.base?.ref !== 'main' ||
    !pr.user?.login
  )
    fail('Scanner PR ownership differs');
  const commits = await listAll(api, `${prefix}/pulls/${pr.number}/commits`);
  if (
    commits.length !== 1 ||
    commits[0].sha !== pr.head.sha ||
    commits[0].parents?.length !== 1 ||
    commits[0].parents[0].sha !== match[4] ||
    commits[0].commit?.message !== identity.message
  )
    fail('Scanner PR commit ownership differs');
  const base = await readManagedTree(api, owner, repo, match[4], desired);
  const changes = contentDiff(base, desired);
  if (
    !changes.length ||
    !same(files.map((f) => f.filename).sort(), changes.map((c) => c.path).sort()) ||
    files.some((f) => f.previous_filename)
  )
    fail('Recovered scanner PR changes are partial or out of scope');
  const tree = await readManagedTree(api, owner, repo, pr.head.sha, desired);
  if (contentDiff(tree, desired).length) fail('Recovered scanner tree differs');
  const issue = await api.request(`${prefix}/issues/${match[5]}`);
  if (
    issue?.number !== Number(match[5]) ||
    issue.pull_request ||
    issue.title !== identity.title ||
    issue.body !== scannerIssueBody(identity) ||
    issue.user?.login !== pr.user.login ||
    !['open', 'closed'].includes(issue.state)
  )
    fail('Scanner issue ownership differs');
  return { pr, identity, issue };
}
async function enableAutoMerge(api, prefix, pr) {
  const detail = await api.request(`${prefix}/pulls/${pr.number}`);
  if (detail.head?.sha !== pr.head.sha || detail.state !== 'open') fail('Scanner head changed before auto-merge');
  if (detail.auto_merge) return;
  if (typeof detail.node_id !== 'string' || !detail.node_id) fail('Scanner pull request node ID missing');
  const result = await api.request('graphql', {
    method: 'POST',
    body: {
      query:
        'mutation($id:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:SQUASH}){pullRequest{number}}}',
      variables: { id: detail.node_id },
    },
  });
  if (result?.errors?.length || result?.data?.enablePullRequestAutoMerge?.pullRequest?.number !== pr.number)
    fail('Scanner auto-merge response is invalid');
}
async function reconcileScannerContent(options) {
  const {
    api,
    owner,
    sourceSha,
    manifest,
    config,
    inventory,
    selection,
    paths,
    mode,
    operation = 'reconcile',
  } = options;
  requireSha(sourceSha);
  if (
    !safeName(owner) ||
    !['dry-run', 'pilot', 'full'].includes(mode) ||
    !['reconcile', 'retire-only'].includes(operation) ||
    !Array.isArray(paths) ||
    !same([...paths].sort(), SCANNER_PATHS) ||
    new Set(paths).size !== 4
  )
    fail('Invalid scanner operation or exact four-file scope');
  if (
    !Array.isArray(inventory) ||
    !inventory.length ||
    new Set(inventory).size !== inventory.length ||
    inventory.some((r) => !safeName(r))
  )
    fail('Invalid scanner repository inventory');
  if (operation === 'retire-only' && !selection) fail('Explicit scanner retirement repository selection is required');
  const repos = selection ? selection.split(',') : inventory;
  if (
    !repos.length ||
    new Set(repos).size !== repos.length ||
    repos.some((r) => !inventory.includes(r)) ||
    (mode === 'pilot' && repos.length !== 1)
  )
    fail('Invalid scanner repository selection');
  // Validate every selected tree and immutable producer byte before the first write.
  const desired = new Map(repos.map((repo) => [repo, desiredScopedEntries(config, manifest, repo, { paths })]));
  const sourceBuffers = await sourceEvidence(options);
  const all = new Map(),
    archived = new Set();
  let active = 0;
  for (const repo of inventory) {
    const metadata = await api.request(`repos/${owner}/${repo}`);
    if (typeof metadata?.archived !== 'boolean' || metadata.default_branch !== 'main')
      fail('Repository archive/default branch evidence unavailable');
    if (metadata.archived) {
      archived.add(repo);
      continue;
    }
    const prs = await listAll(api, `repos/${owner}/${repo}/pulls?state=open`);
    all.set(repo, prs);
    if (prs.some((p) => !Number.isSafeInteger(p.number) || !p.head?.sha || !p.head?.ref))
      fail('Open PR inventory is malformed');
    active += prs.filter((p) =>
      /^governance\/(?:scanner-|reconcile|bootstrap|sync-managed-files)/.test(p.head.ref),
    ).length;
  }
  const result = { sourceSha, scope: SCANNER_PATHS, mode, operation, repositories: [], deferred: false };
  for (const repo of repos) {
    if (archived.has(repo)) {
      result.repositories.push({ repo, status: 'skipped-archived' });
      continue;
    }
    const prefix = `repos/${owner}/${repo}`,
      wanted = desired.get(repo);
    const main = await api.request(`${prefix}/commits/main`);
    requireSha(main?.sha, 'protected main SHA');
    const identity = scannerIdentity(sourceSha, repo, wanted, main.sha);
    const open = all.get(repo),
      scoped = open.filter((p) => p.head.ref.startsWith('governance/scanner-'));
    // A foreign/stale scoped owner must be resolved explicitly, never retired by a new source.
    if (scoped.some((p) => p.head.ref !== identity.branch) || scoped.length > 1)
      fail('Stale or foreign scanner owner blocks delivery');
    let own = scoped[0];
    if (operation === 'retire-only' && !own) {
      const prior = await listAll(
        api,
        `${prefix}/pulls?state=all&head=${owner}:${encodeURIComponent(identity.branch)}`,
      );
      const matched = prior.filter((p) => p.head?.ref === identity.branch);
      if (matched.length > 1) fail('Ambiguous scanner retirement owner');
      own = matched[0];
    }
    if (own) {
      const bound = await ownerEvidence(api, prefix, repo, owner, own, sourceSha, wanted);
      const ref = await optionalRef(api, prefix, bound.identity.branch);
      if (ref !== undefined && ref !== bound.pr.head.sha) fail('Scanner branch identity changed');
      if (operation === 'retire-only') {
        if (mode !== 'dry-run') {
          if (bound.pr.state === 'open')
            await api.request(`${prefix}/pulls/${own.number}`, { method: 'PATCH', body: { state: 'closed' } });
          const fresh = await api.request(`${prefix}/pulls/${own.number}`);
          if (fresh.state !== 'closed' || fresh.head?.sha !== bound.pr.head.sha) fail('Scanner retirement PR changed');
          if (bound.issue.state === 'open')
            await api.request(`${prefix}/issues/${bound.issue.number}`, { method: 'PATCH', body: { state: 'closed' } });
          const current = await optionalRef(api, prefix, bound.identity.branch);
          if (current !== undefined) {
            if (current !== bound.pr.head.sha) fail('Scanner retirement ref changed');
            await api.request(`${prefix}/git/refs/heads/${encodeURIComponent(bound.identity.branch)}`, {
              method: 'DELETE',
            });
          }
        }
        result.repositories.push({ repo, status: mode === 'dry-run' ? 'would-retire' : 'retired', pr: own.number });
        continue;
      }
      if (ref === undefined || bound.pr.state !== 'open') fail('Recovered scanner branch is missing');
      if (mode !== 'dry-run') await enableAutoMerge(api, prefix, bound.pr);
      result.repositories.push({ repo, status: 'recovered', pr: own.number });
      continue;
    }
    if (operation === 'retire-only') {
      result.repositories.push({ repo, status: 'noop-retirement' });
      continue;
    }
    const tree = await readManagedTree(api, owner, repo, main.sha, wanted),
      changes = contentDiff(tree, wanted);
    if (!changes.length) {
      result.repositories.push({ repo, status: 'noop' });
      continue;
    }
    let collision = false;
    let unverified = false;
    for (const pr of open) {
      const canonical = await currentCanonicalPrHead(api, owner, repo, pr, wanted);
      const scope =
        canonical === 'canonical'
          ? 'clear'
          : canonical === 'unverified'
            ? 'unverified'
            : await foreignScannerScope(api, owner, repo, pr);
      collision ||= scope !== 'clear';
      unverified ||= scope === 'unverified';
    }
    if (collision) {
      result.repositories.push({
        repo,
        status: 'deferred-collision',
        reason: unverified ? 'unverified-foreign-scanner-scope' : 'foreign-scanner-path-change',
      });
      result.deferred = true;
      continue;
    }
    if (active >= ACTIVE_PR_LIMIT) {
      result.repositories.push({ repo, status: 'deferred-capacity' });
      result.deferred = true;
      continue;
    }
    if (mode === 'dry-run') {
      result.repositories.push({ repo, status: 'would-create', changes: changes.length });
      continue;
    }
    // Sharing the full workflow concurrency group serializes governed fleet writers.
    const freshMain = await api.request(`${prefix}/commits/main`);
    const freshOpen = await listAll(api, `${prefix}/pulls?state=open`);
    if (freshMain.sha !== main.sha || !same(freshOpen.map(foreignPrRefs).sort(), open.map(foreignPrRefs).sort()))
      fail('Concurrent repository change before scanner writes');
    let commit = await optionalRef(api, prefix, identity.branch);
    if (commit === undefined) {
      const base = await api.request(`${prefix}/git/commits/${main.sha}`);
      requireSha(base.tree?.sha, 'base tree SHA');
      for (const change of changes) {
        if (change.action === 'delete') continue;
        const bytes = sourceBuffers.get(change.src);
        if (!bytes) fail('Qualified source bytes unavailable');
        const blob = await api.request(`${prefix}/git/blobs`, {
          method: 'POST',
          body: { content: bytes.toString('base64'), encoding: 'base64' },
        });
        if (blob?.sha !== change.sha) fail('Downstream canonical blob digest differs');
      }
      const created = await api.request(`${prefix}/git/trees`, {
        method: 'POST',
        body: {
          base_tree: base.tree.sha,
          tree: changes.map((c) => ({
            path: c.path,
            mode: c.mode || '100644',
            type: 'blob',
            sha: c.action === 'delete' ? null : c.sha,
          })),
        },
      });
      requireSha(created?.sha, 'scoped tree SHA');
      const made = await api.request(`${prefix}/git/commits`, {
        method: 'POST',
        body: { message: identity.message, tree: created.sha, parents: [main.sha] },
      });
      commit = requireSha(made?.sha, 'scoped commit SHA');
      await api.request(`${prefix}/git/refs`, {
        method: 'POST',
        body: { ref: `refs/heads/${identity.branch}`, sha: commit },
      });
    } else {
      const saved = await api.request(`${prefix}/git/commits/${commit}`);
      if (
        saved.sha !== commit ||
        saved.parents?.length !== 1 ||
        saved.parents[0].sha !== main.sha ||
        saved.message !== identity.message
      )
        fail('Partial scanner branch ownership differs');
      const recovered = await readManagedTree(api, owner, repo, commit, wanted);
      if (contentDiff(recovered, wanted).length) fail('Partial scanner branch tree differs');
      // Exact compare also prevents unrelated paths in an orphaned branch.
      const compare = await api.request(`${prefix}/compare/${main.sha}...${commit}`);
      if (
        compare.total_commits !== 1 ||
        !Array.isArray(compare.files) ||
        compare.files.length !== changes.length ||
        !same(compare.files.map((f) => f.filename).sort(), changes.map((c) => c.path).sort())
      )
        fail('Partial scanner branch has out-of-scope changes');
    }
    const issueBody = scannerIssueBody(identity);
    const issues = await listAll(api, `${prefix}/issues?state=all`);
    const matching = issues.filter((i) => i.title === identity.title && i.body === issueBody && !i.pull_request);
    if (matching.length > 1 || matching.some((i) => i.state !== 'open')) fail('Ambiguous scanner tracking issue');
    const issue =
      matching[0] ||
      (await api.request(`${prefix}/issues`, {
        method: 'POST',
        body: { title: identity.title, body: issueBody, labels: ['governance'] },
      }));
    if (!Number.isSafeInteger(issue.number) || issue.number < 1) fail('Scanner tracker ID missing');
    const pr = await api.request(`${prefix}/pulls`, {
      method: 'POST',
      body: {
        title: identity.title,
        head: identity.branch,
        base: 'main',
        body: `${identity.note}\n\nCloses #${issue.number}`,
      },
    });
    await ownerEvidence(api, prefix, repo, owner, pr, sourceSha, wanted);
    await enableAutoMerge(api, prefix, pr);
    active++;
    result.repositories.push({ repo, status: 'created', pr: pr.number, changes: changes.length });
  }
  return result;
}
async function main() {
  const root = process.env.GITHUB_WORKSPACE || process.cwd();
  const read = (name) => JSON.parse(fs.readFileSync(path.join(root, name), 'utf8'));
  const manifest = read('.github/config/managed-files-manifest.json');
  if (!process.env.GH_TOKEN) fail('GH_TOKEN is required');
  if (!process.env.SCANNER_PATHS) fail('Explicit scanner path scope is required');
  const options = {
    api: new ScannerApiQueue({ token: process.env.GH_TOKEN }),
    owner: (process.env.GITHUB_REPOSITORY || 'f5-sales-demo/docs-control').split('/')[0],
    sourceSha: process.env.SOURCE_SHA || manifest.source_commit,
    sourceRoot: root,
    manifest,
    config: read('.github/config/repo-settings.json'),
    inventory: read('.github/config/downstream-repos.json'),
    selection: process.env.REPOSITORIES,
    paths: JSON.parse(process.env.SCANNER_PATHS),
    mode: process.env.RECONCILE_MODE || 'dry-run',
    operation: process.env.RECONCILE_OPERATION || 'reconcile',
  };
  console.log(JSON.stringify(await reconcileScannerContent(options), null, 2));
}
if (require.main === module)
  main().catch((error) => {
    console.error(error.stack || error.message);
    process.exit(error instanceof GitHubRetryDeferredError ? 84 : 1);
  });
module.exports = {
  SCANNER_PATHS,
  scannerIdentity,
  reconcileScannerContent,
  ScannerApiQueue,
  foreignScannerScope,
  sourceEvidence,
};
