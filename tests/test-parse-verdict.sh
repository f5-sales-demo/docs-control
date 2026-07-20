#!/usr/bin/env bash
# Hermetic test for scripts/parse-verdict.sh — the gate that turns a Claude
# reviewer verdict.json into the pass/fail of the `review / claude-review` check.
# Locks the green/red CRITERIA deterministically (independent of the LLM):
# block ONLY on high-severity; medium/low never block; fail CLOSED on
# missing/empty/malformed. No network.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/parse-verdict.sh"

FAIL=0
WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# The gate is binary: exit 0 = GREEN (check passes), any non-zero = RED (check
# fails, merge blocked). We assert that green/red outcome, not a specific code
# (e.g. a jq parse error on malformed JSON exits non-zero — still correctly RED).
_run() {
  local rc=0
  bash "$SCRIPT" "$1" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
assert_green() {
  local label="$1" rc
  rc=$(_run "$2")
  if [ "$rc" -eq 0 ]; then echo "[OK] $label → GREEN (rc=$rc)"; else
    echo "[FAIL] $label — expected GREEN (rc=0), got rc=$rc"
    FAIL=1
  fi
}
assert_red() {
  local label="$1" rc
  rc=$(_run "$2")
  if [ "$rc" -ne 0 ]; then echo "[OK] $label → RED (rc=$rc)"; else
    echo "[FAIL] $label — expected RED (rc!=0), got rc=0"
    FAIL=1
  fi
}

w() { # w <name> <json>  -> writes fixture, echoes path
  local p="$WORK/$1.json"
  printf '%s' "$2" >"$p"
  echo "$p"
}

# --- GREEN ---
assert_green "clean verdict" \
  "$(w clean '{"blocking":false,"severity_counts":{"high":0,"medium":0,"low":0},"findings":[]}')"
assert_green "empty object (all defaults)" \
  "$(w empty_obj '{}')"
assert_green "medium+low findings only (never block on non-high)" \
  "$(w medlow '{"blocking":false,"severity_counts":{"high":0,"medium":2,"low":3},"findings":[{"severity":"medium","title":"nit","location":"a:1"},{"severity":"low","title":"style","location":"b:2"}]}')"

# --- RED ---
assert_red "blocking:true" \
  "$(w blocking '{"blocking":true,"severity_counts":{"high":0},"findings":[]}')"
assert_red "severity_counts.high>0" \
  "$(w highcount '{"blocking":false,"severity_counts":{"high":1},"findings":[]}')"
assert_red "high finding with counts.high=0 (backstop)" \
  "$(w highfinding '{"blocking":false,"severity_counts":{"high":0},"findings":[{"severity":"high","title":"broken auth","location":"x:9"}]}')"

# --- Fails CLOSED ---
assert_red "missing file (fails closed)" "$WORK/does-not-exist.json"
assert_red "empty file (fails closed)" "$(w empty '')"
assert_red "malformed JSON (fails closed)" "$(w malformed '{')"

if [ "$FAIL" -ne 0 ]; then
  echo "parse-verdict tests FAILED"
  exit 1
fi
echo "parse-verdict tests passed"
