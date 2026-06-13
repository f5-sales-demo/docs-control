#!/usr/bin/env bash
# Tests for scripts/locale-lint.sh
set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1 — $2"; }

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LINT_SCRIPT="$SCRIPT_DIR/scripts/locale-lint.sh"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_clean_repo() {
  rm -rf "$TMPDIR_BASE/repo"
  mkdir -p "$TMPDIR_BASE/repo/src"
}

run_lint() {
  local dir="$1"
  local exit_code=0
  local output
  output=$(cd "$dir" && bash "$LINT_SCRIPT" 2>&1) || exit_code=$?
  echo "$output"
  return $exit_code
}

echo ""
echo "=== Locale Lint Tests ==="

# Test 1: clean repo passes
setup_clean_repo
cat > "$TMPDIR_BASE/repo/src/app.ts" <<'TS'
import { VALID_SLUGS } from '@f5xc-salesdemos/i18n-core';
console.log(VALID_SLUGS);
TS
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_lint "$TMPDIR_BASE/repo") || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "1. clean repo with i18n-core import passes"
else
  fail "1. clean repo passes" "exit $EXIT_CODE"
fi

# Test 2: hardcoded slug array is detected
setup_clean_repo
cat > "$TMPDIR_BASE/repo/src/bad.ts" <<'TS'
const LOCALES = ['en', 'fr', 'pt-br', 'zh-cn', 'zh-tw', 'ar'];
TS
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_lint "$TMPDIR_BASE/repo") || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "2. hardcoded slug array detected"
else
  fail "2. hardcoded slug array detected" "exit $EXIT_CODE (expected 1)"
fi

# Test 3: inline VALID_LOCALE_SLUGS definition is detected
setup_clean_repo
cat > "$TMPDIR_BASE/repo/src/bad.ts" <<'TS'
const VALID_LOCALE_SLUGS = new Set(['en', 'fr']);
TS
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_lint "$TMPDIR_BASE/repo") || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "3. inline VALID_LOCALE_SLUGS detected"
else
  fail "3. inline VALID_LOCALE_SLUGS detected" "exit $EXIT_CODE (expected 1)"
fi

# Test 4: inline LOCALE_DISPLAY_NAMES definition is detected
setup_clean_repo
cat > "$TMPDIR_BASE/repo/src/bad.ts" <<'TS'
const LOCALE_DISPLAY_NAMES: Record<string, string> = {
  en: "English",
  fr: "French",
};
TS
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_lint "$TMPDIR_BASE/repo") || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "4. inline LOCALE_DISPLAY_NAMES detected"
else
  fail "4. inline LOCALE_DISPLAY_NAMES detected" "exit $EXIT_CODE (expected 1)"
fi

# Test 5: inline langToSlug function is detected
setup_clean_repo
cat > "$TMPDIR_BASE/repo/src/bad.ts" <<'TS'
function langToSlug(lang: string): string {
  return lang.toLowerCase();
}
TS
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_lint "$TMPDIR_BASE/repo") || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 1 ]; then
  pass "5. inline langToSlug function detected"
else
  fail "5. inline langToSlug function detected" "exit $EXIT_CODE (expected 1)"
fi

# Test 6: re-export from i18n-core is allowed
setup_clean_repo
cat > "$TMPDIR_BASE/repo/src/good.ts" <<'TS'
import { LOCALE_DISPLAY_NAMES } from '@f5xc-salesdemos/i18n-core';
export { LOCALE_DISPLAY_NAMES };
TS
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_lint "$TMPDIR_BASE/repo") || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "6. re-export from i18n-core allowed"
else
  fail "6. re-export from i18n-core allowed" "exit $EXIT_CODE"
fi

# Test 7: node_modules are excluded
setup_clean_repo
mkdir -p "$TMPDIR_BASE/repo/node_modules/some-pkg"
cat > "$TMPDIR_BASE/repo/node_modules/some-pkg/index.ts" <<'TS'
const VALID_LOCALE_SLUGS = new Set(['en', 'fr']);
TS
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_lint "$TMPDIR_BASE/repo") || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "7. node_modules excluded"
else
  fail "7. node_modules excluded" "exit $EXIT_CODE"
fi

# Test 8: test files are excluded
setup_clean_repo
cat > "$TMPDIR_BASE/repo/src/locales.test.ts" <<'TS'
const VALID_LOCALE_SLUGS = new Set(['en', 'fr']);
TS
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_lint "$TMPDIR_BASE/repo") || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "8. test files excluded"
else
  fail "8. test files excluded" "exit $EXIT_CODE"
fi

echo ""
echo "════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($((PASS + FAIL)) total)"
echo "════════════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
