#!/usr/bin/env bash
# PreToolUse hook: blocks git commit/push and gh pr create from the main
# session, so all git/GitHub operations are delegated to the
# f5xc-github-ops:github-ops subagent (per CLAUDE.md).
# Allows the delegated subagent through via the agent_type stdin field.
# Distributed by docs-control via managed_files sync.
# Exit 0 = allow, Exit 2 = block (stderr shown to Claude).
set -euo pipefail

# ── Guard: exit if no stdin data (e.g., linter running script) ───────
if ! read -t 0 2>/dev/null; then
  exit 0
fi

INPUT=$(cat)

# ── Self-exclusion: allow all git/GitHub operations in docs-control ─
# docs-control IS the source of truth; delegation policy applies only
# to downstream repos that consume it via managed_files sync.
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if echo "$REMOTE_URL" | grep -q "docs-control"; then
  exit 0
fi

# ── Allow the trusted delegated subagent ────────────────────────────
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || echo "")
if [ "$AGENT_TYPE" = "f5xc-github-ops:github-ops" ]; then
  exit 0
fi

# ── Extract the Bash command ────────────────────────────────────────
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
if [ -z "$COMMAND" ]; then
  exit 0
fi

# ── Block delegated git/gh operations ───────────────────────────────
BLOCK_REGEX='(^|[^A-Za-z0-9_])(git[[:space:]]+(commit|push)|gh[[:space:]]+pr[[:space:]]+create)([^A-Za-z0-9_]|$)'

if [[ "$COMMAND" =~ $BLOCK_REGEX ]]; then
  cat >&2 <<EOF
BLOCKED: "${COMMAND}" is a delegated git/GitHub operation.

CLAUDE.md requires all git commit, git push, and gh pr create calls to
go through the f5xc-github-ops:github-ops subagent. Dispatch that agent
with a clear task description instead of running the command directly.
EOF
  exit 2
fi

exit 0
