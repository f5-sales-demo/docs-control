#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
node "$root/tests/scanner-scope-contract.test.cjs" \
  "$root/scripts/fleet-reconciler.cjs" "$root/scripts/scoped-managed-content.cjs"
