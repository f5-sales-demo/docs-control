#!/usr/bin/env bash
# Security contracts for managed pull-request workflows.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0
pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; FAIL=1; }
require_literal() {
  if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}
reject_literal() {
  if grep -Fq -- "$2" "$1"; then fail "$3"; else pass "$3"; fi
}

for file in "$REPO_ROOT/workflows/require-linked-issue.yml" "$REPO_ROOT/.github/workflows/require-linked-issue.yml"; do
  require_literal "$file" '  pull_request:' "${file#"$REPO_ROOT/"} triggers on pull requests"
  require_literal "$file" '    types: [opened, reopened, edited, synchronize]' "${file#"$REPO_ROOT/"} covers link transitions"
  require_literal "$file" 'permissions: {}' "${file#"$REPO_ROOT/"} denies workflow token permissions"
  require_literal "$file" '    if: github.event.pull_request.head.repo.full_name == github.repository' "${file#"$REPO_ROOT/"} skips fork pull requests"
  require_literal "$file" '    name: Check linked issues' "${file#"$REPO_ROOT/"} emits the exact check context"
  require_literal "$file" '    runs-on: [self-hosted, Linux, X64, "${{ github.event.repository.name }}", ubuntu-24.04]' "${file#"$REPO_ROOT/"} routes to the repository runner"
  require_literal "$file" '      pull-requests: read' "${file#"$REPO_ROOT/"} grants only pull-request read access"
  require_literal "$file" 'closingIssuesReferences(first: 1)' "${file#"$REPO_ROOT/"} queries only the event PR's closing issue"
  require_literal "$file" "Add 'Closes #123'" "${file#"$REPO_ROOT/"} provides actionable guidance"
  for forbidden in schedule workflow_dispatch pull_request_target actions/checkout github.paginate createCommitStatus createComment EXCLUDE_BRANCHES 'issues: write' 'statuses: write'; do
    reject_literal "$file" "$forbidden" "${file#"$REPO_ROOT/"} excludes retired $forbidden surface"
  done
done

if cmp -s "$REPO_ROOT/workflows/require-linked-issue.yml" "$REPO_ROOT/.github/workflows/require-linked-issue.yml"; then
  pass 'active linked-issue workflow exactly matches its managed source'
else
  fail 'active linked-issue workflow must exactly match its managed source'
fi

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
