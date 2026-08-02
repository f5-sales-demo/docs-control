#!/usr/bin/env bash
# Exercise sync's downstream protected-main guard across job advancement.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SYNC_WORKFLOW="$REPO_ROOT/.github/workflows/sync-managed-files.yml"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

extract_function() {
  local function_name="$1"
  awk -v signature="          ${function_name}() {" '
    $0 == signature { found=1 }
    found {
      line=$0
      sub(/^          /, "")
      print
      if (line == "          }") exit
    }
  ' "$SYNC_WORKFLOW"
}

for function_name in retry require_sha ensure_current_downstream_main; do
  extract_function "$function_name" >>"$WORK/helpers.sh"
done
# shellcheck source=/dev/null
source "$WORK/helpers.sh"

cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
case "$*" in
  'api repos/f5-sales-demo/example/commits/main --jq .sha')
    printf '%s\n' "$FAKE_CURRENT_DOWNSTREAM_SHA"
    ;;
  'api repos/f5-sales-demo/example/compare/'*' --jq .status')
    printf '%s\n' "$FAKE_DOWNSTREAM_STATUS"
    ;;
  'workflow run enforce-repo-settings.yml --repo f5-sales-demo/example --ref main -f source_sha='*)
    exit 0
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$WORK/bin/gh"

export PATH="$WORK/bin:$PATH"
export FAKE_GH_LOG="$WORK/gh.log"
export GITHUB_REPOSITORY=f5-sales-demo/example
export REPO_SETTINGS_TOKEN=fake-token
expected_source_sha=1111111111111111111111111111111111111111
expected_downstream_sha=2222222222222222222222222222222222222222
NEW_DOWNSTREAM_SHA=3333333333333333333333333333333333333333
PASS=0
FAIL=0

check() {
  local label="$1" expected_rc="$2" expected_dispatches="$3"
  local rc=0 dispatches
  : >"$FAKE_GH_LOG"
  ensure_current_downstream_main >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?
  dispatches=$(grep -c '^workflow run enforce-repo-settings.yml' "$FAKE_GH_LOG" || true)
  if [ "$rc" -eq "$expected_rc" ] && [ "$dispatches" -eq "$expected_dispatches" ]; then
    echo "[OK] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label (rc=$rc dispatches=$dispatches)"
    sed 's/^/  /' "$WORK/stderr"
    FAIL=$((FAIL + 1))
  fi
}

export FAKE_CURRENT_DOWNSTREAM_SHA="$expected_downstream_sha"
export FAKE_DOWNSTREAM_STATUS=ahead
check "exact checked-out receipt remains current before scanning" 0 0

# Simulate main advancing after the first guard and before the post-scan guard.
export FAKE_CURRENT_DOWNSTREAM_SHA="$NEW_DOWNSTREAM_SHA"
check "post-scan advancement defers mutation and requeues current main" 78 1
if grep -q \
  "^workflow run enforce-repo-settings.yml --repo f5-sales-demo/example --ref main -f source_sha=${expected_source_sha}$" \
  "$FAKE_GH_LOG"; then
  echo "[OK] recovery is bound to main and the exact source receipt"
  PASS=$((PASS + 1))
else
  echo "[FAIL] recovery omitted main or the exact source receipt"
  FAIL=$((FAIL + 1))
fi

export FAKE_CURRENT_DOWNSTREAM_SHA="$NEW_DOWNSTREAM_SHA"
export FAKE_DOWNSTREAM_STATUS=diverged
check "unmerged downstream receipt fails closed" 1 0

export FAKE_CURRENT_DOWNSTREAM_SHA=invalid
export FAKE_DOWNSTREAM_STATUS=ahead
check "malformed downstream protected-main receipt fails closed" 1 0

echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
