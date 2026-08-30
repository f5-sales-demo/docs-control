#!/usr/bin/env bash
# Hermetic contract separating ordinary linked-issue checks from exact manifest receipts.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
workflow="$root/.github/workflows/require-linked-issue.yml"
attestor="$root/.github/workflows/attest-manifest-linked-issue.yml"
publisher="$root/.github/workflows/build-managed-files-manifest.yml"

for token in schedule pull_request_target actions/checkout createCommitStatus createComment github.paginate 'statuses: write' 'issues: write'; do
  if grep -Fq -- "$token" "$workflow" "$attestor"; then
    printf 'FAIL: retired linked-issue surface remains: %s\n' "$token" >&2
    exit 1
  fi
done
grep -Fq "'Check linked issues'" "$workflow"
grep -Fq "'Validate manifest receipt candidate'" "$workflow"
grep -Fq "startsWith(github.event.pull_request.head.ref, 'sync/manifest-')" "$workflow"
if grep -Fq 'workflow_dispatch:' "$workflow"; then
  echo 'FAIL: pull-request workflow must not dispatch the required manifest context' >&2
  exit 1
fi
grep -Fq '  workflow_dispatch:' "$attestor"
grep -Fq 'expected_source_sha:' "$attestor"
grep -Fq 'expected_head_sha:' "$attestor"
grep -Fqx '      checks: write # publish the exact required receipt on the verified head' "$attestor"
grep -Fq 'pull-requests: read' "$attestor"
grep -Fq 'contents: read' "$attestor"
grep -Fq 'name: requiredName' "$attestor"
grep -Fq 'external_id: externalId' "$attestor"
grep -Fq 'filter: "all"' "$attestor"
grep -Fq 'gh workflow run attest-manifest-linked-issue.yml' "$publisher"
grep -Fq 'expected_source_sha=$PROTECTED_MAIN_SHA' "$publisher"
grep -Fq 'wait_for_exact_linked_issue_receipt' "$publisher"
node "$root/tests/manifest-receipt-attestor-behavior.mjs" "$root"
printf 'PASS: linked-issue gate and protected-main manifest attestor are separated\n'
grep -Fq 'for attempt in $(seq 1 36)' "$publisher"
grep -Fq 'Timed out waiting for the exact linked-issue receipt' "$publisher"
grep -Fq 'Protected main advanced after manifest receipt publication' "$publisher"
grep -Fq 'assert_exact_remote_manifest_ref "$EXPECTED_HEAD"' "$publisher"
grep -Fq 'assert_manifest_commit_parent "$EXPECTED_HEAD"' "$publisher"
grep -Fq 'Manifest PR ownership changed after receipt publication' "$publisher"
wait_line=$(grep -n 'wait_for_exact_linked_issue_receipt "$PR_NUM"' "$publisher" | tail -1 | cut -d: -f1)
merge_line=$(grep -n 'gh pr merge "$PR_NUM"' "$publisher" | tail -1 | cut -d: -f1)
if [ "$wait_line" -ge "$merge_line" ]; then
  echo 'FAIL: auto-merge is enabled before the exact receipt wait succeeds' >&2
  exit 1
fi
printf 'PASS: manifest publisher fails closed before auto-merge\n'
