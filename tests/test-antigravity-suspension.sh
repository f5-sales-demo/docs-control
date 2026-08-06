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

if node "$REPO_ROOT/tests/antigravity-control-activation.test.cjs"; then
  pass "activation phases and pilot proof pass behavioral tests"
else
  fail "activation phases and pilot proof pass behavioral tests" \
    "the organization-control state machine failed"
fi

ACTIVATION="$REPO_ROOT/.github/workflows/configure-antigravity-controls.yml"
for token in \
  'workflow_dispatch:' \
  'type: choice' \
  'disabled' \
  'pilot' \
  'all' \
  'environment: antigravity-automation' \
  'secrets.REPO_SETTINGS_TOKEN' \
  'configure-antigravity-controls.cjs'; do
  assert_contains "$ACTIVATION" "$token" \
    "activation workflow contains $token"
done

assert_contains "$ACTIVATION" "permissions: {}" \
  "activation denies default workflow permissions"
assert_contains "$ACTIVATION" "contents: read" \
  "activation grants only read access to the built-in token"

for protected in \
  '.github/workflows/configure-antigravity-controls.yml' \
  'scripts/configure-antigravity-controls.cjs'; do
  if jq -e --arg protected "$protected" \
    '[.protected_files[] | select(. == $protected)] | length == 1' \
    "$GOVERNANCE" >/dev/null; then
    pass "$protected is protected by docs-control governance"
  else
    fail "$protected is protected by docs-control governance" \
      "missing or duplicated protected_files entry"
  fi
done

if ! grep -qE 'AUTOMATION_APP_ID|AUTOMATION_APP_PRIVATE_KEY|create-github-app-token|ruleset|merge-queue' \
  "$ACTIVATION" "$REPO_ROOT/scripts/configure-antigravity-controls.cjs"; then
  pass "activation uses no GitHub App or Enterprise-only control"
else
  fail "activation uses no GitHub App or Enterprise-only control" \
    "an unsupported credential or control is present"
fi

for workflow in \
  "$REPO_ROOT/.github/workflows/antigravity-review.yml" \
  "$REPO_ROOT/.github/workflows/antigravity-translate.yml"; do
  assert_contains "$workflow" "workflow_dispatch:" \
    "$(basename "$workflow") supports the same-repository pilot"
  assert_contains "$workflow" "cancel-in-progress: true" \
    "$(basename "$workflow") cancels duplicate exact-head runs"
done

assert_contains "$REPO_ROOT/.github/workflows/antigravity-review.yml" \
  'group: antigravity-reusable-review-${{ github.repository }}-${{ inputs.pr_number }}-${{ inputs.expected_head_sha }}' \
  "review workflow uses a caller-distinct exact-head concurrency group"
assert_contains "$REPO_ROOT/.github/workflows/antigravity-translate.yml" \
  'group: antigravity-reusable-translation-${{ github.repository }}-${{ inputs.pr_number }}-${{ inputs.expected_head_sha }}' \
  "translation workflow uses a caller-distinct exact-head concurrency group"

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
  "CONTRIBUTING keeps central controls free of repository-variable shadows"
assert_contains "$CONTRIBUTING" "active the reusable workflows" \
  "CONTRIBUTING keeps workflows active after the security hold"
assert_contains "$CONTRIBUTING" "Deterministic only" \
  "CONTRIBUTING keeps local validation model-free"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
