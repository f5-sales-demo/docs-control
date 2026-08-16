#!/usr/bin/env bash
# English-only suspension must prevent model-backed locale generation fleet-wide.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"
WATCHER="$REPO_ROOT/.github/workflows/antigravity-fleet-watcher.yml"
COLLECTOR="$REPO_ROOT/scripts/collect-antigravity-fleet-state.sh"
AUDIT="$REPO_ROOT/.github/workflows/translation-audit.yml"
PRE_COMMIT="$REPO_ROOT/.pre-commit-config.yaml"
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

echo "English-only translation suspension guards"
for path in .github/workflows/antigravity-translate.yml .agents/skills/i18n-translate/SKILL.md; do
  if [ ! -e "$REPO_ROOT/$path" ] && jq -e --arg path "$path" '.managed_files.absent_files | index($path) != null' "$REPO_SETTINGS" >/dev/null; then
    pass "$path is retired from governed rollout"
  else
    fail "$path is retired from governed rollout" "source or downstream deletion route remains"
  fi
done
if ! jq -e '.managed_files.files[] | select(.src|test("antigravity-translate|i18n-translate"))' "$REPO_SETTINGS" >/dev/null; then
  pass "managed catalog contains no translation generator"
else
  fail "managed catalog contains no translation generator" "generator mapping remains"
fi
if ! grep -qE 'antigravity-translate|TRANSLATIONS_ENABLED|translationNeedsRecovery|needs_translation|reconcile_all' "$WATCHER" "$COLLECTOR"; then
  pass "fleet watcher cannot queue or redispatch translations"
else
  fail "fleet watcher cannot queue or redispatch translations" "translation dispatch surface remains"
fi
hook=$(awk '/^      - id: validate-translations$/ {capture=1} capture && /^ci:/ {exit} capture {print}' "$PRE_COMMIT")
if grep -qF 'entry: bash scripts/validate-translations.sh --staged' <<<"$hook" && ! grep -qE 'agy|ANTHROPIC|accept-edits' <<<"$hook"; then
  pass "local validation remains deterministic and model-free"
else
  fail "local validation remains deterministic and model-free" "validator hook changed"
fi
if ! grep -qE 'ANTIGRAVITY_TOKEN|GCP_PROJECT_ID|REPO_SYNC_TOKEN|uses:.*antigravity-translate' "$AUDIT"; then
  pass "policy audit holds no model or publication credential"
else
  fail "policy audit holds no model or publication credential" "credentialed generation route remains"
fi
printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
