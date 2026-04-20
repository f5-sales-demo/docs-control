#!/usr/bin/env bash
# Unit tests for tests/fixtures/fetch-governed.sh
# Run: bash tests/test-fetch-governed.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SOURCE="${SCRIPT_DIR}/fixtures/fetch-governed.sh"

# --- Test harness ----------------------------------------------------
PASS=0
FAIL=0
CURRENT_TEST=""

_assert_eq() {
  local want="$1" got="$2" label="${3:-}"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    echo "  [PASS] ${CURRENT_TEST}${label:+ — }${label:-}"
  else
    FAIL=$((FAIL + 1))
    echo "  [FAIL] ${CURRENT_TEST}${label:+ — }${label:-}"
    echo "    want: ${want}"
    echo "    got:  ${got}"
  fi
}

_assert_nonzero() {
  local rc="$1" label="${2:-}"
  if [ "$rc" != "0" ]; then
    PASS=$((PASS + 1))
    echo "  [PASS] ${CURRENT_TEST}${label:+ — }${label:-}"
  else
    FAIL=$((FAIL + 1))
    echo "  [FAIL] ${CURRENT_TEST}${label:+ — }${label:-} — expected nonzero rc"
  fi
}

# --- Stub factory ---------------------------------------------------
# Writes a fake `curl` and `gh` on PATH for the duration of one test.
setup_stubs() {
  STUB_DIR=$(mktemp -d)
  export PATH="${STUB_DIR}:${PATH}"
  export FAKE_LOG="${STUB_DIR}/calls.log"
  : >"$FAKE_LOG"
}
teardown_stubs() {
  PATH="${PATH#"${STUB_DIR}":}"
  rm -rf "$STUB_DIR"
  unset STUB_DIR FAKE_LOG
}
stub_curl() {
  local mode="$1" body="${2:-}"
  printf '%s' "$body" >"${STUB_DIR}/curl.body"
  cat >"${STUB_DIR}/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "${FAKE_LOG}"
case "${mode}" in
  200)   cat "${STUB_DIR}/curl.body"; exit 0 ;;
  404)   exit 22 ;;
  empty) exit 0 ;;
  hang)  exit 28 ;;
esac
EOF
  chmod +x "${STUB_DIR}/curl"
}
stub_gh() {
  local mode="$1" body="${2:-}"
  printf '%s' "$body" >"${STUB_DIR}/gh.body"
  cat >"${STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "${FAKE_LOG}"
case "${mode}" in
  ok)   cat "${STUB_DIR}/gh.body"; exit 0 ;;
  fail) exit 1 ;;
esac
EOF
  chmod +x "${STUB_DIR}/gh"
}

# --- Tests ----------------------------------------------------------
export PAGES_BASE="https://example.test/docs-control"

# shellcheck source=fixtures/fetch-governed.sh disable=SC1091
. "$SOURCE"

CURRENT_TEST="pages 200 -> use pages, no gh call"
setup_stubs
stub_curl 200 '{"hello":"world"}'
stub_gh fail
out=$(fetch_governed repo-settings.json "repos/x/y/contents/.github/config/repo-settings.json")
_assert_eq '{"hello":"world"}' "$out" "body matches"
if grep -q "^gh " "$FAKE_LOG"; then
  FAIL=$((FAIL + 1))
  echo "  [FAIL] ${CURRENT_TEST} — gh was called"
else
  PASS=$((PASS + 1))
  echo "  [PASS] ${CURRENT_TEST} — gh was NOT called"
fi
teardown_stubs

CURRENT_TEST="pages 404 -> fallback to gh api"
setup_stubs
stub_curl 404
stub_gh ok '{"content":"aGVsbG8=","encoding":"base64"}'
out=$(fetch_governed repo-settings.json "repos/x/y/contents/.github/config/repo-settings.json")
_assert_eq 'hello' "$out" "decoded body"
if grep -q "^gh " "$FAKE_LOG"; then
  PASS=$((PASS + 1))
  echo "  [PASS] ${CURRENT_TEST} — gh invoked"
else
  FAIL=$((FAIL + 1))
  echo "  [FAIL] ${CURRENT_TEST} — gh not invoked"
fi
teardown_stubs

CURRENT_TEST="pages empty body -> fallback"
setup_stubs
stub_curl empty
stub_gh ok '{"content":"Zm9v","encoding":"base64"}'
out=$(fetch_governed x.json "repos/x/y/contents/x.json")
_assert_eq 'foo' "$out"
teardown_stubs

CURRENT_TEST="pages timeout -> fallback"
setup_stubs
stub_curl hang
stub_gh ok '{"content":"YmFy","encoding":"base64"}'
out=$(fetch_governed x.json "repos/x/y/contents/x.json")
_assert_eq 'bar' "$out"
teardown_stubs

CURRENT_TEST="both fail -> non-zero exit"
setup_stubs
stub_curl 404
stub_gh fail
set +e
fetch_governed x.json "repos/x/y/contents/x.json" >/dev/null 2>&1
rc=$?
set -e
_assert_nonzero "$rc"
teardown_stubs

CURRENT_TEST="revision_is_fresh: SHA matches"
setup_stubs
stub_curl 200 '{"commit":"abc123","generated_at":"2026-04-20T00:00:00Z"}'
set +e
revision_is_fresh abc123
rc=$?
set -e
_assert_eq 0 "$rc" "fresh when SHA equal"
teardown_stubs

CURRENT_TEST="revision_is_fresh: SHA mismatch"
setup_stubs
stub_curl 200 '{"commit":"old0000","generated_at":"2026-04-20T00:00:00Z"}'
set +e
revision_is_fresh abc123
rc=$?
set -e
_assert_nonzero "$rc" "stale when SHA differs"
teardown_stubs

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
