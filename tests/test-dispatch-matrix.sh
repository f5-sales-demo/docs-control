#!/usr/bin/env bash
# Structural check on dispatch-downstream.yml: the matrix job must
# cap parallelism with max-parallel, use env indirection for matrix
# values, and consume downstream-repos.json.
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

check "has read-config job" "grep -q '^  read-config:$' '$WF'"
check "has dispatch job" "grep -q '^  dispatch:$' '$WF'"
check "max-parallel: 5 set" "grep -q '^[[:space:]]*max-parallel:[[:space:]]*5' '$WF'"
check "matrix from fromJson" "grep -q 'fromJson(needs.read-config.outputs.repos)' '$WF'"
check "uses env indirection for matrix" "grep -q 'TARGET_REPO:' '$WF'"
check "config is JSON array" "jq -e 'type == \"array\" and length > 0' '$CONFIG' > /dev/null"

if command -v actionlint >/dev/null 2>&1; then
  check "actionlint clean" "actionlint '$WF' >/dev/null 2>&1"
fi

exit "$FAIL"
