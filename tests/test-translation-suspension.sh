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

# Is the stub's audit job gated behind a variable?
if grep -qE '^\s*if:\s*vars\.[A-Z_]+ == .true.' "$AUDIT_STUB"; then
  GATED=true
else
  GATED=false
fi

if [ "$REQUIRED" = "true" ] && [ "$GATED" = "true" ]; then
  fail "1.1 required context and gated-off workflow do not coexist" \
    "'$CONTEXT' is a required check but its job is gated off — it will never report and every PR deadlocks"
else
  pass "1.1 required context and gated-off workflow do not coexist (required=$REQUIRED gated=$GATED)"
fi

# The safe states are both acceptable, but say which one we are in, so a reader
# of CI output can tell suspended from active without opening two files.
if [ "$GATED" = "true" ] && [ "$REQUIRED" = "false" ]; then
  pass "1.2 suspended state is coherent: workflow gated off, context not required"
elif [ "$GATED" = "false" ] && [ "$REQUIRED" = "true" ]; then
  pass "1.2 active state is coherent: workflow runs, context required"
elif [ "$GATED" = "false" ] && [ "$REQUIRED" = "false" ]; then
  # Wasteful rather than dangerous: the audit runs and reports but gates nothing.
  pass "1.2 workflow runs but gates nothing — safe, though the audit is advisory only"
else
  fail "1.2 suspension state is coherent" "unreachable combination: required=$REQUIRED gated=$GATED"
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

# The ordering rule is the load-bearing part of the procedure. Assert the two
# substantive facts rather than one exact phrase: that re-adding the context is
# explicitly sequenced last, and that the consequence of getting it wrong is
# named. Grepping for a single wording made this fail against prose that stated
# the rule three different ways.
if grep -qiE 'only then|order matters' "$CONTRIBUTING" &&
  grep -qi 'deadlock' "$CONTRIBUTING"; then
  pass "3.2 restore procedure sequences the context last and names the deadlock consequence"
else
  fail "3.2 restore procedure sequences the context last and names the deadlock consequence" \
    "re-adding the required context before the check can pass deadlocks every open PR"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($((PASS + FAIL)) total)"
echo "════════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
