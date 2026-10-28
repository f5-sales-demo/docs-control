'use strict';
const assert = require('node:assert/strict');
const { desiredEntries: fullDesiredEntries, manifestStateDigest } = require(
  process.argv[2] || '../scripts/fleet-reconciler.cjs',
);
const { desiredScopedEntries: desiredEntries } = require(process.argv[3] || '../scripts/scoped-managed-content.cjs');
const scannerPaths = ['.gitleaks.toml', 'scripts/check-pii.sh', 'scripts/check_pii.py', 'tests/test-check-pii.sh'];
const entries = [...scannerPaths, 'AGENTS.md']
  .sort()
  .map((path) => ({ path, src: path, sha: 'a'.repeat(40), size: 1, mode: '100644' }));
const config = {
  managed_files: {
    files: entries.map((entry) => ({ src: entry.src, dest: entry.path })),
    absent_files: ['retired-control.yml'],
    skip_files: { two: ['scripts/check_pii.py'] },
  },
};
const manifest = {
  schema_version: 2,
  source_commit: 'b'.repeat(40),
  files: entries,
  absent_paths: ['retired-control.yml'],
  state_digest: manifestStateDigest(entries, ['retired-control.yml']),
};
const desired = desiredEntries(config, manifest, 'one', { paths: scannerPaths });
assert.deepEqual(
  desired.files.map((entry) => entry.path).sort(),
  [...scannerPaths].sort(),
  'scanner scope must exclude unrelated managed files',
);
assert.deepEqual(desired.deletes, [], 'scanner scope must exclude unrelated control retirement');
const skipped = desiredEntries(config, manifest, 'two', { paths: scannerPaths });
assert.deepEqual(
  skipped.files.map((entry) => entry.path).sort(),
  scannerPaths.filter((path) => path !== 'scripts/check_pii.py').sort(),
);
assert.throws(() => desiredEntries(config, manifest, 'one', { paths: ['unmanaged-file'] }), /scope|path|selection/i);
for (const scope of [
  null,
  [],
  { unexpected: true },
  { paths: [] },
  { paths: null },
  { paths: ['.gitleaks.toml', '.gitleaks.toml'] },
  { paths: ['../outside'] },
  { paths: [3] },
])
  assert.throws(() => desiredEntries(config, manifest, 'one', scope), /scope|path|selection/i);
assert.throws(
  () =>
    desiredEntries(config, { ...manifest, state_digest: `sha256:${'0'.repeat(64)}` }, 'one', { paths: scannerPaths }),
  /state digest/i,
  'scope cannot bypass complete manifest validation',
);
assert.deepEqual(fullDesiredEntries(config, manifest, 'one').deletes, ['retired-control.yml']);
console.log('scanner desired-tree scope, opt-out, invalid input and unchanged full behavior PASS');
