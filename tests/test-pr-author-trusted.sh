#!/usr/bin/env bash
# Hermetic test for scripts/pr-author-trusted.sh — the gate that decides whether
# a pull-request author may auto-merge (write/admin ⇒ TRUSTED, everything else
# ⇒ leave for a human). Locks the criteria deterministically with a stubbed `gh`
# (no network): the stub echoes $FAKE_PERMISSION and exits $FAKE_RC, so we
# exercise both the permission-tier decision and the fail-closed path when the
# collaborator-permission API errors (e.g. 404 not-a-collaborator).
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/pr-author-trusted.sh"

FAIL=0
WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Stub gh, first on PATH. Honours FAKE_RC (simulate an API failure) otherwise
# prints FAKE_PERMISSION exactly as `gh api ... --jq '.permission'` would.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${FAKE_RC:-0}" -ne 0 ]; then exit "${FAKE_RC}"; fi
printf '%s\n' "${FAKE_PERMISSION:-none}"
STUB
chmod +x "$WORK/bin/gh"

# The gate is binary: exit 0 = TRUSTED (auto-merge allowed), non-zero = leave
# for human review. We assert the outcome, not a specific non-zero code.
_run() { # _run <permission> [rc] -> echoes the script's exit code
  local rc=0
  FAKE_PERMISSION="$1" FAKE_RC="${2:-0}" PATH="$WORK/bin:$PATH" \
    bash "$SCRIPT" "acme/repo" "octocat" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
assert_trusted() {
  local label="$1" rc
  rc=$(_run "$2" "${3:-0}")
  if [ "$rc" -eq 0 ]; then echo "[OK] $label → TRUSTED (rc=$rc)"; else
    echo "[FAIL] $label — expected TRUSTED (rc=0), got rc=$rc"
    FAIL=1
  fi
}
assert_untrusted() {
  local label="$1" rc
  rc=$(_run "$2" "${3:-0}")
  if [ "$rc" -ne 0 ]; then echo "[OK] $label → UNTRUSTED (rc=$rc)"; else
    echo "[FAIL] $label — expected UNTRUSTED (rc!=0), got rc=0"
    FAIL=1
  fi
}

# --- TRUSTED (write/admin only) ---
assert_trusted "admin permission" "admin"
assert_trusted "write permission" "write"

# --- UNTRUSTED (everything else) ---
assert_untrusted "read permission" "read"
assert_untrusted "none permission" "none"
assert_untrusted "triage permission" "triage"
assert_untrusted "maintain string (only exact admin/write pass)" "maintain"
assert_untrusted "empty permission" ""

# --- Fails CLOSED when the API errors (404/network) even if perm would be admin ---
assert_untrusted "gh api failure (fails closed)" "admin" 1

# --- Missing required args must error (not silently pass) ---
missing_rc=0
PATH="$WORK/bin:$PATH" bash "$SCRIPT" "acme/repo" >/dev/null 2>&1 || missing_rc=$?
if [ "$missing_rc" -ne 0 ]; then echo "[OK] missing author arg → error (rc=$missing_rc)"; else
  echo "[FAIL] missing author arg — expected non-zero"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "pr-author-trusted tests FAILED"
  exit 1
fi
echo "pr-author-trusted tests passed"
