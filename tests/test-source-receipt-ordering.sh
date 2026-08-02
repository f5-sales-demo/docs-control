#!/usr/bin/env bash
# Execute the managed caller's receipt resolver against hermetic GitHub stubs.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CALLER="$REPO_ROOT/workflows/enforce-repo-settings.yml"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

python3 - "$CALLER" "$WORK/resolve.sh" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as workflow_file:
    workflow = yaml.load(workflow_file, Loader=yaml.BaseLoader)
steps = workflow["jobs"]["resolve-source"]["steps"]
run = next(step["run"] for step in steps if step.get("id") == "resolve")
with open(sys.argv[2], "w", encoding="utf-8") as script_file:
    script_file.write(run)
PY

cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
case "$*" in
  *'/commits/main'*) printf '%s\n' "$FAKE_CURRENT_SHA" ;;
  *'/compare/'*) printf '%s\n' "$FAKE_COMPARE_STATUS" ;;
  *'docs-control/contents/workflows/enforce-repo-settings.yml?ref='*)
    printf '{"type":"file","encoding":"base64","sha":"%s","content":"%s"}\n' \
      "$FAKE_CALLER_BLOB" "$FAKE_CALLER_CONTENT"
    ;;
  *'docs-control/contents/.github/config/governance-rollout.json?ref='*)
    rollout_file=$(mktemp)
    printf '{"state":"%s"}\n' "$FAKE_ROLLOUT_STATE" >"$rollout_file"
    rollout_blob=$(git hash-object "$rollout_file")
    rollout_content=$(base64 <"$rollout_file" | tr -d '\n')
    rm -f "$rollout_file"
    printf '{"type":"file","encoding":"base64","sha":"%s","content":"%s"}\n' \
      "$rollout_blob" "$rollout_content"
    ;;
  *'contents/.github/workflows/enforce-repo-settings.yml?ref='*)
    if [[ "$*" == *'repos/f5-sales-demo/docs-control/'* ]]; then
      printf '%s\n' "$FAKE_ENFORCE_BLOB"
    else
      printf '%s\n' "$FAKE_DOWNSTREAM_CALLER_BLOB"
    fi
    ;;
  *'docs-control/contents/.github/workflows/sync-managed-files.yml?ref='*)
    printf '%s\n' "$FAKE_SYNC_BLOB"
    ;;
  'workflow run enforce-repo-settings.yml'*) exit 0 ;;
  'workflow run dispatch-downstream.yml'*) exit 0 ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$WORK/bin/gh"

OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
BRANCH_SHA=3333333333333333333333333333333333333333
ENFORCE_BLOB=5555555555555555555555555555555555555555
SYNC_BLOB=6666666666666666666666666666666666666666
PIN_SHA=7777777777777777777777777777777777777777
CALLER_CONTENT=$(printf '%s\n' \
  "uses: f5-sales-demo/docs-control/.github/workflows/enforce-repo-settings.yml@${PIN_SHA}" \
  "uses: f5-sales-demo/docs-control/.github/workflows/sync-managed-files.yml@${PIN_SHA}" |
  base64 | tr -d '\n')
CALLER_BLOB=$(printf '%s' "$CALLER_CONTENT" | base64 -d | git hash-object --stdin)
PASS=0
FAIL=0

run_case() {
  local label="$1" requested="$2" current="$3" status="$4" expected_rc="$5" expected_ready="$6"
  local expected_requeues="$7" expected_bootstraps="$8" rc ready requeues bootstraps
  : >"$WORK/output"
  : >"$WORK/gh.log"
  set +e
  env \
    PATH="$WORK/bin:$PATH" \
    GITHUB_OUTPUT="$WORK/output" \
    GITHUB_REPOSITORY_OWNER=f5-sales-demo \
    GITHUB_REPOSITORY=f5-sales-demo/example \
    DOWNSTREAM_SHA=8888888888888888888888888888888888888888 \
    REQUESTED_SOURCE_SHA="$requested" \
    FAKE_CURRENT_SHA="$current" \
    FAKE_COMPARE_STATUS="$status" \
    FAKE_GH_LOG="$WORK/gh.log" \
    FAKE_CALLER_BLOB="$CALLER_BLOB" \
    FAKE_CALLER_CONTENT="$CALLER_CONTENT" \
    FAKE_DOWNSTREAM_CALLER_BLOB="${FAKE_DOWNSTREAM_CALLER_BLOB:-$CALLER_BLOB}" \
    FAKE_ENFORCE_BLOB="$ENFORCE_BLOB" \
    FAKE_SYNC_BLOB="$SYNC_BLOB" \
    FAKE_ROLLOUT_STATE="${FAKE_ROLLOUT_STATE:-active}" \
    bash "$WORK/resolve.sh" >"$WORK/stdout" 2>"$WORK/stderr"
  rc=$?
  set -e
  ready=$(sed -n 's/^ready=//p' "$WORK/output")
  requeues=$(grep -c '^workflow run enforce-repo-settings.yml' "$WORK/gh.log" || true)
  bootstraps=$(grep -c '^workflow run dispatch-downstream.yml' "$WORK/gh.log" || true)
  if [ "$rc" = "$expected_rc" ] && [ "$ready" = "$expected_ready" ] &&
    [ "$requeues" = "$expected_requeues" ] && [ "$bootstraps" = "$expected_bootstraps" ]; then
    echo "[OK] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label (rc=$rc ready=$ready)"
    sed 's/^/  stderr: /' "$WORK/stderr"
    FAIL=$((FAIL + 1))
  fi
}

run_case "old receipt applies while old is protected main" "$OLD_SHA" "$OLD_SHA" ahead 0 true 0 0
run_case "new receipt applies after protected main advances" "$NEW_SHA" "$NEW_SHA" ahead 0 true 0 0
run_case "old receipt enqueues new main instead of rolling back" "$OLD_SHA" "$NEW_SHA" ahead 0 false 1 0
run_case "unmerged branch receipt fails provenance" "$BRANCH_SHA" "$NEW_SHA" diverged 1 "" 0 0

FAKE_DOWNSTREAM_CALLER_BLOB=9999999999999999999999999999999999999999
run_case "legacy caller enqueues central bootstrap without enforcement" "$NEW_SHA" "$NEW_SHA" ahead 0 false 0 1
unset FAKE_DOWNSTREAM_CALLER_BLOB

FAKE_ROLLOUT_STATE=quiesced
run_case "quiesced caller refuses reusable enforcement and requests state repair" \
  "$NEW_SHA" "$NEW_SHA" ahead 0 false 0 1
unset FAKE_ROLLOUT_STATE

echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
