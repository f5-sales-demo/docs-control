#!/usr/bin/env bash
# Decides whether a pull-request author may auto-merge: TRUSTED iff the author
# has write or admin permission on the target repository. Resolves the effective
# permission via the GitHub API (repos/{repo}/collaborators/{user}/permission)
# using the authenticated `gh` on PATH ($GH_TOKEN). Fails CLOSED — any API error,
# a missing collaborator (404), or a none/read/triage permission is treated as
# UNTRUSTED (exit 1). This is the gate the auto-merge workflow consults before
# enabling `gh pr merge --auto`, so external / fork PRs are never auto-merged.
#
# Usage: pr-author-trusted.sh <owner/repo> <author-login>
set -euo pipefail

repo="${1:?usage: pr-author-trusted.sh <owner/repo> <author-login>}"
author="${2:?usage: pr-author-trusted.sh <owner/repo> <author-login>}"

# Resolve the author's effective permission. On ANY failure (network, auth, or a
# 404 because the author is not a collaborator on this repo) fall back to "none"
# so the decision fails closed rather than open.
perm=$(gh api "repos/${repo}/collaborators/${author}/permission" \
  --jq '.permission' 2>/dev/null || true)
perm="${perm:-none}"

case "$perm" in
  admin | write)
    echo "auto-merge: author '${author}' has '${perm}' on '${repo}' → TRUSTED"
    exit 0
    ;;
  *)
    echo "auto-merge: author '${author}' has '${perm}' on '${repo}' → UNTRUSTED — leaving PR for human review"
    exit 1
    ;;
esac
