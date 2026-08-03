#!/usr/bin/env bash
# Proves quota-backed Antigravity automation has fail-closed central controls.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"
GOVERNANCE="$REPO_ROOT/.claude/governance.json"
CONTRIBUTING="$REPO_ROOT/CONTRIBUTING.md"

PASS=0
FAIL=0

pass() {
  printf '  PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf '  FAIL: %s — %s\n' "$1" "$2"
  FAIL=$((FAIL + 1))
}

assert_contains() {
  local file="$1" token="$2" label="$3"
  if grep -qF "$token" "$file"; then
    pass "$label"
  else
    fail "$label" "$file does not contain: $token"
  fi
}

echo "Antigravity runtime-control guards"

for file in \
  "$REPO_ROOT/.github/workflows/antigravity-review.yml" \
  "$REPO_ROOT/workflows/antigravity-review.yml"; do
  assert_contains "$file" "vars.ANTIGRAVITY_REVIEW_ENABLED == 'true'" \
    "review workflow $(basename "$file") is positive-gated"
done

for file in \
  "$REPO_ROOT/.github/workflows/antigravity-translate.yml" \
  "$REPO_ROOT/workflows/antigravity-translate.yml"; do
  assert_contains "$file" "vars.TRANSLATIONS_ENABLED == 'true'" \
    "translation workflow $(basename "$file") shares the translation gate"
done

for mapping in \
  'workflows/antigravity-review.yml|.github/workflows/antigravity-review.yml' \
  'workflows/antigravity-translate.yml|.github/workflows/antigravity-translate.yml'; do
  src=${mapping%%|*}
  dest=${mapping#*|}
  if jq -e --arg src "$src" --arg dest "$dest" '
    [.managed_files.files[] | select(.src == $src and .dest == $dest)] | length == 1
  ' "$REPO_SETTINGS" >/dev/null; then
    pass "$dest has one canonical managed-file mapping"
  else
    fail "$dest has one canonical managed-file mapping" \
      "missing or duplicated src=$src dest=$dest"
  fi
  if jq -e --arg dest "$dest" '
    [.protected_files[] | select(. == $dest)] | length == 1
  ' "$GOVERNANCE" >/dev/null; then
    pass "$dest is protected by docs-control governance"
  else
    fail "$dest is protected by docs-control governance" \
      "missing or duplicated protected_files entry"
  fi
done

if jq -e '
  ((.branch_protection[0].required_status_checks.contexts // []) +
   ([.repo_overrides // {} | .[] | .additional_contexts // []] | flatten)) |
  all(.[]; test("antigravity"; "i") | not)
' "$REPO_SETTINGS" >/dev/null; then
  pass "no Antigravity workflow is a required status context"
else
  fail "no Antigravity workflow is a required status context" \
    "a gated workflow must never be required"
fi

assert_contains "$CONTRIBUTING" "ANTIGRAVITY_REVIEW_ENABLED" \
  "CONTRIBUTING documents the review runtime switch"
assert_contains "$CONTRIBUTING" "TRANSLATIONS_ENABLED" \
  "CONTRIBUTING documents the translation runtime switch"
assert_contains "$CONTRIBUTING" "same-named repository variables" \
  "CONTRIBUTING forbids repository variables that shadow central controls"
assert_contains "$CONTRIBUTING" "do not manually disable" \
  "CONTRIBUTING keeps workflows active after the security hold"
assert_contains "$CONTRIBUTING" "Local translation generation is always active" \
  "CONTRIBUTING keeps local translation independent of Actions controls"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
