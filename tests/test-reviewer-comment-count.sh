#!/usr/bin/env bash
# Hermetic test for scripts/reviewer-comment-count.sh — the reviewer-scoped
# comment counter feeding the retry classifier. Proves that comments from other
# actors (super-linter summary, dependabot, humans) are NOT counted, so a
# concurrent comment cannot misclassify a pre-posting failure as a partial
# review. No network.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/reviewer-comment-count.sh"
BOT="github-actions[bot]"

FAIL=0
WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

w() {
  printf '%s' "$2" >"$WORK/$1"
  echo "$WORK/$1"
}

assert_eq() { # <label> <expected> <issues.json> <pulls.json>
  local got
  got=$(bash "$SCRIPT" "$3" "$4" 2>/dev/null || echo "ERR")
  if [ "$got" = "$2" ]; then echo "[OK] $1 → $got"; else
    echo "[FAIL] $1 — expected $2, got $got"
    FAIL=1
  fi
}

EMPTY=$(w empty.json '[]')

# The bug scenario: only a super-linter summary + a human comment exist (both
# NOT the reviewer). The reviewer has posted nothing → count MUST be 0.
NON_REVIEWER=$(w nonrev.json "$(
  cat <<JSON
[
  {"user":{"login":"$BOT"},"body":"<!-- super-linter-summary-comment -->\n# Super-linter summary\n| CHECKOV | Pass ✅ |"},
  {"user":{"login":"a-human"},"body":"Looks good, but consider X"}
]
JSON
)")
assert_eq "non-reviewer issue comments not counted (bug scenario)" 0 "$NON_REVIEWER" "$EMPTY"

# Reviewer summary present alongside super-linter + human → exactly 1.
WITH_SUMMARY=$(w withsum.json "$(
  cat <<JSON
[
  {"user":{"login":"$BOT"},"body":"<!-- super-linter-summary-comment -->\n# Super-linter summary"},
  {"user":{"login":"$BOT"},"body":"## Code review\n\nNo issues found. Checked for bugs, CLAUDE.md compliance, and authenticated verification."},
  {"user":{"login":"a-human"},"body":"thanks"}
]
JSON
)")
assert_eq "reviewer summary counted, others excluded" 1 "$WITH_SUMMARY" "$EMPTY"

# Severity-table summary (emoji marker) also counts.
EMOJI_SUMMARY=$(w emoji.json "$(
  cat <<JSON
[
  {"user":{"login":"$BOT"},"body":"## Code review\n\n| Severity | Count |\n| 🔴 | 1 |"}
]
JSON
)")
assert_eq "emoji severity summary counted" 1 "$EMOJI_SUMMARY" "$EMPTY"

# Inline (pull) comments: reviewer bot comments counted, human inline excluded.
PULLS=$(w pulls.json "$(
  cat <<JSON
[
  {"user":{"login":"$BOT"},"body":"🔴 incorrect logic here"},
  {"user":{"login":"$BOT"},"body":"🟡 nit: rename"},
  {"user":{"login":"a-human"},"body":"I disagree"}
]
JSON
)")
assert_eq "reviewer inline counted, human inline excluded" 2 "$EMPTY" "$PULLS"

# Combined: 1 summary + 2 inline = 3.
assert_eq "combined summary + inline" 3 "$WITH_SUMMARY" "$PULLS"

# Malformed input → 0 (fail toward "nothing posted").
BAD=$(w bad.json '{not json')
assert_eq "malformed issues → 0" 0 "$BAD" "$EMPTY"

# Missing pulls file tolerated: summary still counts (1), missing file → 0 pulls.
assert_eq "missing pulls file tolerated (summary=1)" 1 "$WITH_SUMMARY" "$WORK/does-not-exist.json"

if [ "$FAIL" -ne 0 ]; then
  echo "reviewer-comment-count tests FAILED"
  exit 1
fi
echo "reviewer-comment-count tests passed"
