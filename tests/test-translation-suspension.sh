#!/usr/bin/env bash
# Translation generation is centrally gated while deterministic local validation stays active.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"
AUDIT="$REPO_ROOT/workflows/translation-audit.yml"
PRE_COMMIT="$REPO_ROOT/.pre-commit-config.yaml"
CONTRIBUTING="$REPO_ROOT/CONTRIBUTING.md"
CONTEXT='audit / Translation freshness'
PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

echo "Translation routing guards"

required=$(jq -r --arg context "$CONTEXT" '
  ((.branch_protection[0].required_status_checks.contexts // []) +
   ([.repo_overrides[]?.additional_contexts // []] | flatten)) |
  index($context) != null
' "$REPO_SETTINGS")
if grep -qE '^\s*if:\s*vars\.TRANSLATIONS_ENABLED' "$AUDIT"; then gated=true; else gated=false; fi
if [ "$required" = true ] && [ "$gated" = true ]; then
  fail "a gated audit is never required" "the status would remain pending forever"
else
  pass "a gated audit is never required"
fi

for workflow in \
  "$REPO_ROOT/.github/workflows/antigravity-translate.yml" \
  "$REPO_ROOT/workflows/antigravity-translate.yml"; do
  if grep -qF "vars.TRANSLATIONS_ENABLED == 'true'" "$workflow"; then
    pass "$(basename "$workflow") is positive-gated"
  else
    fail "$(basename "$workflow") is positive-gated" "literal true gate is absent"
  fi
  if grep -q 'workflow_dispatch:' "$workflow" || [[ "$workflow" == *'/.github/'* ]]; then
    pass "$(basename "$workflow") has a trusted automation route"
  else
    fail "$(basename "$workflow") has a trusted automation route" "dispatch route is absent"
  fi
done

hook=$(awk '
  /^      - id: validate-translations$/ {capture=1}
  capture && /^ci:/ {exit}
  capture {print}
' "$PRE_COMMIT")
if grep -qF 'entry: bash scripts/validate-translations.sh --staged' <<<"$hook" &&
  ! grep -qE 'agy|ANTHROPIC|TRANSLATIONS_ENABLED|accept-edits' <<<"$hook"; then
  pass "local translation hook is deterministic and model-free"
else
  fail "local translation hook is deterministic and model-free" "hook invokes or depends on a model"
fi

for retired in scripts/antigravity-translate-staged.sh scripts/parse-translation-trigger.sh; do
  if [ ! -e "$REPO_ROOT/$retired" ] &&
    jq -e --arg retired "$retired" '.managed_files.absent_files | index($retired) != null' \
      "$REPO_SETTINGS" >/dev/null; then
    pass "$retired is removed fleet-wide"
  else
    fail "$retired is removed fleet-wide" "source or deletion route remains"
  fi
done

if grep -qF 'scripts/validate-translations.sh' "$REPO_ROOT/.github/workflows/antigravity-translate.yml" &&
  grep -qF 'scripts/validate-translations.sh' "$REPO_SETTINGS"; then
  pass "trusted source-hash/output validator gates translation publication"
else
  fail "trusted source-hash/output validator gates translation publication" \
    "workflow or managed catalog omits the validator"
fi

if grep -q 'skip_files' "$CONTRIBUTING" &&
  grep -q 'terraform-provider-xcsh' "$CONTRIBUTING" &&
  ! grep -qE 'terraform-provider-xcsh.{0,80}code-review|code-review.{0,80}terraform-provider-xcsh' \
    <(tr '\n' ' ' <"$CONTRIBUTING"); then
  pass "restore procedure derives exclusions without the retired repository"
else
  fail "restore procedure derives exclusions without the retired repository" \
    "restore instructions are stale"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
