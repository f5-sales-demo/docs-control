#!/usr/bin/env bash
# Hermetic test for scripts/review-slot.sh — the machine-wide counting
# semaphore that caps concurrent PR reviews on the self-hosted runner.
# No network / no GitHub; everything runs against temp slot dirs.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/review-slot.sh"

FAIL=0
check() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "[OK] $label"; else
    echo "[FAIL] $label"
    FAIL=1
  fi
}

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- Test 1: cap — N=5, 12 concurrent workers, peak holders must never exceed 5 ---
SLOTS="$WORK/slots1"
ACTIVE="$WORK/active"
PEAKS="$WORK/peaks"
ERRLOG="$WORK/err"
mkdir -p "$SLOTS" "$ACTIVE"
: >"$PEAKS"
: >"$ERRLOG"

worker() {
  local id="$1" genv slot marker level
  genv="$(mktemp "$WORK/genv.XXXXXX")"
  # A worker enters the critical section only after acquire returns 0.
  if ! GITHUB_ENV="$genv" REVIEW_SLOTS_DIR="$SLOTS" REVIEW_MAX_SLOTS=5 \
    REVIEW_POLL_SECONDS=1 REVIEW_MAX_WAIT_SECONDS=60 REVIEW_STALE_SECONDS=2700 \
    GITHUB_REPOSITORY="test/repo" PR_NUMBER="$id" GITHUB_RUN_ID="$id" \
    bash "$SCRIPT" acquire >/dev/null 2>&1; then
    echo "acquire-failed:$id" >>"$ERRLOG"
    return 0
  fi
  slot="$(grep '^REVIEW_SLOT=' "$genv" | tail -1 | cut -d= -f2)"
  # Independent concurrency probe: unique marker per worker; the number of
  # markers present == true number of workers in the critical section right now,
  # regardless of which slot id each holds (catches a "same slot for all" bug).
  marker="$ACTIVE/w-$id"
  : >"$marker"
  level=$(find "$ACTIVE" -type f | wc -l | tr -d ' ')
  echo "$level" >>"$PEAKS"
  sleep 0.5
  rm -f "$marker"
  REVIEW_SLOT="$slot" REVIEW_SLOTS_DIR="$SLOTS" bash "$SCRIPT" release >/dev/null 2>&1 || true
}

for i in $(seq 1 12); do worker "$i" & done
wait

peak=$(sort -n "$PEAKS" | tail -1)
[ -z "$peak" ] && peak=0
remaining=$(find "$SLOTS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

check "all 12 workers acquired (no failures)" "[ ! -s '$ERRLOG' ]"
check "peak concurrency never exceeded 5 (was $peak)" "[ '$peak' -le 5 ]"
check "concurrency actually occurred, not serialized (peak $peak >= 2)" "[ '$peak' -ge 2 ]"
check "all slots released after run (remaining=$remaining)" "[ '$remaining' -eq 0 ]"

# --- Test 2: stale reclaim — a slot older than STALE is reclaimed ---
SLOTS2="$WORK/slots2"
mkdir -p "$SLOTS2/slot-1"
echo "epoch=$(($(date +%s) - 100))" >"$SLOTS2/slot-1/meta"
genv2="$(mktemp "$WORK/genv2.XXXXXX")"
rc=0
GITHUB_ENV="$genv2" REVIEW_SLOTS_DIR="$SLOTS2" REVIEW_MAX_SLOTS=1 \
  REVIEW_STALE_SECONDS=1 REVIEW_POLL_SECONDS=1 REVIEW_MAX_WAIT_SECONDS=10 \
  bash "$SCRIPT" acquire >/dev/null 2>&1 || rc=$?
check "acquire reclaims a stale slot (rc=$rc)" "[ '$rc' -eq 0 ]"
check "acquire recorded a slot after reclaim" "grep -q '^REVIEW_SLOT=' '$genv2'"

# --- Test 3: a FRESH (live) held slot is NOT stolen; acquire times out ---
SLOTS3="$WORK/slots3"
mkdir -p "$SLOTS3/slot-1"
echo "epoch=$(date +%s)" >"$SLOTS3/slot-1/meta"
genv3="$(mktemp "$WORK/genv3.XXXXXX")"
rc3=0
GITHUB_ENV="$genv3" REVIEW_SLOTS_DIR="$SLOTS3" REVIEW_MAX_SLOTS=1 \
  REVIEW_STALE_SECONDS=2700 REVIEW_POLL_SECONDS=1 REVIEW_MAX_WAIT_SECONDS=3 \
  bash "$SCRIPT" acquire >/dev/null 2>&1 || rc3=$?
check "acquire times out rather than stealing a live slot (rc=$rc3)" "[ '$rc3' -ne 0 ]"

# --- Test 4: release is idempotent / safe when no slot is held ---
rc4=0
REVIEW_SLOT="" REVIEW_SLOTS_DIR="$SLOTS3" bash "$SCRIPT" release >/dev/null 2>&1 || rc4=$?
check "release with empty REVIEW_SLOT is a safe no-op (rc=$rc4)" "[ '$rc4' -eq 0 ]"

if [ "$FAIL" -ne 0 ]; then
  echo "review-slot tests FAILED"
  exit 1
fi
echo "review-slot tests passed"
