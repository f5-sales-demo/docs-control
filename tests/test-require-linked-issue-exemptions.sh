#!/usr/bin/env bash
# Hermetic safety contract for the same-repository linked-issue gate and its
# exact-receipt manual path used by the manifest publisher.
set -euo pipefail

workflow="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows/require-linked-issue.yml"
forbidden=(schedule pull_request_target actions/checkout EXCLUDE_BRANCHES createCommitStatus createComment github.paginate 'statuses: write' 'issues: write')
for token in "${forbidden[@]}"; do
  if grep -Fq -- "$token" "$workflow"; then
    printf 'FAIL: retired linked-issue surface remains: %s\n' "$token" >&2
    exit 1
  fi
done
grep -Fq "github.event_name == 'workflow_dispatch'" "$workflow"
grep -Fq 'github.event.pull_request.head.repo.full_name == github.repository' "$workflow"
grep -Fqx '    name: Check linked issues' "$workflow"
grep -Fqx '    runs-on: [self-hosted, Linux, X64, "${{ github.event.repository.name }}", ubuntu-24.04]' "$workflow"
grep -Fqx '      pull-requests: read' "$workflow"
grep -Fqx '      contents: read' "$workflow"
grep -Fq 'expected_base_sha:' "$workflow"
grep -Fq 'expected_head_sha:' "$workflow"
grep -Fq 'dispatched linked-issue receipt does not match' "$workflow"
grep -Fq 'pull.data.head.ref === "sync/manifest"' "$workflow"
grep -Fq 'exact synthetic manifest publication' "$workflow"
grep -Fq 'closingIssuesReferences(first: 1)' "$workflow"
printf 'PASS: linked-issue gate is same-repository, exact-receipt, and read-only\n'
