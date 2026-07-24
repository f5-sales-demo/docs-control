#!/usr/bin/env bash
# reviewer-comment-count.sh — count ONLY the Claude reviewer's own comments
# (its one summary comment + its inline review comments) on a PR.
#
#   reviewer-comment-count.sh <issue-comments.json> <pull-comments.json>
#     -> echoes a single integer (0 on unreadable/malformed input)
#
# Each argument is a file holding the JSON array returned by the GitHub
# comments API (issues/{pr}/comments and pulls/{pr}/comments respectively).
#
# WHY scoped to the reviewer: the retry classifier (review-retry-decision.sh)
# compares a BEFORE vs AFTER comment count to tell a pre-posting failure (safe to
# retry) from a partial review (already posted — do not retry). If it counted
# EVERY comment, a comment posted by another actor DURING the review window — the
# super-linter summary (also github-actions[bot]), dependabot, or a human — would
# inflate the AFTER count and misclassify a clean pre-posting failure as a
# "partial review", failing the check spuriously. Counting only the reviewer's
# own comments removes that coupling.
#
# Identity: the reviewer posts via the workflow GITHUB_TOKEN, so its author is
# github-actions[bot] — but so is super-linter's summary, so author alone is not
# enough for issue comments. The reviewer's summary is matched by content
# markers ("Code review" / "No issues found" / a severity emoji); super-linter's
# summary ("Super-linter summary", ✅/❌) matches none of them. Inline review
# comments are posted only by the reviewer among bots, so for pull comments the
# bot-author filter suffices.
set -euo pipefail

issues_json="${1:?usage: reviewer-comment-count.sh <issue-comments.json> <pull-comments.json>}"
pulls_json="${2:?usage: reviewer-comment-count.sh <issue-comments.json> <pull-comments.json>}"

BOT="github-actions[bot]"
# Markers that identify the reviewer's summary issue-comment (see REVIEW.md /
# the plugin command summary template). Kept broad enough to match both the
# "no issues" summary and the severity-table summary.
MARKER='Code review|No issues found|🔴|🟠|🟡'

count_issue=$(jq --arg b "$BOT" --arg m "$MARKER" \
  '[.[] | select((.user.login // "") == $b and ((.body // "") | test($m)))] | length' \
  "$issues_json" 2>/dev/null || echo 0)

count_pull=$(jq --arg b "$BOT" \
  '[.[] | select((.user.login // "") == $b)] | length' \
  "$pulls_json" 2>/dev/null || echo 0)

# Guard against non-numeric (malformed input -> 0, fail toward "nothing posted").
[[ "$count_issue" =~ ^[0-9]+$ ]] || count_issue=0
[[ "$count_pull" =~ ^[0-9]+$ ]] || count_pull=0
echo $((count_issue + count_pull))
