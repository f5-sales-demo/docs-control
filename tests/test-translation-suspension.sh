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

# GATED is the functional question: can this job decline to report?
#
# The condition is what actually withholds the status. Because restoration deletes
# the `if:` outright rather than flipping the variable (see "Restoring translations"
# in CONTRIBUTING.md), its presence is a reliable signal — and it is the only signal
# that catches the dangerous case where someone removes the explanatory comment but
# leaves the condition behind. A repository the variable is not visible to then
# emits no status at all, and a required context would wait on it forever.
#
# Keying on the comment alone was wrong for exactly that reason.
if grep -qE "^\s*if:\s*vars\.TRANSLATIONS_ENABLED" "$AUDIT_STUB"; then
  GATED=true
else
  GATED=false
fi

# The marker is documentation of intent. It must agree with the condition, or the
# next reader is told one thing while CI does another.
if grep -q 'SUSPENDED:' "$AUDIT_STUB"; then
  MARKED=true
else
  MARKED=false
fi

if [ "$REQUIRED" = "true" ] && [ "$GATED" = "true" ]; then
  fail "1.1 a conditionally-skipped audit is never a required context" \
    "'$CONTEXT' is required while the job can skip itself — repos without the variable emit no status and their PRs deadlock"
else
  pass "1.1 a conditionally-skipped audit is never a required context (required=$REQUIRED gated=$GATED)"
fi

if [ "$GATED" = "$MARKED" ]; then
  pass "1.2 the SUSPENDED marker agrees with the actual gate (gated=$GATED marked=$MARKED)"
else
  fail "1.2 the SUSPENDED marker agrees with the actual gate" \
    "gated=$GATED but marked=$MARKED — the comment and the condition disagree, so one of them is lying"
fi

# Name the state, so CI output says suspended or restored without a reader
# opening two files.
if [ "$GATED" = "true" ] && [ "$REQUIRED" = "false" ]; then
  pass "1.3 suspended state is coherent: audit can skip, context not required"
elif [ "$GATED" = "false" ] && [ "$REQUIRED" = "true" ]; then
  pass "1.3 restored state is coherent: audit unconditional, context required"
else
  # Unconditional but gating nothing: wasteful rather than dangerous, and it is the
  # transient state between the two halves of a restore.
  pass "1.3 audit unconditional but not required — safe, advisory only (mid-restore)"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 2: generation cannot spend money by default
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 2: generation is opt-in, not opt-out ==="

# Assert against the current state rather than assuming suspension forever.
# Restoration removes this branch from the hook (CONTRIBUTING step 3), so an
# unconditional requirement would fail the moment someone follows the documented
# procedure — forcing an undocumented test edit in the middle of a recovery.
#
# Testing the negative form ("!= true") rather than any mention of the variable,
# because a hook that merely names it could still run by default.
if grep -qE 'TRANSLATIONS_ENABLED:-.*\!=\s*"true"' "$PRE_COMMIT"; then
  HOOK_GATED=true
else
  HOOK_GATED=false
fi

if [ "$GATED" = "true" ]; then
  if [ "$HOOK_GATED" = "true" ]; then
    pass "2.1 while suspended, the docs-translate hook requires TRANSLATIONS_ENABLED=true"
  else
    fail "2.1 while suspended, the docs-translate hook requires TRANSLATIONS_ENABLED=true" \
      "the audit is suspended but generation is not gated — unset must mean no generation, or money is spent by accident"
  fi
elif [ "$HOOK_GATED" = "false" ]; then
  pass "2.1 while restored, the docs-translate hook runs unconditionally"
else
  fail "2.1 while restored, the docs-translate hook runs unconditionally" \
    "the audit is active but generation is still gated — translations would go stale while the audit demands freshness"
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

# Section 1 keys on the SUSPENDED marker, so restoring must remove it. A
# procedure that flips the variable and the context but leaves the marker in place
# would fail 1.1 immediately after a correct restore.
# Match the marker token exactly, case-sensitively, and flattened.
#
# Three earlier attempts got this wrong, in both directions. Requiring the verb
# adjacent to the marker missed correct prose. Widening to a sentence broke on the
# period inside `vars.TRANSLATIONS_ENABLED`. Widening further with -i made it
# vacuous, because the document says "suspended" nine times in ordinary prose and
# something always matched. `SUSPENDED:` with its colon is the literal marker and
# appears only where the procedure discusses it, so it is the discriminating token.
# Flattening is still needed: the verb and the marker wrap onto different lines and
# grep is line-based.
if tr '\n' ' ' <"$CONTRIBUTING" | grep -qE '(remove|delete|Remove|Delete).{0,200}SUSPENDED:'; then
  pass "3.3 restore procedure removes the SUSPENDED markers that section 1 keys on"
else
  fail "3.3 restore procedure removes the SUSPENDED markers that section 1 keys on" \
    "leaving the marker in place fails 1.1 straight after a correct restore"
fi

# One green pull request does not prove the audit reports everywhere. During #867
# a five-repo spot check came back clean while 9 of 38 repos were still stale,
# because enforcement fans out in batches. Re-adding the context on that evidence
# deadlocks whichever repos have not caught up.
if grep -qiE 'every governed repo|all governed repo' "$CONTRIBUTING"; then
  pass "3.4 restore procedure requires fleet-wide confirmation, not a single PR"
else
  fail "3.4 restore procedure requires fleet-wide confirmation, not a single PR" \
    "a sample can be green while repos lag; the context must not be re-added on that evidence"
fi

# "Every governed repo must report" is impossible as stated: repos listed in
# skip_files for translation-audit.yml never receive the workflow, so the check
# can never appear there. Verified: terraform-provider-xcsh skips it and the file
# 404s in that repository. That is exactly why it carried an
# excluded_required_contexts entry — a required check whose workflow does not
# exist is a permanent deadlock, not a transient one.
#
# So the procedure must scope its verification to repos that actually receive the
# workflow, and must derive that set from skip_files rather than from a
# hand-maintained list that will drift.
if grep -q 'skip_files' "$CONTRIBUTING"; then
  pass "3.4b restore procedure excludes repos that never receive the audit workflow"
else
  fail "3.4b restore procedure excludes repos that never receive the audit workflow" \
    "terraform-provider-xcsh skips translation-audit.yml; demanding a report from it is impossible"
fi

# The ordering rule is the load-bearing part of the procedure. Assert the two
# substantive facts rather than one exact phrase: that re-adding the context is
# explicitly sequenced last, and that the consequence of getting it wrong is
# named. Grepping for a single wording made this fail against prose that stated
# the rule three different ways.
if grep -qiE 'only then|order matters' "$CONTRIBUTING" &&
  grep -qi 'deadlock' "$CONTRIBUTING"; then
  pass "3.5 restore procedure sequences the context last and names the deadlock consequence"
else
  fail "3.5 restore procedure sequences the context last and names the deadlock consequence" \
    "re-adding the required context before the check can pass deadlocks every open PR"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($((PASS + FAIL)) total)"
echo "════════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
