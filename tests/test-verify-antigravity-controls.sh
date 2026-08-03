#!/usr/bin/env bash
# Hermetic tests for the live Antigravity control verifier.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/verify-antigravity-controls.sh"
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

setup_fixture() {
  rm -rf "${WORK:?}/bin" "$WORK/state"
  mkdir -p "$WORK/bin" "$WORK/state"
  printf '["repo-a"]\n' >"$WORK/repos.json"
  printf '0\n' >"$WORK/state/calls"
  cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
calls=$(cat "$FAKE_STATE/calls")
calls=$((calls + 1))
printf '%s\n' "$calls" >"$FAKE_STATE/calls"
printf '%s\n' "$*" >>"$FAKE_STATE/requests"

if [ "${FAKE_RATE_AT:-0}" -eq "$calls" ]; then
  echo 'gh: API rate limit exceeded (HTTP 429)' >&2
  exit 1
fi

endpoint="$2"
case "$endpoint" in
orgs/example/actions/variables/ANTIGRAVITY_REVIEW_ENABLED)
  printf '{"name":"ANTIGRAVITY_REVIEW_ENABLED","value":"%s","visibility":"%s"}\n' \
    "${FAKE_REVIEW_VALUE:-false}" "${FAKE_VISIBILITY:-all}"
  ;;
orgs/example/actions/variables/TRANSLATIONS_ENABLED)
  printf '{"name":"TRANSLATIONS_ENABLED","value":"%s","visibility":"%s"}\n' \
    "${FAKE_TRANSLATION_VALUE:-false}" "${FAKE_VISIBILITY:-all}"
  ;;
repos/example/*/actions/variables*)
  repo=${endpoint#repos/example/}
  repo=${repo%%/*}
  if [ "${FAKE_SHADOW_REPO:-}" = "$repo" ]; then
    printf '[{"total_count":1,"variables":[{"name":"TRANSLATIONS_ENABLED","value":"true"}]}]\n'
  else
    printf '[{"total_count":0,"variables":[]}]\n'
  fi
  ;;
repos/example/*/actions/workflows*)
  repo=${endpoint#repos/example/}
  repo=${repo%%/*}
  if [ -n "${FAKE_WORKFLOW_STATE:-}" ]; then
    state=$FAKE_WORKFLOW_STATE
  elif [ "$repo" = docs-control ]; then
    state=disabled_manually
  else
    state=active
  fi
  printf '[{"workflows":[{"path":".github/workflows/antigravity-review.yml","state":"%s"},{"path":".github/workflows/antigravity-translate.yml","state":"%s"}]}]\n' "$state" "$state"
  ;;
*)
  echo "unexpected endpoint: $endpoint" >&2
  exit 2
  ;;
esac
SH
  chmod +x "$WORK/bin/gh"
}

run_verifier() {
  local rc=0
  PATH="$WORK/bin:$PATH" FAKE_STATE="$WORK/state" "$SCRIPT" \
    --org example --repos-file "$WORK/repos.json" "$@" >"$WORK/out" 2>"$WORK/err" || rc=$?
  return "$rc"
}

echo "Antigravity live-control verifier tests"

setup_fixture
if run_verifier --workflow-state held &&
  grep -q '2 organisation variables, 2 repositories, 4 workflows' "$WORK/out"; then
  pass "false central variables and deliberately held workflows verify"
else
  fail "false central variables and held workflows verify" "$(cat "$WORK/err")"
fi

setup_fixture
export FAKE_WORKFLOW_STATE=active
if run_verifier --review-enabled true --translations-enabled true --workflow-state active; then
  fail "requested enabled values are enforced" "mismatched false variables passed"
elif grep -q 'ANTIGRAVITY_REVIEW_ENABLED' "$WORK/err"; then
  pass "requested enabled values are enforced"
else
  fail "requested enabled values are enforced" "wrong diagnostic"
fi
unset FAKE_WORKFLOW_STATE

setup_fixture
export FAKE_SHADOW_REPO=repo-a
if run_verifier --workflow-state held; then
  fail "repository variable shadows fail closed" "shadow passed"
elif grep -q 'repo-a.*TRANSLATIONS_ENABLED' "$WORK/err"; then
  pass "repository variable shadows fail closed"
else
  fail "repository variable shadows fail closed" "wrong diagnostic"
fi
unset FAKE_SHADOW_REPO

setup_fixture
export FAKE_RATE_AT=3
if run_verifier --workflow-state held; then
  fail "rate exhaustion defers without amplification" "rate limit passed"
else
  rc=$?
  calls=$(cat "$WORK/state/calls")
  if [ "$rc" -eq 84 ] && [ "$calls" -eq 3 ] && grep -q '\[DEFER\]' "$WORK/err"; then
    pass "rate exhaustion defers without amplification"
  else
    fail "rate exhaustion defers without amplification" "rc=$rc calls=$calls"
  fi
fi
unset FAKE_RATE_AT

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
