#!/usr/bin/env bash
# Automated test suite for .claude/hooks/protect-managed-files.sh
# Run from repo root: bash tests/test-protect-managed-files.sh
set -euo pipefail

# ── Test framework ──────────────────────────────────────────────────
PASS=0
FAIL=0
TESTS_RUN=0

pass() {
  PASS=$((PASS + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "  PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "  FAIL: $1 — $2"
}

assert_exit_code() {
  local expected="$1" actual="$2" label="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass "$label"
  else
    fail "$label" "expected exit $expected, got $actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label" "output does not contain: $needle"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    fail "$label" "output unexpectedly contains: $needle"
  else
    pass "$label"
  fi
}

# ── Setup: create isolated downstream repo ──────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$REPO_ROOT/.claude/hooks/protect-managed-files.sh"
GOVERNANCE_JSON="$REPO_ROOT/.claude/governance.json"
REPO_SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"

TMPDIR_BASE=$(mktemp -d)
DOWNSTREAM="$TMPDIR_BASE/downstream-repo"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_downstream() {
  rm -rf "$DOWNSTREAM"
  mkdir -p "$DOWNSTREAM/.claude/hooks"
  cp "$HOOK_SCRIPT" "$DOWNSTREAM/.claude/hooks/"
  cp "$GOVERNANCE_JSON" "$DOWNSTREAM/.claude/"
  cd "$DOWNSTREAM"
  git init -q
  git remote add origin https://github.com/f5xc-salesdemos/waf.git
}

# Helper: run the hook in a given directory with a given file_path input
run_hook() {
  local dir="$1" file_path="$2"
  local exit_code=0
  local output
  output=$(cd "$dir" && echo "{\"tool_input\":{\"file_path\":\"$file_path\"}}" |
    bash .claude/hooks/protect-managed-files.sh 2>&1) || exit_code=$?
  echo "$output"
  return $exit_code
}

# ════════════════════════════════════════════════════════════════════
# SECTION 1: JSON Validity
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 1: JSON Validity ==="

# Test 1.1: governance.json is valid JSON
if jq empty "$GOVERNANCE_JSON" 2>/dev/null; then
  pass "1.1 governance.json is valid JSON"
else
  fail "1.1 governance.json is valid JSON" "jq parse failed"
fi

# Test 1.2: settings.json is valid JSON
SETTINGS_JSON="$REPO_ROOT/.claude/settings.json"
if jq empty "$SETTINGS_JSON" 2>/dev/null; then
  pass "1.2 settings.json is valid JSON"
else
  fail "1.2 settings.json is valid JSON" "jq parse failed"
fi

# Test 1.3: repo-settings.json is valid JSON
if jq empty "$REPO_SETTINGS" 2>/dev/null; then
  pass "1.3 repo-settings.json is valid JSON"
else
  fail "1.3 repo-settings.json is valid JSON" "jq parse failed"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 2: File Integrity
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 2: File Integrity ==="

# Test 2.1: hook script is executable
if [ -x "$HOOK_SCRIPT" ]; then
  pass "2.1 hook script is executable"
else
  fail "2.1 hook script is executable" "missing execute permission"
fi

# Test 2.2: hook script has bash shebang
SHEBANG=$(head -1 "$HOOK_SCRIPT")
if echo "$SHEBANG" | grep -q "bash"; then
  pass "2.2 hook script has bash shebang"
else
  fail "2.2 hook script has bash shebang" "got: $SHEBANG"
fi

# Test 2.3: settings.json registers Edit|Write matcher
MATCHER=$(jq -r '.hooks.PreToolUse[0].matcher' "$SETTINGS_JSON" 2>/dev/null)
if [ "$MATCHER" = "Edit|Write" ]; then
  pass "2.3 settings.json has Edit|Write matcher"
else
  fail "2.3 settings.json has Edit|Write matcher" "got: $MATCHER"
fi

# Test 2.4: settings.json hook command references correct script path
HOOK_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SETTINGS_JSON" 2>/dev/null)
if echo "$HOOK_CMD" | grep -q "protect-managed-files.sh"; then
  pass "2.4 settings.json hook command references correct script"
else
  fail "2.4 settings.json hook command references correct script" "got: $HOOK_CMD"
fi

# Test 2.5: governance.json has source_repo field
SOURCE_REPO=$(jq -r '.source_repo' "$GOVERNANCE_JSON" 2>/dev/null)
if [ "$SOURCE_REPO" = "f5xc-salesdemos/docs-control" ]; then
  pass "2.5 governance.json source_repo is correct"
else
  fail "2.5 governance.json source_repo is correct" "got: $SOURCE_REPO"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 3: Governance Manifest Consistency
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 3: Governance Manifest Consistency ==="

# Test 3.1: every dest path in repo-settings.json managed_files
#           appears in governance.json protected_files
MANAGED_DESTS=$(jq -r '.managed_files.files[].dest' "$REPO_SETTINGS" | sort)
PROTECTED_FILES=$(jq -r '.protected_files[]' "$GOVERNANCE_JSON" | sort)

MISSING_FROM_GOVERNANCE=""
while IFS= read -r dest; do
  if ! echo "$PROTECTED_FILES" | grep -qxF "$dest"; then
    MISSING_FROM_GOVERNANCE="${MISSING_FROM_GOVERNANCE}  - ${dest}\n"
  fi
done <<<"$MANAGED_DESTS"

if [ -z "$MISSING_FROM_GOVERNANCE" ]; then
  pass "3.1 all repo-settings.json dest paths are in governance.json"
else
  fail "3.1 all repo-settings.json dest paths are in governance.json" \
    "missing:\n$MISSING_FROM_GOVERNANCE"
fi

# Test 3.2: governance.json includes the hook infrastructure files
for infra_file in ".claude/governance.json" ".claude/settings.json" ".claude/hooks/protect-managed-files.sh"; do
  if echo "$PROTECTED_FILES" | grep -qxF "$infra_file"; then
    pass "3.2 governance.json protects $infra_file (self-protection)"
  else
    fail "3.2 governance.json protects $infra_file (self-protection)" "not found"
  fi
done

# Test 3.3: governance.json includes dynamically managed files
for dynamic_file in "README.md" ".github/dependabot.yml"; do
  if echo "$PROTECTED_FILES" | grep -qxF "$dynamic_file"; then
    pass "3.3 governance.json protects dynamic file $dynamic_file"
  else
    fail "3.3 governance.json protects dynamic file $dynamic_file" "not found"
  fi
done

# Test 3.4: repo-settings.json includes the 3 new managed file entries
for new_entry in ".claude/governance.json" ".claude/settings.json" ".claude/hooks/protect-managed-files.sh"; do
  if echo "$MANAGED_DESTS" | grep -qxF "$new_entry"; then
    pass "3.4 repo-settings.json distributes $new_entry"
  else
    fail "3.4 repo-settings.json distributes $new_entry" "not in managed_files"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 4: Hook Behavior — Self-Exclusion
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 4: Hook Self-Exclusion (docs-control) ==="

# Test 4.1: hook allows edits in docs-control itself
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(cd "$REPO_ROOT" && echo '{"tool_input":{"file_path":"CONTRIBUTING.md"}}' |
  bash .claude/hooks/protect-managed-files.sh 2>&1) || EXIT_CODE=$?
assert_exit_code 0 "$EXIT_CODE" "4.1 self-exclusion: protected file allowed in docs-control"

# Test 4.2: no BLOCKED message in docs-control
assert_not_contains "$OUTPUT" "BLOCKED" "4.2 self-exclusion: no BLOCKED message in docs-control"

# ════════════════════════════════════════════════════════════════════
# SECTION 5: Hook Behavior — Blocking Protected Files
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 5: Blocking Protected Files (downstream) ==="

setup_downstream

# Test each category of protected file
PROTECTED_TEST_CASES=(
  "CLAUDE.md"
  "CONTRIBUTING.md"
  ".gitignore"
  ".pre-commit-config.yaml"
  ".github/workflows/super-linter.yml"
  ".github/PULL_REQUEST_TEMPLATE.md"
  ".github/ISSUE_TEMPLATE/bug_report.md"
  "biome.json"
  ".editorconfig"
  "LICENSE"
  "README.md"
  ".github/dependabot.yml"
  ".claude/CLAUDE.md"
  ".claude/settings.json"
  ".claude/governance.json"
  ".claude/hooks/protect-managed-files.sh"
)

for file in "${PROTECTED_TEST_CASES[@]}"; do
  OUTPUT=""
  EXIT_CODE=0
  OUTPUT=$(run_hook "$DOWNSTREAM" "$file") || EXIT_CODE=$?
  assert_exit_code 2 "$EXIT_CODE" "5.x block: $file"
  assert_contains "$OUTPUT" "BLOCKED" "5.x message: $file shows BLOCKED"
  assert_contains "$OUTPUT" "docs-control" "5.x message: $file mentions docs-control"
done

# ════════════════════════════════════════════════════════════════════
# SECTION 6: Hook Behavior — Allowing Non-Protected Files
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 6: Allowing Non-Protected Files (downstream) ==="

NON_PROTECTED_TEST_CASES=(
  "docs/index.mdx"
  "src/components/Header.astro"
  "astro.config.mjs"
  "package.json"
  "tsconfig.json"
  ".env"
  "docs/demo/phase-1.md"
  "DEMO_PRODUCT_EXPERTISE.md"
)

for file in "${NON_PROTECTED_TEST_CASES[@]}"; do
  OUTPUT=""
  EXIT_CODE=0
  OUTPUT=$(run_hook "$DOWNSTREAM" "$file") || EXIT_CODE=$?
  assert_exit_code 0 "$EXIT_CODE" "6.x allow: $file"
  assert_not_contains "$OUTPUT" "BLOCKED" "6.x no block message: $file"
done

# ════════════════════════════════════════════════════════════════════
# SECTION 7: Hook Behavior — Path Normalization
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 7: Path Normalization ==="

# Test 7.1: ./ prefix is stripped
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_hook "$DOWNSTREAM" "./CLAUDE.md") || EXIT_CODE=$?
assert_exit_code 2 "$EXIT_CODE" "7.1 ./ prefix stripped: ./CLAUDE.md blocked"

# Test 7.2: absolute path is normalized to repo-relative
ABS_PATH="$DOWNSTREAM/CONTRIBUTING.md"
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_hook "$DOWNSTREAM" "$ABS_PATH") || EXIT_CODE=$?
assert_exit_code 2 "$EXIT_CODE" "7.2 absolute path normalized: $ABS_PATH blocked"

# Test 7.3: nested ./ prefix in subdirectory
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_hook "$DOWNSTREAM" "./.github/workflows/super-linter.yml") || EXIT_CODE=$?
assert_exit_code 2 "$EXIT_CODE" "7.3 ./ prefix in subdir: ./.github/workflows/super-linter.yml blocked"

# ════════════════════════════════════════════════════════════════════
# SECTION 8: Hook Behavior — Edge Cases
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 8: Edge Cases ==="

# Test 8.1: empty file_path
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(cd "$DOWNSTREAM" && echo '{"tool_input":{"file_path":""}}' |
  bash .claude/hooks/protect-managed-files.sh 2>&1) || EXIT_CODE=$?
assert_exit_code 0 "$EXIT_CODE" "8.1 empty file_path: allowed (exit 0)"

# Test 8.2: missing file_path key
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(cd "$DOWNSTREAM" && echo '{"tool_input":{"content":"hello"}}' |
  bash .claude/hooks/protect-managed-files.sh 2>&1) || EXIT_CODE=$?
assert_exit_code 0 "$EXIT_CODE" "8.2 missing file_path key: allowed (exit 0)"

# Test 8.3: missing governance.json (graceful fallback)
mv "$DOWNSTREAM/.claude/governance.json" "$DOWNSTREAM/.claude/governance.json.bak"
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_hook "$DOWNSTREAM" "CLAUDE.md") || EXIT_CODE=$?
assert_exit_code 0 "$EXIT_CODE" "8.3 missing governance.json: allowed (exit 0)"
mv "$DOWNSTREAM/.claude/governance.json.bak" "$DOWNSTREAM/.claude/governance.json"

# Test 8.4: partial path match does NOT trigger (e.g., "CLAUDE.md.bak")
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_hook "$DOWNSTREAM" "CLAUDE.md.bak") || EXIT_CODE=$?
assert_exit_code 0 "$EXIT_CODE" "8.4 partial match CLAUDE.md.bak: allowed (not protected)"

# Test 8.5: similar but different path (e.g., "my-CONTRIBUTING.md")
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_hook "$DOWNSTREAM" "my-CONTRIBUTING.md") || EXIT_CODE=$?
assert_exit_code 0 "$EXIT_CODE" "8.5 similar path my-CONTRIBUTING.md: allowed (not protected)"

# Test 8.6: malformed JSON input (should not crash)
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(cd "$DOWNSTREAM" && echo 'not json at all' |
  bash .claude/hooks/protect-managed-files.sh 2>&1) || EXIT_CODE=$?
assert_exit_code 0 "$EXIT_CODE" "8.6 malformed JSON input: allowed (exit 0, no crash)"

# ════════════════════════════════════════════════════════════════════
# SECTION 9: Hook Error Message Quality
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 9: Error Message Quality ==="

OUTPUT=""
EXIT_CODE=0
OUTPUT=$(run_hook "$DOWNSTREAM" "CONTRIBUTING.md") || EXIT_CODE=$?
assert_contains "$OUTPUT" "BLOCKED" "9.1 message starts with BLOCKED"
assert_contains "$OUTPUT" "CONTRIBUTING.md" "9.2 message includes the file name"
assert_contains "$OUTPUT" "f5xc-salesdemos/docs-control" "9.3 message includes source repo"
assert_contains "$OUTPUT" "https://github.com/f5xc-salesdemos/docs-control" "9.4 message includes issue URL"
assert_contains "$OUTPUT" "governance.json" "9.5 message references governance manifest"
assert_contains "$OUTPUT" "synced to all downstream repos" "9.6 message explains auto-sync"

# ════════════════════════════════════════════════════════════════════
# SECTION 10: CLAUDE.md Content Verification
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 10: CLAUDE.md Content ==="

CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
CLAUDE_CONTENT=$(cat "$CLAUDE_MD")

# Test 10.1: mentions managed files / governance
if echo "$CLAUDE_CONTENT" | grep -q "governance.json"; then
  pass "10.1 CLAUDE.md references governance.json"
else
  fail "10.1 CLAUDE.md references governance.json" "not found"
fi

# Test 10.2: mentions github-ops delegation
if echo "$CLAUDE_CONTENT" | grep -q "github-ops"; then
  pass "10.2 CLAUDE.md mentions github-ops routing"
else
  fail "10.2 CLAUDE.md mentions github-ops routing" "not found"
fi

# Test 10.3: has project rules section
if echo "$CLAUDE_CONTENT" | grep -q "Conventional commits"; then
  pass "10.3 CLAUDE.md has project rules"
else
  fail "10.3 CLAUDE.md has project rules" "not found"
fi

# Test 10.4: references CONTRIBUTING.md
if echo "$CLAUDE_CONTENT" | grep -q "CONTRIBUTING.md"; then
  pass "10.4 CLAUDE.md references CONTRIBUTING.md"
else
  fail "10.4 CLAUDE.md references CONTRIBUTING.md" "not found"
fi

# Test 10.5: slimmed down (under 50 lines)
LINE_COUNT=$(wc -l <"$CLAUDE_MD")
if [ "$LINE_COUNT" -le 50 ]; then
  pass "10.5 CLAUDE.md is concise ($LINE_COUNT lines, <= 50)"
else
  fail "10.5 CLAUDE.md is concise" "got $LINE_COUNT lines, expected <= 50"
fi

# Test 10.6: removed verbose sections
if echo "$CLAUDE_CONTENT" | grep -q "Organization Overview"; then
  fail "10.6 removed Organization Overview section" "still present"
else
  pass "10.6 removed Organization Overview section"
fi

if echo "$CLAUDE_CONTENT" | grep -q "Plugin Directives"; then
  fail "10.7 removed Plugin Directives section" "still present"
else
  pass "10.7 removed Plugin Directives section"
fi

if echo "$CLAUDE_CONTENT" | grep -q "Container Awareness"; then
  fail "10.8 removed Container Awareness section" "still present"
else
  pass "10.8 removed Container Awareness section"
fi

# ════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($TESTS_RUN total)"
echo "════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
