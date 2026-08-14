#!/usr/bin/env bash
# Prove governed workflows stop mutating when docs-control main advances.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
case "$*" in
  'api repos/f5-sales-demo/docs-control/commits/main --jq .sha')
    if [ -n "${FAKE_ADVANCE_FILE:-}" ] && [ -f "$FAKE_ADVANCE_FILE" ]; then
      printf '%s\n' "$FAKE_ADVANCED_SOURCE_SHA"
    else
      printf '%s\n' "$FAKE_CURRENT_SOURCE_SHA"
    fi
    ;;
  'api repos/f5-sales-demo/docs-control/compare/'*' --jq .status')
    printf '%s\n' "$FAKE_SOURCE_STATUS"
    ;;
  'workflow run enforce-repo-settings.yml --repo f5-sales-demo/example --ref main -f source_sha='*)
    exit 0
    ;;
  'api repos/f5-sales-demo/example/commits/main --jq .sha')
    printf '%s\n' "$FAKE_CURRENT_DOWNSTREAM_SHA"
    ;;
  'api repos/f5-sales-demo/example --method PATCH --input - --include')
    touch "$FAKE_ADVANCE_FILE"
    exit 1
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$WORK/bin/gh"

extract_function() {
  local workflow="$1" function_name="$2"
  awk -v signature="          ${function_name}() {" '
    $0 == signature { found=1 }
    found {
      line=$0
      sub(/^          /, "")
      print
      if (line == "          }") exit
    }
  ' "$workflow"
}

PASS=0
FAIL=0
OLD_SOURCE_SHA=1111111111111111111111111111111111111111
NEW_SOURCE_SHA=2222222222222222222222222222222222222222

for workflow in \
  "$REPO_ROOT/.github/workflows/sync-managed-files.yml" \
  "$REPO_ROOT/.github/workflows/enforce-repo-settings.yml"; do
  workflow_name=$(basename "$workflow")
  helper_file="$WORK/${workflow_name}.helpers.sh"
  extract_function "$workflow" retry >"$helper_file"
  if [ "$workflow_name" = sync-managed-files.yml ]; then
    extract_function "$workflow" require_sha >>"$helper_file"
  fi
  extract_function "$workflow" ensure_current_source_main >>"$helper_file"

  rc=0
  : >"$WORK/gh.log"
  (
    # shellcheck source=/dev/null
    source "$helper_file"
    export PATH="$WORK/bin:$PATH"
    export FAKE_GH_LOG="$WORK/gh.log"
    export FAKE_CURRENT_SOURCE_SHA="$OLD_SOURCE_SHA"
    export FAKE_SOURCE_STATUS=ahead
    export GITHUB_REPOSITORY_OWNER=f5-sales-demo
    export GITHUB_REPOSITORY=f5-sales-demo/example
    export REPO_SETTINGS_TOKEN=fake-token
    expected_source_sha="$OLD_SOURCE_SHA"
    ensure_current_source_main

    # This is the mutation-boundary call after main advances during the run.
    export FAKE_CURRENT_SOURCE_SHA="$NEW_SOURCE_SHA"
    ensure_current_source_main
  ) >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?

  dispatches=$(grep -c '^workflow run enforce-repo-settings.yml' "$WORK/gh.log" || true)
  if [ "$rc" -eq 78 ] && [ "$dispatches" -eq 1 ] && grep -q \
    "^workflow run enforce-repo-settings.yml --repo f5-sales-demo/example --ref main -f source_sha=${NEW_SOURCE_SHA}$" \
    "$WORK/gh.log"; then
    echo "[OK] ${workflow_name} defers stale mutation and enqueues exact source main"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${workflow_name} did not stop a stale mutation (rc=$rc dispatches=$dispatches)"
    sed 's/^/  /' "$WORK/stderr"
    FAIL=$((FAIL + 1))
  fi
done

for workflow in \
  "$REPO_ROOT/.github/workflows/sync-managed-files.yml" \
  "$REPO_ROOT/.github/workflows/enforce-repo-settings.yml"; do
  workflow_name=$(basename "$workflow")
  helper_file="$WORK/${workflow_name}.retry-helpers.sh"
  extract_function "$workflow" retry >"$helper_file"
  if [ "$workflow_name" = sync-managed-files.yml ]; then
    for function_name in \
      require_sha ensure_current_downstream_main require_current_downstream_main; do
      extract_function "$workflow" "$function_name" >>"$helper_file"
    done
  fi
  for function_name in \
    ensure_current_source_main require_current_source_main \
    current_json_request retry_current_json; do
    extract_function "$workflow" "$function_name" >>"$helper_file"
  done

  rc=0
  : >"$WORK/gh.log"
  advance_file="$WORK/${workflow_name}.advanced"
  rm -f "$advance_file"
  (
    # shellcheck source=/dev/null
    source "$helper_file"
    export PATH="$WORK/bin:$PATH"
    export FAKE_GH_LOG="$WORK/gh.log"
    export FAKE_CURRENT_SOURCE_SHA="$OLD_SOURCE_SHA"
    export FAKE_ADVANCED_SOURCE_SHA="$NEW_SOURCE_SHA"
    export FAKE_ADVANCE_FILE="$advance_file"
    export FAKE_SOURCE_STATUS=ahead
    export FAKE_CURRENT_DOWNSTREAM_SHA=3333333333333333333333333333333333333333
    export GITHUB_REPOSITORY_OWNER=f5-sales-demo
    export GITHUB_REPOSITORY=f5-sales-demo/example
    export REPO_SETTINGS_TOKEN=fake-token
    expected_source_sha="$OLD_SOURCE_SHA"
    expected_downstream_sha="$FAKE_CURRENT_DOWNSTREAM_SHA"
    retry_current_json 3 '{}' "repos/${GITHUB_REPOSITORY}" --method PATCH
  ) >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?

  mutations=$(grep -c '^api repos/f5-sales-demo/example --method PATCH --input - --include$' \
    "$WORK/gh.log" || true)
  dispatches=$(grep -c '^workflow run enforce-repo-settings.yml' "$WORK/gh.log" || true)
  if [ "$rc" -eq 0 ] && [ "$mutations" -eq 1 ] && [ "$dispatches" -eq 1 ]; then
    echo "[OK] ${workflow_name} re-proves source before a mutation retry"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${workflow_name} retried a mutation after source advancement"
    sed 's/^/  /' "$WORK/stderr"
    FAIL=$((FAIL + 1))
  fi
done

sync_guard_count=$(grep -c 'require_current_source_main' \
  "$REPO_ROOT/.github/workflows/sync-managed-files.yml")
settings_guard_count=$(grep -c 'require_current_source_main' \
  "$REPO_ROOT/.github/workflows/enforce-repo-settings.yml")
if [ "$sync_guard_count" -ge 10 ] && [ "$settings_guard_count" -ge 10 ] &&
  ! grep -q 'max_wait=' "$REPO_ROOT/.github/workflows/sync-managed-files.yml" &&
  grep -q 'enablePullRequestAutoMerge' "$REPO_ROOT/.github/workflows/sync-managed-files.yml" &&
  grep -q 'retry_current_json 3.*auto_merge_json' \
    "$REPO_ROOT/.github/workflows/sync-managed-files.yml"; then
  echo "[OK] source guards run initially and again at every governed result or mutation boundary"
  PASS=$((PASS + 1))
else
  echo "[FAIL] source guards are not repeated at governed mutation boundaries"
  FAIL=$((FAIL + 1))
fi

echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
