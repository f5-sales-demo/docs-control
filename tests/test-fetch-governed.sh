#!/usr/bin/env bash
# Unit tests for exact governed-content reads.
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
  cat >"${STUB_DIR}/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "${FAKE_LOG}"
exit 99
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

expected_source_sha="1111111111111111111111111111111111111111"

# shellcheck source=fixtures/fetch-governed.sh disable=SC1091
. "$SOURCE"

CURRENT_TEST="exact API read returns verified receipt bytes"
setup_stubs
stub_curl
stub_gh ok '{"type":"file","sha":"e4e07a17cff3c298ae171a752a8186ff4484638d","size":19,"content":"ZXhhY3QtcmVjZWlwdC1ieXRlcw==","encoding":"base64"}'
out=$(fetch_governed repo-settings.json "repos/x/y/contents/.github/config/repo-settings.json")
_assert_eq 'exact-receipt-bytes' "$out" "decoded body"
_assert_eq \
  "gh api repos/x/y/contents/.github/config/repo-settings.json?ref=${expected_source_sha}" \
  "$(grep '^gh ' "$FAKE_LOG")" \
  "API read is bound to the exact source receipt"
_assert_eq "" "$(grep '^curl ' "$FAKE_LOG" || true)" \
  "mutable Pages/CDN bytes are never requested"
teardown_stubs

CURRENT_TEST="invalid source receipt fails before any read"
setup_stubs
stub_curl
stub_gh ok '{"type":"file","sha":"e4e07a17cff3c298ae171a752a8186ff4484638d","size":19,"content":"ZXhhY3QtcmVjZWlwdC1ieXRlcw==","encoding":"base64"}'
saved_source_sha="$expected_source_sha"
expected_source_sha=""
set +e
fetch_governed x.json "repos/x/y/contents/x.json" >/dev/null 2>&1
rc=$?
set -e
expected_source_sha="$saved_source_sha"
_assert_nonzero "$rc"
_assert_eq "" "$(cat "$FAKE_LOG")" "no network read attempted"
teardown_stubs

CURRENT_TEST="pre-existing query cannot override the exact receipt"
setup_stubs
stub_curl
stub_gh ok '{"type":"file","sha":"e4e07a17cff3c298ae171a752a8186ff4484638d","size":19,"content":"ZXhhY3QtcmVjZWlwdC1ieXRlcw==","encoding":"base64"}'
set +e
fetch_governed x.json "repos/x/y/contents/x.json?ref=main" >/dev/null 2>&1
rc=$?
set -e
_assert_nonzero "$rc"
_assert_eq "" "$(cat "$FAKE_LOG")" "ambiguous API path rejected locally"
teardown_stubs

CURRENT_TEST="API failure returns non-zero"
setup_stubs
stub_curl
stub_gh fail
set +e
fetch_governed x.json "repos/x/y/contents/x.json" >/dev/null 2>&1
rc=$?
set -e
_assert_nonzero "$rc"
teardown_stubs

CURRENT_TEST="malformed API envelope returns non-zero"
setup_stubs
stub_curl
stub_gh ok '{"type":"file","sha":"bad","size":19,"content":"","encoding":"none"}'
set +e
fetch_governed x.json "repos/x/y/contents/x.json" >/dev/null 2>&1
rc=$?
set -e
_assert_nonzero "$rc" "invalid content response rejected"
teardown_stubs

CURRENT_TEST="content digest mismatch returns non-zero"
setup_stubs
stub_curl
stub_gh ok '{"type":"file","sha":"0000000000000000000000000000000000000000","size":19,"content":"ZXhhY3QtcmVjZWlwdC1ieXRlcw==","encoding":"base64"}'
set +e
fetch_governed x.json "repos/x/y/contents/x.json" >/dev/null 2>&1
rc=$?
set -e
_assert_nonzero "$rc" "decoded bytes must match GitHub blob receipt"
teardown_stubs

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
