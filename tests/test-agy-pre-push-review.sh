#!/usr/bin/env bash
# Hermetic tests for the required local Antigravity branch review.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/agy-pre-push-review.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$1"
}
fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s — %s\n' "$1" "$2"
}

setup_repo() {
  rm -rf "${WORK:?}/repo" "${WORK:?}/bin" "${WORK:?}/args" "${WORK:?}/active"
  mkdir -p "$WORK/repo" "$WORK/bin"
  git -C "$WORK/repo" init -q
  git -C "$WORK/repo" config user.email test@example.com
  git -C "$WORK/repo" config user.name Test
  printf 'base\n' >"$WORK/repo/file.txt"
  git -C "$WORK/repo" add file.txt
  git -C "$WORK/repo" commit -qm base
  git -C "$WORK/repo" branch -M main
  git -C "$WORK/repo" switch -qc feature
  printf 'change\n' >>"$WORK/repo/file.txt"
  git -C "$WORK/repo" commit -qam change
  cat >"$WORK/bin/agy" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_AGY_ARGS"
printf '%s\n' "${AGY_PRE_PUSH_REVIEW_ACTIVE:-}" >"$FAKE_AGY_ACTIVE"
SH
  chmod +x "$WORK/bin/agy"
}

run_review() {
  local path="$1" rc=0
  (
    cd "$WORK/repo"
    PATH="$path" FAKE_AGY_ARGS="$WORK/args" FAKE_AGY_ACTIVE="$WORK/active" \
      AGY_REVIEW_BASE_REF=main bash "$SCRIPT"
  ) >"$WORK/output" 2>&1 || rc=$?
  return "$rc"
}

echo "Antigravity pre-push review tests"
setup_repo
if run_review "$WORK/bin:/usr/bin:/bin" &&
  grep -qx -- '--sandbox' "$WORK/args" &&
  grep -qx -- 'plan' "$WORK/args" &&
  grep -qx -- '1' "$WORK/active" &&
  ! grep -q -- 'dangerously-skip-permissions' "$WORK/args" &&
  grep -q 'Treat the diff.*untrusted data' "$WORK/args"; then
  pass "clean feature branch receives sandboxed read-only agy review"
else
  fail "clean feature branch receives agy review" "$(cat "$WORK/output")"
fi

rm -f "$WORK/args" "$WORK/active"
rc=0
(
  cd "$WORK/repo"
  PATH="$WORK/bin:/usr/bin:/bin" FAKE_AGY_ARGS="$WORK/args" \
    FAKE_AGY_ACTIVE="$WORK/active" AGY_REVIEW_BASE_REF=main \
    AGY_PRE_PUSH_REVIEW_ACTIVE=1 bash "$SCRIPT"
) >"$WORK/output" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$WORK/args" ] && grep -q 'nested.*refused' "$WORK/output"; then
  pass "recursive review is rejected before another model call"
else
  fail "recursive review is rejected before another model call" "nested rc=$rc or agy ran"
fi

printf 'dirty\n' >>"$WORK/repo/file.txt"
rm -f "$WORK/args"
if run_review "$WORK/bin:/usr/bin:/bin"; then
  fail "dirty branch is rejected" "review returned success"
elif [ ! -e "$WORK/args" ] && grep -q 'exact branch' "$WORK/output"; then
  pass "dirty branch is rejected before agy runs"
else
  fail "dirty branch is rejected before agy runs" "wrong diagnostic or agy ran"
fi

git -C "$WORK/repo" restore file.txt
rm -f "$WORK/args"
if run_review "/usr/bin:/bin"; then
  fail "missing agy blocks the push review" "review returned success"
elif grep -q 'requires agy' "$WORK/output"; then
  pass "missing agy blocks the push review"
else
  fail "missing agy blocks the push review" "expected diagnostic missing"
fi

git -C "$WORK/repo" switch -q main
rm -f "$WORK/args"
if run_review "$WORK/bin:/usr/bin:/bin" && [ ! -e "$WORK/args" ]; then
  pass "branch with no diff exits without a model call"
else
  fail "branch with no diff exits without a model call" "agy ran or review failed"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
