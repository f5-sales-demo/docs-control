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
grep -Fqx '    runs-on: managed-socketless' "$workflow"
grep -Fqx '      pull-requests: read # inspect and attest the current pull request' "$workflow"
grep -Fqx '      contents: read # resolve repository metadata for linked-issue validation' "$workflow"
grep -Fq 'pull_request_number:' "$workflow"
grep -Fq 'expected_head_sha:' "$workflow"
grep -Fq 'dispatched linked-issue receipt does not match' "$workflow"
grep -Fq 'pull.data.head.ref === "sync/manifest"' "$workflow"
grep -Fq 'exact synthetic manifest publication' "$workflow"
grep -Fq 'trusted synthetic manifest publication branch' "$workflow"
grep -Fq 'closingIssuesReferences(first: 1)' "$workflow"
grep -Fq "group: require-linked-issue-\${{ github.event_name }}-\${{ github.event.pull_request.number || inputs.pull_request_number }}-\${{ inputs.expected_head_sha || 'live' }}" "$workflow"
grep -Fq 'cancel-in-progress: true' "$workflow"
printf 'PASS: linked-issue gate is same-repository, exact-receipt, and read-only\n'
