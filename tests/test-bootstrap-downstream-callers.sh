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
BASE_TREE=8888888888888888888888888888888888888888
REFRESH_TREE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REFRESH_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CALLER_TEXT='name: Enforce Repository Settings'
CALLER_CONTENT=$(printf '%s\n' "$CALLER_TEXT" | base64 | tr -d '\n')
CALLER_BLOB=$(printf '%s\n' "$CALLER_TEXT" | git hash-object --stdin)
LINT_CALLER_TEXT='name: Super-Linter'
LINT_CALLER_CONTENT=$(printf '%s\n' "$LINT_CALLER_TEXT" | base64 | tr -d '\n')
LINT_CALLER_BLOB=$(printf '%s\n' "$LINT_CALLER_TEXT" | git hash-object --stdin)
LINKED_CALLER_TEXT='name: Require Linked Issue'
LINKED_CALLER_CONTENT=$(printf '%s\n' "$LINKED_CALLER_TEXT" | base64 | tr -d '\n')
LINKED_CALLER_BLOB=$(printf '%s\n' "$LINKED_CALLER_TEXT" | git hash-object --stdin)
printf '["example"]\n' >"$WORK/repos.json"
printf '{"revision":"%s"}\n' "$PIN_SHA" >"$WORK/pin.json"
printf '{"state":"active"}\n' >"$WORK/rollout.json"
printf '{"skip_files":{}}\n' >"$WORK/governance.json"
cat >"$WORK/repo-settings.json" <<'EOF'
{
  "repository": {
    "allow_squash_merge": true,
    "allow_auto_merge": true,
    "delete_branch_on_merge": true
  },
  "branch_protection": [
    {
      "branch": "main",
      "enforce_admins": true,
      "required_status_checks": {
        "strict": true,
        "contexts": [
          "Check linked issues",
          "lint / Lint Code Base",
          "lint / Shell Unit Tests"
        ],
        "self_contexts": ["Check linked issues", "Lint Code Base", "Shell Unit Tests"]
      },
      "required_pull_request_reviews": null,
      "restrictions": null,
      "required_linear_history": false,
      "allow_force_pushes": false,
      "allow_deletions": false,
      "block_creations": false,
      "required_conversation_resolution": false,
      "lock_branch": false,
      "allow_fork_syncing": false
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

if grep -Fqi 'checkov' "$SOURCE" || ! grep -Fq 'first_repo' "$SOURCE"; then
  echo "[FAIL] first-repository bootstrap is not limited to exact managed callers"
  exit 1
fi
echo "[OK] first-repository bootstrap is limited to exact managed callers"

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
  'api repos/f5-sales-demo/docs-control/contents/workflows/require-linked-issue.yml?ref='*)
    if [[ "$*" == *'--jq .sha'* ]]; then
      printf '%s\n' "$LINKED_CALLER_BLOB"
    else
      printf '{"type":"file","encoding":"base64","sha":"%s","content":"%s"}\n' \
        "$LINKED_CALLER_BLOB" "$LINKED_CALLER_CONTENT"
    fi
    ;;
  'api repos/f5-sales-demo/example/commits/main')
    if [ -f "$FAKE_STATE/required-check-failed" ]; then
      touch "$FAKE_STATE/continued-after-required-check-failure"
    fi
    printf '%s\n' "$BASE_SHA"
    ;;
  'api repos/f5-sales-demo/example/actions/workflows/enforce-repo-settings.yml')
    if { [ "${FAKE_MISSING_WORKFLOW:-}" = 1 ] || [ "${FAKE_FIRST_REPO:-}" = 1 ] ||
      [ "${FAKE_PROTECTED_EMPTY_CALLERS:-}" = 1 ]; } &&
      [ ! -f "$FAKE_STATE/merged" ]; then
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
      if [ "${FAKE_FIRST_REPO:-}" = 1 ]; then
        jq -e '
          (.contexts | index("Check linked issues")) != null and
          (.contexts | index("check / Check linked issues")) == null
        ' "$input" >/dev/null || exit 65
        cp "$input" "$FAKE_STATE/final-required-checks.json"
        touch "$FAKE_STATE/final-required-checks-reconciled"
      elif [ "${FAKE_STAGED_LINKED_TRANSITION:-}" = 1 ]; then
        if jq -e '
          (.contexts | index("check / Check linked issues")) != null and
          (.contexts | index("Check linked issues")) == null
        ' "$input" >/dev/null; then
          cp "$input" "$FAKE_STATE/transition-required-checks.json"
          touch "$FAKE_STATE/transition-required-checks-reconciled"
        elif jq -e '
          (.contexts | index("Check linked issues")) != null and
          (.contexts | index("check / Check linked issues")) == null
        ' "$input" >/dev/null; then
          cp "$input" "$FAKE_STATE/final-required-checks.json"
          touch "$FAKE_STATE/final-required-checks-reconciled"
        else
          exit 65
        fi
      else
        touch "$FAKE_STATE/required-checks-reconciled"
      fi
    elif [ "${FAKE_FIRST_REPO:-}" = 1 ] && [ ! -f "$FAKE_STATE/protection-created" ]; then
      echo 'gh: Branch not protected (HTTP 404)' >&2
      exit 1
    elif [ "${FAKE_FIRST_REPO:-}" = 1 ] &&
      [ ! -f "$FAKE_STATE/final-required-checks-reconciled" ]; then
      printf '{"strict":true,"contexts":["Example CI","lint / Lint Code Base"]}\n'
    elif [ "${FAKE_REQUIRED_CHECKS_ERROR:-}" = 1 ]; then
      touch "$FAKE_STATE/required-check-failed"
      echo 'gh: synthetic required-check read failure (HTTP 500)' >&2
      exit 1
    elif [ "${FAKE_STAGED_LINKED_TRANSITION:-}" = 1 ] &&
      [ -f "$FAKE_STATE/transition-required-checks-reconciled" ] &&
      [ ! -f "$FAKE_STATE/final-required-checks-reconciled" ]; then
      printf '{"strict":true,"contexts":["check / Check linked issues","Example CI","lint / Lint Code Base"]}\n'
    elif [ "${FAKE_STAGED_LINKED_TRANSITION:-}" = 1 ]; then
      printf '{"strict":true,"contexts":["Check linked issues","Example CI","lint / Lint Code Base"]}\n'
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
  'api repos/f5-sales-demo/example/commits/'*'/check-runs'*)
    if [ "${FAKE_FIRST_REPO:-}" = 1 ]; then
      if [ "${FAKE_FAST_FAIL:-}" = 1 ]; then
        touch "$FAKE_STATE/advance-main"
      fi
      case "${FAKE_FIRST_REPO_LINT_MODE:-success}" in
      absent)
        printf '{"total_count":0,"check_runs":[]}\n'
        ;;
      malformed)
        printf '{"total_count":2,"check_runs":"invalid"}\n'
        ;;
      *)
        lint_status=completed
        lint_conclusion=success
        app_id=15368
        app_slug=github-actions
        case "${FAKE_FIRST_REPO_LINT_MODE:-success}" in
        pending)
          lint_status=in_progress
          lint_conclusion=null
          ;;
        failed) lint_conclusion=failure ;;
        spoofed)
          app_id=99999
          app_slug=untrusted-check-writer
          ;;
        success | wrong-pr | wrong-run) ;;
        *) exit 64 ;;
        esac
        jq -cn --arg sha "$BRANCH_HEAD" --arg status "$lint_status" \
          --arg conclusion "$lint_conclusion" \
          --argjson app_id "$app_id" --arg app_slug "$app_slug" '
          {total_count:2,check_runs:[
            {id:10001,name:"lint / Lint Code Base",head_sha:$sha,
             status:$status,
             conclusion:(if $conclusion == "null" then null else $conclusion end),
             details_url:"https://github.com/f5-sales-demo/example/actions/runs/1001/job/10001",
             app:{id:$app_id,slug:$app_slug},pull_requests:[]},
            {id:10002,name:"lint / Shell Unit Tests",head_sha:$sha,
             status:"completed",conclusion:"success",
             details_url:"https://github.com/f5-sales-demo/example/actions/runs/1001/job/10002",
             app:{id:$app_id,slug:$app_slug},pull_requests:[]}
          ]}'
        ;;
      esac
    elif [ "${FAKE_LEGACY_LINKED_CHECK:-}" = 1 ]; then
      jq -cn --arg sha "$BRANCH_HEAD" \
        '{check_runs:[{name:"check / Check linked issues",head_sha:$sha,status:"completed",conclusion:"success",details_url:"https://github.com/f5-sales-demo/example/actions/runs/999/job/1000",app:{id:15368,slug:"github-actions"}}]}'
    else
      printf '{"check_runs":[]}\n'
    fi
    ;;
  'api repos/f5-sales-demo/example/actions/runs/999')
    jq -cn --arg sha "$BRANCH_HEAD" \
      '{path:".github/workflows/require-linked-issue.yml",event:"pull_request_target",head_sha:$sha,status:"completed",conclusion:"success"}'
    ;;
  'api repos/f5-sales-demo/example/actions/runs/1001')
    run_path=.github/workflows/super-linter.yml
    pr_number=42
    if [ "${FAKE_FIRST_REPO_LINT_MODE:-success}" = wrong-run ]; then
      run_path=.github/workflows/untrusted.yml
    elif [ "${FAKE_FIRST_REPO_LINT_MODE:-success}" = wrong-pr ]; then
      pr_number=43
    fi
    jq -cn --arg sha "$BRANCH_HEAD" --arg branch "$EXPECTED_BRANCH" \
      --arg path "$run_path" --arg revision "$PIN_SHA" \
      --arg slug f5-sales-demo/example --argjson pr "$pr_number" '
      {id:1001,name:"Super-Linter",path:$path,event:"pull_request",head_sha:$sha,
       head_branch:$branch,head_commit:{id:$sha},
       head_repository:{id:123,full_name:$slug},
       repository:{id:123,full_name:$slug},
       status:"completed",conclusion:"success",
       pull_requests:[{number:$pr,head:{sha:$sha,ref:$branch},base:{ref:"main"}}],
       referenced_workflows:[{
         path:("f5-sales-demo/docs-control/.github/workflows/super-linter.yml@" + $revision),
         sha:$revision
       }]}'
    ;;
  'api repos/f5-sales-demo/example/actions/workflows/require-linked-issue.yml/dispatches')
    input=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--input" ]; then
        input="$2"
        break
      fi
      shift
    done
    [ -n "$input" ] || exit 64
    if [ "${FAKE_FIRST_REPO:-}" = 1 ] && [ ! -f "$FAKE_STATE/merged" ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    if [ "${FAKE_STAGED_LINKED_TRANSITION:-}" = 1 ] &&
      ! jq -e '.inputs.pull_request_number and .inputs.expected_head_sha' "$input" >/dev/null; then
      echo 'gh: workflow does not have workflow_dispatch trigger (HTTP 422)' >&2
      exit 1
    fi
    count=0
    [ ! -f "$FAKE_STATE/linked-dispatch-count" ] || count=$(cat "$FAKE_STATE/linked-dispatch-count")
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_STATE/linked-dispatch-count"
    ;;
  'api repos/f5-sales-demo/example/commits/'*'/statuses')
    if [ -f "$FAKE_STATE/linked-dispatch-count" ]; then
      status_id=$(cat "$FAKE_STATE/linked-dispatch-count")
      jq -cn --argjson id "$status_id" \
        '[{id:$id,context:"Check linked issues",state:"success",creator:{id:41898282,login:"github-actions[bot]",type:"Bot"}}]'
    else
      printf '[]\n'
    fi
    ;;
  'api repos/f5-sales-demo/example-two/commits/main')
    if [ "${FAKE_FAIL_SECOND_BOOTSTRAP:-}" = 1 ]; then
      echo 'gh: synthetic protected-main read failure (HTTP 500)' >&2
      exit 1
    fi
    printf '%s\n' "$BASE_SHA"
    ;;
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
  'api repos/f5-sales-demo/example-two/contents/.github/workflows/require-linked-issue.yml?ref='*)
    printf '%s\n' "$DOWNSTREAM_LINKED_BLOB"
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
    if [ "${FAKE_FIRST_REPO_PARTIAL:-}" = 1 ] && [ ! -f "$FAKE_STATE/merged" ] &&
      [ "$ref" != "$BRANCH_HEAD" ]; then
      printf '%s\n' "$OLD_BLOB"
    elif { [ "${FAKE_MISSING_WORKFLOW:-}" = 1 ] || [ "${FAKE_FIRST_REPO:-}" = 1 ] ||
      [ "${FAKE_PROTECTED_EMPTY_CALLERS:-}" = 1 ]; } &&
      [ ! -f "$FAKE_STATE/merged" ] &&
      [ "$ref" != "$BRANCH_HEAD" ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    elif { [ "$ref" = "$BRANCH_HEAD" ] || [ "$ref" = "$REFRESH_HEAD" ]; } &&
      [ -f "$FAKE_STATE/updated" ]; then
      printf '%s\n' "$CALLER_BLOB"
    elif [ "$ref" = "$BRANCH_HEAD" ] || [ "$ref" = "$REFRESH_HEAD" ]; then
      printf '%s\n' "$DOWNSTREAM_BLOB"
    elif [ -f "$FAKE_STATE/merged" ]; then
      printf '%s\n' "$CALLER_BLOB"
    else
      printf '%s\n' "$DOWNSTREAM_BLOB"
    fi
    ;;
  'api repos/f5-sales-demo/example/contents/.github/workflows/super-linter.yml?ref='*)
    if [ "${FAKE_FORBID_LINT_READ:-}" = 1 ]; then
      echo 'unexpected opted-out Super-Linter caller read' >&2
      exit 65
    fi
    ref=${endpoint##*ref=}
    if { [ "${FAKE_FIRST_REPO:-}" = 1 ] ||
      [ "${FAKE_PROTECTED_EMPTY_CALLERS:-}" = 1 ]; } &&
      [ ! -f "$FAKE_STATE/merged" ] &&
      [ "$ref" != "$BRANCH_HEAD" ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    elif { [ "$ref" = "$BRANCH_HEAD" ] || [ "$ref" = "$REFRESH_HEAD" ]; } &&
      [ -f "$FAKE_STATE/lint-updated" ]; then
      printf '%s\n' "$LINT_CALLER_BLOB"
    elif [ "$ref" = "$BRANCH_HEAD" ] || [ "$ref" = "$REFRESH_HEAD" ]; then
      printf '%s\n' "$DOWNSTREAM_LINT_BLOB"
    elif [ -f "$FAKE_STATE/merged" ]; then
      printf '%s\n' "$LINT_CALLER_BLOB"
    else
      printf '%s\n' "$DOWNSTREAM_LINT_BLOB"
    fi
    ;;
  'api repos/f5-sales-demo/example/contents/.github/workflows/require-linked-issue.yml?ref='*)
    ref=${endpoint##*ref=}
    if [ "${FAKE_BAD_RECOVER_LINKED:-}" = 1 ] && [ "$ref" = "$BRANCH_HEAD" ]; then
      printf '%s\n' "$OLD_BLOB"
    elif { [ "${FAKE_FIRST_REPO:-}" = 1 ] ||
      [ "${FAKE_PROTECTED_EMPTY_CALLERS:-}" = 1 ]; } &&
      [ ! -f "$FAKE_STATE/merged" ] &&
      [ "$ref" != "$BRANCH_HEAD" ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    elif { [ "$ref" = "$BRANCH_HEAD" ] || [ "$ref" = "$REFRESH_HEAD" ]; } &&
      [ -f "$FAKE_STATE/linked-updated" ]; then
      printf '%s\n' "$LINKED_CALLER_BLOB"
    elif [ "$ref" = "$BRANCH_HEAD" ] || [ "$ref" = "$REFRESH_HEAD" ]; then
      printf '%s\n' "$DOWNSTREAM_LINKED_BLOB"
    elif [ -f "$FAKE_STATE/merged" ]; then
      printf '%s\n' "$LINKED_CALLER_BLOB"
    else
      printf '%s\n' "$DOWNSTREAM_LINKED_BLOB"
    fi
    ;;
  'api repos/f5-sales-demo/example/branches/main/protection')
    if [[ "$*" == *'--method PUT'* ]]; then
      input=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--input" ]; then
          input="$2"
          break
        fi
        shift
      done
      [ -n "$input" ] || exit 64
      jq -e '
        .enforce_admins == true and
        .required_status_checks.strict == true and
        .required_status_checks.contexts == ["Example CI", "lint / Lint Code Base"] and
        .required_pull_request_reviews == null and .restrictions == null and
        .allow_force_pushes == false and .allow_deletions == false
      ' "$input" >/dev/null || exit 65
      cp "$input" "$FAKE_STATE/transition-protection.json"
      touch "$FAKE_STATE/protection-created"
    elif [ "${FAKE_FIRST_REPO:-}" = 1 ] && [ ! -f "$FAKE_STATE/protection-created" ]; then
      echo 'gh: Branch not protected (HTTP 404)' >&2
      exit 1
    elif [ "${FAKE_FIRST_REPO:-}" = 1 ]; then
      jq -cn --slurpfile desired "$FAKE_STATE/transition-protection.json" '
        $desired[0] | {
          enforce_admins:{enabled:.enforce_admins},
          required_status_checks:.required_status_checks,
          required_pull_request_reviews:.required_pull_request_reviews,
          restrictions:.restrictions,
          required_linear_history:{enabled:.required_linear_history},
          allow_force_pushes:{enabled:.allow_force_pushes},
          allow_deletions:{enabled:.allow_deletions},
          block_creations:{enabled:.block_creations},
          required_conversation_resolution:{enabled:.required_conversation_resolution},
          lock_branch:{enabled:.lock_branch},
          allow_fork_syncing:{enabled:.allow_fork_syncing}
        }'
    else
      printf '%s\n' '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["Check linked issues","Example CI","lint / Lint Code Base"]},"required_pull_request_reviews":null,"restrictions":null,"required_linear_history":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false},"block_creations":{"enabled":false},"required_conversation_resolution":{"enabled":false},"lock_branch":{"enabled":false},"allow_fork_syncing":{"enabled":false}}'
    fi
    ;;
  'api repos/f5-sales-demo/example')
    if [[ "$*" == *'--method PATCH'* ]]; then
      input=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--input" ]; then
          input="$2"
          break
        fi
        shift
      done
      [ -n "$input" ] || exit 64
      jq -e '
        .allow_squash_merge == true and .allow_auto_merge == true and
        .delete_branch_on_merge == true
      ' "$input" >/dev/null || exit 65
      touch "$FAKE_STATE/repo-settings-reconciled"
    elif [[ "$*" == *'--jq .default_branch'* ]]; then
      printf 'main\n'
    elif [ -f "$FAKE_STATE/repo-settings-reconciled" ]; then
      printf '{"allow_squash_merge":true,"allow_auto_merge":true,"delete_branch_on_merge":true}\n'
    else
      printf '{"allow_squash_merge":true,"allow_auto_merge":false,"delete_branch_on_merge":false}\n'
    fi
    ;;
  'api repos/f5-sales-demo/example/git/ref/heads/main') printf '%s\n' "$BASE_SHA" ;;
  'api repos/f5-sales-demo/example/git/ref/heads/sync/exact-caller-'*)
    if [ -f "$FAKE_STATE/branch" ]; then
      if [ -f "$FAKE_STATE/corrupt" ]; then
        printf '%s\n' '8888888888888888888888888888888888888888'
      elif [ -f "$FAKE_STATE/refreshed" ]; then
        printf '%s\n' "$REFRESH_HEAD"
      elif [ -f "$FAKE_STATE/updated" ] || [ -f "$FAKE_STATE/lint-updated" ] ||
        [ -f "$FAKE_STATE/linked-updated" ]; then
        printf '%s\n' "$BRANCH_HEAD"
      else
        printf '%s\n' "$BASE_SHA"
      fi
    else
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    ;;
  'api repos/f5-sales-demo/example/git/commits/'*)
    jq -cn --arg sha "$BASE_SHA" --arg tree "$BASE_TREE" \
      '{sha:$sha,tree:{sha:$tree},parents:[]}'
    ;;
  'api repos/f5-sales-demo/example/git/trees')
    input=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--input" ]; then
        input="$2"
        break
      fi
      shift
    done
    [ -n "$input" ] || exit 64
    skip_lint=false
    [ "${FAKE_SKIP_LINT_CALLER:-}" != 1 ] || skip_lint=true
    jq -e --arg base "$BASE_TREE" --arg caller "$CALLER_BLOB" \
      --arg lint "$LINT_CALLER_BLOB" --arg linked "$LINKED_CALLER_BLOB" \
      --argjson skip_lint "$skip_lint" '
      .base_tree == $base and
      .tree == (
        [{path:".github/workflows/enforce-repo-settings.yml",mode:"100644",type:"blob",sha:$caller}] +
        (if $skip_lint then [] else
          [{path:".github/workflows/super-linter.yml",mode:"100644",type:"blob",sha:$lint}]
        end) +
        [{path:".github/workflows/require-linked-issue.yml",mode:"100644",type:"blob",sha:$linked}]
      )
    ' "$input" >/dev/null || exit 65
    touch "$FAKE_STATE/refresh-tree-created"
    jq -cn --arg sha "$REFRESH_TREE" '{sha:$sha}'
    ;;
  'api repos/f5-sales-demo/example/git/commits')
    input=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--input" ]; then
        input="$2"
        break
      fi
      shift
    done
    [ -n "$input" ] || exit 64
    jq -e --arg tree "$REFRESH_TREE" --arg head "$BRANCH_HEAD" --arg base "$BASE_SHA" '
      .tree == $tree and .parents == [$head, $base]
    ' "$input" >/dev/null || exit 65
    [ -f "$FAKE_STATE/refresh-tree-created" ] || exit 65
    touch "$FAKE_STATE/refresh-commit-created"
    jq -cn --arg sha "$REFRESH_HEAD" --arg tree "$REFRESH_TREE" \
      --arg head "$BRANCH_HEAD" --arg base "$BASE_SHA" \
      '{sha:$sha,tree:{sha:$tree},parents:[{sha:$head},{sha:$base}]}'
    ;;
  'api repos/f5-sales-demo/example/git/refs/heads/sync/exact-caller-'*)
    input=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--input" ]; then
        input="$2"
        break
      fi
      shift
    done
    [ -n "$input" ] || exit 64
    jq -e --arg sha "$REFRESH_HEAD" '.sha == $sha and .force == false' \
      "$input" >/dev/null || exit 65
    [ -f "$FAKE_STATE/refresh-commit-created" ] || exit 65
    touch "$FAKE_STATE/refreshed"
    jq -cn --arg sha "$REFRESH_HEAD" '{object:{sha:$sha}}'
    ;;
  'api repos/f5-sales-demo/example/git/refs') touch "$FAKE_STATE/branch" ;;
  'api repos/f5-sales-demo/example/contents/.github/workflows/enforce-repo-settings.yml')
    touch "$FAKE_STATE/updated"
    ;;
  'api repos/f5-sales-demo/example/contents/.github/workflows/super-linter.yml')
    touch "$FAKE_STATE/lint-updated"
    ;;
  'api repos/f5-sales-demo/example/contents/.github/workflows/require-linked-issue.yml')
    touch "$FAKE_STATE/linked-updated"
    ;;
  'api repos/f5-sales-demo/example/compare/'*)
    files='[]'
    count=0
    if [ "$DOWNSTREAM_BLOB" != "$CALLER_BLOB" ]; then
      files=$(jq -cn --argjson files "$files" --arg sha "$CALLER_BLOB" \
        '$files + [{filename:".github/workflows/enforce-repo-settings.yml",sha:$sha,status:"modified"}]')
      count=$((count + 1))
    fi
    if [ "${FAKE_SKIP_LINT_CALLER:-}" != 1 ] &&
      [ "$DOWNSTREAM_LINT_BLOB" != "$LINT_CALLER_BLOB" ]; then
      files=$(jq -cn --argjson files "$files" --arg sha "$LINT_CALLER_BLOB" \
        '$files + [{filename:".github/workflows/super-linter.yml",sha:$sha,status:"modified"}]')
      count=$((count + 1))
    fi
    if [ "$DOWNSTREAM_LINKED_BLOB" != "$LINKED_CALLER_BLOB" ]; then
      files=$(jq -cn --argjson files "$files" --arg sha "$LINKED_CALLER_BLOB" \
        '$files + [{filename:".github/workflows/require-linked-issue.yml",sha:$sha,status:"modified"}]')
      count=$((count + 1))
    fi
    if [ "${FAKE_DIVERGED_BASE:-}" = 1 ] && [ ! -f "$FAKE_STATE/refreshed" ]; then
      jq -cn --argjson count "$count" --argjson files "$files" \
        '{status:"diverged",ahead_by:$count,behind_by:1,total_commits:$count,commits:[range(0;$count)|{}],files:$files}'
    elif [ -f "$FAKE_STATE/refreshed" ]; then
      refreshed_count=$((count + 1))
      jq -cn --arg base "$BASE_SHA" --argjson count "$refreshed_count" \
        --argjson files "$files" \
        '{status:"ahead",ahead_by:$count,behind_by:0,total_commits:$count,
          merge_base_commit:{sha:$base},commits:[range(0;$count)|{}],files:$files}'
    else
      jq -cn --argjson count "$count" --argjson files "$files" \
        '{status:"ahead",ahead_by:$count,behind_by:0,total_commits:$count,commits:[range(0;$count)|{}],files:$files}'
    fi
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
        --arg branch "sync/exact-caller-${OTHER_SHA}${OTHER_SHA}${OTHER_SHA}" \
        '[], [{number: 9, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    elif [ -f "$FAKE_STATE/current-pr" ]; then
      current_head="$BRANCH_HEAD"
      [ ! -f "$FAKE_STATE/refreshed" ] || current_head="$REFRESH_HEAD"
      jq -cn --arg sha "$current_head" --arg branch "$EXPECTED_BRANCH" \
        --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[{number: 42, head: {ref: $branch, sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    elif [ -f "$FAKE_STATE/old-open" ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[{number: 7, head: {ref: "sync/exact-caller-aaaaaaaaaaaa-12-1", sha: $sha, repo: {full_name: $repo}}, base: {ref: "main"}}]'
    else
      printf '[]\n'
    fi
    ;;
  'api repos/f5-sales-demo/example/pulls?state=closed&sort=updated&direction=desc&per_page=100')
    if [ "${FAKE_RECOVER_MERGED_TRANSITION:-}" = 1 ]; then
      jq -cn --arg sha "$BRANCH_HEAD" --arg branch "$EXPECTED_BRANCH" \
        --arg repo "${GITHUB_REPOSITORY%/*}/example" \
        '[{number:42,merged_at:"2026-08-04T12:00:00Z",head:{ref:$branch,sha:$sha,repo:{full_name:$repo}},base:{ref:"main"}}]'
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
  'pr close') rm -f "$FAKE_STATE/old-open" "$FAKE_STATE/page-two-open" ;;
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
    if [ "${FAKE_SKIP_LINT_CALLER:-}" != 1 ] &&
      [ "$DOWNSTREAM_LINT_BLOB" != "$LINT_CALLER_BLOB" ]; then
      files=$(jq -cn --argjson files "$files" '$files + [{path:".github/workflows/super-linter.yml"}]')
      count=$((count + 1))
    fi
    if [ "$DOWNSTREAM_LINKED_BLOB" != "$LINKED_CALLER_BLOB" ]; then
      files=$(jq -cn --argjson files "$files" \
        '$files + [{path:".github/workflows/require-linked-issue.yml"}]')
      count=$((count + 1))
    fi
    current_head="$BRANCH_HEAD"
    commit_count="$count"
    if [ -f "$FAKE_STATE/refreshed" ]; then
      current_head="$REFRESH_HEAD"
      commit_count=$((commit_count + 1))
    fi
    jq -cn --arg branch "$EXPECTED_BRANCH" --arg sha "$current_head" \
      --argjson count "$commit_count" --argjson files "$files" \
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
  local expected_lint_receipt="$LINT_CALLER_BLOB"
  if [ "${FAKE_SKIP_LINT_CALLER:-}" = 1 ]; then
    expected_lint_receipt=skipped
  fi
  local expected_branch="sync/exact-caller-${CALLER_BLOB}${expected_lint_receipt}${LINKED_CALLER_BLOB}"
  env \
    PATH="$WORK/bin:$PATH" \
    GITHUB_REPOSITORY=f5-sales-demo/docs-control \
    SOURCE_SHA="$SOURCE_SHA" \
    PIN_CONFIG="$WORK/pin.json" \
    ROLLOUT_CONFIG="${TEST_ROLLOUT_CONFIG:-$WORK/rollout.json}" \
    DOWNSTREAM_CONFIG="${TEST_DOWNSTREAM_CONFIG:-$WORK/repos.json}" \
    REPO_SETTINGS_CONFIG="${TEST_REPO_SETTINGS_CONFIG:-$WORK/repo-settings.json}" \
    GOVERNANCE_CONFIG="${TEST_GOVERNANCE_CONFIG:-$WORK/governance.json}" \
    BOOTSTRAP_WAIT_SECONDS=0 \
    BOOTSTRAP_LINKED_WAIT_SECONDS=0 \
    FAKE_LOG="$WORK/gh.log" \
    FAKE_STATE="$state" \
    SOURCE_SHA="$SOURCE_SHA" \
    PIN_SHA="$PIN_SHA" \
    BASE_SHA="$BASE_SHA" \
    BASE_TREE="$BASE_TREE" \
    OTHER_SHA="$OTHER_SHA" \
    OLD_BLOB="$OLD_BLOB" \
    ENFORCE_BLOB="$ENFORCE_BLOB" \
    SYNC_BLOB="$SYNC_BLOB" \
    BRANCH_HEAD="$BRANCH_HEAD" \
    REFRESH_TREE="$REFRESH_TREE" \
    REFRESH_HEAD="$REFRESH_HEAD" \
    EXPECTED_BRANCH="$expected_branch" \
    CALLER_BLOB="$CALLER_BLOB" \
    CALLER_CONTENT="$CALLER_CONTENT" \
    LINT_CALLER_BLOB="$LINT_CALLER_BLOB" \
    LINT_CALLER_CONTENT="$LINT_CALLER_CONTENT" \
    LINKED_CALLER_BLOB="$LINKED_CALLER_BLOB" \
    LINKED_CALLER_CONTENT="$LINKED_CALLER_CONTENT" \
    DOWNSTREAM_BLOB="$DOWNSTREAM_BLOB" \
    DOWNSTREAM_LINT_BLOB="${DOWNSTREAM_LINT_BLOB:-$LINT_CALLER_BLOB}" \
    DOWNSTREAM_LINKED_BLOB="${DOWNSTREAM_LINKED_BLOB:-$LINKED_CALLER_BLOB}" \
    FAKE_SKIP_LINT_CALLER="${FAKE_SKIP_LINT_CALLER:-}" \
    FAKE_FORBID_LINT_READ="${FAKE_FORBID_LINT_READ:-}" \
    FAKE_READ_ERROR="${FAKE_READ_ERROR:-}" \
    FAKE_MAIN_ADVANCE_AT="${FAKE_MAIN_ADVANCE_AT:-}" \
    FAKE_DIVERGED_BASE="${FAKE_DIVERGED_BASE:-}" \
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
    FAKE_STAGED_LINKED_TRANSITION="${FAKE_STAGED_LINKED_TRANSITION:-}" \
    FAKE_LEGACY_LINKED_CHECK="${FAKE_LEGACY_LINKED_CHECK:-}" \
    FAKE_RECOVER_MERGED_TRANSITION="${FAKE_RECOVER_MERGED_TRANSITION:-}" \
    FAKE_FIRST_REPO="${FAKE_FIRST_REPO:-}" \
    FAKE_FIRST_REPO_PARTIAL="${FAKE_FIRST_REPO_PARTIAL:-}" \
    FAKE_PROTECTED_EMPTY_CALLERS="${FAKE_PROTECTED_EMPTY_CALLERS:-}" \
    FAKE_FIRST_REPO_LINT_MODE="${FAKE_FIRST_REPO_LINT_MODE:-}" \
    FAKE_FAST_FAIL="${FAKE_FAST_FAIL:-}" \
    FAKE_BAD_RECOVER_LINKED="${FAKE_BAD_RECOVER_LINKED:-}" \
    FAKE_FAIL_SECOND_BOOTSTRAP="${FAKE_FAIL_SECOND_BOOTSTRAP:-}" \
    REPO_SETTINGS_TOKEN=settings-token \
    "$SOURCE"
}

DOWNSTREAM_BLOB="$OLD_BLOB"
DOWNSTREAM_LINT_BLOB="$OLD_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
for lint_mode in absent pending failed malformed spoofed wrong-pr wrong-run; do
  state="$WORK/state-first-repo-${lint_mode}-lint"
  mkdir -p "$state"
  : >"$WORK/gh.log"
  FAKE_FIRST_REPO=1
  FAKE_FIRST_REPO_LINT_MODE="$lint_mode"
  FAKE_FAST_FAIL=1
  FAKE_MERGE_LANDS=1
  set +e
  run_bootstrap "$state" >"$WORK/first-repo-${lint_mode}-lint.out" \
    2>"$WORK/first-repo-${lint_mode}-lint.err"
  rc=$?
  set -e
  unset FAKE_FIRST_REPO FAKE_FIRST_REPO_LINT_MODE FAKE_FAST_FAIL FAKE_MERGE_LANDS
  case "$lint_mode" in
  absent | pending) expected_error='Waiting for authentic Super-Linter checks' ;;
  failed) expected_error='First-repository lint checks did not succeed' ;;
  malformed) expected_error='First-repository lint check response is malformed' ;;
  spoofed) expected_error='First-repository lint checks are not authentic exact-head receipts' ;;
  wrong-pr) expected_error='First-repository lint workflow run is not an exact trusted receipt' ;;
  wrong-run) expected_error='First-repository lint workflow run is not an exact trusted receipt' ;;
  esac
  if [ "$rc" = 0 ] || grep -qE '^pr merge |require-linked-issue.yml/dispatches' \
    "$WORK/gh.log" || ! grep -q "$expected_error" \
    "$WORK/first-repo-${lint_mode}-lint.out" \
    "$WORK/first-repo-${lint_mode}-lint.err"; then
    echo "[FAIL] first-repository ${lint_mode} lint receipt did not fail closed"
    cat "$WORK/first-repo-${lint_mode}-lint.err"
    sed 's/^/  log: /' "$WORK/gh.log"
    exit 1
  fi
done
unset DOWNSTREAM_LINT_BLOB DOWNSTREAM_LINKED_BLOB
echo "[OK] absent, pending, failed, malformed, spoofed, and untrusted first-repository lint receipts fail closed"

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

: >"$WORK/gh.log"
set +e
run_bootstrap "$state" >"$WORK/adopt-stable-receipt.out" \
  2>"$WORK/adopt-stable-receipt.err"
rc=$?
set -e
if [ "$rc" != 83 ] ||
  grep -qE '^pr (close|create) |git/refs --method POST|contents/.github/workflows/.* --method PUT' \
    "$WORK/gh.log" ||
  ! grep -q '^pr view 42 ' "$WORK/gh.log" ||
  ! grep -q '^pr merge 42 ' "$WORK/gh.log"; then
  echo "[FAIL] recovery did not adopt the existing stable exact-caller receipt"
  cat "$WORK/adopt-stable-receipt.err"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] recovery adopts the existing stable exact-caller receipt without churn"

state="$WORK/state-diverged-stable-receipt"
mkdir -p "$state"
touch "$state/disabled" "$state/branch" "$state/current-pr" \
  "$state/updated" "$state/lint-updated" "$state/linked-updated"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
DOWNSTREAM_LINT_BLOB="$OLD_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
FAKE_DIVERGED_BASE=1
set +e
run_bootstrap "$state" >"$WORK/diverged-stable-receipt.out" \
  2>"$WORK/diverged-stable-receipt.err"
rc=$?
set -e
if [ "$rc" != 83 ] ||
  ! grep -q 'git/trees --method POST' "$WORK/gh.log" ||
  ! grep -q 'git/commits --method POST' "$WORK/gh.log" ||
  ! grep -q 'git/refs/heads/sync/exact-caller-.* --method PATCH' "$WORK/gh.log" ||
  ! grep -q -- "--match-head-commit $REFRESH_HEAD" "$WORK/gh.log" ||
  grep -qE '^pr (close|create) |(^|[[:space:]])--force([[:space:]]|$)|"force"[[:space:]]*:[[:space:]]*true' \
    "$WORK/gh.log"; then
  echo "[FAIL] protected-main drift did not fast-forward the stable exact-caller owner"
  cat "$WORK/diverged-stable-receipt.err"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] protected-main drift fast-forwards one exact stable owner without force"

: >"$WORK/gh.log"
set +e
run_bootstrap "$state" >"$WORK/adopt-refreshed-stable-receipt.out" \
  2>"$WORK/adopt-refreshed-stable-receipt.err"
rc=$?
set -e
unset FAKE_DIVERGED_BASE DOWNSTREAM_LINT_BLOB DOWNSTREAM_LINKED_BLOB
if [ "$rc" != 83 ] ||
  grep -qE '^pr (close|create) |git/(trees|commits) --method POST|git/refs/heads/.* --method PATCH' \
    "$WORK/gh.log" ||
  ! grep -q -- "--match-head-commit $REFRESH_HEAD" "$WORK/gh.log"; then
  echo "[FAIL] recovery did not idempotently adopt the refreshed stable owner"
  cat "$WORK/adopt-refreshed-stable-receipt.err"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] recovery adopts the refreshed stable owner without another mutation"

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
linked_status_line=$(grep -n '/status' "$WORK/gh.log" | tail -1 | cut -d: -f1 || true)
merge_line=$(grep -n '^pr merge ' "$WORK/gh.log" | head -1 | cut -d: -f1 || true)
if [ "$rc" != 83 ] || [ -z "$required_patch_line" ] || [ -z "$branch_create_line" ] ||
  [ -z "$linked_status_line" ] || [ -z "$merge_line" ] ||
  [ "$branch_create_line" -ge "$linked_status_line" ] ||
  [ "$linked_status_line" -ge "$required_patch_line" ] ||
  [ "$required_patch_line" -ge "$merge_line" ] ||
  ! jq -e '
    .strict == true and
    .contexts == ["Check linked issues", "Example CI", "lint / Lint Code Base"]
  ' "$state/required-checks-input.json" >/dev/null; then
  echo "[FAIL] stale required checks were not reconciled after exact evaluator proof"
  cat "$WORK/stale-required-checks.err"
  exit 1
fi
echo "[OK] stale required checks reconcile only after exact evaluator proof"

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
if [ "$rc" = 0 ] ||
  grep -qE '^pr merge |actions/workflows/enforce-repo-settings.yml/enable' \
    "$WORK/gh.log"; then
  echo "[FAIL] required-check API failure did not block merge and enforcement"
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
if [ "$rc" != 84 ] ||
  [ "$(grep -c 'required_status_checks --method PATCH' "$WORK/gh.log")" -ne 1 ] ||
  grep -qE '^pr merge |actions/workflows/enforce-repo-settings.yml/enable' \
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
if [ "$rc" = 0 ] ||
  ! grep -q 'example/branches/main/protection/required_status_checks --method PATCH' \
    "$WORK/gh.log" ||
  grep -qE '^pr merge |actions/workflows/enforce-repo-settings.yml/enable' \
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

cat >"$WORK/governance-skip-lint.json" <<'EOF'
{"skip_files":{"example":[".github/workflows/super-linter.yml"]}}
EOF
state="$WORK/state-skip-stale-lint"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
DOWNSTREAM_LINT_BLOB="$OLD_BLOB"
FAKE_SKIP_LINT_CALLER=1
FAKE_FORBID_LINT_READ=1
set +e
TEST_GOVERNANCE_CONFIG="$WORK/governance-skip-lint.json" run_bootstrap "$state" \
  >"$WORK/skip-stale-lint.out" 2>"$WORK/skip-stale-lint.err"
rc=$?
set -e
unset DOWNSTREAM_LINT_BLOB FAKE_SKIP_LINT_CALLER FAKE_FORBID_LINT_READ \
  TEST_GOVERNANCE_CONFIG
if [ "$rc" != 83 ] ||
  ! grep -q 'contents/.github/workflows/enforce-repo-settings.yml --method PUT' \
    "$WORK/gh.log" ||
  grep -q 'example/contents/.github/workflows/super-linter.yml' "$WORK/gh.log" ||
  grep -q 'contents/.github/workflows/super-linter.yml --method PUT' "$WORK/gh.log" ||
  grep -q 'actions/workflows/enforce-repo-settings.yml/enable --method PUT' \
    "$WORK/gh.log"; then
  echo "[FAIL] opted-out lint caller was read, changed, or allowed to bypass exact enforcement"
  cat "$WORK/skip-stale-lint.err"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] opted-out lint caller is untouched while mandatory callers stay fail-closed"

state="$WORK/state-diverged-skip-stale-lint"
mkdir -p "$state"
touch "$state/disabled" "$state/branch" "$state/current-pr" \
  "$state/updated" "$state/linked-updated"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
DOWNSTREAM_LINT_BLOB="$OLD_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
FAKE_DIVERGED_BASE=1
FAKE_SKIP_LINT_CALLER=1
FAKE_FORBID_LINT_READ=1
set +e
TEST_GOVERNANCE_CONFIG="$WORK/governance-skip-lint.json" run_bootstrap "$state" \
  >"$WORK/diverged-skip-stale-lint.out" 2>"$WORK/diverged-skip-stale-lint.err"
rc=$?
set -e
unset FAKE_DIVERGED_BASE FAKE_SKIP_LINT_CALLER FAKE_FORBID_LINT_READ \
  DOWNSTREAM_LINT_BLOB DOWNSTREAM_LINKED_BLOB TEST_GOVERNANCE_CONFIG
if [ "$rc" != 83 ] ||
  ! grep -q 'git/trees --method POST' "$WORK/gh.log" ||
  grep -q 'example/contents/.github/workflows/super-linter.yml' "$WORK/gh.log" ||
  grep -q 'contents/.github/workflows/super-linter.yml --method PUT' "$WORK/gh.log" ||
  grep -qE '^pr (close|create) |(^|[[:space:]])--force([[:space:]]|$)|"force"[[:space:]]*:[[:space:]]*true' \
    "$WORK/gh.log"; then
  echo "[FAIL] protected-main refresh read or replaced an opted-out lint caller"
  cat "$WORK/diverged-skip-stale-lint.err"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] protected-main refresh preserves an opted-out repository-owned lint caller"

state="$WORK/state-stale-linked-only"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
set +e
run_bootstrap "$state" >"$WORK/stale-linked-only.out" 2>"$WORK/stale-linked-only.err"
rc=$?
set -e
unset DOWNSTREAM_LINKED_BLOB
if [ "$rc" != 83 ] ||
  grep -q 'contents/.github/workflows/enforce-repo-settings.yml --method PUT' "$WORK/gh.log" ||
  grep -q 'contents/.github/workflows/super-linter.yml --method PUT' "$WORK/gh.log" ||
  ! grep -q 'contents/.github/workflows/require-linked-issue.yml --method PUT' "$WORK/gh.log" ||
  ! grep -q 'require-linked-issue.yml/dispatches --method POST' "$WORK/gh.log" ||
  ! grep -q '^pr merge ' "$WORK/gh.log" ||
  grep -q 'actions/workflows/enforce-repo-settings.yml/enable --method PUT' "$WORK/gh.log"; then
  echo "[FAIL] stale linked-issue evaluator was not carried by its exact bounded PR"
  cat "$WORK/stale-linked-only.err"
  exit 1
fi
echo "[OK] stale linked-issue evaluator is bootstrapped before enforcement resumes"

state="$WORK/state-staged-linked-transition"
mkdir -p "$state"
touch "$state/disabled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
FAKE_STAGED_LINKED_TRANSITION=1
FAKE_LEGACY_LINKED_CHECK=1
FAKE_MERGE_LANDS=1
set +e
run_bootstrap "$state" >"$WORK/staged-linked-transition.out" \
  2>"$WORK/staged-linked-transition.err"
rc=$?
set -e
unset DOWNSTREAM_LINKED_BLOB FAKE_STAGED_LINKED_TRANSITION FAKE_LEGACY_LINKED_CHECK \
  FAKE_MERGE_LANDS
legacy_check_line=$(grep -n '/check-runs' "$WORK/gh.log" | head -1 | cut -d: -f1 || true)
transition_patch_line=$(grep -n 'required_status_checks --method PATCH' "$WORK/gh.log" | head -1 | cut -d: -f1 || true)
merge_line=$(grep -n '^pr merge ' "$WORK/gh.log" | head -1 | cut -d: -f1 || true)
dispatch_line=$(grep -n 'require-linked-issue.yml/dispatches --method POST' "$WORK/gh.log" | tail -1 | cut -d: -f1 || true)
status_line=$(grep -n '/status' "$WORK/gh.log" | tail -1 | cut -d: -f1 || true)
final_patch_line=$(grep -n 'required_status_checks --method PATCH' "$WORK/gh.log" | tail -1 | cut -d: -f1 || true)
if [ "$rc" != 0 ] || [ -z "$legacy_check_line" ] || [ -z "$transition_patch_line" ] ||
  [ -z "$merge_line" ] || [ -z "$dispatch_line" ] || [ -z "$status_line" ] ||
  [ -z "$final_patch_line" ] || [ "$legacy_check_line" -ge "$transition_patch_line" ] ||
  [ "$transition_patch_line" -ge "$merge_line" ] || [ "$merge_line" -ge "$dispatch_line" ] ||
  [ "$dispatch_line" -ge "$status_line" ] || [ "$status_line" -ge "$final_patch_line" ] ||
  [ "$(grep -c 'required_status_checks --method PATCH' "$WORK/gh.log")" -ne 2 ] ||
  ! jq -e '.contexts | index("check / Check linked issues") != null' \
    "$state/transition-required-checks.json" >/dev/null ||
  ! jq -e '.contexts | index("Check linked issues") != null' \
    "$state/final-required-checks.json" >/dev/null; then
  echo "[FAIL] linked-issue evaluator transition did not retain a real gate through both stages"
  cat "$WORK/staged-linked-transition.err"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] linked-issue evaluator transition preserves a verified real gate throughout"

state="$WORK/state-recover-linked-transition"
mkdir -p "$state"
touch "$state/transition-required-checks-reconciled"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
FAKE_STAGED_LINKED_TRANSITION=1
FAKE_RECOVER_MERGED_TRANSITION=1
run_bootstrap "$state" >"$WORK/recover-linked-transition.out" \
  2>"$WORK/recover-linked-transition.err"
unset FAKE_STAGED_LINKED_TRANSITION FAKE_RECOVER_MERGED_TRANSITION
if ! grep -q 'pulls?state=closed&sort=updated&direction=desc&per_page=100' "$WORK/gh.log" ||
  ! grep -q 'require-linked-issue.yml/dispatches --method POST' "$WORK/gh.log" ||
  [ "$(grep -c 'required_status_checks --method PATCH' "$WORK/gh.log")" -ne 1 ] ||
  grep -qE 'git/refs --method POST|contents/.github/workflows/.* --method PUT|^pr (create|merge)' \
    "$WORK/gh.log"; then
  echo "[FAIL] interrupted linked-issue transition did not recover from its merged exact receipt"
  cat "$WORK/recover-linked-transition.err"
  exit 1
fi
echo "[OK] interrupted transition recovers idempotently from its merged exact receipt"

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
  ! grep -q '^pr close 9 ' "$WORK/gh.log" ||
  ! grep -qE 'git/refs --method POST|contents/.github/workflows/enforce-repo-settings.yml --method PUT|^pr create ' "$WORK/gh.log"; then
  echo "[FAIL] superseded exact-caller PR outside the first API page was not replaced"
  echo "  rc=$rc"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] paginated exact-caller inventory replaces later-page superseded receipts"

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
state="$WORK/state-mixed-pending-and-failure"
mkdir -p "$state"
touch "$state/disabled" "$state/disabled-example-two"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
FAKE_STAGED_LINKED_TRANSITION=1
FAKE_FAIL_SECOND_BOOTSTRAP=1
set +e
TEST_DOWNSTREAM_CONFIG="$WORK/repos-two.json" run_bootstrap "$state" >/dev/null 2>&1
rc=$?
set -e
unset DOWNSTREAM_LINKED_BLOB FAKE_STAGED_LINKED_TRANSITION FAKE_FAIL_SECOND_BOOTSTRAP
if [ "$rc" != 1 ] || grep -q 'actions/workflows/enforce-repo-settings.yml/enable --method PUT' \
  "$WORK/gh.log"; then
  echo "[FAIL] recoverable transition state masked a permanent fleet bootstrap failure"
  exit 1
fi
echo "[OK] permanent fleet bootstrap failures take precedence over recoverable transition state"

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

state="$WORK/state-protected-empty-callers"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
DOWNSTREAM_LINT_BLOB="$OLD_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
FAKE_PROTECTED_EMPTY_CALLERS=1
set +e
run_bootstrap "$state" >"$WORK/protected-empty-callers.out" \
  2>"$WORK/protected-empty-callers.err"
rc=$?
set -e
unset FAKE_PROTECTED_EMPTY_CALLERS
if [ "$rc" = 0 ] ||
  grep -qE 'repos/f5-sales-demo/example --method PATCH|branches/main/protection --method PUT|git/refs --method POST|contents/.* --method PUT|^pr (create|merge)' \
    "$WORK/gh.log"; then
  echo "[FAIL] protected callerless repository entered the first-repository transition"
  cat "$WORK/protected-empty-callers.err"
  exit 1
fi
echo "[OK] existing protection cannot be replaced by the first-repository transition"

state="$WORK/state-unprotected-partial-callers"
mkdir -p "$state"
: >"$WORK/gh.log"
FAKE_FIRST_REPO=1
FAKE_FIRST_REPO_PARTIAL=1
set +e
run_bootstrap "$state" >"$WORK/unprotected-partial-callers.out" \
  2>"$WORK/unprotected-partial-callers.err"
rc=$?
set -e
unset FAKE_FIRST_REPO FAKE_FIRST_REPO_PARTIAL
if [ "$rc" = 0 ] ||
  grep -qE 'repos/f5-sales-demo/example --method PATCH|branches/main/protection --method PUT|git/refs --method POST|contents/.* --method PUT|^pr (create|merge)' \
    "$WORK/gh.log"; then
  echo "[FAIL] unprotected partial caller set entered a bootstrap mutation"
  cat "$WORK/unprotected-partial-callers.err"
  exit 1
fi
echo "[OK] unprotected partial caller set fails before bootstrap mutation"

state="$WORK/state-first-repo-without-governed-lint"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
FAKE_FIRST_REPO=1
FAKE_SKIP_LINT_CALLER=1
FAKE_FORBID_LINT_READ=1
set +e
TEST_GOVERNANCE_CONFIG="$WORK/governance-skip-lint.json" run_bootstrap "$state" \
  >"$WORK/first-repo-without-governed-lint.out" \
  2>"$WORK/first-repo-without-governed-lint.err"
rc=$?
set -e
unset DOWNSTREAM_LINKED_BLOB FAKE_FIRST_REPO FAKE_SKIP_LINT_CALLER \
  FAKE_FORBID_LINT_READ TEST_GOVERNANCE_CONFIG
if [ "$rc" = 0 ] ||
  grep -qE 'repos/f5-sales-demo/example --method PATCH|branches/main/protection --method PUT|git/refs --method POST|contents/.* --method PUT|^pr (create|merge)' \
    "$WORK/gh.log"; then
  echo "[FAIL] first repository without governed lint entered a bootstrap mutation"
  cat "$WORK/first-repo-without-governed-lint.err"
  exit 1
fi
echo "[OK] first repository without governed Super-Linter fails before mutation"

state="$WORK/state-first-repo"
mkdir -p "$state"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$OLD_BLOB"
DOWNSTREAM_LINT_BLOB="$OLD_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
FAKE_FIRST_REPO=1
FAKE_FIRST_REPO_LINT_MODE=success
FAKE_MERGE_LANDS=1
set +e
run_bootstrap "$state" >"$WORK/first-repo.out" 2>"$WORK/first-repo.err"
rc=$?
set -e
unset DOWNSTREAM_LINT_BLOB DOWNSTREAM_LINKED_BLOB FAKE_FIRST_REPO \
  FAKE_FIRST_REPO_LINT_MODE FAKE_MERGE_LANDS
protection_line=$(grep -n 'branches/main/protection --method PUT' "$WORK/gh.log" |
  head -1 | cut -d: -f1 || true)
check_line=$(grep -n '/check-runs' "$WORK/gh.log" | head -1 | cut -d: -f1 || true)
run_line=$(grep -n 'actions/runs/1001' "$WORK/gh.log" | head -1 | cut -d: -f1 || true)
merge_line=$(grep -n '^pr merge ' "$WORK/gh.log" | head -1 | cut -d: -f1 || true)
dispatch_line=$(grep -n 'require-linked-issue.yml/dispatches --method POST' "$WORK/gh.log" |
  head -1 | cut -d: -f1 || true)
final_context_line=$(grep -n 'required_status_checks --method PATCH' "$WORK/gh.log" |
  tail -1 | cut -d: -f1 || true)
if [ "$rc" != 0 ] || [ -z "$protection_line" ] || [ -z "$check_line" ] ||
  [ -z "$run_line" ] || [ -z "$merge_line" ] ||
  [ -z "$dispatch_line" ] || [ -z "$final_context_line" ] ||
  [ "$protection_line" -ge "$check_line" ] || [ "$check_line" -ge "$run_line" ] ||
  [ "$run_line" -ge "$merge_line" ] || [ "$merge_line" -ge "$dispatch_line" ] ||
  [ "$dispatch_line" -ge "$final_context_line" ] ||
  ! grep -q -- "--match-head-commit $BRANCH_HEAD" "$WORK/gh.log" ||
  ! grep -q 'repos/f5-sales-demo/example --method PATCH' "$WORK/gh.log" ||
  [ "$(grep -c 'required_status_checks --method PATCH' "$WORK/gh.log")" -ne 1 ] ||
  ! jq -e '.required_status_checks.contexts | index("Check linked issues") == null' \
    "$state/transition-protection.json" >/dev/null ||
  ! jq -e '.contexts | index("Check linked issues") != null' \
    "$state/final-required-checks.json" >/dev/null; then
  echo "[FAIL] first governed repository did not complete the verified three-caller transition"
  echo "  rc=$rc"
  sed 's/^/  /' "$WORK/first-repo.err"
  sed 's/^/  log: /' "$WORK/gh.log"
  exit 1
fi
echo "[OK] first repository verifies authentic exact-head lint before merge and protection restoration"

state="$WORK/state-resume-first-repo-protection"
mkdir -p "$state"
touch "$state/protection-created"
cp "$WORK/state-first-repo/transition-protection.json" \
  "$state/transition-protection.json"
: >"$WORK/gh.log"
DOWNSTREAM_LINT_BLOB="$OLD_BLOB"
DOWNSTREAM_LINKED_BLOB="$OLD_BLOB"
FAKE_FIRST_REPO=1
FAKE_MERGE_LANDS=1
set +e
run_bootstrap "$state" >"$WORK/resume-first-repo-protection.out" \
  2>"$WORK/resume-first-repo-protection.err"
rc=$?
set -e
unset DOWNSTREAM_LINT_BLOB DOWNSTREAM_LINKED_BLOB FAKE_FIRST_REPO FAKE_MERGE_LANDS
if [ "$rc" != 0 ] ||
  grep -q 'branches/main/protection --method PUT' "$WORK/gh.log" ||
  ! grep -q '^pr merge ' "$WORK/gh.log" ||
  ! grep -q 'require-linked-issue.yml/dispatches --method POST' "$WORK/gh.log"; then
  echo "[FAIL] exact first-repository protection receipt did not resume safely"
  cat "$WORK/resume-first-repo-protection.err"
  exit 1
fi
echo "[OK] exact first-repository protection receipt resumes without replacement"

state="$WORK/state-recover-first-repo"
mkdir -p "$state"
touch "$state/merged" "$state/protection-created"
cp "$WORK/state-first-repo/transition-protection.json" \
  "$state/transition-protection.json"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
FAKE_FIRST_REPO=1
FAKE_RECOVER_MERGED_TRANSITION=1
run_bootstrap "$state" >"$WORK/recover-first-repo.out" \
  2>"$WORK/recover-first-repo.err"
unset FAKE_FIRST_REPO FAKE_RECOVER_MERGED_TRANSITION
if ! grep -q 'pulls?state=closed&sort=updated&direction=desc&per_page=100' "$WORK/gh.log" ||
  ! grep -q 'require-linked-issue.yml/dispatches --method POST' "$WORK/gh.log" ||
  [ "$(grep -c 'required_status_checks --method PATCH' "$WORK/gh.log")" -ne 1 ] ||
  grep -qE 'git/refs --method POST|contents/.github/workflows/.* --method PUT|^pr (create|merge)' \
    "$WORK/gh.log"; then
  echo "[FAIL] interrupted first-repository transition did not recover from three exact blobs"
  cat "$WORK/recover-first-repo.err"
  exit 1
fi
echo "[OK] interrupted first-repository transition recovers from three exact blobs"

state="$WORK/state-hostile-first-repo-receipt"
mkdir -p "$state"
touch "$state/merged" "$state/protection-created"
cp "$WORK/state-first-repo/transition-protection.json" \
  "$state/transition-protection.json"
: >"$WORK/gh.log"
DOWNSTREAM_BLOB="$CALLER_BLOB"
FAKE_FIRST_REPO=1
FAKE_RECOVER_MERGED_TRANSITION=1
FAKE_BAD_RECOVER_LINKED=1
set +e
run_bootstrap "$state" >/dev/null 2>"$WORK/hostile-first-repo-receipt.err"
rc=$?
set -e
unset FAKE_FIRST_REPO FAKE_RECOVER_MERGED_TRANSITION FAKE_BAD_RECOVER_LINKED
if [ "$rc" = 0 ] ||
  grep -qE 'require-linked-issue.yml/dispatches --method POST|required_status_checks --method PATCH|^pr merge' \
    "$WORK/gh.log"; then
  echo "[FAIL] hostile first-repository receipt reached dispatch or protection mutation"
  cat "$WORK/hostile-first-repo-receipt.err"
  exit 1
fi
echo "[OK] hostile first-repository receipt fails before dispatch or protection mutation"

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
