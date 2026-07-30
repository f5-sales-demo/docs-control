#!/usr/bin/env bash
# Regression harness for the two-layer review split (issue #799).
#
# The local layer reviews specs, plans, and unpushed branches and is advisory;
# the CI layer reviews the pull-request diff and is the merge gate. An agent that
# picks a PR-diff reviewer for a spec gets the wrong review, and in the case of
# code-review-f5 also gets a write-capable, gh/az/terraform-capable tool pointed
# at local work. These assertions keep the enforcement honest: every reviewer
# CLAUDE.md prohibits must actually be blocked by a mechanism, and the one
# carve-out must stay a carve-out for its stated reason.
#
# Run from repo root: bash tests/test-review-layer-routing.sh
set -euo pipefail

# ── Test framework (shared pattern with test-linter-configs.sh) ──
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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$REPO_ROOT/.claude/settings.json"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
F5_CMD="$REPO_ROOT/plugins/f5-review/code-review-f5/commands/code-review.md"

# ════════════════════════════════════════════════════════════════════
# SECTION 1: deny rules for the model-invocable PR-diff reviewers
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 1: permissions.deny blocks the model-invocable PR-diff reviewers ==="

if jq empty "$SETTINGS" 2>/dev/null; then
  pass "1.1 .claude/settings.json is valid JSON"
else
  fail "1.1 .claude/settings.json is valid JSON" "jq parse failed"
fi

# Verified empirically: a deny rule of this shape yields
# "Skill execution blocked by permission rules", even under
# --dangerously-skip-permissions.
for skill in "code-review:code-review" "pr-review-toolkit:review-pr"; do
  if jq -e --arg s "Skill($skill)" '.permissions.deny // [] | index($s)' \
    "$SETTINGS" >/dev/null 2>&1; then
    pass "1.2 permissions.deny contains Skill($skill)"
  else
    fail "1.2 permissions.deny contains Skill($skill)" "rule missing from deny list"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 2: the code-review-f5 carve-out
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 2: code-review-f5 is gated by disable-model-invocation, not deny ==="

# A deny rule would break the merge gate: CI invokes the reviewer through the
# workflow's `prompt:` as a slash command, and a deny rule does not distinguish
# that from model selection. Verified A/B — with the deny rule in place the
# CI-style prompt returned BLOCKED; without it, EXPANDED.
if jq -e '.permissions.deny // [] | index("Skill(code-review-f5:code-review)")' \
  "$SETTINGS" >/dev/null 2>&1; then
  fail "2.1 code-review-f5 is NOT in permissions.deny" \
    "denying it also blocks the CI workflow's own prompt-level invocation, breaking the required gate"
else
  pass "2.1 code-review-f5 is NOT in permissions.deny"
fi

# disable-model-invocation does distinguish the two: the prompt-level slash
# command still expands, while a Skill tool call is refused.
if [[ -f $F5_CMD ]]; then
  pass "2.2 vendored f5 reviewer command exists"
  if awk '/^---$/{n++; next} n==1' "$F5_CMD" |
    grep -qE '^disable-model-invocation:[[:space:]]*true[[:space:]]*$'; then
    pass "2.3 f5 reviewer command sets disable-model-invocation: true"
  else
    fail "2.3 f5 reviewer command sets disable-model-invocation: true" \
      "frontmatter lacks the flag, so an agent can auto-select the merge-gate reviewer locally"
  fi
else
  fail "2.2 vendored f5 reviewer command exists" "not found at $F5_CMD"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 3: CLAUDE.md routes to the local layer and names the exclusions
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 3: CLAUDE.md names the tool to use and the tools not to use ==="

for token in "codex:verified-code-review" "review-doc"; do
  if grep -qF "$token" "$CLAUDE_MD"; then
    pass "3.1 CLAUDE.md names $token"
  else
    fail "3.1 CLAUDE.md names $token" "local-layer routing target missing"
  fi
done

# Every prohibited reviewer must be named explicitly. Prose that says "do not use
# a PR-diff reviewer" without naming them loses the routing contest to their own
# terse, all-review skill descriptions.
for reviewer in "code-review:code-review" "code-review-f5:code-review" \
  "pr-review-toolkit:review-pr" "/review" "/security-review"; do
  if grep -qF "$reviewer" "$CLAUDE_MD"; then
    pass "3.2 CLAUDE.md names prohibited reviewer $reviewer"
  else
    fail "3.2 CLAUDE.md names prohibited reviewer $reviewer" "exclusion list is incomplete"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 4: unsafe destructive tools denied (issue #825)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 4: destructive tools the docs forbid are denied, not merely discouraged ==="

# clean_gone runs `git worktree remove --force` and `git branch -D` over every
# [gone] branch with no merge check. [gone] is also true for a PR closed WITHOUT
# merging, where the local branch holds the only copy of unmerged commits — so
# the force-delete can destroy work. CONTRIBUTING.md tells contributors not to
# use it; this rule makes that enforceable rather than advisory.
# Verified empirically: without the rule the tool returns "Launching skill:
# commit-commands:clean_gone"; with it, "Skill execution blocked by permission rules".
if jq -e '.permissions.deny // [] | index("Skill(commit-commands:clean_gone)")' \
  "$SETTINGS" >/dev/null 2>&1; then
  pass "4.1 permissions.deny contains Skill(commit-commands:clean_gone)"
else
  fail "4.1 permissions.deny contains Skill(commit-commands:clean_gone)" \
    "the docs forbid this tool but nothing stops it being invoked"
fi

# The docs must keep explaining WHY, so the rule is not mistaken for arbitrary.
if grep -q 'clean_gone' "$REPO_ROOT/CONTRIBUTING.md"; then
  pass "4.2 CONTRIBUTING.md still documents why clean_gone is unsafe"
else
  fail "4.2 CONTRIBUTING.md still documents why clean_gone is unsafe" \
    "a deny rule with no stated rationale invites someone to remove it"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 5: CLAUDE.md stays small enough to be read (issue #855)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 5: CLAUDE.md stays within its size budget ==="

# CLAUDE.md loads at the start of every session and again in every subagent's
# own context. Anthropic's Claude Code best practices: "Bloated CLAUDE.md files
# cause Claude to ignore your actual instructions" and "If Claude keeps doing
# something you don't want despite having a rule against it, the file is
# probably too long and the rule is getting lost."
#
# This file grew 7x in three weeks (1,449 bytes on 2026-07-05 to 10,121 on
# 2026-07-27) one well-intentioned rule at a time, and no single PR looked
# unreasonable. The budget makes the next increment a conscious decision: to add
# something, prune something. Raising this number is not the fix.
CLAUDE_MD_MAX_BYTES=8500
CLAUDE_MD_BYTES=$(wc -c <"$CLAUDE_MD" | tr -d ' ')

if [ "$CLAUDE_MD_BYTES" -le "$CLAUDE_MD_MAX_BYTES" ]; then
  pass "5.1 CLAUDE.md is ${CLAUDE_MD_BYTES}B, within the ${CLAUDE_MD_MAX_BYTES}B budget"
else
  fail "5.1 CLAUDE.md is within its ${CLAUDE_MD_MAX_BYTES}B budget" \
    "it is ${CLAUDE_MD_BYTES}B — prune before adding; bloat makes Claude ignore the rules that matter"
fi

# ════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Tests run: $TESTS_RUN | Passed: $PASS | Failed: $FAIL"
echo "════════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
