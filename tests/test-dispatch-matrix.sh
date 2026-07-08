#!/usr/bin/env bash
# Structural check on dispatch-downstream.yml: a single runner must
# fan out to every downstream repo, cap parallelism at 5, keep
# retry-with-backoff, and aggregate per-repo failures.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="${REPO_ROOT}/.github/workflows/dispatch-downstream.yml"
CONFIG="${REPO_ROOT}/.github/config/downstream-repos.json"

FAIL=0
check() {
  local label="$1"
  local cond="$2"
  if eval "$cond"; then
    echo "[OK] $label"
  else
    echo "[FAIL] $label"
    FAIL=1
  fi
}

# Architecture: one job named `dispatch`, no per-repo matrix fan-out.
check "has dispatch job" "grep -q '^  dispatch:$' '$WF'"
check "no matrix fan-out (single runner)" "! grep -q '^[[:space:]]*matrix:$' '$WF'"
check "no read-config job (consolidated)" "! grep -q '^  read-config:$' '$WF'"

# Parallelism cap stays at 5 via batched dispatch loop.
check "BATCH_SIZE=5 for parallelism cap" "grep -q 'BATCH_SIZE=5' '$WF'"

# Retry-with-backoff preserved (2s → 4s → 8s).
check "retry max=3 attempts" "grep -Eq 'max=3' '$WF'"
check "backoff delay starts at 2s" "grep -Eq 'delay=2' '$WF'"

# Failure aggregation — step fails iff at least one dispatch failed.
check "emits [FAIL] markers" "grep -q '\[FAIL\]' '$WF'"
check "aggregates FAIL_COUNT" "grep -q 'FAIL_COUNT' '$WF'"

# Config still drives the fan-out.
check "consumes downstream-repos.json" "grep -q 'downstream-repos.json' '$WF'"
check "config is JSON array" "jq -e 'type == \"array\" and length > 0' '$CONFIG' > /dev/null"

# Trigger: dispatch must run when the regenerated manifest LANDS on main (the
# auto-merging sync/manifest PR merges), not when the manifest build completes.
# Triggering on build completion races the PR merge and fans out a stale
# manifest — see issue #634.
check "triggers on manifest landing on main" \
  "grep -q 'managed-files-manifest.json' '$WF'"
check "triggers on repo-settings.json (settings-only changes)" \
  "grep -q 'repo-settings.json' '$WF'"
check "does NOT trigger on build workflow_run (stale-manifest race)" \
  "! grep -q 'workflow_run:' '$WF'"
check "keeps manual workflow_dispatch fallback" \
  "grep -q 'workflow_dispatch:' '$WF'"

if command -v actionlint >/dev/null 2>&1; then
  check "actionlint clean" "actionlint '$WF' >/dev/null 2>&1"
fi

exit "$FAIL"
