#!/usr/bin/env bash
# Guards the translation suspension against the one combination that deadlocks
# pull requests fleet-wide: a required status check whose workflow is gated off
# never reports, so the check can never go green and no PR can merge without an
# administrator.
#
# This is not hypothetical. The suspended Claude reviewer hit it, and the fix is
# recorded in workflows/code-review.yml:
#
#   "The `review / claude-review` context was removed from branch protection
#    first (docs-control#833); skipping this job while it was still required
#    would have deadlocked every open PR."
#
# The two settings live in different files that propagate through different
# fan-outs (branch protection via enforce-repo-settings, the workflow via
# managed-file sync), so nothing else couples them. This test does.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"
AUDIT_STUB="$REPO_ROOT/workflows/translation-audit.yml"
PRE_COMMIT="$REPO_ROOT/.pre-commit-config.yaml"
CONTRIBUTING="$REPO_ROOT/CONTRIBUTING.md"

CONTEXT="audit / Translation freshness"
PASS=0
FAIL=0

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1 — $2"
  FAIL=$((FAIL + 1))
}

echo "════════════════════════════════════════════════════════════════"
echo "Translation suspension guards"
echo "════════════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════
# SECTION 1: the deadlock combination is impossible
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 1: a required context never coexists with a gated-off workflow ==="

# Is the context required anywhere it could be? Base contexts plus any
# per-repo additional_contexts — the two sources enforce-repo-settings merges.
REQUIRED=$(jq -r --arg c "$CONTEXT" '
  ((.branch_protection[0].required_status_checks.contexts // []) +
   ([.repo_overrides // {} | .[] | .additional_contexts // []] | flatten))
  | index($c) != null
' "$REPO_SETTINGS")

# Is the audit intentionally suspended? Read the declared intent, not the
# presence of a condition.
#
# The obvious test — "does the job carry an `if: vars.X == 'true'`" — is wrong,
# and wrong in the direction that breaks restoration. That condition is still
# present when translations are switched back on; only the variable's value
# changes, and a static test cannot see it. Treating any conditioned job as
# gated off would fail the moment someone follows the restore procedure, which
# legitimately ends with the context required AND the condition present.
#
# The `SUSPENDED:` marker states intent in the repository, changes in the same
# commit as the condition, and is the convention already used in
# workflows/code-review.yml. Restoring translations removes both together.
if grep -q 'SUSPENDED:' "$AUDIT_STUB"; then
  SUSPENDED=true
else
  SUSPENDED=false
fi

if [ "$REQUIRED" = "true" ] && [ "$SUSPENDED" = "true" ]; then
  fail "1.1 a suspended audit is never a required context" \
    "'$CONTEXT' is required while the audit is marked SUSPENDED — it will never report and every PR deadlocks"
else
  pass "1.1 a suspended audit is never a required context (required=$REQUIRED suspended=$SUSPENDED)"
fi

# Both safe states are legitimate. Name which one we are in, so CI output says
# suspended or active without a reader opening two files.
if [ "$SUSPENDED" = "true" ] && [ "$REQUIRED" = "false" ]; then
  pass "1.2 suspended state is coherent: audit off, context not required"
elif [ "$SUSPENDED" = "false" ] && [ "$REQUIRED" = "true" ]; then
  pass "1.2 restored state is coherent: audit active, context required"
else
  # Audit active but gating nothing: wasteful rather than dangerous, and it is the
  # transient state between the two halves of a restore.
  pass "1.2 audit active but not required — safe, advisory only (mid-restore)"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 2: generation cannot spend money by default
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 2: generation is opt-in, not opt-out ==="

# The hook must require an explicit opt-in. Testing for the negative form
# ("!= true") rather than any mention of the variable, because a hook that
# merely names it could still run by default.
if grep -qE 'TRANSLATIONS_ENABLED:-.*\!=\s*"true"' "$PRE_COMMIT"; then
  pass "2.1 docs-translate hook requires TRANSLATIONS_ENABLED=true to run"
else
  fail "2.1 docs-translate hook requires TRANSLATIONS_ENABLED=true to run" \
    "unset or absent must mean no generation; an opt-out default spends money by accident"
fi

# The hook must still exist and still be scoped to English sources — a suspension
# that deleted the hook would be harder to restore and would lose the trigger.
if grep -q 'id: docs-translate' "$PRE_COMMIT" &&
  grep -qE '^\s*files:\s*\^docs/en/\.\*\\\.mdx\?\$' "$PRE_COMMIT"; then
  pass "2.2 the hook is suspended rather than deleted, still scoped to docs/en"
else
  fail "2.2 the hook is suspended rather than deleted, still scoped to docs/en" \
    "suspension should gate the hook, not remove it"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 3: the restore procedure records what removal took away
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 3: restoring is documented, including the non-obvious parts ==="

# Removing the base context forced the removal of two per-repo exclusions,
# because tests/test-linter-configs.sh section 7c rejects an exclusion that
# matches no required context. Restoring the context without restoring those
# exclusions silently subjects those repos to a check they were exempt from.
for repo in terraform-provider-xcsh code-review; do
  if grep -q "$repo" "$CONTRIBUTING"; then
    pass "3.1 restore procedure names $repo, whose exclusion was removed with the context"
  else
    fail "3.1 restore procedure names $repo, whose exclusion was removed with the context" \
      "restoring the context without its exclusion gives this repo a check it was exempt from"
  fi
done

# TRANSLATIONS_ENABLED is one name for two independent switches, and conflating
# them silently half-restores the system. The organisation variable reaches only
# the Actions `vars` context, so it enables the audit workflow; the pre-commit
# hook reads the developer's local process environment, which no organisation
# variable sets. A procedure that mentions only the variable leaves generation off
# — the first `--force` run works, then every later English edit silently skips
# translation, and the failure surfaces only once the audit is required again.
if grep -q 'export TRANSLATIONS_ENABLED' "$CONTRIBUTING"; then
  pass "3.2 restore procedure sets TRANSLATIONS_ENABLED locally, not just as an org variable"
else
  fail "3.2 restore procedure sets TRANSLATIONS_ENABLED locally, not just as an org variable" \
    "the org variable reaches Actions only; the pre-commit hook reads the local environment"
fi

# The ordering rule is the load-bearing part of the procedure. Assert the two
# substantive facts rather than one exact phrase: that re-adding the context is
# explicitly sequenced last, and that the consequence of getting it wrong is
# named. Grepping for a single wording made this fail against prose that stated
# the rule three different ways.
if grep -qiE 'only then|order matters' "$CONTRIBUTING" &&
  grep -qi 'deadlock' "$CONTRIBUTING"; then
  pass "3.3 restore procedure sequences the context last and names the deadlock consequence"
else
  fail "3.3 restore procedure sequences the context last and names the deadlock consequence" \
    "re-adding the required context before the check can pass deadlocks every open PR"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($((PASS + FAIL)) total)"
echo "════════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
