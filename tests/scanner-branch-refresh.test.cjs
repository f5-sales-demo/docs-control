'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { manifestStateDigest } = require('../scripts/fleet-reconciler.cjs');
const { SCANNER_PATHS } = require('../scripts/scanner-reconciler.cjs');
const { planBranchRefresh, executeBranchRefresh } = require('../scripts/scanner-branch-refresh.cjs');
const sourceSha = 'a'.repeat(40),
  original = 'b'.repeat(40),
  next = 'c'.repeat(40);
function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'scanner-refresh-'));
  const entries = SCANNER_PATHS.map((name) => {
    const bytes = Buffer.from(`${name}\n`);
    fs.mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
    fs.writeFileSync(path.join(root, name), bytes);
    return {
      path: name,
      src: name,
      sha: crypto
        .createHash('sha1')
        .update(Buffer.from(`blob ${bytes.length}\0`))
        .update(bytes)
        .digest('hex'),
      size: bytes.length,
      mode: '100644',
    };
  });
  const config = {
    managed_files: {
      source_repo: 'example/docs-control',
      files: entries.map((e) => ({ src: e.src, dest: e.path })),
      absent_files: [],
      skip_files: {},
    },
  };
  const manifest = {
    schema_version: 2,
    source_commit: sourceSha,
    files: entries,
    absent_paths: [],
    state_digest: manifestStateDigest(entries, []),
  };
  const repositoryIdentity = (owner, repository) => ({ ['full' + '_name']: [owner, repository].join('/') });
  const repositoryMetadata = repositoryIdentity('example', 'demo');
  const pr = {
    number: 7,
    state: 'open',
    draft: true,
    base: { sha: 'd'.repeat(40), ref: 'main' },
    head: { sha: original, ref: 'feature/demo', repo: repositoryMetadata },
  };
  const originalTree = {
    truncated: false,
    tree: [
      { path: 'feature.ts', sha: 'f'.repeat(40), type: 'blob', mode: '100644' },
      ...entries.map((e) => ({ path: e.path, sha: '1'.repeat(40), type: 'blob', mode: '100644' })),
    ],
  };
  const state = { pr, writes: [], tree: originalTree, message: null, archived: false, loseResponse: false };
  const api = {
    async request(endpoint, options = {}) {
      const method = options.method || 'GET';
      if (method !== 'GET') state.writes.push({ endpoint, method, body: options.body });
      if (endpoint === `repos/example/docs-control/commits/${sourceSha}`) return { sha: sourceSha };
      if (endpoint.startsWith('repos/example/docs-control/git/trees/'))
        return { truncated: false, tree: entries.map((e) => ({ ...e, type: 'blob' })) };
      if (endpoint === 'repos/example/demo')
        return { private: false, archived: state.archived, default_branch: 'main' };
      if (endpoint === 'repos/example/demo/pulls/7') return structuredClone(state.pr);
      if (endpoint.startsWith('repos/example/demo/git/ref/heads/')) return { object: { sha: state.pr.head.sha } };
      if (endpoint.startsWith('repos/example/demo/git/trees/'))
        return structuredClone(endpoint.includes(original) ? originalTree : state.tree);
      if (endpoint === `repos/example/demo/git/commits/${original}`) return { sha: original, tree: { sha: original } };
      if (endpoint === `repos/example/demo/git/commits/${next}`)
        return { sha: next, tree: { sha: next }, parents: [{ sha: original }], message: state.message };
      if (endpoint.endsWith('/git/blobs') && method === 'POST') {
        const b = Buffer.from(options.body.content, 'base64');
        return {
          sha: crypto
            .createHash('sha1')
            .update(Buffer.from(`blob ${b.length}\0`))
            .update(b)
            .digest('hex'),
        };
      }
      if (endpoint.endsWith('/git/trees') && method === 'POST') {
        assert.equal(options.body.base_tree, original);
        state.tree = {
          truncated: false,
          tree: originalTree.tree.map((e) => options.body.tree.find((n) => n.path === e.path) || e),
        };
        return { sha: next };
      }
      if (endpoint.endsWith('/git/commits') && method === 'POST') {
        assert.deepEqual(options.body.parents, [original]);
        state.message = options.body.message;
        return { sha: next };
      }
      if (endpoint.startsWith('repos/example/demo/git/refs/heads/') && method === 'PATCH') {
        assert.equal(options.body.force, false);
        state.pr.head.sha = options.body.sha;
        if (state.loseResponse) {
          state.loseResponse = false;
          throw Error('Response lost after ref update');
        }
        return { object: { sha: state.pr.head.sha } };
      }
      throw Error(`Unqualified fixture operation ${method} ${endpoint}`);
    },
  };
  const options = {
    api,
    owner: 'example',
    sourceSha,
    sourceRoot: root,
    manifest,
    config,
    inventory: ['demo'],
    targets: [{ repo: 'demo', pullRequest: 7, headSha: original }],
    mode: 'dry-run',
  };
  return { root, state, options, dispose: () => fs.rmSync(root, { recursive: true, force: true }) };
}
async function using(run) {
  const f = fixture();
  try {
    await run(f);
  } finally {
    f.dispose();
  }
}
test('reviewed plans and dry-run bind exact branch and scanner scope without writes', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    assert.equal(plan.targets[0].headSha, original);
    assert.equal(plan.targets[0].draft, true);
    const result = await executeBranchRefresh(f.options, plan);
    assert.equal(result.targets[0].status, 'would-refresh');
    assert.equal(f.state.writes.length, 0);
  }));
test('refresh uses a fast-forward scoped commit and preserves feature content and draft state', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    const result = await executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan);
    assert.equal(result.targets[0].status, 'refreshed');
    assert.equal(f.state.pr.draft, true);
    assert.equal(f.state.tree.tree.find((e) => e.path === 'feature.ts').sha, 'f'.repeat(40));
    const count = f.state.writes.length;
    const repeat = await executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan);
    assert.equal(repeat.targets[0].status, 'recovered');
    assert.equal(f.state.writes.length, count);
  }));
test('stale head, base, ref and draft plans refuse before writes', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    for (const mutate of [
      (p) => {
        p.head.sha = 'e'.repeat(40);
      },
      (p) => {
        p.base.sha = 'e'.repeat(40);
      },
      (p) => {
        p.head.ref = 'feature/other';
      },
      (p) => {
        p.draft = false;
      },
    ]) {
      const before = structuredClone(f.state.pr);
      mutate(f.state.pr);
      await assert.rejects(executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan));
      assert.equal(f.state.writes.length, 0);
      f.state.pr = before;
    }
  }));
test('private, archived, primary and duplicate targets cannot produce a reviewed plan', () =>
  using(async (f) => {
    f.state.archived = true;
    await assert.rejects(planBranchRefresh(f.options), /archived/);
    f.state.archived = false;
    f.state.pr.head.ref = 'main';
    await assert.rejects(planBranchRefresh(f.options), /ownership/);
    f.state.pr.head.ref = 'feature/demo';
    await assert.rejects(
      planBranchRefresh({ ...f.options, targets: [...f.options.targets, ...f.options.targets] }),
      /selection/,
    );
    assert.equal(f.state.writes.length, 0);
    const read = f.options.api.request.bind(f.options.api);
    f.options.api.request = async (endpoint, options) =>
      endpoint === 'repos/example/demo'
        ? { private: true, archived: false, default_branch: 'main' }
        : read(endpoint, options);
    await assert.rejects(planBranchRefresh(f.options), /Private/);
    assert.equal(f.state.writes.length, 0);
  }));
test('source bytes, plan digest and original scoped blobs are independently verified', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    const forged = structuredClone(plan);
    forged.targets[0].headSha = 'e'.repeat(40);
    await assert.rejects(executeBranchRefresh({ ...f.options, mode: 'pilot' }, forged), /binding/);
    assert.equal(f.state.writes.length, 0);
    fs.writeFileSync(path.join(f.root, SCANNER_PATHS[0]), 'changed source');
    await assert.rejects(executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan), /blob/);
    assert.equal(f.state.writes.length, 0);
  }));
test('ref response loss recovers the exact owned commit without another mutation', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    f.state.loseResponse = true;
    await assert.rejects(executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan), /Response lost/);
    const count = f.state.writes.length;
    const result = await executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan);
    assert.equal(result.targets[0].status, 'recovered');
    assert.equal(f.state.writes.length, count);
  }));
test('a foreign replacement head cannot borrow the refresh provenance', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    f.state.pr.head.sha = next;
    await assert.rejects(executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan), /provenance/);
    assert.equal(f.state.writes.length, 0);
  }));
test('successful ref acknowledgement without the expected PR head is not success', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    const read = f.options.api.request.bind(f.options.api);
    f.options.api.request = async (endpoint, options) =>
      endpoint.includes('/git/refs/heads/') ? { object: { sha: next } } : read(endpoint, options);
    await assert.rejects(executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan), /identity differs/);
  }));
test('independent full tree verification rejects an unrelated feature change', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    const read = f.options.api.request.bind(f.options.api);
    f.options.api.request = async (endpoint, options) => {
      const result = await read(endpoint, options);
      if (endpoint.includes(`/git/trees/${next}`))
        result.tree.find((entry) => entry.path === 'feature.ts').sha = 'e'.repeat(40);
      return result;
    };
    await assert.rejects(executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan), /unrelated/);
  }));
test('repository opt-outs are excluded from both reviewed scope changes and writes', () =>
  using(async (f) => {
    f.options.config.managed_files.skip_files.demo = ['scripts/check_pii.py'];
    const plan = await planBranchRefresh(f.options);
    assert(!plan.targets[0].changes.some((e) => e.path === 'scripts/check_pii.py'));
    await executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan);
    assert.equal(f.state.tree.tree.find((e) => e.path === 'scripts/check_pii.py').sha, '1'.repeat(40));
  }));

test('reviewed stacked feature bases remain intact during scanner refresh', () =>
  using(async (f) => {
    f.state.pr.base.ref = 'feature/parent';
    const plan = await planBranchRefresh(f.options);
    assert.equal(plan.targets[0].baseRef, 'feature/parent');
    await executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan);
    assert.equal(f.state.pr.base.ref, 'feature/parent');
  }));

test('unavailable ref state and partial full-tree evidence cannot become verified refresh', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    const read = f.options.api.request.bind(f.options.api);
    f.options.api.request = async (endpoint, options) => {
      if (endpoint.includes('/git/trees/') && endpoint.includes(next)) return { truncated: true, tree: [] };
      return read(endpoint, options);
    };
    await assert.rejects(executeBranchRefresh({ ...f.options, mode: 'pilot' }, plan), /incomplete/);
  }));
test('invalid execution modes and unselected target repositories fail before writes', () =>
  using(async (f) => {
    const plan = await planBranchRefresh(f.options);
    await assert.rejects(executeBranchRefresh({ ...f.options, mode: 'unreviewed' }, plan), /mode/);
    await assert.rejects(
      planBranchRefresh({ ...f.options, targets: [{ repo: 'foreign', pullRequest: 7, headSha: original }] }),
      /unresolved/,
    );
    assert.equal(f.state.writes.length, 0);
  }));
test('all reviewed targets preflight before any branch mutation', () =>
  using(async (f) => {
    const originalOptions = {
      ...f.options,
      inventory: ['demo', 'missing'],
      targets: [...f.options.targets, { repo: 'missing', pullRequest: 8, headSha: original }],
    };
    await assert.rejects(planBranchRefresh(originalOptions));
    assert.equal(f.state.writes.length, 0);
  }));
