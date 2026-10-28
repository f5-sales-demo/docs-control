'use strict';
const { desiredEntries, validateManifest } = require('./fleet-reconciler.cjs');

function desiredScopedEntries(config, manifest, repo, scope) {
  validateManifest(config, manifest);
  if (!scope || typeof scope !== 'object' || Array.isArray(scope) || Object.keys(scope).some((key) => key !== 'paths'))
    throw new Error('managed path scope is invalid');
  const known = new Set([...manifest.files.map((entry) => entry.path), ...manifest.absent_paths]);
  if (
    !Array.isArray(scope.paths) ||
    !scope.paths.length ||
    new Set(scope.paths).size !== scope.paths.length ||
    scope.paths.some((entry) => typeof entry !== 'string' || !known.has(entry))
  )
    throw new Error('managed path scope selection is invalid');
  const selected = new Set(scope.paths);
  const desired = desiredEntries(config, manifest, repo);
  return {
    files: desired.files.filter((entry) => selected.has(entry.path)),
    deletes: desired.deletes.filter((entry) => selected.has(entry)),
  };
}

module.exports = { desiredScopedEntries };
