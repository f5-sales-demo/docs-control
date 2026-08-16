#!/usr/bin/env bash
# Proves the remaining Antigravity review control is isolated from suspended translation generation.
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
assert_contains() { if grep -qF "$2" "$1"; then pass "$3"; else fail "$3" "missing $2"; fi; }

echo "Antigravity review and English-only suspension guards"
if node "$REPO_ROOT/tests/antigravity-control-activation.test.cjs"; then pass "review control state machine passes behavioral tests"; else fail "review control state machine passes behavioral tests" "control test failed"; fi
ACTIVATION="$REPO_ROOT/.github/workflows/configure-antigravity-controls.yml"
assert_contains "$ACTIVATION" 'permissions: {}' "activation denies default workflow permissions"
assert_contains "$ACTIVATION" 'secrets.REPO_SETTINGS_TOKEN' "activation uses the protected governance token"
for file in "$REPO_ROOT/.github/workflows/antigravity-review.yml" "$REPO_ROOT/workflows/antigravity-review.yml"; do
  assert_contains "$file" "vars.ANTIGRAVITY_REVIEW_ENABLED == 'true'" "$(basename "$file") keeps the review gate"
done
for path in .github/workflows/antigravity-translate.yml workflows/antigravity-translate.yml .agents/skills/i18n-translate/SKILL.md; do
  if [ ! -e "$REPO_ROOT/$path" ] && jq -e --arg path "${path#workflows/}" '.managed_files.absent_files | index($path) != null' "$REPO_SETTINGS" >/dev/null 2>&1; then
    pass "$path is absent from source and downstream rollout"
  elif [ "$path" = workflows/antigravity-translate.yml ] && [ ! -e "$REPO_ROOT/$path" ] && jq -e '.managed_files.absent_files | index(".github/workflows/antigravity-translate.yml") != null' "$REPO_SETTINGS" >/dev/null; then
    pass "$path has a downstream deletion route"
  else
    fail "$path is absent from source and downstream rollout" "retired asset remains"
  fi
done
if ! grep -qE 'antigravity-translate|TRANSLATIONS_ENABLED|translationNeedsRecovery' "$REPO_ROOT/.github/workflows/antigravity-fleet-watcher.yml" "$REPO_ROOT/scripts/collect-antigravity-fleet-state.sh"; then pass "watcher has no translation recovery path"; else fail "watcher has no translation recovery path" "translation dispatch remains"; fi
if grep -qF 'English-only' "$CONTRIBUTING" && ! grep -qF 'TRANSLATIONS_ENABLED' "$CONTRIBUTING"; then pass "contributor guidance requires release authorization"; else fail "contributor guidance requires release authorization" "stale activation guidance remains"; fi
if jq -e '((.branch_protection[0].required_status_checks.contexts // []) + ([.repo_overrides // {} | .[] | .additional_contexts // []] | flatten)) | all(.[]; test("antigravity"; "i") | not)' "$REPO_SETTINGS" >/dev/null; then pass "no Antigravity workflow is required"; else fail "no Antigravity workflow is required" "gated workflow is required"; fi
printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
