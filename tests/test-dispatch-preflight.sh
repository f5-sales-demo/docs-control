#!/usr/bin/env bash
# Unit tests for the protected-main and immutable-caller dispatch preflight.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$REPO_ROOT/scripts/preflight-downstream-dispatch.sh"
SOURCE_SHA=1111111111111111111111111111111111111111
PIN_SHA=2222222222222222222222222222222222222222
OTHER_SHA=3333333333333333333333333333333333333333
ENFORCE_BLOB=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SYNC_BLOB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PASS=0
FAIL=0

check_case() {
  local label="$1" expected_rc="$2" expected_text="$3"
  local work rc output
  work=$(mktemp -d)
  mkdir -p "$work/bin"
  printf '{"revision":"%s"}\n' "$PIN_SHA" >"$work/pin.json"
  printf '["example"]\n' >"$work/repos.json"
  printf '{"state":"active"}\n' >"$work/rollout.json"
  cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  *'repos/f5-sales-demo/example/commits/main'*) printf '%s\n' "$FAKE_DOWNSTREAM_MAIN" ;;
  *'/commits/main'*) printf '%s\n' "$FAKE_MAIN_SHA" ;;
  *'/compare/'*) printf '%s\n' "$FAKE_COMPARE_STATUS" ;;
  *"enforce-repo-settings.yml?ref=$FAKE_PIN_SHA"*) printf '%s\n' "$FAKE_PIN_ENFORCE_BLOB" ;;
  *"sync-managed-files.yml?ref=$FAKE_PIN_SHA"*) printf '%s\n' "$FAKE_PIN_SYNC_BLOB" ;;
  *"contents/workflows/enforce-repo-settings.yml?ref=$FAKE_SOURCE_SHA"*)
    printf '%s\n' "$FAKE_SOURCE_CALLER_BLOB"
    ;;
  *"enforce-repo-settings.yml?ref=$FAKE_SOURCE_SHA"*) printf '%s\n' "$FAKE_SOURCE_ENFORCE_BLOB" ;;
  *"sync-managed-files.yml?ref=$FAKE_SOURCE_SHA"*) printf '%s\n' "$FAKE_SOURCE_SYNC_BLOB" ;;
  *"repos/f5-sales-demo/example/contents/.github/workflows/enforce-repo-settings.yml?ref=$FAKE_DOWNSTREAM_MAIN"*)
    if [ "${FAKE_MISSING_CALLER:-}" = 1 ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    printf '%s\n' "$FAKE_DOWNSTREAM_CALLER_BLOB"
    ;;
  *'repos/f5-sales-demo/example/actions/workflows/enforce-repo-settings.yml'*)
    if [ "${FAKE_MISSING_CALLER:-}" = 1 ] || [ "${FAKE_STATE_READ_FAIL:-}" = 1 ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    printf 'active\n'
    ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$work/bin/gh"
  : >"$work/gh.log"
  set +e
  output=$(env \
    PATH="$work/bin:$PATH" \
    GH_LOG="$work/gh.log" \
    GITHUB_REPOSITORY=f5-sales-demo/docs-control \
    SOURCE_SHA="$SOURCE_SHA" \
    PIN_CONFIG="$work/pin.json" \
    DOWNSTREAM_CONFIG="$work/repos.json" \
    ROLLOUT_CONFIG="$work/rollout.json" \
    FAKE_MAIN_SHA="$FAKE_MAIN_SHA" \
    FAKE_COMPARE_STATUS="$FAKE_COMPARE_STATUS" \
    FAKE_PIN_SHA="$PIN_SHA" \
    FAKE_SOURCE_SHA="$SOURCE_SHA" \
    FAKE_PIN_ENFORCE_BLOB="$FAKE_PIN_ENFORCE_BLOB" \
    FAKE_PIN_SYNC_BLOB="$FAKE_PIN_SYNC_BLOB" \
    FAKE_SOURCE_ENFORCE_BLOB="$FAKE_SOURCE_ENFORCE_BLOB" \
    FAKE_SOURCE_SYNC_BLOB="$FAKE_SOURCE_SYNC_BLOB" \
    FAKE_SOURCE_CALLER_BLOB="$FAKE_SOURCE_CALLER_BLOB" \
    FAKE_DOWNSTREAM_CALLER_BLOB="$FAKE_DOWNSTREAM_CALLER_BLOB" \
    FAKE_DOWNSTREAM_MAIN="$FAKE_DOWNSTREAM_MAIN" \
    FAKE_MISSING_CALLER="${FAKE_MISSING_CALLER:-}" \
    FAKE_STATE_READ_FAIL="${FAKE_STATE_READ_FAIL:-}" \
    "$SOURCE" 2>&1)
  rc=$?
  set -e
  if [ "$rc" = "$expected_rc" ] && printf '%s' "$output" | grep -Fq "$expected_text"; then
    echo "[OK] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label (rc=$rc, output=$output)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$work"
}

FAKE_MAIN_SHA="$SOURCE_SHA"
FAKE_COMPARE_STATUS=ahead
FAKE_PIN_ENFORCE_BLOB="$ENFORCE_BLOB"
FAKE_PIN_SYNC_BLOB="$SYNC_BLOB"
FAKE_SOURCE_ENFORCE_BLOB="$ENFORCE_BLOB"
FAKE_SOURCE_SYNC_BLOB="$SYNC_BLOB"
FAKE_SOURCE_CALLER_BLOB=cccccccccccccccccccccccccccccccccccccccc
FAKE_DOWNSTREAM_CALLER_BLOB="$FAKE_SOURCE_CALLER_BLOB"
FAKE_DOWNSTREAM_MAIN=dddddddddddddddddddddddddddddddddddddddd
check_case "exact main receipt and exact caller pin permit fan-out" 0 "[OK]"

FAKE_MAIN_SHA="$OTHER_SHA"
check_case "historical dispatcher run defers before reading caller blobs" 78 "[DEFER]"

FAKE_COMPARE_STATUS=diverged
check_case "unmerged dispatcher receipt fails provenance validation" 1 \
  "not an approved protected-main commit"

FAKE_MAIN_SHA="$SOURCE_SHA"
FAKE_COMPARE_STATUS=ahead
FAKE_PIN_ENFORCE_BLOB="$OTHER_SHA"
check_case "legacy pinned reusable implementation defers fan-out" 79 \
  "[DEFER] governed workflow pin"

FAKE_PIN_ENFORCE_BLOB="$ENFORCE_BLOB"
FAKE_DOWNSTREAM_CALLER_BLOB="$OTHER_SHA"
FAKE_STATE_READ_FAIL=1
check_case "stale caller bootstraps without requiring legacy workflow state" 80 \
  "[BOOTSTRAP]"
unset FAKE_STATE_READ_FAIL

FAKE_MISSING_CALLER=1
check_case "missing workflow reaches exact caller bootstrap" 80 "[BOOTSTRAP]"
unset FAKE_MISSING_CALLER

echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
