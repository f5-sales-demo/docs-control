#!/usr/bin/env bash
# Regression harness for review routing (issues #799 and #1083).
#
# Document review is advisory and local branch review is a required Antigravity
# pre-push step. An agent that picks a PR-diff reviewer for either route gets the
# wrong review. These assertions keep the routing guidance and deny rules aligned
# while ensuring the discontinued CI reviewer cannot be reintroduced by stale
# governed assets or credentials.
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
AGENTS_MD="$REPO_ROOT/AGENTS.md"
AGY_REVIEW="$REPO_ROOT/scripts/agy-pre-push-review.sh"
REPO_SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"
GOVERNANCE="$REPO_ROOT/.claude/governance.json"

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
# SECTION 2: the discontinued CI reviewer stays retired
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 2: the discontinued CI reviewer has no executable or credential surface ==="

RETIRED_ASSETS=(
  ".github/workflows/claude-review.yml"
  "workflows/code-review.yml"
  "REVIEWER-SPEC.md"
  "REVIEW.md"
  "plugins/f5-review"
  "scripts/parse-verdict.sh"
  "scripts/review-retry-decision.sh"
  "scripts/reviewer-comment-count.sh"
  "scripts/check-review-deps.sh"
  "tests/test-claude-review-retry.sh"
  "tests/test-parse-verdict.sh"
  "tests/test-reviewer-comment-count.sh"
  "tests/test-check-review-deps.sh"
)
REMAINING_ASSETS=()
for asset in "${RETIRED_ASSETS[@]}"; do
  if [ -e "$REPO_ROOT/$asset" ]; then
    REMAINING_ASSETS+=("$asset")
  fi
done
if [ "${#REMAINING_ASSETS[@]}" -eq 0 ]; then
  pass "2.1 discontinued reviewer assets are absent"
else
  fail "2.1 discontinued reviewer assets are absent" \
    "still present: ${REMAINING_ASSETS[*]}"
fi

if jq -e '
    (.managed_files.absent_files | index(".github/workflows/code-review.yml") != null) and
    all(.managed_files.files[]; .dest != ".github/workflows/code-review.yml") and
    (.secrets_manifest.roles | has("claude_review") | not) and
    all(.secrets_manifest.repo_roles[]; index("claude_review") == null)
  ' "$REPO_SETTINGS" >/dev/null &&
  jq -e '.protected_files | index(".github/workflows/code-review.yml") == null' \
    "$GOVERNANCE" >/dev/null; then
  pass "2.2 governance deletes the retired caller and grants no reviewer secret"
else
  fail "2.2 governance deletes the retired caller and grants no reviewer secret" \
    "managed routing, protected files, or secret roles still retain the reviewer"
fi

if ! grep -Eq 'review / claude-review|REVIEWER-SPEC\.md|code-review-f5|\.github/workflows/claude-review\.yml' \
  "$CLAUDE_MD" "$REPO_ROOT/CONTRIBUTING.md"; then
  pass "2.3 contributor guidance contains no retired reviewer route"
else
  fail "2.3 contributor guidance contains no retired reviewer route" \
    "CLAUDE.md or CONTRIBUTING.md still directs contributors to discontinued review infrastructure"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 3: CLAUDE.md routes to the local layer and names the exclusions
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 3: CLAUDE.md names the tool to use and the tools not to use ==="

for token in "verified-review:verified-code-review" "document --kind"; do
  if grep -qF "$token" "$CLAUDE_MD"; then
    pass "3.1 CLAUDE.md names $token"
  else
    fail "3.1 CLAUDE.md names $token" "local-layer routing target missing"
  fi
done

if grep -qF 'verified-code-review' "$AGENTS_MD"; then
  pass "3.1a AGENTS.md names the cross-platform verified review workflow"
else
  fail "3.1a AGENTS.md names the cross-platform verified review workflow" \
    "generic skill name missing"
fi

for document in "$CLAUDE_MD" "$AGENTS_MD"; do
  if grep -qF 'bash scripts/agy-pre-push-review.sh' "$document" &&
    grep -qiE 'before (any|every|a) push|before every PR push' "$document"; then
    pass "3.1b $(basename "$document") requires the managed agy review before push"
  else
    fail "3.1b $(basename "$document") requires the managed agy review before push" \
      "command or ordering requirement missing"
  fi
done

if grep -q -- '--sandbox' "$AGY_REVIEW" &&
  grep -q -- '--mode plan' "$AGY_REVIEW" &&
  ! grep -q -- '--dangerously-skip-permissions' "$AGY_REVIEW"; then
  pass "3.1c managed agy review is sandboxed and read-only"
else
  fail "3.1c managed agy review is sandboxed and read-only" \
    "sandbox/plan flags are missing or permission bypass is present"
fi

# Every prohibited reviewer must be named explicitly. Prose that says "do not use
# a PR-diff reviewer" without naming them loses the routing contest to their own
# terse, all-review skill descriptions.
for reviewer in "code-review:code-review" "pr-review-toolkit:review-pr" \
  "/review" "/security-review"; do
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
# SECTION 3b: deny rules and guidance name the same PR-diff tools
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 3b: CLAUDE.md and settings agree on prohibited PR-diff tools ==="

# The local document-review layer is optional tooling. CLAUDE.md must say so
# itself: an unconditional instruction can stall work or push an agent toward a
# prohibited PR-diff reviewer when the preferred skill is unavailable.
LOCAL_LINE=$(grep -F 'verified-review:verified-code-review' "$CLAUDE_MD" | head -1)
if printf '%s' "$LOCAL_LINE" | grep -qiE 'when (it is )?(installed|available|present)|skip|absent|not installed'; then
  pass "3b.0 CLAUDE.md itself says the local layer is skipped when the tooling is absent"
else
  fail "3b.0 CLAUDE.md itself says the local layer is skipped when the tooling is absent" \
    "reads as unconditional; the caveat must live with the routing instruction"
fi

# Every PR-diff reviewer denied in settings must be named in the guidance.
while IFS= read -r denied; do
  case "$denied" in *:*) : ;; *) continue ;; esac
  if grep -qF "$denied" "$CLAUDE_MD"; then
    pass "3b.1 $denied is denied in settings and named in CLAUDE.md"
  else
    fail "3b.1 $denied is denied in settings and named in CLAUDE.md" \
      "the enforcement exists without matching contributor guidance"
  fi
done <<EOF
$(jq -r '.permissions.deny // [] | .[]' "$SETTINGS" |
  sed -n 's/^Skill(\(.*review.*\))$/\1/p')
EOF

# ════════════════════════════════════════════════════════════════════
# SECTION 4b: CLAUDE.md's cross-references must resolve everywhere (issue #859)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 4b: no governed repo receives CLAUDE.md but skips CONTRIBUTING.md ==="

# CLAUDE.md is synced to every governed repo and points into CONTRIBUTING.md for
# detail it deliberately does not carry. A repo that receives one but skips the
# other gets dangling pointers, and the only safe response is to inline the
# guidance into CLAUDE.md — which fights the size budget in Section 5. xcsh was
# exactly this case until its repo-specific content moved to DEVELOPING.md
# (f5-sales-demo/xcsh#2605) and this opt-out was removed.
# Checking skip_files alone is not enough. sync-managed-files.yml iterates
# repo-settings.json's managed_files.files[] and drops a file for a repo when
# either skip_files lists it or the entry carries an only_repos allowlist that
# excludes the repo (workflow lines ~387-405). Model those exact two rules
# against that exact source.
#
# Deliberately NOT read from managed-files-manifest.json: that artifact keeps
# only src/dest/sha/size and discards only_repos, so a real allowlist added in
# repo-settings.json would be invisible there and this check would pass while
# the sync skipped the file.
DOWNSTREAM="$REPO_ROOT/.github/config/downstream-repos.json"

OFFENDERS=$(
  jq -n -r \
    --slurpfile settings "$REPO_SETTINGS" \
    --slurpfile repos "$DOWNSTREAM" '
    ($settings[0].managed_files.files // [])      as $files |
    ($settings[0].managed_files.skip_files // {}) as $skips |
    ($repos[0])                                   as $all   |
    # receives(repo, dest): routed to this repo by the same rules the sync applies
    def receives($repo; $name):
      ([$files[] | select(.dest == $name)] | first) as $entry |
      if $entry == null then false
      elif ($entry.only_repos // null) != null and (($entry.only_repos | index($repo)) == null) then false
      elif (($skips[$repo] // []) | index($name)) != null then false
      else true end;
    $all
    | map(select(receives(.; "CLAUDE.md") and (receives(.; "CONTRIBUTING.md") | not)))
    | .[]
  ' 2>/dev/null | tr '\n' ' '
)

if [ -z "${OFFENDERS// /}" ]; then
  pass "4b.1 every repo receiving CLAUDE.md also receives CONTRIBUTING.md"
else
  fail "4b.1 every repo receiving CLAUDE.md also receives CONTRIBUTING.md" \
    "CLAUDE.md points into CONTRIBUTING.md; these repos get one without the other: ${OFFENDERS}"
fi

# governance.json is the copy the sync and preflight read, so the two skip lists
# must not drift apart.
if diff -q \
  <(jq -S '.skip_files' "$GOVERNANCE") \
  <(jq -S '.managed_files.skip_files' "$REPO_SETTINGS") >/dev/null 2>&1; then
  pass "4b.2 governance.json and repo-settings.json skip lists agree"
else
  fail "4b.2 governance.json and repo-settings.json skip lists agree" \
    "the two copies of skip_files have drifted; sync and preflight would disagree"
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
