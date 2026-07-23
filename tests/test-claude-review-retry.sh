#!/usr/bin/env bash
# Hermetic test for scripts/review-retry-decision.sh — the decision helper that
# decides whether a FAILED first attempt of the agentic Claude review may be
# safely retried. No network / no GitHub; pure function of three integers/flags.
#
# The review posts inline comments + one summary comment AS IT RUNS, and writes
# verdict.json LAST. So the only provably-safe-to-retry failure is one where
# NOTHING was posted (comment count unchanged) AND no verdict exists — the
# pre-work launch/auth/rate-limit class. A complete verdict means "let the gate
# decide" (no retry); any posting without a verdict is a partial review that
# must be surfaced, never silently retried (would double-post).
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/review-retry-decision.sh"

FAIL=0
check() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "[OK] $label"; else
    echo "[FAIL] $label"
    FAIL=1
  fi
}

# decide <baseline> <current> <verdict_present 0|1> -> prints retry|gate|fail
decide() { bash "$SCRIPT" decide "$1" "$2" "$3"; }

# --- Safe retry: nothing posted, no verdict ---
check "no posts, no verdict -> retry"            '[ "$(decide 3 3 0)" = retry ]'
check "no posts (zero baseline), no verdict -> retry" '[ "$(decide 0 0 0)" = retry ]'

# --- Gate: a complete verdict exists (regardless of comment delta) ---
check "verdict present -> gate"                  '[ "$(decide 3 3 1)" = gate ]'
check "verdict present even if posts grew -> gate" '[ "$(decide 3 5 1)" = gate ]'

# --- Fail: posted comments but no verdict = partial review, surface it ---
check "posts grew, no verdict -> fail"           '[ "$(decide 3 5 0)" = fail ]'
check "anomalous count drop, no verdict -> fail" '[ "$(decide 5 3 0)" = fail ]'

# --- Robustness: non-numeric / missing args fail safe to 'fail' (never retry) ---
check "non-numeric current -> fail (safe)"       '[ "$(decide 3 x 0)" = fail ]'
check "missing verdict flag -> fail (safe)"      '[ "$(bash "$SCRIPT" decide 3 3)" = fail ]'

# --- Unknown subcommand exits non-zero ---
check "unknown subcommand exits non-zero"        '! bash "$SCRIPT" bogus 1 2 3 >/dev/null 2>&1'

if [ "$FAIL" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
