#!/usr/bin/env bash
# Hermetic safety contract for the PR-only linked-issue gate.
set -euo pipefail

workflow="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows/require-linked-issue.yml"
forbidden=(schedule workflow_dispatch pull_request_target actions/checkout EXCLUDE_BRANCHES createCommitStatus createComment github.paginate 'statuses: write' 'issues: write')
for token in "${forbidden[@]}"; do
  if grep -Fq -- "$token" "$workflow"; then
    printf 'FAIL: retired linked-issue surface remains: %s\n' "$token" >&2
    exit 1
  fi
done
grep -Fqx '    if: github.event.pull_request.head.repo.full_name == github.repository' "$workflow"
grep -Fqx '    name: Check linked issues' "$workflow"
grep -Fqx '    runs-on: [self-hosted, Linux, X64, "${{ github.event.repository.name }}", ubuntu-24.04]' "$workflow"
grep -Fqx '      pull-requests: read' "$workflow"
grep -Fq 'closingIssuesReferences(first: 1)' "$workflow"
printf 'PASS: linked-issue gate is PR-only, same-repository, and read-only\n'
