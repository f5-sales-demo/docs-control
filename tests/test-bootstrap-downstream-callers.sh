#!/usr/bin/env bash
# Hermetic acceptance tests for exact-caller bootstrap PR creation.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$REPO_ROOT/scripts/bootstrap-downstream-callers.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
SOURCE_SHA=1111111111111111111111111111111111111111
PIN_SHA=2222222222222222222222222222222222222222
BASE_SHA=3333333333333333333333333333333333333333
OTHER_SHA=9999999999999999999999999999999999999999
OLD_BLOB=4444444444444444444444444444444444444444
ENFORCE_BLOB=5555555555555555555555555555555555555555
SYNC_BLOB=6666666666666666666666666666666666666666
BRANCH_HEAD=7777777777777777777777777777777777777777
CALLER_TEXT='name: Enforce Repository Settings'
CALLER_CONTENT=$(printf '%s\n' "$CALLER_TEXT" | base64 | tr -d '\n')
CALLER_BLOB=$(printf '%s\n' "$CALLER_TEXT" | git hash-object --stdin)
printf '["example"]\n' >"$WORK/repos.json"
printf '{"revision":"%s"}\n' "$PIN_SHA" >"$WORK/pin.json"
printf '{"state":"active"}\n' >"$WORK/rollout.json"

cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
endpoint="${2:-}"
case "$1 $endpoint" in
  'api repos/f5-sales-demo/docs-control/commits/main')
    count_file="$FAKE_STATE/main-read-count"
    count=0
    [ ! -f "$count_file" ] || count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ -f "$FAKE_STATE/advance-main" ] ||
      { [ -n "${FAKE_MAIN_ADVANCE_AT:-}" ] && [ "$count" -ge "$FAKE_MAIN_ADVANCE_AT" ]; }; then
      printf '%s\n' "$OTHER_SHA"
    else
      printf '%s\n' "$SOURCE_SHA"
    fi
    ;;
  'api repos/f5-sales-demo/docs-control/compare/'*) printf 'ahead\n' ;;
  'api repos/f5-sales-demo/docs-control/contents/.github/workflows/enforce-repo-settings.yml?ref='*)
    printf '%s\n' "$ENFORCE_BLOB"
    ;;
  'api repos/f5-sales-demo/docs-control/contents/.github/workflows/sync-managed-files.yml?ref='*)
    printf '%s\n' "$SYNC_BLOB"
    ;;
  'api repos/f5-sales-demo/docs-control/contents/workflows/enforce-repo-settings.yml?ref='*)
    if [[ "$*" == *'--jq .sha'* ]]; then
      printf '%s\n' "$CALLER_BLOB"
    elif [ "${FAKE_MALFORMED_CALLER:-}" = 1 ]; then
      printf '{"type":"file","encoding":"base64","sha":"bad","content":"%%%"}\n'
    else
      printf '{"type":"file","encoding":"base64","sha":"%s","content":"%s"}\n' \
        "$CALLER_BLOB" "$CALLER_CONTENT"
    fi
    ;;
  'api repos/f5-sales-demo/example/commits/main') printf '%s\n' "$BASE_SHA" ;;
  'api repos/f5-sales-demo/example/actions/workflows/enforce-repo-settings.yml')
    if [ "${FAKE_MISSING_WORKFLOW:-}" = 1 ] && [ ! -f "$FAKE_STATE/merged" ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    if [ -f "$FAKE_STATE/disabled" ]; then printf 'disabled_manually\n'; else printf 'active\n'; fi
    ;;
  'api repos/f5-sales-demo/example/actions/workflows/enforce-repo-settings.yml/disable')
    touch "$FAKE_STATE/disabled"
    ;;
  'api repos/f5-sales-demo/example/actions/workflows/enforce-repo-settings.yml/enable')
    rm -f "$FAKE_STATE/disabled"
    if [ "${FAKE_ADVANCE_AFTER_ENABLE:-}" = 1 ]; then
      touch "$FAKE_STATE/advance-main"
    fi
    ;;
  'api repos/f5-sales-demo/example/actions/workflows/enforce-repo-settings.yml/runs?per_page=100')
    if [ -f "$FAKE_STATE/active-run" ] && [ ! -f "$FAKE_STATE/canceled" ]; then
      printf '900\n'
    else
      printf '\n'
    fi
    ;;
  'api repos/f5-sales-demo/example/actions/runs/900/cancel')
    touch "$FAKE_STATE/canceled"
    ;;
  'api repos/f5-sales-demo/example/contents/.github/workflows/enforce-repo-settings.yml?ref='*)
    if [ "${FAKE_READ_ERROR:-}" = 403 ]; then
      echo 'gh: Forbidden (HTTP 403)' >&2
      exit 1
    fi
    ref=${endpoint##*ref=}
    if [ "${FAKE_MISSING_WORKFLOW:-}" = 1 ] && [ ! -f "$FAKE_STATE/merged" ] &&
      [ "$ref" != "$BRANCH_HEAD" ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    elif [ "$ref" = "$BRANCH_HEAD" ] && [ -f "$FAKE_STATE/updated" ]; then
      printf '%s\n' "$CALLER_BLOB"
    elif [ "$ref" = "$BRANCH_HEAD" ]; then
      printf '%s\n' "$OLD_BLOB"
    elif [ -f "$FAKE_STATE/merged" ]; then
      printf '%s\n' "$CALLER_BLOB"
    else
      printf '%s\n' "$DOWNSTREAM_BLOB"
    fi
    ;;
  'api repos/f5-sales-demo/example') printf 'main\n' ;;
  'api repos/f5-sales-demo/example/git/ref/heads/main') printf '%s\n' "$BASE_SHA" ;;
  'api repos/f5-sales-demo/example/git/ref/heads/sync/exact-caller-'*)
    if [ -f "$FAKE_STATE/branch" ]; then
      if [ -f "$FAKE_STATE/corrupt" ]; then
        printf '%s\n' '8888888888888888888888888888888888888888'
      elif [ -f "$FAKE_STATE/updated" ]; then
        printf '%s\n' "$BRANCH_HEAD"
      else
        printf '%s\n' "$BASE_SHA"
      fi
    else
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    ;;
  'api repos/f5-sales-demo/example/git/refs') touch "$FAKE_STATE/branch" ;;
  'api repos/f5-sales-demo/example/contents/.github/workflows/enforce-repo-settings.yml')
    touch "$FAKE_STATE/updated"
    ;;
  'api repos/f5-sales-demo/example/compare/'*)
    printf '{"status":"ahead","ahead_by":1,"total_commits":1,"commits":[{}],"files":[{"filename":".github/workflows/enforce-repo-settings.yml","sha":"%s","status":"modified"}]}\n' "$CALLER_BLOB"
    ;;
  'api repos/f5-sales-demo/example/pulls?state=open&per_page=100')
    if [ -f "$FAKE_STATE/duplicate-current-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg branch "$EXPECTED_BRANCH" \
        --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[[{number: 12, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}},
           {number: 13, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    elif [ -f "$FAKE_STATE/fork-current-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg branch "$EXPECTED_BRANCH" \
        --arg repo "${GITHUB_REPOSITORY%/*}-fork/example" \
        '[[{number: 11, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    elif [ -f "$FAKE_STATE/page-two-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[[], [{number: 9, head: {ref: "sync/exact-caller-aaaaaaaaaaaa-99999-1", sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    elif [ -f "$FAKE_STATE/huge-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[[{number: 10, head: {ref: "sync/exact-caller-aaaaaaaaaaaa-999999999999999999999999999999-1", sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    elif [ -f "$FAKE_STATE/newer-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[[{number: 8, head: {ref: "sync/exact-caller-aaaaaaaaaaaa-99999-1", sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    elif [ -f "$FAKE_STATE/current-pr" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg branch "$EXPECTED_BRANCH" \
        --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[[{number: 42, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    elif [ -f "$FAKE_STATE/old-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[[{number: 7, head: {ref: "sync/exact-caller-aaaaaaaaaaaa-12-1", sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    else
      printf '[[]]\n'
    fi
    ;;
  'pr list')
    if [[ "$*" == *'--head '* ]]; then
      if [ -f "$FAKE_STATE/current-pr" ]; then printf '42\n'; else printf '\n'; fi
    else
      printf '[]\n'
    fi
    ;;
  'pr close') rm -f "$FAKE_STATE/old-open" ;;
  'pr create')
    touch "$FAKE_STATE/current-pr"
    printf 'https://github.com/f5-sales-demo/example/pull/42\n'
    ;;
  'pr view')
    printf '{"baseRefName":"main","headRefName":"%s","headRefOid":"%s","commits":[{}],"files":[{"path":".github/workflows/enforce-repo-settings.yml"}]}\n' \
      "$EXPECTED_BRANCH" "$BRANCH_HEAD"
    ;;
  'pr merge')
    if [ -f "$FAKE_STATE/fail-merge" ]; then
      rm -f "$FAKE_STATE/fail-merge"
      exit 1
    fi
    if [ "${FAKE_MERGE_LANDS:-}" = 1 ]; then
      touch "$FAKE_STATE/merged"
    fi
    exit 0
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$WORK/bin/gh"

run_bootstrap() {
  local state="$1"
  env \
    PATH="$WORK/bin:$PATH" \
    GITHUB_REPOSITORY=f5-sales-demo/docs-control \
    GITHUB_RUN_ID=12345 \
    GITHUB_RUN_ATTEMPT=1 \
    SOURCE_SHA="$SOURCE_SHA" \
    PIN_CONFIG="$WORK/pin.json" \
    ROLLOUT_CONFIG="${TEST_ROLLOUT_CONFIG:-$WORK/rollout.json}" \
    DOWNSTREAM_CONFIG="${TEST_DOWNSTREAM_CONFIG:-$WORK/repos.json}" \
    BOOTSTRAP_WAIT_SECONDS=0 \
    FAKE_LOG="$WORK/gh.log" \
    FAKE_STATE="$state" \
    SOURCE_SHA="$SOURCE_SHA" \
    PIN_SHA="$PIN_SHA" \
    BASE_SHA="$BASE_SHA" \
    OTHER_SHA="$OTHER_SHA" \
    OLD_BLOB="$OLD_BLOB" \
    ENFORCE_BLOB="$ENFORCE_BLOB" \
    SYNC_BLOB="$SYNC_BLOB" \
    BRANCH_HEAD="$BRANCH_HEAD" \
    EXPECTED_BRANCH="sync/exact-caller-${CALLER_BLOB:0:12}-12345-1" \
    CALLER_BLOB="$CALLER_BLOB" \
    CALLER_CONTENT="$CALLER_CONTENT" \
    DOWNSTREAM_BLOB="$DOWNSTREAM_BLOB" \
    FAKE_READ_ERROR="${FAKE_READ_ERROR:-}" \
    FAKE_MAIN_ADVANCE_AT="${FAKE_MAIN_ADVANCE_AT:-}" \
    FAKE_MALFORMED_CALLER="${FAKE_MALFORMED_CALLER:-}" \
    FAKE_MISSING_WORKFLOW="${FAKE_MISSING_WORKFLOW:-}" \
    FAKE_MERGE_LANDS="${FAKE_MERGE_LANDS:-}" \
    FAKE_ADVANCE_AFTER_ENABLE="${FAKE_ADVANCE_AFTER_ENABLE:-}" \
    REPO_SETTINGS_TOKEN=settings-token \
    "$SOURCE"
}

state="$WORK/state-stale"
mkdir -p "$state"
touch "$state/old-open"
touch "$state/fail-merge"
touch "$state/active-run"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
set +e
run_bootstrap "$state" >"$WORK/stale.out" 2>"$WORK/stale.err"
rc=$?
set -e
if [ "$rc" != 83 ]; then
  echo "[FAIL] stale bootstrap did not defer for merge verification (rc=$rc)"
  cat "$WORK/stale.err"
  exit 1
fi
grep -q '^pr close 7 ' "$WORK/gh.log"
grep -q 'git/refs --method POST' "$WORK/gh.log"
grep -q 'contents/.github/workflows/enforce-repo-settings.yml --method PUT' "$WORK/gh.log"
grep -q '^pr create ' "$WORK/gh.log"
grep -q '^pr view ' "$WORK/gh.log"
grep -q '^pr merge ' "$WORK/gh.log"
grep -q 'actions/runs/900/cancel --method POST' "$WORK/gh.log"
if [ "$(grep -c '^pr merge ' "$WORK/gh.log")" -ne 2 ]; then
  echo "[FAIL] transient auto-merge failure was not retried"
  exit 1
fi
if grep -qE '(^|[[:space:]])--force([[:space:]]|$)|"force"[[:space:]]*:[[:space:]]*true' "$WORK/gh.log"; then
  echo "[FAIL] bootstrap used a non-monotonic force update"
  exit 1
fi
echo "[OK] stale caller closes older PRs and queues one exact one-file PR"

state="$WORK/state-exact"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
run_bootstrap "$state" >"$WORK/exact.out"
if grep -qE 'git/refs --method POST| --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] exact caller caused an unnecessary mutation"
  exit 1
fi
echo "[OK] exact caller is a no-op"

state="$WORK/state-enable"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
run_bootstrap "$state" >"$WORK/enable.out"
grep -q 'actions/workflows/enforce-repo-settings.yml/enable --method PUT' "$WORK/gh.log"
echo "[OK] active rollout enables only the verified exact caller"

printf '{"state":"quiesced"}\n' >"$WORK/rollout-quiesced.json"
state="$WORK/state-quiesced"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
set +e
TEST_ROLLOUT_CONFIG="$WORK/rollout-quiesced.json" run_bootstrap "$state" >"$WORK/quiesced.out"
rc=$?
set -e
unset TEST_ROLLOUT_CONFIG
if [ "$rc" != 81 ] || ! grep -q 'actions/workflows/enforce-repo-settings.yml/disable --method PUT' "$WORK/gh.log" ||
  grep -q 'actions/workflows/enforce-repo-settings.yml/enable --method PUT' "$WORK/gh.log"; then
  echo "[FAIL] quiesced rollout did not remain disabled after exact caller verification"
  exit 1
fi
echo "[OK] quiesced rollout keeps autonomous legacy enforcement disabled"

state="$WORK/state-forbidden"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_READ_ERROR=403
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_READ_ERROR
if [ "$rc" = 0 ] || grep -qE 'git/refs --method POST| --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] non-404 read failure did not fail closed before mutation"
  exit 1
fi
echo "[OK] non-404 read failure causes zero mutations"

state="$WORK/state-newer"
mkdir -p "$state"
touch "$state/newer-open"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" != 83 ] || grep -qE '^pr close |git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] older run did not defer to the newer bootstrap owner"
  echo "  rc=$rc"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] older run cannot close or overtake a newer bootstrap PR"

state="$WORK/state-huge-owner"
mkdir -p "$state"
touch "$state/huge-open"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" != 83 ] || grep -qE '^pr close |git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] oversized owner was not treated as a newer exact-caller run"
  echo "  rc=$rc"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] oversized exact-caller owner defers without integer overflow"

state="$WORK/state-page-two-owner"
mkdir -p "$state"
touch "$state/page-two-open"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" != 83 ] || ! grep -q -- '--paginate --slurp' "$WORK/gh.log" ||
  grep -qE '^pr close |git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] exact-caller owner outside the first API page was not detected"
  exit 1
fi
echo "[OK] paginated exact-caller inventory detects later-page owners"

state="$WORK/state-fork-current"
mkdir -p "$state"
touch "$state/fork-current-open" "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" = 0 ] ||
  grep -qE '^pr (close|create|merge) |git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT' "$WORK/gh.log"; then
  echo "[FAIL] hostile same-ref fork PR was treated as the exact-caller owner"
  echo "  rc=$rc"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] hostile same-ref fork PR blocks exact-caller mutation"

state="$WORK/state-duplicate-current"
mkdir -p "$state"
touch "$state/duplicate-current-open" "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" = 0 ] ||
  grep -qE '^pr (close|create|merge) |git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT' "$WORK/gh.log"; then
  echo "[FAIL] duplicate current exact-caller PRs were treated as one owner"
  exit 1
fi
echo "[OK] duplicate current exact-caller PRs block mutation"

printf '["example","example"]\n' >"$WORK/repos-invalid.json"
: >"$WORK/gh.log"
set +e
TEST_DOWNSTREAM_CONFIG="$WORK/repos-invalid.json" run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset TEST_DOWNSTREAM_CONFIG
if [ "$rc" = 0 ] || [ -s "$WORK/gh.log" ]; then
  echo "[FAIL] invalid inventory was not rejected before network access"
  exit 1
fi
echo "[OK] invalid inventory is rejected before network access"

state="$WORK/state-internal-preflight-superseded"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_MAIN_ADVANCE_AT=1
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_MAIN_ADVANCE_AT
if [ "$rc" != 78 ] || grep -qE '/disable|/cancel|/enable| --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] internal preflight source supersession did not return recoverable rc78"
  exit 1
fi
echo "[OK] internal preflight source supersession returns rc78 without mutation"

state="$WORK/state-superseded-before-quiesce"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_MAIN_ADVANCE_AT=2
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_MAIN_ADVANCE_AT
if [ "$rc" != 78 ] || grep -qE '/disable|/cancel|/enable| --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] superseded source mutated workflow state before exact bootstrap proof"
  echo "  rc=$rc"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] superseded source causes zero workflow-state or caller mutations"

state="$WORK/state-malformed-caller"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_MALFORMED_CALLER=1
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_MALFORMED_CALLER
if [ "$rc" = 0 ] || grep -qE '/disable|/cancel|/enable| --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] malformed canonical caller caused a state or caller mutation"
  exit 1
fi
echo "[OK] malformed canonical caller fails before any workflow-state mutation"

state="$WORK/state-superseded-before-enable"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
FAKE_MAIN_ADVANCE_AT=4
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_MAIN_ADVANCE_AT
if [ "$rc" != 78 ] || grep -q '/enable --method PUT' "$WORK/gh.log"; then
  echo "[FAIL] historical active rollout enabled enforcement after source advancement"
  exit 1
fi
echo "[OK] source is re-proved after caller verification and before enable"

state="$WORK/state-advance-after-enable"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
FAKE_ADVANCE_AFTER_ENABLE=1
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_ADVANCE_AFTER_ENABLE
if [ "$rc" != 78 ] || ! grep -q '/enable --method PUT' "$WORK/gh.log" ||
  ! grep -q '/disable --method PUT' "$WORK/gh.log" || [ ! -f "$state/disabled" ]; then
  echo "[FAIL] source advancement after enable did not roll the fleet back to quiescence"
  exit 1
fi
echo "[OK] source advancement during enable re-quiesces the fleet"

state="$WORK/state-missing-workflow"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_MISSING_WORKFLOW=1
FAKE_MERGE_LANDS=1
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_MISSING_WORKFLOW FAKE_MERGE_LANDS
if [ "$rc" != 0 ] || ! grep -q '^pr create ' "$WORK/gh.log" ||
  grep -q 'actions/workflows/enforce-repo-settings.yml/disable' "$WORK/gh.log"; then
  echo "[FAIL] repository without a caller did not bootstrap from the measured 404 state"
  exit 1
fi
echo "[OK] missing workflow is bootstrapped before its desired state is enforced"
