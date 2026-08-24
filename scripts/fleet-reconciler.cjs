#!/usr/bin/env node
'use strict';

// Central, deliberately serial fleet reconciler.  It owns all GitHub mutations
// so downstream repositories never need a governance dispatcher or token.
const fs = require('node:fs');
const path = require('node:path');
const { GitHubRetryDeferredError, requestGitHubApi } = require('./github-api-resilience.cjs');

const SHA = /^[0-9a-f]{40}$/;
const MODES = new Set(['dry-run', 'pilot', 'full']);
const ACTIVE_PR_LIMIT = 2;
const WRITE_GAP_MS = 1000;
const ATTESTED_CONTEXTS = ['lint / Lint Code Base', 'lint / Shell Unit Tests'];

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
function desiredEntries(config, manifest, repo) {
  const source = new Map((config.managed_files.files || []).map((entry) => [entry.dest, entry]));
  const skip = config.managed_files.skip_files || {};
  const files = [];
  for (const [dest, receipt] of Object.entries(manifest.files || {})) {
    const entry = source.get(dest);
    if (!entry || !repositoryApplies(entry, repo, skip)) continue;
    if (!SHA.test(receipt.sha) || !['100644', '100755'].includes(receipt.mode))
      fail(`invalid manifest receipt for ${dest}`);
    files.push({ path: dest, sha: receipt.sha, mode: receipt.mode, src: receipt.src });
  }
  const deletes = (config.managed_files.absent_files || []).filter((entry) => !(skip[repo] || []).includes(entry));
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
function branchName(sourceSha, repo) {
  return `governance/reconcile-${sourceSha.slice(0, 12)}-${repo}`;
}
function marker(sourceSha, desiredTree) {
  return `<!-- governance-reconciler source=${sourceSha} desired-tree=${desiredTree} -->`;
}
function issueTitle(sourceSha) {
  return `Governance reconciliation @ ${sourceSha.slice(0, 12)}`;
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
    active += prs.filter((pr) => pr.head?.ref?.startsWith('governance/reconcile-')).length;
  }
  return active;
}

async function attestManagedCommit(api, { owner, repo, sha, sourceSha }) {
  for (const context of ATTESTED_CONTEXTS) {
    await api.request(`repos/${owner}/${repo}/statuses/${sha}`, {
      method: 'POST',
      body: {
        state: 'success',
        context,
        description: `Canonical managed tree verified @ ${sourceSha.slice(0, 12)}`,
        target_url: `https://github.com/${owner}/docs-control/commit/${sourceSha}`,
      },
      operationName: `attest ${context} for ${repo}`,
    });
  }
}

function assertAttestableRecovery({ pr, note, changes, files, headTree, desired }) {
  if (pr.base?.ref !== 'main' || !pr.body?.includes(note)) fail('recovered reconciliation PR metadata is invalid');
  const expectedPaths = changes.map((change) => change.path).sort();
  const actualPaths = files.map((file) => file.filename).sort();
  if (JSON.stringify(actualPaths) !== JSON.stringify(expectedPaths))
    fail('recovered reconciliation PR contains unexpected paths');
  if (contentDiff(headTree, desired).length)
    fail('recovered reconciliation PR does not contain the desired managed tree');
}

async function createContentPr(
  api,
  { owner, repo, sourceSha, desiredTree, desired, baseSha, changes, sourceRoot, mode },
) {
  const branch = branchName(sourceSha, repo);
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
    await attestManagedCommit(api, { owner, repo, sha: recovered.head.sha, sourceSha });
    return { status: 'recovered', pr: recovered.number };
  }
  if (mode === 'dry-run') return { status: 'would-create', changes: changes.length };
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
      message: `chore: reconcile governed files @ ${sourceSha.slice(0, 12)}`,
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
  await attestManagedCommit(api, { owner, repo, sha: commit.sha, sourceSha });
  await api.request('graphql', {
    method: 'POST',
    body: {
      query:
        'mutation($id:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:SQUASH}){pullRequest{number}}}',
      variables: { id: pr.node_id },
    },
    operationName: `enable reconciliation auto-merge for ${repo}`,
  });
  return { status: 'created', pr: pr.number, changes: changes.length };
}

async function reconcileContent(options) {
  const { api, owner, sourceSha, mode, inventory, config, manifest, sourceRoot, selection } = options;
  requireSha(sourceSha);
  if (!MODES.has(mode)) fail('mode must be dry-run, pilot, or full');
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
    if (active >= ACTIVE_PR_LIMIT && mode !== 'dry-run') {
      result.repositories.push({ repo, status: 'deferred-capacity' });
      result.deferred = true;
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
    });
    if (outcome.status === 'created') active += 1;
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
  const { self_contexts: _selfContexts, ...requiredStatusChecks } = base.required_status_checks || {};
  // This reconciler only manages downstream repositories. `self_contexts`
  // documents docs-control's own unqualified workflow names; downstream
  // workflows report the qualified names in `contexts`.
  const contexts = [
    ...new Set([...(base.required_status_checks?.contexts || []), ...(override.additional_contexts || [])]),
  ].sort();
  return {
    enforce_admins: base.enforce_admins,
    required_status_checks: { ...requiredStatusChecks, contexts },
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
  return {
    enforce_admins: enabled(protection.enforce_admins),
    required_status_checks: protection.required_status_checks && {
      strict: protection.required_status_checks.strict,
      contexts: [...(protection.required_status_checks.contexts || [])].sort(),
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
    const protectionDelta =
      JSON.stringify(currentProtection(protection)) === JSON.stringify(wantedProtection) ? null : wantedProtection;
    if (protectionDelta) {
      await api.request(`repos/${owner}/${repo}/branches/main/protection`, {
        method: 'PUT',
        body: protectionDelta,
        operationName: `repair branch protection for ${repo}`,
      });
    }
    result.push({
      repo,
      status:
        Object.keys(delta).length ||
        Object.keys(actionsDelta).length ||
        Object.keys(forkDelta).length ||
        protectionDelta
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
  ATTESTED_CONTEXTS,
  ApiQueue,
  assertAttestableRecovery,
  contentDiff,
  currentProtection,
  desiredEntries,
  desiredProtection,
  parseSelection,
  reconcileContent,
  reconcileSettings,
  repositoryApplies,
  requireSha,
  settingsDelta,
};
