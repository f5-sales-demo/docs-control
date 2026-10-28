'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { manifestStateDigest } = require('../scripts/fleet-reconciler.cjs');
const {
  reconcileScannerContent,
  scannerIdentity,
  SCANNER_PATHS,
  ScannerApiQueue,
} = require('../scripts/scanner-reconciler.cjs');
const sha = 'a'.repeat(40),
  baseSha = 'b'.repeat(40),
  headSha = 'c'.repeat(40);
function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'scanner-lifecycle-'));
  const entries = [...SCANNER_PATHS, 'AGENTS.md'].sort().map((p) => {
    const bytes = Buffer.from(`${p}\n`);
    fs.mkdirSync(path.dirname(path.join(root, p)), { recursive: true });
    fs.writeFileSync(path.join(root, p), bytes);
    return {
      path: p,
      src: p,
      size: bytes.length,
      mode: '100644',
      sha: crypto
        .createHash('sha1')
        .update(Buffer.from(`blob ${bytes.length}\0`))
        .update(bytes)
        .digest('hex'),
    };
  });
  const config = {
    managed_files: {
      source_repo: 'example/docs-control',
      files: entries.map((e) => ({ src: e.src, dest: e.path })),
      absent_files: [],
      skip_files: { two: ['scripts/check_pii.py'] },
    },
  };
  const manifest = {
    schema_version: 2,
    source_commit: sha,
    files: entries,
    absent_paths: [],
    state_digest: manifestStateDigest(entries, []),
  };
  const state = { prs: [], issues: [], refs: new Map(), writes: [], tree: null, archived: false, partial: false };
  const sourceTree = { truncated: false, tree: entries.map((e) => ({ ...e, type: 'blob' })) };
  const baseTree = { truncated: false, tree: [] };
  const api = {
    async request(endpoint, options = {}) {
      const method = options.method || 'GET',
        body = options.body;
      if (method !== 'GET') state.writes.push({ endpoint, method, body });
      if (endpoint === `repos/example/docs-control/commits/${sha}`) return { sha };
      if (endpoint.startsWith('repos/example/docs-control/git/trees/')) return sourceTree;
      if (endpoint === 'repos/example/one' || endpoint === 'repos/example/two')
        return { archived: state.archived, default_branch: 'main' };
      if (endpoint === 'repos/example/one/commits/main' || endpoint === 'repos/example/two/commits/main')
        return { sha: baseSha };
      if (endpoint.includes('/pulls?'))
        return state.prs.filter((pr) => !endpoint.includes('state=open') || pr.state === 'open');
      if (endpoint.endsWith('/issues?state=all&per_page=100&page=1')) return state.issues;
      if (endpoint.includes('/pulls/') && endpoint.includes('/files?'))
        return state.partial ? [] : state.prs.find((p) => endpoint.includes(`/pulls/${p.number}/`)).files;
      if (endpoint.includes('/pulls/') && endpoint.includes('/commits?'))
        return [{ sha: headSha, parents: [{ sha: baseSha }], commit: { message: state.commitMessage } }];
      if (endpoint.match(/\/pulls\/\d+$/)) {
        const p = state.prs.find((p) => endpoint.endsWith(`/${p.number}`));
        if (method === 'PATCH') {
          p.state = body.state;
          return p;
        }
        return p;
      }
      if (endpoint.match(/\/issues\/\d+$/)) {
        const issue = state.issues.find((i) => endpoint.endsWith(`/${i.number}`));
        if (method === 'PATCH') {
          issue.state = body.state;
          return issue;
        }
        return issue;
      }
      if (endpoint.includes('/git/ref/heads/')) {
        const ref = decodeURIComponent(endpoint.split('/heads/')[1]);
        if (!state.refs.has(ref)) {
          const error = new Error('not found');
          error.status = 404;
          throw error;
        }
        return { object: { sha: state.refs.get(ref) } };
      }
      if (endpoint.includes('/git/refs/heads/') && method === 'DELETE') {
        state.refs.delete(decodeURIComponent(endpoint.split('/heads/')[1]));
        return {};
      }
      if (endpoint.endsWith(`/git/commits/${baseSha}`)) return { tree: { sha: baseSha } };
      if (endpoint.endsWith(`/git/commits/${headSha}`))
        return { sha: headSha, parents: [{ sha: baseSha }], message: state.commitMessage, tree: { sha: headSha } };
      if (endpoint.includes('/git/trees/') && method === 'GET')
        return endpoint.includes(baseSha) ? baseTree : state.tree;
      if (endpoint.endsWith('/git/blobs') && method === 'POST') {
        assert.equal(body.encoding, 'base64');
        const bytes = Buffer.from(body.content, 'base64');
        return {
          sha: crypto
            .createHash('sha1')
            .update(Buffer.from(`blob ${bytes.length}\0`))
            .update(bytes)
            .digest('hex'),
        };
      }
      if (endpoint.endsWith('/git/trees') && method === 'POST') {
        state.tree = { truncated: false, tree: body.tree };
        return { sha: headSha };
      }
      if (endpoint.endsWith('/git/commits') && method === 'POST') {
        state.commitMessage = body.message;
        return { sha: headSha };
      }
      if (endpoint.endsWith('/git/refs') && method === 'POST') {
        state.refs.set(body.ref.replace('refs/heads/', ''), body.sha);
        return {};
      }
      if (endpoint.endsWith('/issues') && method === 'POST') {
        const issue = { ...body, number: 4, state: 'open', user: { login: 'app' } };
        state.issues.push(issue);
        return issue;
      }
      if (endpoint.endsWith('/pulls') && method === 'POST') {
        const repositoryMetadata = JSON.parse('{"full_name":"example/one","default_branch":"main"}');
        const files = state.tree.tree.map((e) => ({ filename: e.path, status: e.sha === null ? 'removed' : 'added' }));
        const pr = {
          ...body,
          number: 5,
          node_id: 'PR_node_5',
          state: 'open',
          changed_files: files.length,
          user: { login: 'app' },
          base: { ref: 'main' },
          head: { ref: body.head, sha: headSha, repo: repositoryMetadata },
          files,
        };
        state.prs.push(pr);
        return pr;
      }
      if (endpoint === 'graphql') {
        return { data: { enablePullRequestAutoMerge: { pullRequest: { number: 5 } } } };
      }
      throw Error(`Unexpected API request ${method} ${endpoint}`);
    },
  };
  return {
    root,
    state,
    entries,
    api,
    options: {
      api,
      owner: 'example',
      sourceSha: sha,
      sourceRoot: root,
      manifest,
      config,
      inventory: ['one'],
      selection: 'one',
      paths: [...SCANNER_PATHS],
      mode: 'full',
    },
    dispose: () => fs.rmSync(root, { recursive: true, force: true }),
  };
}
async function using(run) {
  const f = fixture();
  try {
    await run(f);
  } finally {
    f.dispose();
  }
}
test('dry-run makes no writes; scoped delivery preserves unrelated content and recovers idempotently', () =>
  using(async (f) => {
    const dry = await reconcileScannerContent({ ...f.options, mode: 'dry-run' });
    assert.equal(dry.repositories[0].status, 'would-create');
    assert.equal(f.state.writes.length, 0);
    const result = await reconcileScannerContent(f.options);
    assert.equal(result.repositories[0].status, 'created');
    const tree = f.state.writes.find((r) => r.endpoint.endsWith('/git/trees')).body;
    assert.equal(tree.base_tree, baseSha);
    assert.deepEqual(tree.tree.map((e) => e.path).sort(), [...SCANNER_PATHS].sort());
    assert(tree.tree.every((e) => e.sha && e.content === undefined));
    const blobs = f.state.writes.filter((r) => r.endpoint.endsWith('/git/blobs'));
    assert.equal(blobs.length, 4, 'canonical blobs must be created in each downstream object database');
    assert.deepEqual(
      blobs.map((r) => Buffer.from(r.body.content, 'base64').toString()).sort(),
      SCANNER_PATHS.map((p) => `${p}\n`).sort(),
    );
    const count = f.state.writes.length;
    const recovered = await reconcileScannerContent({ ...f.options, mode: 'dry-run' });
    assert.equal(recovered.repositories[0].status, 'recovered');
    assert.equal(f.state.writes.length, count);
  }));
test('foreign overlapping PR is deferred and untouched; non-overlap still counts toward capacity', () =>
  using(async (f) => {
    f.state.prs = [
      {
        number: 9,
        state: 'open',
        head: { ref: 'governance/sync-managed-files-other', sha: headSha },
        files: [{ filename: '.gitleaks.toml' }],
        changed_files: 1,
      },
    ];
    assert.equal((await reconcileScannerContent(f.options)).repositories[0].status, 'deferred-collision');
    assert.equal(f.state.writes.length, 0);
    f.state.prs = [1, 2].map((number) => ({
      number,
      state: 'open',
      head: { ref: `governance/reconcile/${number}`, sha: headSha },
      files: [{ filename: 'AGENTS.md' }],
      changed_files: 1,
    }));
    assert.equal((await reconcileScannerContent(f.options)).repositories[0].status, 'deferred-capacity');
    assert.equal(f.state.writes.length, 0);
  }));
test('unmanaged, partial scope and stale source fail before writes', () =>
  using(async (f) => {
    for (const options of [{ paths: ['AGENTS.md'] }, { paths: SCANNER_PATHS.slice(1) }, { sourceSha: 'd'.repeat(40) }])
      await assert.rejects(reconcileScannerContent({ ...f.options, ...options }));
    assert.equal(f.state.writes.length, 0);
    fs.writeFileSync(path.join(f.root, 'AGENTS.md'), 'changed');
    await assert.rejects(reconcileScannerContent(f.options), /source|digest|blob/i);
    assert.equal(f.state.writes.length, 0);
  }));
test('archived repository is explicit skip; opt-out cannot be written', () =>
  using(async (f) => {
    f.state.archived = true;
    assert.equal((await reconcileScannerContent(f.options)).repositories[0].status, 'skipped-archived');
    assert.equal(f.state.writes.length, 0);
    f.state.archived = false;
    f.options.config.managed_files.skip_files.one = ['scripts/check_pii.py'];
    await reconcileScannerContent(f.options);
    const tree = f.state.writes.find((r) => r.endpoint.endsWith('/git/trees')).body.tree;
    assert(!tree.some((e) => e.path === 'scripts/check_pii.py'));
  }));
test('partial or foreign recovered ownership fails before mutations', () =>
  using(async (f) => {
    await reconcileScannerContent(f.options);
    const count = f.state.writes.length;
    f.state.partial = true;
    await assert.rejects(reconcileScannerContent(f.options));
    assert.equal(f.state.writes.length, count);
    f.state.partial = false;
    f.state.prs[0].body += 'foreign';
    await assert.rejects(reconcileScannerContent(f.options));
    assert.equal(f.state.writes.length, count);
  }));
test('retire-only validates exact scoped owner and resumes closed retirement without touching full owners', () =>
  using(async (f) => {
    await reconcileScannerContent(f.options);
    const own = f.state.prs[0];
    f.state.prs.push({
      number: 9,
      state: 'open',
      head: { ref: 'governance/sync-managed-files-other', sha: headSha },
      files: [{ filename: 'AGENTS.md' }],
      changed_files: 1,
    });
    const result = await reconcileScannerContent({ ...f.options, operation: 'retire-only' });
    assert.equal(result.repositories[0].status, 'retired');
    assert.equal(own.state, 'closed');
    assert.equal(f.state.prs[1].state, 'open');
    assert.equal(f.state.refs.size, 0);
    assert.equal(
      (await reconcileScannerContent({ ...f.options, operation: 'retire-only' })).repositories[0].status,
      'retired',
    );
  }));
test('scanner identity is separate from full reconciliation and binds scope and desired tree', () => {
  const desired = { files: [], deletes: [] };
  const id = scannerIdentity(sha, 'one', desired, baseSha);
  assert(id.branch.startsWith('governance/scanner-'));
  assert(id.note.includes('scope='));
  assert(id.note.includes(`base=${baseSha}`));
});

test('source tree corruption and malformed open inventories fail before writes', () =>
  using(async (f) => {
    const exec = f.api.request.bind(f.api);
    f.api.request = async (endpoint, options) => {
      const result = await exec(endpoint, options);
      return endpoint.includes('docs-control/git/trees') ? { ...result, tree: result.tree.slice(1) } : result;
    };
    await assert.rejects(reconcileScannerContent(f.options), /source tree/i);
    assert.equal(f.state.writes.length, 0);
  }));
test('stale scoped source, changed branch and out-of-scope recovery are rejected', () =>
  using(async (f) => {
    await reconcileScannerContent(f.options);
    const count = f.state.writes.length;
    const pr = f.state.prs[0];
    const body = pr.body;
    pr.body = body.replace(`source=${sha}`, `source=${'d'.repeat(40)}`);
    await assert.rejects(reconcileScannerContent(f.options), /ownership/i);
    assert.equal(f.state.writes.length, count);
    pr.body = body;
    f.state.refs.set(pr.head.ref, 'd'.repeat(40));
    await assert.rejects(reconcileScannerContent({ ...f.options, operation: 'retire-only' }), /branch identity/i);
    assert.equal(f.state.writes.length, count);
    f.state.refs.set(pr.head.ref, headSha);
    pr.files.push({ filename: 'AGENTS.md' });
    pr.changed_files++;
    await assert.rejects(reconcileScannerContent(f.options), /out of scope/i);
    assert.equal(f.state.writes.length, count);
  }));
test('partial branch recovery verifies exact changes and does not create another branch', () =>
  using(async (f) => {
    const exec = f.api.request.bind(f.api);
    let interrupt = true;
    f.api.request = async (endpoint, options) => {
      if (endpoint.endsWith('/pulls') && options?.method === 'POST' && interrupt) {
        interrupt = false;
        throw Error('submission interrupted');
      }
      if (endpoint.includes('/compare/'))
        return { total_commits: 1, files: f.state.tree.tree.map((e) => ({ filename: e.path })) };
      return exec(endpoint, options);
    };
    await assert.rejects(reconcileScannerContent(f.options), /interrupted/);
    assert.equal(f.state.refs.size, 1);
    assert.equal((await reconcileScannerContent(f.options)).repositories[0].status, 'created');
    assert.equal(f.state.writes.filter((r) => r.endpoint.endsWith('/git/refs') && r.method === 'POST').length, 1);
  }));

test('GraphQL errors cannot be reported as enabled auto-merge', () =>
  using(async (f) => {
    const exec = f.api.request.bind(f.api);
    f.api.request = async (endpoint, options) =>
      endpoint === 'graphql' ? { errors: [{ message: 'denied' }] } : exec(endpoint, options);
    await assert.rejects(reconcileScannerContent(f.options), /auto.merge/i);
  }));

test('producer controls may remain when the manifest retires them only downstream', () =>
  using(async (f) => {
    f.options.config.managed_files.absent_files = ['producer-control.cjs'];
    f.options.manifest.absent_paths = ['producer-control.cjs'];
    f.options.manifest.state_digest = manifestStateDigest(f.options.manifest.files, f.options.manifest.absent_paths);
    const request = f.api.request.bind(f.api);
    f.api.request = async (endpoint, options) => {
      const result = await request(endpoint, options);
      return endpoint.includes('docs-control/git/trees')
        ? {
            ...result,
            tree: [...result.tree, { path: 'producer-control.cjs', type: 'blob', sha: 'd'.repeat(40), mode: '100644' }],
          }
        : result;
    };
    const result = await reconcileScannerContent({ ...f.options, mode: 'dry-run' });
    assert.equal(result.repositories[0].status, 'would-create');
    assert.equal(f.state.writes.length, 0);
  }));

test('scanner identity rechecks request fresh bodies while retaining write pacing', async () => {
  const requests = [];
  const waits = [];
  const api = new ScannerApiQueue({
    token: 'synthetic-test-token',
    now: () => 1000,
    sleep: async (milliseconds) => waits.push(milliseconds),
    fetch: async (url, options) => {
      requests.push({ url, ...options });
      assert.equal(options.headers['if-none-match'], undefined, 'fresh identity evidence requires a body');
      return new Response(JSON.stringify({ number: 5 }), {
        status: 200,
        headers: { etag: '"synthetic-etag"', 'content-type': 'application/json' },
      });
    },
  });
  const endpoint = 'repos/example/one/pulls/5';
  assert.deepEqual(await api.request(endpoint), { number: 5 });
  assert.deepEqual(await api.request(endpoint), { number: 5 });
  await api.request('repos/example/one/issues', { method: 'POST', body: { title: 'synthetic' } });
  await api.request('repos/example/one/issues', { method: 'POST', body: { title: 'synthetic' } });
  assert.equal(requests.length, 4);
  assert.equal(waits.length, 1);
  assert(waits[0] > 0, 'the shared write-gap contract remains active');
});
