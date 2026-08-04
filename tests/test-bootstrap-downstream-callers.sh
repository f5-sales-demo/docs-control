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
LINT_CALLER_TEXT='name: Super-Linter'
LINT_CALLER_CONTENT=$(printf '%s\n' "$LINT_CALLER_TEXT" | base64 | tr -d '\n')
LINT_CALLER_BLOB=$(printf '%s\n' "$LINT_CALLER_TEXT" | git hash-object --stdin)
printf '["example"]\n' >"$WORK/repos.json"
printf '{"revision":"%s"}\n' "$PIN_SHA" >"$WORK/pin.json"
printf '{"state":"active"}\n' >"$WORK/rollout.json"
cat >"$WORK/repo-settings.json" <<'EOF'
{
  "branch_protection": [
    {
      "branch": "main",
      "required_status_checks": {
        "strict": true,
        "contexts": [
          "Check linked issues",
          "lint / Lint Code Base",
          "lint / Shell Unit Tests"
        ]
      }
    }
  ],
  "repo_overrides": {
    "example": {
      "additional_contexts": ["Example CI"],
      "excluded_required_contexts": ["lint / Shell Unit Tests"]
    }
  }
}
EOF

for run_status in queued in_progress waiting requested pending; do
  if ! grep -Fq "status=${run_status}" "$SOURCE"; then
    echo "[FAIL] bootstrap does not query bounded ${run_status} workflow runs"
    exit 1
  fi
done
if ! grep -Fq 'actions/runs?${state_filter}' "$SOURCE" ||
  ! grep -Fq 'select(.path == ".github/workflows/enforce-repo-settings.yml")' "$SOURCE"; then
  echo "[FAIL] repository-wide active-run inventory is not filtered to the exact workflow path"
  exit 1
fi
if grep -Fq 'actions/workflows/enforce-repo-settings.yml/runs?' "$SOURCE"; then
  echo "[FAIL] bootstrap cannot inventory legacy runs after the workflow file is deleted"
  exit 1
fi
if grep -Fq 'runs?per_page=100' "$SOURCE"; then
  echo "[FAIL] bootstrap still paginates complete workflow-run history"
  exit 1
fi
echo "[OK] bootstrap inventories only bounded active workflow-run states"

if ! grep -q -- '--match-head-commit "$verified_head"' "$SOURCE"; then
  echo "[FAIL] bootstrap auto-merge is not bound to the verified PR head"
  exit 1
fi
enable_failure_block=$(sed -n '/if \[ "$enable_failures" -gt 0 \]; then/,/^fi$/p' "$SOURCE")
if ! grep -q 'quiesce_fleet' <<<"$enable_failure_block"; then
  echo "[FAIL] partial enable failure does not return the fleet to quiescence"
  exit 1
fi
echo "[OK] merge and enable transitions retain exact safe ownership"

if ! grep -Fq 'contents/workflows/super-linter.yml?ref=${source_sha}' "$SOURCE" ||
  ! grep -Fq '.github/workflows/super-linter.yml' "$SOURCE"; then
  echo "[FAIL] exact-caller bootstrap does not carry the current Super-Linter caller"
  exit 1
fi
echo "[OK] bootstrap carries the lint caller that validates its own PR"

cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
if [[ "$*" == *'--slurp'* ]]; then
  echo 'unknown flag: --slurp' >&2
  exit 64
fi
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
  'api repos/f5-sales-demo/docs-control/contents/workflows/super-linter.yml?ref='*)
    if [[ "$*" == *'--jq .sha'* ]]; then
      printf '%s\n' "$LINT_CALLER_BLOB"
    else
      printf '{"type":"file","encoding":"base64","sha":"%s","content":"%s"}\n' \
        "$LINT_CALLER_BLOB" "$LINT_CALLER_CONTENT"
    fi
    ;;
  'api repos/f5-sales-demo/example/commits/main')
    if [ -f "$FAKE_STATE/required-check-failed" ]; then
      touch "$FAKE_STATE/continued-after-required-check-failure"
    fi
    printf '%s\n' "$BASE_SHA"
    ;;
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
  'api repos/f5-sales-demo/example/branches/main/protection/required_status_checks')
    if [[ "$*" == *'--method PATCH'* ]]; then
      if [ "${FAKE_REQUIRED_CHECKS_PATCH_RATE_LIMIT:-}" = 1 ]; then
        touch "$FAKE_STATE/required-check-failed"
        echo 'gh: API rate limit exceeded for user ID 123. (HTTP 403)' >&2
        exit 1
      fi
      input=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--input" ]; then
          input="$2"
          break
        fi
        shift
      done
      [ -n "$input" ] || exit 64
      cp "$input" "$FAKE_STATE/required-checks-input.json"
      touch "$FAKE_STATE/required-checks-reconciled"
    elif [ "${FAKE_REQUIRED_CHECKS_ERROR:-}" = 1 ]; then
      touch "$FAKE_STATE/required-check-failed"
      echo 'gh: synthetic required-check read failure (HTTP 500)' >&2
      exit 1
    elif [ "${FAKE_STALE_REQUIRED_CHECKS:-}" = 1 ] &&
      { [ ! -f "$FAKE_STATE/required-checks-reconciled" ] ||
        [ "${FAKE_REQUIRED_CHECKS_VERIFY_DRIFT:-}" = 1 ]; }; then
      if [ -f "$FAKE_STATE/required-checks-reconciled" ]; then
        touch "$FAKE_STATE/required-check-failed"
      fi
      printf '{"strict":true,"contexts":["check / Check linked issues","lint / Lint Code Base","lint / Shell Unit Tests"]}\n'
    else
      printf '{"strict":true,"contexts":["Check linked issues","Example CI","lint / Lint Code Base"]}\n'
    fi
    ;;
  'api repos/f5-sales-demo/example-two/commits/main') printf '%s\n' "$BASE_SHA" ;;
  'api repos/f5-sales-demo/example-two/actions/workflows/enforce-repo-settings.yml')
    if [ -f "$FAKE_STATE/disabled-example-two" ]; then
      printf 'disabled_manually\n'
    else
      printf 'active\n'
    fi
    ;;
  'api repos/f5-sales-demo/example-two/actions/workflows/enforce-repo-settings.yml/disable')
    touch "$FAKE_STATE/disabled-example-two"
    ;;
  'api repos/f5-sales-demo/example-two/actions/workflows/enforce-repo-settings.yml/enable')
    if [ "${FAKE_FAIL_ENABLE_REPO:-}" = example-two ]; then
      exit 1
    fi
    rm -f "$FAKE_STATE/disabled-example-two"
    ;;
  'api repos/f5-sales-demo/example-two/branches/main/protection/required_status_checks')
    printf '{"strict":true,"contexts":["Check linked issues","lint / Lint Code Base","lint / Shell Unit Tests"]}\n'
    ;;
  'api repos/f5-sales-demo/example-two/actions/runs?status='*) printf '\n' ;;
  'api repos/f5-sales-demo/example-two/contents/.github/workflows/enforce-repo-settings.yml?ref='*)
    printf '%s\n' "$DOWNSTREAM_BLOB"
    ;;
  'api repos/f5-sales-demo/example-two/contents/.github/workflows/super-linter.yml?ref='*)
    printf '%s\n' "$DOWNSTREAM_LINT_BLOB"
    ;;
  'api repos/f5-sales-demo/example/actions/runs?status='*)
    if [ -n "${FAKE_RATE_LIMIT_STATUS:-}" ] &&
      [[ "$endpoint" == *"status=${FAKE_RATE_LIMIT_STATUS}"* ]]; then
      echo 'gh: API rate limit exceeded for user ID 123. (HTTP 403)' >&2
      exit 1
    fi
    if [ -n "${FAKE_RUN_QUERY_FAIL_STATUS:-}" ] &&
      [[ "$endpoint" == *"status=${FAKE_RUN_QUERY_FAIL_STATUS}"* ]]; then
      echo 'gh: synthetic active-run query failure (HTTP 500)' >&2
      exit 1
    fi
    if [ "${FAKE_FORWARD_TRANSITIONAL_RUN:-}" = 1 ] &&
      [[ "$endpoint" == *'status=requested'* ]] &&
      [ ! -f "$FAKE_STATE/forward-transition-started" ]; then
      touch "$FAKE_STATE/forward-transition-started"
      printf '\n'
    elif [ "${FAKE_FORWARD_TRANSITIONAL_RUN:-}" = 1 ] &&
      [[ "$endpoint" == *'status=queued'* ]] &&
      [ -f "$FAKE_STATE/forward-transition-started" ] &&
      [ ! -f "$FAKE_STATE/forward-transition-canceled" ]; then
      printf '904\n'
    elif [ "${FAKE_MALFORMED_RUN_ID:-}" = 1 ] && [[ "$endpoint" == *'status=queued'* ]]; then
      printf 'not-a-run-id\n'
    elif [ "${FAKE_UNRELATED_RUN:-}" = 1 ] &&
      [[ "$*" != *'select(.path == ".github/workflows/enforce-repo-settings.yml")'* ]] &&
      [[ "$endpoint" == *'status=queued'* ]]; then
      printf '903\n'
    elif [ "${FAKE_TRANSITIONAL_RUN:-}" = 1 ] && [[ "$endpoint" == *'status=queued'* ]]; then
      if [ ! -f "$FAKE_STATE/transition-started" ]; then
        touch "$FAKE_STATE/transition-started"
        printf '\n'
      elif [ ! -f "$FAKE_STATE/transition-canceled" ]; then
        printf '901\n'
      else
        printf '\n'
      fi
    elif [[ "$endpoint" == *'status=in_progress'* ]] &&
      [ "${FAKE_LEGACY_RUN:-}" = 1 ] && [ ! -f "$FAKE_STATE/legacy-canceled" ]; then
      printf '902\n'
    elif [[ "$endpoint" == *'status=in_progress'* ]] &&
      [ -f "$FAKE_STATE/active-run" ] && [ ! -f "$FAKE_STATE/canceled" ]; then
      printf '900\n'
    else
      printf '\n'
    fi
    ;;
  'api repos/f5-sales-demo/example/actions/workflows/enforce-repo-settings.yml/runs?status='*)
    if [ -n "${FAKE_RUN_QUERY_FAIL_STATUS:-}" ] &&
      [[ "$endpoint" == *"status=${FAKE_RUN_QUERY_FAIL_STATUS}"* ]]; then
      echo 'gh: synthetic active-run query failure (HTTP 500)' >&2
      exit 1
    fi
    if [ "${FAKE_TRANSITIONAL_RUN:-}" = 1 ] && [[ "$endpoint" == *'status=queued'* ]]; then
      if [ ! -f "$FAKE_STATE/transition-started" ]; then
        touch "$FAKE_STATE/transition-started"
        printf '\n'
      elif [ ! -f "$FAKE_STATE/transition-canceled" ]; then
        printf '901\n'
      else
        printf '\n'
      fi
    elif [[ "$endpoint" == *'status=in_progress'* ]] &&
      [ -f "$FAKE_STATE/active-run" ] && [ ! -f "$FAKE_STATE/canceled" ]; then
      printf '900\n'
    else
      printf '\n'
    fi
    ;;
  'api repos/f5-sales-demo/example/actions/runs/900/cancel')
    touch "$FAKE_STATE/canceled"
    ;;
  'api repos/f5-sales-demo/example/actions/runs/901/cancel')
    touch "$FAKE_STATE/transition-canceled"
    ;;
  'api repos/f5-sales-demo/example/actions/runs/902/cancel')
    touch "$FAKE_STATE/legacy-canceled"
    ;;
  'api repos/f5-sales-demo/example/actions/runs/903/cancel')
    touch "$FAKE_STATE/unrelated-canceled"
    ;;
  'api repos/f5-sales-demo/example/actions/runs/904/cancel')
    touch "$FAKE_STATE/forward-transition-canceled"
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
      printf '%s\n' "$DOWNSTREAM_BLOB"
    elif [ -f "$FAKE_STATE/merged" ]; then
      printf '%s\n' "$CALLER_BLOB"
    else
      printf '%s\n' "$DOWNSTREAM_BLOB"
    fi
    ;;
  'api repos/f5-sales-demo/example/contents/.github/workflows/super-linter.yml?ref='*)
    ref=${endpoint##*ref=}
    if [ "$ref" = "$BRANCH_HEAD" ] && [ -f "$FAKE_STATE/lint-updated" ]; then
      printf '%s\n' "$LINT_CALLER_BLOB"
    elif [ "$ref" = "$BRANCH_HEAD" ]; then
      printf '%s\n' "$DOWNSTREAM_LINT_BLOB"
    elif [ -f "$FAKE_STATE/merged" ]; then
      printf '%s\n' "$LINT_CALLER_BLOB"
    else
      printf '%s\n' "$DOWNSTREAM_LINT_BLOB"
    fi
    ;;
  'api repos/f5-sales-demo/example') printf 'main\n' ;;
  'api repos/f5-sales-demo/example/git/ref/heads/main') printf '%s\n' "$BASE_SHA" ;;
  'api repos/f5-sales-demo/example/git/ref/heads/sync/exact-caller-'*)
    if [ -f "$FAKE_STATE/branch" ]; then
      if [ -f "$FAKE_STATE/corrupt" ]; then
        printf '%s\n' '8888888888888888888888888888888888888888'
      elif [ -f "$FAKE_STATE/updated" ] || [ -f "$FAKE_STATE/lint-updated" ]; then
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
  'api repos/f5-sales-demo/example/contents/.github/workflows/super-linter.yml')
    touch "$FAKE_STATE/lint-updated"
    ;;
  'api repos/f5-sales-demo/example/compare/'*)
    files='[]'
    count=0
    if [ "$DOWNSTREAM_BLOB" != "$CALLER_BLOB" ]; then
      files=$(jq -cn --argjson files "$files" --arg sha "$CALLER_BLOB" \
        '$files + [{filename:".github/workflows/enforce-repo-settings.yml",sha:$sha,status:"modified"}]')
      count=$((count + 1))
    fi
    if [ "$DOWNSTREAM_LINT_BLOB" != "$LINT_CALLER_BLOB" ]; then
      files=$(jq -cn --argjson files "$files" --arg sha "$LINT_CALLER_BLOB" \
        '$files + [{filename:".github/workflows/super-linter.yml",sha:$sha,status:"modified"}]')
      count=$((count + 1))
    fi
    jq -cn --argjson count "$count" --argjson files "$files" \
      '{status:"ahead",ahead_by:$count,total_commits:$count,commits:[range(0;$count)|{}],files:$files}'
    ;;
  'api repos/f5-sales-demo/example/pulls?state=open&per_page=100')
    if [ -f "$FAKE_STATE/duplicate-current-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg branch "$EXPECTED_BRANCH" \
        --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[{number: 12, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}},
          {number: 13, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    elif [ -f "$FAKE_STATE/fork-current-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg branch "$EXPECTED_BRANCH" \
        --arg repo "${GITHUB_REPOSITORY%/*}-fork/example" \
        '[{number: 11, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    elif [ -f "$FAKE_STATE/page-two-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[], [{number: 9, head: {ref: "sync/exact-caller-aaaaaaaaaaaa-99999-1", sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    elif [ -f "$FAKE_STATE/huge-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[{number: 10, head: {ref: "sync/exact-caller-aaaaaaaaaaaa-999999999999999999999999999999-1", sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    elif [ -f "$FAKE_STATE/newer-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[{number: 8, head: {ref: "sync/exact-caller-aaaaaaaaaaaa-99999-1", sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    elif [ -f "$FAKE_STATE/current-pr" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg branch "$EXPECTED_BRANCH" \
        --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[{number: 42, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    elif [ -f "$FAKE_STATE/old-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[{number: 7, head: {ref: "sync/exact-caller-aaaaaaaaaaaa-12-1", sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    else
      printf '[]\n'
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
    files='[]'
    count=0
    if [ "$DOWNSTREAM_BLOB" != "$CALLER_BLOB" ]; then
      files=$(jq -cn --argjson files "$files" '$files + [{path:".github/workflows/enforce-repo-settings.yml"}]')
      count=$((count + 1))
    fi
    if [ "$DOWNSTREAM_LINT_BLOB" != "$LINT_CALLER_BLOB" ]; then
      files=$(jq -cn --argjson files "$files" '$files + [{path:".github/workflows/super-linter.yml"}]')
      count=$((count + 1))
    fi
    jq -cn --arg branch "$EXPECTED_BRANCH" --arg sha "$BRANCH_HEAD" \
      --argjson count "$count" --argjson files "$files" \
      '{baseRefName:"main",headRefName:$branch,headRefOid:$sha,commits:[range(0;$count)|{}],files:$files}'
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
    REPO_SETTINGS_CONFIG="${TEST_REPO_SETTINGS_CONFIG:-$WORK/repo-settings.json}" \
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
    EXPECTED_BRANCH="sync/exact-caller-${CALLER_BLOB:0:6}${LINT_CALLER_BLOB:0:6}-12345-1" \
    CALLER_BLOB="$CALLER_BLOB" \
    CALLER_CONTENT="$CALLER_CONTENT" \
    LINT_CALLER_BLOB="$LINT_CALLER_BLOB" \
    LINT_CALLER_CONTENT="$LINT_CALLER_CONTENT" \
    DOWNSTREAM_BLOB="$DOWNSTREAM_BLOB" \
    DOWNSTREAM_LINT_BLOB="${DOWNSTREAM_LINT_BLOB:-$LINT_CALLER_BLOB}" \
    FAKE_READ_ERROR="${FAKE_READ_ERROR:-}" \
    FAKE_MAIN_ADVANCE_AT="${FAKE_MAIN_ADVANCE_AT:-}" \
    FAKE_MALFORMED_CALLER="${FAKE_MALFORMED_CALLER:-}" \
    FAKE_MISSING_WORKFLOW="${FAKE_MISSING_WORKFLOW:-}" \
    FAKE_MERGE_LANDS="${FAKE_MERGE_LANDS:-}" \
    FAKE_ADVANCE_AFTER_ENABLE="${FAKE_ADVANCE_AFTER_ENABLE:-}" \
    FAKE_FAIL_ENABLE_REPO="${FAKE_FAIL_ENABLE_REPO:-}" \
    FAKE_RATE_LIMIT_STATUS="${FAKE_RATE_LIMIT_STATUS:-}" \
    FAKE_RUN_QUERY_FAIL_STATUS="${FAKE_RUN_QUERY_FAIL_STATUS:-}" \
    FAKE_FORWARD_TRANSITIONAL_RUN="${FAKE_FORWARD_TRANSITIONAL_RUN:-}" \
    FAKE_TRANSITIONAL_RUN="${FAKE_TRANSITIONAL_RUN:-}" \
    FAKE_LEGACY_RUN="${FAKE_LEGACY_RUN:-}" \
    FAKE_UNRELATED_RUN="${FAKE_UNRELATED_RUN:-}" \
    FAKE_MALFORMED_RUN_ID="${FAKE_MALFORMED_RUN_ID:-}" \
    FAKE_STALE_REQUIRED_CHECKS="${FAKE_STALE_REQUIRED_CHECKS:-}" \
    FAKE_REQUIRED_CHECKS_ERROR="${FAKE_REQUIRED_CHECKS_ERROR:-}" \
    FAKE_REQUIRED_CHECKS_VERIFY_DRIFT="${FAKE_REQUIRED_CHECKS_VERIFY_DRIFT:-}" \
    FAKE_REQUIRED_CHECKS_PATCH_RATE_LIMIT="${FAKE_REQUIRED_CHECKS_PATCH_RATE_LIMIT:-}" \
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
echo "[OK] stale callers close older PRs and queue one exact bounded PR"

state="$WORK/state-stale-required-checks"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_STALE_REQUIRED_CHECKS=1
set +e
run_bootstrap "$state" >"$WORK/stale-required-checks.out" 2>"$WORK/stale-required-checks.err"
rc=$?
set -e
unset FAKE_STALE_REQUIRED_CHECKS
required_patch_line=$(grep -n \
  'example/branches/main/protection/required_status_checks --method PATCH' \
  "$WORK/gh.log" | cut -d: -f1 || true)
branch_create_line=$(grep -n 'git/refs --method POST' "$WORK/gh.log" | cut -d: -f1 || true)
if [ "$rc" != 83 ] || [ -z "$required_patch_line" ] || [ -z "$branch_create_line" ] ||
  [ "$required_patch_line" -ge "$branch_create_line" ] ||
  ! jq -e '
    .strict == true and
    .contexts == ["Check linked issues", "Example CI", "lint / Lint Code Base"]
  ' "$state/required-checks-input.json" >/dev/null; then
  echo "[FAIL] stale required checks were not reconciled exactly before caller PR creation"
  cat "$WORK/stale-required-checks.err"
  exit 1
fi
echo "[OK] stale required checks reconcile additions and exclusions before caller PR creation"

state="$WORK/state-required-check-read-failure"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_REQUIRED_CHECKS_ERROR=1
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_REQUIRED_CHECKS_ERROR
if [ "$rc" = 0 ] || [ -f "$state/continued-after-required-check-failure" ] ||
  grep -qE 'git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr (create|merge)' \
    "$WORK/gh.log"; then
  echo "[FAIL] required-check API failure did not block caller mutation"
  exit 1
fi
echo "[OK] required-check API failure blocks caller mutation"

state="$WORK/state-required-check-patch-rate-limit"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_STALE_REQUIRED_CHECKS=1
FAKE_REQUIRED_CHECKS_PATCH_RATE_LIMIT=1
set +e
run_bootstrap "$state" >/dev/null 2>"$WORK/required-check-patch-rate-limit.err"
rc=$?
set -e
unset FAKE_STALE_REQUIRED_CHECKS FAKE_REQUIRED_CHECKS_PATCH_RATE_LIMIT
if [ "$rc" != 84 ] || [ -f "$state/continued-after-required-check-failure" ] ||
  [ "$(grep -c 'required_status_checks --method PATCH' "$WORK/gh.log")" -ne 1 ] ||
  grep -qE 'git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr (create|merge)' \
    "$WORK/gh.log"; then
  echo "[FAIL] required-check rate exhaustion did not defer immediately before caller mutation"
  exit 1
fi
echo "[OK] required-check rate exhaustion returns a bounded recoverable defer"

state="$WORK/state-required-check-verification-drift"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_STALE_REQUIRED_CHECKS=1
FAKE_REQUIRED_CHECKS_VERIFY_DRIFT=1
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_STALE_REQUIRED_CHECKS FAKE_REQUIRED_CHECKS_VERIFY_DRIFT
if [ "$rc" = 0 ] || [ -f "$state/continued-after-required-check-failure" ] ||
  ! grep -q 'example/branches/main/protection/required_status_checks --method PATCH' \
    "$WORK/gh.log" ||
  grep -qE 'git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr (create|merge)' \
    "$WORK/gh.log"; then
  echo "[FAIL] required-check postcondition drift did not fail before caller mutation"
  exit 1
fi
echo "[OK] required-check reconciliation verifies its exact postcondition"

state="$WORK/state-stale-lint-only"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
DOWNSTREAM_LINT_BLOB="$OLD_BLOB"
set +e
run_bootstrap "$state" >"$WORK/stale-lint-only.out" 2>"$WORK/stale-lint-only.err"
rc=$?
set -e
unset DOWNSTREAM_LINT_BLOB
if [ "$rc" != 83 ] ||
  grep -q 'contents/.github/workflows/enforce-repo-settings.yml --method PUT' "$WORK/gh.log" ||
  ! grep -q 'contents/.github/workflows/super-linter.yml --method PUT' "$WORK/gh.log" ||
  grep -q 'actions/workflows/enforce-repo-settings.yml/enable --method PUT' "$WORK/gh.log"; then
  echo "[FAIL] stale lint-only caller was not kept quiesced behind its exact bounded PR"
  cat "$WORK/stale-lint-only.err"
  exit 1
fi
echo "[OK] exact enforcement with stale lint updates only lint and remains quiesced"

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
if [ "$(grep -c 'actions/runs?status=' "$WORK/gh.log")" -ne 5 ]; then
  echo "[FAIL] a workflow disabled before bootstrap required more than one bounded run inventory"
  exit 1
fi
echo "[OK] active rollout enables only the verified exact caller"

state="$WORK/state-disabled-forward-transition"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
FAKE_FORWARD_TRANSITIONAL_RUN=1
run_bootstrap "$state" >"$WORK/disabled-forward-transition.out"
unset FAKE_FORWARD_TRANSITIONAL_RUN
if [ ! -f "$state/forward-transition-canceled" ] ||
  ! grep -q 'actions/runs/904/cancel --method POST' "$WORK/gh.log"; then
  echo "[FAIL] one bounded disabled-workflow inventory missed a forward status transition"
  exit 1
fi
echo "[OK] bounded disabled-workflow inventory catches forward status transitions"

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

state="$WORK/state-run-query-failure"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_RUN_QUERY_FAIL_STATUS=queued
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_RUN_QUERY_FAIL_STATUS
if [ "$rc" = 0 ] ||
  grep -qE 'git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] partial active-run inventory was treated as fleet quiescence"
  exit 1
fi
echo "[OK] any active-run status query failure blocks caller mutation"

state="$WORK/state-run-query-rate-limit"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_RATE_LIMIT_STATUS=requested
set +e
run_bootstrap "$state" >"$WORK/rate-limit.out" 2>"$WORK/rate-limit.err"
rc=$?
set -e
unset FAKE_RATE_LIMIT_STATUS
if [ "$rc" != 84 ] ||
  [ "$(grep -c 'API rate limit exceeded' "$WORK/rate-limit.err")" -ne 1 ] ||
  [ "$(grep -c 'runs?status=' "$WORK/gh.log")" -ne 1 ] ||
  grep -qE 'git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] API rate exhaustion did not defer immediately before caller mutation"
  exit 1
fi
echo "[OK] API rate exhaustion returns a bounded recoverable defer"

state="$WORK/state-malformed-run-inventory"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_MALFORMED_RUN_ID=1
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_MALFORMED_RUN_ID
if [ "$rc" = 0 ] || grep -q 'actions/runs/not-a-run-id' "$WORK/gh.log" ||
  grep -qE 'git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr (create|merge)' "$WORK/gh.log"; then
  echo "[FAIL] malformed active-run inventory was used as a cancellation target"
  exit 1
fi
echo "[OK] malformed active-run inventory fails before cancellation or caller mutation"

state="$WORK/state-transitioning-run"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_TRANSITIONAL_RUN=1
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_TRANSITIONAL_RUN
if [ "$rc" != 83 ] ||
  ! grep -q 'actions/runs/901/cancel --method POST' "$WORK/gh.log" ||
  [ ! -f "$state/transition-canceled" ] ||
  [ "$(grep -c 'runs?status=queued' "$WORK/gh.log")" -lt 4 ]; then
  echo "[FAIL] status transition escaped the settled quiescence proof"
  exit 1
fi
echo "[OK] repeated empty inventories catch and cancel status transitions"

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
if [ "$rc" != 83 ] || ! grep -q -- '--paginate' "$WORK/gh.log" || grep -q -- '--slurp' "$WORK/gh.log" ||
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

cat >"$WORK/repo-settings-invalid.json" <<'EOF'
{
  "branch_protection": [
    {
      "branch": "main",
      "required_status_checks": {
        "strict": true,
        "contexts": ["Check linked issues", "Check linked issues"]
      }
    }
  ],
  "repo_overrides": {}
}
EOF
: >"$WORK/gh.log"
set +e
TEST_REPO_SETTINGS_CONFIG="$WORK/repo-settings-invalid.json" run_bootstrap "$state" \
  >/dev/null 2>&1
rc=$?
set -e
unset TEST_REPO_SETTINGS_CONFIG
if [ "$rc" = 0 ] || [ -s "$WORK/gh.log" ]; then
  echo "[FAIL] invalid required-check configuration was not rejected before network access"
  exit 1
fi
echo "[OK] invalid required-check configuration is rejected before network access"

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

printf '["example","example-two"]\n' >"$WORK/repos-two.json"
state="$WORK/state-partial-enable-failure"
mkdir -p "$state"
touch "$state/disabled" "$state/disabled-example-two"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
FAKE_FAIL_ENABLE_REPO=example-two
set +e
TEST_DOWNSTREAM_CONFIG="$WORK/repos-two.json" run_bootstrap "$state" \
  >"$WORK/partial-enable.out" 2>"$WORK/partial-enable.err"
rc=$?
set -e
unset FAKE_FAIL_ENABLE_REPO TEST_DOWNSTREAM_CONFIG
example_enable_line=$(grep -n \
  'example/actions/workflows/enforce-repo-settings.yml/enable --method PUT' \
  "$WORK/gh.log" | tail -1 | cut -d: -f1)
example_rollback_line=$(grep -n \
  'example/actions/workflows/enforce-repo-settings.yml/disable --method PUT' \
  "$WORK/gh.log" | tail -1 | cut -d: -f1)
second_enable_attempts=$(grep -c \
  'example-two/actions/workflows/enforce-repo-settings.yml/enable --method PUT' \
  "$WORK/gh.log" || true)
second_enable_first_line=$(grep -n \
  'example-two/actions/workflows/enforce-repo-settings.yml/enable --method PUT' \
  "$WORK/gh.log" | head -1 | cut -d: -f1)
second_enable_last_line=$(grep -n \
  'example-two/actions/workflows/enforce-repo-settings.yml/enable --method PUT' \
  "$WORK/gh.log" | tail -1 | cut -d: -f1)
if [ "$rc" = 0 ] || [ -z "$example_enable_line" ] ||
  [ -z "$example_rollback_line" ] ||
  [ "$example_rollback_line" -le "$example_enable_line" ] ||
  [ "$second_enable_attempts" -ne 3 ] ||
  [ -z "$second_enable_first_line" ] || [ -z "$second_enable_last_line" ] ||
  [ "$second_enable_first_line" -le "$example_enable_line" ] ||
  [ "$second_enable_last_line" -ge "$example_rollback_line" ] ||
  ! grep -q '\[FAIL\] Could not enable exact enforcement for example-two' \
    "$WORK/partial-enable.err" ||
  [ ! -f "$state/disabled" ] || [ ! -f "$state/disabled-example-two" ]; then
  echo "[FAIL] a later enable failure left part of the fleet active"
  sed 's/^/  /' "$WORK/partial-enable.err"
  exit 1
fi
echo "[OK] partial enable failure behaviorally returns the whole fleet to quiescence"

state="$WORK/state-missing-workflow-active-run"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
FAKE_MISSING_WORKFLOW=1
FAKE_MERGE_LANDS=1
FAKE_LEGACY_RUN=1
FAKE_UNRELATED_RUN=1
set +e
run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset FAKE_MISSING_WORKFLOW FAKE_MERGE_LANDS FAKE_LEGACY_RUN FAKE_UNRELATED_RUN
if [ "$rc" != 0 ] || [ ! -f "$state/legacy-canceled" ] ||
  ! grep -q 'actions/runs/902/cancel --method POST' "$WORK/gh.log" ||
  grep -q 'actions/runs/903/cancel' "$WORK/gh.log" || [ -f "$state/unrelated-canceled" ]; then
  echo "[FAIL] active legacy run escaped quiescence after its workflow file was deleted"
  exit 1
fi
echo "[OK] missing current workflow still inventories and cancels active legacy runs"

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
