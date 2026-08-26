#!/usr/bin/env bash
# Security contracts for managed pull-request workflows.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0
pass() { printf '[OK] %s\n' "$1"; }
fail() {
  printf '[FAIL] %s\n' "$1" >&2
  FAIL=1
}
require_literal() {
  if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}
reject_literal() {
  if grep -Fq -- "$2" "$1"; then fail "$3"; else pass "$3"; fi
}

managed="$REPO_ROOT/workflows/require-linked-issue.yml"
central="$REPO_ROOT/.github/workflows/require-linked-issue.yml"

for file in "$managed" "$central"; do
  require_literal "$file" '  pull_request:' "${file#"$REPO_ROOT/"} triggers on pull requests"
  require_literal "$file" '    types: [opened, reopened, edited, synchronize]' "${file#"$REPO_ROOT/"} covers link transitions"
  require_literal "$file" 'permissions: {}' "${file#"$REPO_ROOT/"} denies default workflow token permissions"
  require_literal "$file" 'github.event.pull_request.head.repo.full_name == github.repository' "${file#"$REPO_ROOT/"} skips fork pull requests"
  require_literal "$file" '    name: Check linked issues' "${file#"$REPO_ROOT/"} emits the exact check context"
  require_literal "$file" '    runs-on: [self-hosted, Linux, X64, "${{ github.event.repository.name }}", ubuntu-24.04]' "${file#"$REPO_ROOT/"} routes to the repository runner"
  require_literal "$file" '      pull-requests: read' "${file#"$REPO_ROOT/"} grants pull-request read access"
  require_literal "$file" 'closingIssuesReferences(first: 1)' "${file#"$REPO_ROOT/"} queries only one closing issue"
  require_literal "$file" "Add 'Closes #123'" "${file#"$REPO_ROOT/"} provides actionable guidance"
  for forbidden in schedule pull_request_target actions/checkout github.paginate createCommitStatus createComment EXCLUDE_BRANCHES 'issues: write' 'statuses: write'; do
    reject_literal "$file" "$forbidden" "${file#"$REPO_ROOT/"} excludes retired $forbidden surface"
  done
done

reject_literal "$managed" workflow_dispatch 'managed caller excludes central-only workflow dispatch'
require_literal "$managed" "!startsWith(github.event.pull_request.head.ref, 'governance/reconcile-')" \
  'managed caller skips centrally attested reconciliation PRs'
require_literal "$managed" '  group: require-linked-issue-${{ github.event.pull_request.number }}' \
  'managed caller serializes checks per pull request'
require_literal "$managed" '  cancel-in-progress: true' \
  'managed caller cancels superseded checks'

require_literal "$central" '  workflow_dispatch:' 'central implementation exposes exact-receipt dispatch'
require_literal "$central" 'pull_request_number:' 'central dispatch requires a PR number'
require_literal "$central" 'expected_head_sha:' 'central dispatch requires an exact head SHA'
require_literal "$central" 'pull.data.head.sha !== process.env.EXPECTED_HEAD_SHA' \
  'central dispatch verifies the current PR head'
require_literal "$central" 'pull.data.head.repo?.full_name !== `${owner}/${repo}`' \
  'central dispatch verifies same-repository ownership'
require_literal "$central" '      contents: read' 'central dispatch receives only the extra content read scope it needs'
require_literal "$central" "  group: require-linked-issue-\${{ github.event_name }}-\${{ github.event.pull_request.number || inputs.pull_request_number }}-\${{ inputs.expected_head_sha || 'live' }}" \
  'central implementation separates live PR and exact-receipt concurrency identities'
require_literal "$central" '  cancel-in-progress: true' \
  'central implementation cancels only superseded matching checks'
if jq -e '.hosted_exceptions["f5-sales-demo/docs-control"][".github/workflows/require-linked-issue.yml"]' \
  "$REPO_ROOT/.github/config/self-hosted-runner-policy.json" >/dev/null; then
  fail 'docs-control runner policy excludes the retired linked-issue hosted exception'
else
  pass 'docs-control runner policy excludes the retired linked-issue hosted exception'
fi
pass 'central and downstream linked-issue workflows have intentionally separate contracts'

if node "$REPO_ROOT/tests/privileged-pr-workflow-behavior.mjs" "$REPO_ROOT"; then
  pass 'linked-issue workflow behavior matches its exact-PR API contract'
else
  fail 'linked-issue workflow behavior must match its exact-PR API contract'
fi

if [ "$FAIL" -eq 0 ]; then
  printf 'PASS: linked-issue workflow contract is secure\n'
else
  printf 'FAIL: linked-issue workflow contract is incomplete\n' >&2
fi
exit "$FAIL"
