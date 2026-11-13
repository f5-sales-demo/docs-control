'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { foreignScannerScope } = require('../scripts/scanner-reconciler.cjs');
const head = 'a'.repeat(40);
const base = 'b'.repeat(40);
function largePr({ count = 1162, files, mutateInitial, mutateFinal } = {}) {
  const rows =
    files || Array.from({ length: count }, (_, i) => ({ filename: `docs/generated/item-${i}.md`, status: 'modified' }));
  const pr = {
    number: 42,
    state: 'open',
    commits: 595,
    changed_files: count,
    head: { sha: head, ref: 'feature/demo' },
    base: { sha: base, ref: 'main' },
  };
  const requests = [];
  let reads = 0;
  return {
    listed: structuredClone(pr),
    requests,
    api: {
      async request(endpoint, options = {}) {
        assert.equal(options.method || 'GET', 'GET');
        requests.push(endpoint);
        if (endpoint === 'repos/example/demo/pulls/42') {
          const value = structuredClone(pr);
          reads++;
          if (reads === 1 && mutateInitial) mutateInitial(value);
          if (reads > 1 && mutateFinal) mutateFinal(value);
          return value;
        }
        const page = endpoint.match(/\/files\?per_page=100&page=(\d+)$/);
        if (page) return rows.slice((Number(page[1]) - 1) * 100, Number(page[1]) * 100);
        throw Error('Unexpected large-PR graph or write request');
      },
    },
  };
}
test('complete scanner-unchanged path inventory qualifies a PR above the commit endpoint limit', async () => {
  const f = largePr();
  assert.equal(await foreignScannerScope(f.api, 'example', 'demo', f.listed), 'clear');
  assert.equal(f.requests.filter((p) => p.includes('/files?')).length, 12);
  assert(!f.requests.some((p) => p.includes('/commits?')));
});
test('a changed scanner path in a large PR retains the unverified graph boundary', async () => {
  const f = largePr({ count: 1, files: [{ filename: 'scripts/check_pii.py', status: 'modified' }] });
  assert.equal(await foreignScannerScope(f.api, 'example', 'demo', f.listed), 'unverified');
});

test('exactly full file pages require the final empty page', async () => {
  const f = largePr({ count: 100 });
  assert.equal(await foreignScannerScope(f.api, 'example', 'demo', f.listed), 'clear');
  assert.equal(f.requests.filter((p) => p.includes('/files?')).length, 2);
});
test('partial, duplicate, malformed and unsupported file inventories remain unverified', async () => {
  for (const setup of [
    { count: 2, files: [{ filename: 'docs/one.md' }] },
    { count: 2, files: [{ filename: 'docs/one.md' }, { filename: 'docs/one.md' }] },
    { count: 1, files: [{ filename: '../scripts/check_pii.py' }] },
    { count: 1, files: [{ filename: 'docs/renamed.md', status: 'renamed' }] },
    { count: 1, files: [{ filename: 'docs/one.md', previous_filename: '../outside' }] },
    { count: 3001 },
    {
      mutateInitial: (p) => {
        delete p.changed_files;
      },
    },
    {
      mutateInitial: (p) => {
        delete p.base.sha;
      },
    },
  ]) {
    const f = largePr(setup);
    assert.equal(await foreignScannerScope(f.api, 'example', 'demo', f.listed), 'unverified');
  }
});
test('renames into or away from governed paths cannot prove unchanged scanner scope', async () => {
  for (const file of [
    { filename: 'docs/renamed.md', previous_filename: 'scripts/check_pii.py', status: 'renamed' },
    { filename: 'scripts/check_pii.py', previous_filename: 'docs/renamed.md', status: 'renamed' },
    { filename: '.gitleaks.toml', status: 'removed' },
  ]) {
    const f = largePr({ count: 1, files: [file] });
    assert.equal(await foreignScannerScope(f.api, 'example', 'demo', f.listed), 'unverified');
  }
});
test('head, base, target, state and count changes invalidate the collected path inventory', async () => {
  for (const mutateFinal of [
    (p) => {
      p.head.sha = 'c'.repeat(40);
    },
    (p) => {
      p.base.sha = 'c'.repeat(40);
    },
    (p) => {
      p.base.ref = 'release/demo';
    },
    (p) => {
      p.state = 'closed';
    },
    (p) => {
      p.commits++;
    },
    (p) => {
      p.changed_files++;
    },
    (p) => {
      p.number++;
    },
  ]) {
    const f = largePr({ count: 1, mutateFinal });
    assert.equal(await foreignScannerScope(f.api, 'example', 'demo', f.listed), 'unverified');
  }
});
test('initial base mismatch and unavailable file service remain unverified', async () => {
  const changed = largePr({
    mutateInitial: (p) => {
      p.base.sha = 'c'.repeat(40);
    },
  });
  assert.equal(await foreignScannerScope(changed.api, 'example', 'demo', changed.listed), 'unverified');
  for (const status of [403, 500]) {
    const f = largePr();
    const read = f.api.request.bind(f.api);
    f.api.request = async (endpoint, options) => {
      if (endpoint.includes('/files?')) {
        const error = Error('Unavailable public path inventory');
        error.status = status;
        throw error;
      }
      return read(endpoint, options);
    };
    assert.equal(await foreignScannerScope(f.api, 'example', 'demo', f.listed), 'unverified');
  }
});
