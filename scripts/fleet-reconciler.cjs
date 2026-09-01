#!/usr/bin/env node
'use strict';

// Central, deliberately serial fleet reconciler.  It owns all GitHub mutations
// so downstream repositories never need a governance dispatcher or token.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { GitHubRetryDeferredError, requestGitHubApi } = require('./github-api-resilience.cjs');

const SHA = /^[0-9a-f]{40}$/;
const MODES = new Set(['dry-run', 'pilot', 'full']);
const BRANCH_PREFIXES = new Set([
  'governance/reconcile',
  'governance/bootstrap',
  'governance/sync-managed-files',
]);
const ACTIVE_PR_LIMIT = 2;
const WRITE_GAP_MS = 1000;

function fail(message) {
  throw new Error(message);
}
function requireSha(value, name = 'source SHA') {
  if (!SHA.test(value || '')) fail(`${name} must be a full lowercase commit SHA`);
  return value;
}
function parseSelection(value, inventory) {
  if (!value) return inventory;
  const selected = [...new Set(value.split(',').filter(Boolean))];
  if (!selected.length || selected.some((name) => !inventory.includes(name))) fail('repository selection is invalid');
  return selected;
}
function repositoryApplies(entry, repo, skipFiles) {
  if ((entry.only_repos || []).length && !entry.only_repos.includes(repo)) return false;
  return !(skipFiles[repo] || []).includes(entry.dest);
}
function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object')
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
function manifestStateDigest(files, absentPaths) {
  return `sha256:${crypto.createHash('sha256').update(canonicalJson({ files, absent_paths: absentPaths })).digest('hex')}`;
}
function validateManifest(config, manifest) {
  if (!manifest || manifest.schema_version !== 2 || !SHA.test(manifest.source_commit || '') ||
      !Array.isArray(manifest.files) || !Array.isArray(manifest.absent_paths) ||
      typeof manifest.state_digest !== 'string') fail('managed manifest schema version 2 is required');
  const configFiles = config.managed_files?.files || [];
  const configPaths = configFiles.map((entry) => entry.dest).sort();
  const manifestPaths = manifest.files.map((entry) => entry?.path);
  const configAbsent = [...(config.managed_files?.absent_files || [])].sort();
  const safePath = (value) => typeof value === 'string' && /^[A-Za-z0-9._/-]+$/.test(value) &&
    !value.startsWith('/') && value.split('/').every((part) => part && part !== '.' && part !== '..');
  if (JSON.stringify(manifestPaths) !== JSON.stringify([...manifestPaths].sort()) ||
      new Set(manifestPaths).size !== manifestPaths.length ||
      JSON.stringify(manifest.absent_paths) !== JSON.stringify([...manifest.absent_paths].sort()) ||
      new Set(manifest.absent_paths).size !== manifest.absent_paths.length ||
      manifestPaths.some((entry) => !safePath(entry)) || manifest.absent_paths.some((entry) => !safePath(entry)) ||
      manifestPaths.some((entry) => manifest.absent_paths.includes(entry)))
    fail('managed manifest present and absent paths must be sorted and unique');
  if (JSON.stringify(configPaths) !== JSON.stringify(manifestPaths) ||
      JSON.stringify(configAbsent) !== JSON.stringify(manifest.absent_paths))
    fail('managed configuration and manifest paths disagree');
  const source = new Map(configFiles.map((entry) => [entry.dest, entry.src]));
  for (const receipt of manifest.files) {
    if (!receipt || JSON.stringify(Object.keys(receipt).sort()) !== JSON.stringify(['mode', 'path', 'sha', 'size', 'src']) ||
        source.get(receipt.path) !== receipt.src || !SHA.test(receipt.sha || '') ||
        !['100644', '100755'].includes(receipt.mode) || !Number.isSafeInteger(receipt.size) || receipt.size < 0)
      fail(`invalid manifest receipt for ${receipt?.path || 'unknown path'}`);
  }
  if (manifest.state_digest !== manifestStateDigest(manifest.files, manifest.absent_paths))
    fail('managed manifest state digest is invalid');
  return manifest;
}
function desiredEntries(config, manifest, repo) {
  validateManifest(config, manifest);
  const source = new Map((config.managed_files.files || []).map((entry) => [entry.dest, entry]));
  const skip = config.managed_files.skip_files || {};
  const files = [];
  for (const receipt of manifest.files) {
    const entry = source.get(receipt.path);
    if (!entry || !repositoryApplies(entry, repo, skip)) continue;
    files.push({ path: receipt.path, sha: receipt.sha, mode: receipt.mode, src: receipt.src });
  }
  const deletes = manifest.absent_paths.filter((entry) => !(skip[repo] || []).includes(entry));
  return { files, deletes };
}
function contentDiff(tree, desired) {
  const actual = new Map(
    (tree.tree || []).filter((entry) => entry.type === 'blob').map((entry) => [entry.path, entry]),
  );
  const changes = [];
  for (const wanted of desired.files) {
    const current = actual.get(wanted.path);
    if (!current || current.sha !== wanted.sha || current.mode !== wanted.mode)
      changes.push({ ...wanted, action: 'upsert' });
  }
  for (const absent of desired.deletes) if (actual.has(absent)) changes.push({ path: absent, action: 'delete' });
  return changes.sort((a, b) => a.path.localeCompare(b.path));
}
function reconciliationBranchPrefix(value = 'governance/reconcile') {
  if (!BRANCH_PREFIXES.has(value)) fail('reconciliation branch prefix is invalid');
  return value;
}
function branchName(sourceSha, repo, prefix = 'governance/reconcile') {
  const approvedPrefix = reconciliationBranchPrefix(prefix);
  if (approvedPrefix === 'governance/sync-managed-files') {
    // Downstream developer-owned governance guards recognize this exact form.
    // The repository-derived positive number makes the ref deterministic without
    // exposing an arbitrary caller-controlled suffix.
    const repositoryId = (crypto.createHash('sha256').update(repo).digest().readUInt32BE(0) || 1);
    return `${approvedPrefix}-${sourceSha.slice(0, 12)}-${repositoryId}-1`;
  }
  return `${approvedPrefix}-${sourceSha.slice(0, 12)}-${repo}`;
}
function isReconciliationBranch(ref) {
  return [...BRANCH_PREFIXES].some((prefix) => ref?.startsWith(`${prefix}-`));
}
function marker(sourceSha, desiredTree) {
  return `<!-- governance-reconciler source=${sourceSha} desired-tree=${desiredTree} -->`;
}
function issueTitle(sourceSha) {
  return `Governance reconciliation @ ${sourceSha.slice(0, 12)}`;
}
function managedCommitMessage(sourceSha) {
  // Protected targets require their real pull-request workflows.  Do not add a
  // skip-CI marker here: GitHub would suppress those checks before they can
  // satisfy branch protection.
  return `chore: reconcile governed files @ ${sourceSha.slice(0, 12)}`;
}

class ApiQueue {
  constructor({
    token,
    fetch,
    sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    now = () => Date.now(),
  }) {
    this.token = token;
    this.fetch = fetch;
    this.sleep = sleep;
    this.now = now;
    this.lastWrite = -Infinity;
    this.etags = new Map();
  }
  async request(endpoint, options = {}) {
    const method = options.method || 'GET';
    const isWrite = !['GET', 'HEAD', 'OPTIONS'].includes(method);
    if (isWrite) {
      const wait = Math.max(0, WRITE_GAP_MS - (this.now() - this.lastWrite));
      if (wait) await this.sleep(wait);
    }
    const headers = { ...(options.headers || {}) };
    if (!isWrite && this.etags.has(endpoint)) headers['if-none-match'] = this.etags.get(endpoint);
    const data = await requestGitHubApi(endpoint, {
      token: this.token,
      fetch: this.fetch,
      method,
      body: options.body,
      headers,
      operationName: options.operationName || `${method} ${endpoint}`,
      totalWaitBudgetSeconds: 900,
      onResponse: ({ status, headers: responseHeaders }) => {
        const etag = responseHeaders?.get?.('etag');
        if (!isWrite && status === 200 && etag) this.etags.set(endpoint, etag);
      },
    });
    if (isWrite) this.lastWrite = this.now();
    return data;
  }
}

async function activeGovernancePrs(api, owner, inventory) {
  let active = 0;
  for (const repo of inventory) {
    const prs = await api.request(`repos/${owner}/${repo}/pulls?state=open&per_page=100`, {
      operationName: `list reconciliation PRs for ${repo}`,
    });
    active += prs.filter((pr) => isReconciliationBranch(pr.head?.ref)).length;
  }
  return active;
}

async function enableManagedAutoMerge(api, repo, pullRequestId) {
  await api.request('graphql', {
    method: 'POST',
    body: {
      query:
        'mutation($id:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:SQUASH}){pullRequest{number}}}',
      variables: { id: pullRequestId },
    },
    operationName: `enable reconciliation auto-merge for ${repo}`,
  });
}

function assertAttestableRecovery({ pr, note, changes, files, headTree, desired }) {
  if (pr.base?.ref !== 'main' || !pr.body?.includes(note) || !/^Closes #[1-9][0-9]*$/m.test(pr.body))
    fail('recovered reconciliation PR metadata is invalid');
  const expectedPaths = changes.map((change) => change.path).sort();
  const actualPaths = files.flatMap((file) => [
    file.filename,
    ...(file.status === 'renamed' && typeof file.previous_filename === 'string' ? [file.previous_filename] : []),
  ]).sort();
  if (JSON.stringify(actualPaths) !== JSON.stringify(expectedPaths))
    fail('recovered reconciliation PR contains unexpected paths');
  if (contentDiff(headTree, desired).length)
    fail('recovered reconciliation PR does not contain the desired managed tree');
}

async function createContentPr(
  api,
  { owner, repo, sourceSha, desiredTree, desired, baseSha, changes, sourceRoot, mode, capacityAvailable, branchPrefix },
) {
  const branch = branchName(sourceSha, repo, branchPrefix);
  const note = marker(sourceSha, desiredTree);
  const open = await api.request(
    `repos/${owner}/${repo}/pulls?state=open&head=${owner}:${encodeURIComponent(branch)}&per_page=10`,
    { operationName: `find recovered PR for ${repo}` },
  );
  if (open.length) {
    const recovered = open[0];
    const files = await api.request(`repos/${owner}/${repo}/pulls/${recovered.number}/files?per_page=100`, {
      operationName: `verify recovered PR paths for ${repo}`,
    });
    const headTree = await api.request(`repos/${owner}/${repo}/git/trees/${recovered.head.sha}?recursive=1`, {
      operationName: `verify recovered PR tree for ${repo}`,
    });
    assertAttestableRecovery({ pr: recovered, note, changes, files, headTree, desired });
    await enableManagedAutoMerge(api, repo, recovered.node_id);
    return { status: 'recovered', pr: recovered.number };
  }
  if (mode === 'dry-run') return { status: 'would-create', changes: changes.length };
  if (!capacityAvailable) return { status: 'deferred-capacity' };
  const baseTree = await api.request(`repos/${owner}/${repo}/git/commits/${baseSha}`, {
    operationName: `read base tree for ${repo}`,
  });
  const tree = changes.map((change) => {
    if (change.action === 'delete') return { path: change.path, mode: '100644', type: 'blob', sha: null };
    const bytes = fs.readFileSync(path.join(sourceRoot, change.src));
    return { path: change.path, mode: change.mode, type: 'blob', content: bytes.toString('utf8') };
  });
  const createdTree = await api.request(`repos/${owner}/${repo}/git/trees`, {
    method: 'POST',
    body: { base_tree: baseTree.tree.sha, tree },
    operationName: `build managed tree for ${repo}`,
  });
  const commit = await api.request(`repos/${owner}/${repo}/git/commits`, {
    method: 'POST',
    body: {
      message: managedCommitMessage(sourceSha),
      tree: createdTree.sha,
      parents: [baseSha],
    },
    operationName: `commit managed files for ${repo}`,
  });
  await api.request(`repos/${owner}/${repo}/git/refs`, {
    method: 'POST',
    body: { ref: `refs/heads/${branch}`, sha: commit.sha },
    operationName: `create governance branch for ${repo}`,
  });
  const issues = await api.request(`repos/${owner}/${repo}/issues?state=open&per_page=100`, {
    operationName: `find reconciliation issue for ${repo}`,
  });
  let issue = issues.find((item) => item.title === issueTitle(sourceSha) && item.body?.includes(note));
  if (!issue)
    issue = await api.request(`repos/${owner}/${repo}/issues`, {
      method: 'POST',
      body: {
        title: issueTitle(sourceSha),
        body: `${note}\n\nCentral reconciliation of managed files.`,
        labels: ['governance'],
      },
      operationName: `create reconciliation issue for ${repo}`,
    });
  const pr = await api.request(`repos/${owner}/${repo}/pulls`, {
    method: 'POST',
    body: { title: issueTitle(sourceSha), head: branch, base: 'main', body: `${note}\n\nCloses #${issue.number}` },
    operationName: `create reconciliation PR for ${repo}`,
  });
  await enableManagedAutoMerge(api, repo, pr.node_id);
  return { status: 'created', pr: pr.number, changes: changes.length };
}

async function reconcileContent(options) {
  const { api, owner, sourceSha, mode, inventory, config, manifest, sourceRoot, selection, branchPrefix = 'governance/reconcile' } = options;
  requireSha(sourceSha);
  if (!MODES.has(mode)) fail('mode must be dry-run, pilot, or full');
  reconciliationBranchPrefix(branchPrefix);
  const repos = parseSelection(selection, inventory);
  const result = { sourceSha, mode, repositories: [], deferred: false };
  let active = await activeGovernancePrs(api, owner, inventory);
  for (const repo of repos) {
    const main = await api.request(`repos/${owner}/${repo}/commits/main`, {
      operationName: `read protected main for ${repo}`,
    });
    const desired = desiredEntries(config, manifest, repo);
    const tree = await api.request(`repos/${owner}/${repo}/git/trees/${main.sha}?recursive=1`, {
      operationName: `read managed tree for ${repo}`,
    });
    const changes = contentDiff(tree, desired);
    const desiredTree = require('node:crypto').createHash('sha256').update(JSON.stringify(desired)).digest('hex');
    if (!changes.length) {
      result.repositories.push({ repo, status: 'noop' });
      continue;
    }
    const outcome = await createContentPr(api, {
      owner,
      repo,
      sourceSha,
      desiredTree,
      desired,
      baseSha: main.sha,
      changes,
      sourceRoot,
      mode,
      capacityAvailable: active < ACTIVE_PR_LIMIT,
      branchPrefix,
    });
    if (outcome.status === 'created') active += 1;
    if (outcome.status === 'deferred-capacity') result.deferred = true;
    result.repositories.push({ repo, ...outcome });
  }
  return result;
}

function settingsDelta(current, desired) {
  const delta = {};
  for (const [key, value] of Object.entries(desired))
    if (JSON.stringify(current[key]) !== JSON.stringify(value)) delta[key] = value;
  return delta;
}
function desiredProtection(config, repo) {
  const base = (config.branch_protection || []).find((entry) => entry.branch === 'main');
  if (!base) return null;
  const override = config.repo_overrides?.[repo] || {};
  const {
    self_contexts: _selfContexts,
    contexts: _configuredContexts,
    checks: _configuredChecks,
    ...requiredStatusChecks
  } = base.required_status_checks || {};
  // This reconciler only manages downstream repositories. `self_contexts`
  // documents docs-control's own unqualified workflow names; downstream
  // workflows report the qualified names in `contexts`.
  const contexts = [
    ...new Set([...(base.required_status_checks?.contexts || []), ...(override.additional_contexts || [])]),
  ].sort();
  const checks = contexts.map((context) => ({
    context,
    // GitHub documents -1 as an explicit any-app binding. Exact-commit central
    // statuses can then satisfy the complete repository-specific check set on
    // managed PRs, while developer PRs still have to run those same contexts.
    app_id: -1,
  }));
  checks.sort((a, b) => a.context.localeCompare(b.context) || a.app_id - b.app_id);
  return {
    enforce_admins: base.enforce_admins,
    required_status_checks: { ...requiredStatusChecks, contexts: [], checks },
    required_pull_request_reviews: base.required_pull_request_reviews,
    restrictions: base.restrictions,
    required_linear_history: base.required_linear_history,
    allow_force_pushes: base.allow_force_pushes,
    allow_deletions: base.allow_deletions,
    block_creations: base.block_creations,
    required_conversation_resolution: base.required_conversation_resolution,
    lock_branch: base.lock_branch,
    allow_fork_syncing: base.allow_fork_syncing,
  };
}
function currentProtection(protection) {
  const enabled = (value) => (typeof value === 'object' ? Boolean(value.enabled) : Boolean(value));
  const identities = (items = []) =>
    items.map((item) => (typeof item === 'string' ? item : item.login || item.slug)).sort();
  const review = protection.required_pull_request_reviews;
  const normalizedReview =
    review === null
      ? null
      : {
          dismiss_stale_reviews: review?.dismiss_stale_reviews || false,
          require_code_owner_reviews: review?.require_code_owner_reviews || false,
          required_approving_review_count: review?.required_approving_review_count || 0,
          require_last_push_approval: review?.require_last_push_approval || false,
          dismissal_restrictions: {
            users: identities(review?.dismissal_restrictions?.users),
            teams: identities(review?.dismissal_restrictions?.teams),
          },
          bypass_pull_request_allowances: {
            users: identities(review?.bypass_pull_request_allowances?.users),
            teams: identities(review?.bypass_pull_request_allowances?.teams),
            apps: identities(review?.bypass_pull_request_allowances?.apps),
          },
        };
  const normalizedRestrictions = {
    users: identities(protection.restrictions?.users),
    teams: identities(protection.restrictions?.teams),
    apps: identities(protection.restrictions?.apps),
  };
  const restrictions =
    protection.restrictions === null || Object.values(normalizedRestrictions).every((items) => items.length === 0)
      ? null
      : normalizedRestrictions;
  const checks = [...(protection.required_status_checks?.checks || [])]
    .map((check) => ({ context: check.context, app_id: check.app_id ?? -1 }))
    .sort((a, b) => a.context.localeCompare(b.context) || a.app_id - b.app_id);
  return {
    enforce_admins: enabled(protection.enforce_admins),
    required_status_checks: protection.required_status_checks && {
      strict: protection.required_status_checks.strict,
      contexts: checks.length ? [] : [...(protection.required_status_checks.contexts || [])].sort(),
      checks,
    },
    required_pull_request_reviews: normalizedReview,
    restrictions,
    required_linear_history: enabled(protection.required_linear_history),
    allow_force_pushes: enabled(protection.allow_force_pushes),
    allow_deletions: enabled(protection.allow_deletions),
    block_creations: enabled(protection.block_creations),
    required_conversation_resolution: enabled(protection.required_conversation_resolution),
    lock_branch: enabled(protection.lock_branch),
    allow_fork_syncing: enabled(protection.allow_fork_syncing),
  };
}
function aggregateProtection(protection) {
  if (!protection) return protection;
  const status = protection.required_status_checks;
  return {
    ...protection,
    required_status_checks:
      status === null
        ? null
        : {
            strict: status.strict,
            contexts: (status.checks || []).map((check) => check.context).sort(),
          },
  };
}
async function reconcileSettings(options) {
  const { api, owner, inventory, config, selection, mode } = options;
  const repos = parseSelection(selection, inventory);
  const result = [];
  for (const repo of repos) {
    const current = await api.request(`repos/${owner}/${repo}`, { operationName: `read settings for ${repo}` });
    const delta = settingsDelta(current, config.repository);
    if (mode === 'dry-run') {
      result.push({ repo, status: Object.keys(delta).length ? 'would-update' : 'noop', delta });
      continue;
    }
    if (Object.keys(delta).length) {
      await api.request(`repos/${owner}/${repo}`, {
        method: 'PATCH',
        body: delta,
        operationName: `repair settings for ${repo}`,
      });
      const verified = await api.request(`repos/${owner}/${repo}`, { operationName: `verify settings for ${repo}` });
      if (Object.keys(settingsDelta(verified, delta)).length) fail(`settings verification failed for ${repo}`);
    }
    const actions = await api.request(`repos/${owner}/${repo}/actions/permissions/workflow`, {
      operationName: `read Actions policy for ${repo}`,
    });
    const actionsDelta = settingsDelta(actions, config.actions_permissions || {});
    if (Object.keys(actionsDelta).length) {
      await api.request(`repos/${owner}/${repo}/actions/permissions/workflow`, {
        method: 'PUT',
        body: actionsDelta,
        operationName: `repair Actions policy for ${repo}`,
      });
    }
    const fork = await api.request(`repos/${owner}/${repo}/actions/permissions/fork-pr-contributor-approval`, {
      operationName: `read fork approval policy for ${repo}`,
    });
    const forkDelta = settingsDelta(fork, config.actions_fork_pr_approval || {});
    if (Object.keys(forkDelta).length) {
      await api.request(`repos/${owner}/${repo}/actions/permissions/fork-pr-contributor-approval`, {
        method: 'PUT',
        body: forkDelta,
        operationName: `repair fork approval policy for ${repo}`,
      });
    }
    const protection = await api.request(`repos/${owner}/${repo}/branches/main/protection`, {
      operationName: `read branch protection for ${repo}`,
    });
    const wantedProtection = desiredProtection(config, repo);
    const normalizedProtection = currentProtection(protection);
    const aggregateDelta =
      JSON.stringify(aggregateProtection(normalizedProtection)) ===
      JSON.stringify(aggregateProtection(wantedProtection))
        ? null
        : aggregateProtection(wantedProtection);
    const statusChecksDelta =
      JSON.stringify(normalizedProtection.required_status_checks) ===
      JSON.stringify(wantedProtection.required_status_checks)
        ? null
        : wantedProtection.required_status_checks;
    if (aggregateDelta) {
      await api.request(`repos/${owner}/${repo}/branches/main/protection`, {
        method: 'PUT',
        body: aggregateDelta,
        operationName: `repair branch protection for ${repo}`,
      });
    }
    if (statusChecksDelta || aggregateDelta) {
      await api.request(`repos/${owner}/${repo}/branches/main/protection/required_status_checks`, {
        method: 'PATCH',
        body: wantedProtection.required_status_checks,
        operationName: `repair required check bindings for ${repo}`,
      });
      const verified = await api.request(`repos/${owner}/${repo}/branches/main/protection`, {
        operationName: `verify branch protection for ${repo}`,
      });
      if (JSON.stringify(currentProtection(verified)) !== JSON.stringify(wantedProtection))
        fail(`branch protection verification failed for ${repo}`);
    }
    result.push({
      repo,
      status:
        Object.keys(delta).length ||
        Object.keys(actionsDelta).length ||
        Object.keys(forkDelta).length ||
        aggregateDelta ||
        statusChecksDelta
          ? 'updated'
          : 'noop',
      delta,
    });
  }
  return result;
}

async function main() {
  const mode = process.env.RECONCILE_MODE || 'full';
  const kind = process.env.RECONCILE_KIND || 'content';
  const root = process.env.GITHUB_WORKSPACE || process.cwd();
  const token = process.env.GH_TOKEN;
  if (!token) fail('GH_TOKEN is required (GitHub App installation token preferred)');
  const sourceSha =
    process.env.SOURCE_SHA ||
    JSON.parse(fs.readFileSync(path.join(root, '.github/config/managed-files-manifest.json'))).source_commit;
  const inventory = JSON.parse(fs.readFileSync(path.join(root, '.github/config/downstream-repos.json')));
  const config = JSON.parse(fs.readFileSync(path.join(root, '.github/config/repo-settings.json')));
  const manifest = JSON.parse(fs.readFileSync(path.join(root, '.github/config/managed-files-manifest.json')));
  const owner = (process.env.GITHUB_REPOSITORY || 'f5-sales-demo/docs-control').split('/')[0];
  const api = new ApiQueue({ token });
  const result =
    kind === 'settings'
      ? await reconcileSettings({ api, owner, inventory, config, selection: process.env.REPOSITORIES, mode })
      : await reconcileContent({
          api,
          owner,
          sourceSha,
          mode,
          inventory,
          config,
          manifest,
          sourceRoot: root,
          selection: process.env.REPOSITORIES,
          branchPrefix: reconciliationBranchPrefix(process.env.RECONCILE_BRANCH_PREFIX || 'governance/reconcile'),
        });
  console.log(JSON.stringify(result, null, 2));
}
if (require.main === module)
  main().catch((error) => {
    console.error(error.stack || error.message);
    process.exit(error instanceof GitHubRetryDeferredError ? 84 : 1);
  });

module.exports = {
  ACTIVE_PR_LIMIT,
  ApiQueue,
  aggregateProtection,
  assertAttestableRecovery,
  contentDiff,
  branchName,
  currentProtection,
  desiredEntries,
  desiredProtection,
  managedCommitMessage,
  manifestStateDigest,
  reconciliationBranchPrefix,
  parseSelection,
  reconcileContent,
  reconcileSettings,
  repositoryApplies,
  requireSha,
  settingsDelta,
  validateManifest,
};
