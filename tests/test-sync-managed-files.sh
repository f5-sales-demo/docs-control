#!/usr/bin/env bash
# Assertions on how sync-managed-files updates an existing sync PR.
#
# When drift is found and a sync PR is already open, the branch has to be
# rebased onto main so the PR diff shows only managed files rather than
# reverting whatever landed in between. Doing that as a standalone force-reset
# to main's SHA empties the PR: for the interval between the reset and the
# follow-up commit the branch IS main, so the PR has zero commits ahead of
# base, and GitHub closes it and disables auto-merge. The content comes back on
# the next call, but a closed PR does not reopen (#836).
#
# The rebase and the commit therefore have to be a single ref update.
#
# Run from repo root: bash tests/test-sync-managed-files.sh
set -euo pipefail

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
SYNC="$REPO_ROOT/.github/workflows/sync-managed-files.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The branch of the drift handler that runs when a sync PR is already open.
awk '/if \[ -n "\$EXISTING_PR" \]; then/{f=1} f{print} f&&/^                else$/{exit}' \
  "$SYNC" >"$WORK/existing_pr_block.txt"

echo ""
echo "=== Section 1: the existing-PR path is present ==="

if [ -s "$WORK/existing_pr_block.txt" ]; then
  pass "1.1 located the existing-PR branch of the drift handler"
else
  fail "1.1 located the existing-PR branch of the drift handler" \
    "extraction produced nothing; the assertions below would be vacuous"
fi

if grep -q 'commit_tree' "$WORK/existing_pr_block.txt"; then
  pass "1.2 the existing-PR path commits the drifted files"
else
  fail "1.2 the existing-PR path commits the drifted files" "no commit_tree call found"
fi

echo ""
echo "=== Section 2: the branch is never reset to main on its own ==="

# The defect: a PATCH of the sync branch ref carrying main's SHA, separate from
# the commit. Detected structurally rather than by message, so rewording the
# echo cannot hide it.
if grep -q 'refs/heads/governance/sync-managed-files.*--method PATCH' \
  "$WORK/existing_pr_block.txt"; then
  fail "2.1 no standalone reset of the sync branch to main's SHA" \
    "the existing-PR path force-updates the branch ref directly; that empties the PR and GitHub closes it (#836)"
else
  pass "2.1 no standalone reset of the sync branch to main's SHA"
fi

if grep -qE 'Rebased PR branch onto main HEAD' "$WORK/existing_pr_block.txt"; then
  fail "2.2 the emptying rebase step is gone" \
    "the standalone rebase echo is still present"
else
  pass "2.2 the emptying rebase step is gone"
fi

echo ""
echo "=== Section 3: rebasing still happens, atomically ==="

# Dropping the rebase is not an acceptable fix: a branch based on an old main
# produces a diff that reverts unrelated commits. It has to move to main's SHA
# as part of the same ref update that adds the drift commit.
# The call is written across backslash-continued lines, so join continuations
# before matching -- grep is line-based and would miss it.
perl -0pe 's/\\\n\s*/ /g' "$WORK/existing_pr_block.txt" >"$WORK/existing_pr_joined.txt"

if grep -qE 'commit_tree[^|;]*"\$MAIN_SHA"' "$WORK/existing_pr_joined.txt"; then
  pass "3.1 the existing-PR path rebases via commit_tree's base argument"
else
  fail "3.1 the existing-PR path rebases via commit_tree's base argument" \
    "commit_tree is not given a base commit, so the branch would stay on its old base"
fi

if grep -qE 'local base_override|base_override="\$3"' "$SYNC"; then
  pass "3.2 commit_tree accepts a base-commit override"
else
  fail "3.2 commit_tree accepts a base-commit override" \
    "commit_tree still derives its parent solely from the branch head"
fi

# A force update is required once the parent is main rather than the branch tip.
if grep -qE '"force": *(true|\$force)' "$SYNC"; then
  pass "3.3 commit_tree can force the ref update when rebasing"
else
  fail "3.3 commit_tree can force the ref update when rebasing" \
    "a non-force PATCH cannot move the branch onto a new base"
fi

echo ""
echo "════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($TESTS_RUN total)"
echo "════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
