#!/usr/bin/env bash
# Security contracts for workflows that need write access while handling pull requests.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0

pass() {
  printf '[OK] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  FAIL=1
}

require_literal() {
  local file="$1"
  local literal="$2"
  local contract="$3"
  if grep -Fq -- "$literal" "$file"; then
    pass "$contract"
  else
    fail "$contract"
  fi
}

reject_literal() {
  local file="$1"
  local literal="$2"
  local contract="$3"
  if grep -Fq -- "$literal" "$file"; then
    fail "$contract"
  else
    pass "$contract"
  fi
}

PRIVILEGED_FILES=(
  "$REPO_ROOT/workflows/dependabot-auto-merge.yml"
  "$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
  "$REPO_ROOT/workflows/require-linked-issue.yml"
  "$REPO_ROOT/.github/workflows/require-linked-issue.yml"
)

for file in "${PRIVILEGED_FILES[@]}"; do
  require_literal "$file" '  schedule:' "${file#"$REPO_ROOT/"} runs from the protected default branch"
  require_literal "$file" "- cron: '*/5 * * * *'" "${file#"$REPO_ROOT/"} bounds automation latency to five minutes"
  require_literal "$file" '  workflow_dispatch:' "${file#"$REPO_ROOT/"} supports an immediate operator retry"
  require_literal "$file" 'permissions: {}' "${file#"$REPO_ROOT/"} denies workflow-level token permissions"
  reject_literal "$file" 'pull_request_target' "${file#"$REPO_ROOT/"} has no dangerous trigger"
  reject_literal "$file" 'workflow_run:' "${file#"$REPO_ROOT/"} has no privileged workflow chain"
  reject_literal "$file" 'actions/checkout@' "${file#"$REPO_ROOT/"} never checks out PR content"
  reject_literal "$file" 'download-artifact' "${file#"$REPO_ROOT/"} never consumes PR artifacts"
  reject_literal "$file" 'actions/cache' "${file#"$REPO_ROOT/"} never restores PR-controlled caches"
done

for file in \
  "$REPO_ROOT/workflows/dependabot-auto-merge.yml" \
  "$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"; do
  require_literal "$file" 'const DEPENDABOT_ID = 49699333;' "${file#"$REPO_ROOT/"} authenticates Dependabot by immutable actor ID"
  require_literal "$file" 'github.rest.pulls.createReview' "${file#"$REPO_ROOT/"} preserves approval behavior"
  require_literal "$file" 'review.commit_id === pull.head.sha' "${file#"$REPO_ROOT/"} approves each head at most once"
  require_literal "$file" 'enablePullRequestAutoMerge' "${file#"$REPO_ROOT/"} preserves gated auto-merge behavior"
  require_literal "$file" 'if (pull.auto_merge)' "${file#"$REPO_ROOT/"} does not re-enable existing auto-merge"
done

for file in \
  "$REPO_ROOT/workflows/require-linked-issue.yml" \
  "$REPO_ROOT/.github/workflows/require-linked-issue.yml"; do
  require_literal "$file" '#checkov:skip=CKV_GHA_7:Targeted inputs are exact PR receipts validated before a status is written.' \
    "${file#"$REPO_ROOT/"} carries its pristine-repository Checkov justification"
  published_context=$(sed -n 's/.*const STATUS_CONTEXT = "\([^"]*\)";.*/\1/p' "$file")
  for context_scope in contexts self_contexts; do
    case "$context_scope" in
    contexts) context_label="consumer" ;;
    self_contexts) context_label="self-repository" ;;
    esac
    required_context=$(jq -r --arg scope "$context_scope" '
      .branch_protection[0].required_status_checks[$scope]
      | map(select(endswith("Check linked issues")))
      | if length == 1 then .[0] else empty end
    ' "$REPO_ROOT/.github/config/repo-settings.json")
    if [ -n "$required_context" ] && [ "$published_context" = "$required_context" ]; then
      pass "${file#"$REPO_ROOT/"} publishes the exact required $context_label context"
    else
      fail "${file#"$REPO_ROOT/"} publishes the exact required $context_label context"
    fi
  done
  require_literal "$file" 'const headSha = pull.head.sha;' "${file#"$REPO_ROOT/"} publishes status on the current PR head"
  require_literal "$file" 'github.paginate(github.rest.pulls.list' "${file#"$REPO_ROOT/"} evaluates every open pull request"
  require_literal "$file" 'postStatus("pending"' "${file#"$REPO_ROOT/"} publishes a pending status before evaluation"
  require_literal "$file" 'postStatus("success"' "${file#"$REPO_ROOT/"} publishes a passing status"
  require_literal "$file" 'postStatus("failure"' "${file#"$REPO_ROOT/"} publishes a failing status"
  require_literal "$file" '<!-- require-linked-issue -->' "${file#"$REPO_ROOT/"} preserves the deduplicated guidance comment"
done

for file in \
  "$REPO_ROOT/workflows/enforce-repo-settings.yml" \
  "$REPO_ROOT/.github/workflows/enforce-repo-settings.yml"; do
  require_literal "$file" '#checkov:skip=CKV_GHA_7:Exact source receipts are validated before any governed read or mutation.' \
    "${file#"$REPO_ROOT/"} carries its pristine-repository Checkov justification"
done

AUTO_MERGE_CALLER="$REPO_ROOT/workflows/auto-merge.yml"
require_literal "$AUTO_MERGE_CALLER" 'group: caller-auto-merge-${{ github.repository }}-${{ github.event.pull_request.number || github.run_id }}' \
  'managed auto-merge caller limits concurrency without colliding with the reusable'
require_literal "$AUTO_MERGE_CALLER" '    environment: repository-settings' \
  'managed auto-merge token preflight uses the existing protected environment'

reject_literal "$REPO_ROOT/zizmor.yaml" 'disable:' 'zizmor configuration disables no audits'
reject_literal "$REPO_ROOT/zizmor.yaml" 'ignore:' 'zizmor configuration ignores no findings'
require_literal "$REPO_ROOT/workflows/workflow-security-audit.yml" '--no-config --no-ignores --persona=auditor' 'managed audit refuses configuration and inline suppressions'
require_literal "$REPO_ROOT/workflows/workflow-security-audit.yml" 'workflows/*.yml' 'managed audit covers workflow sources as well as active workflows'
reject_literal "$REPO_ROOT/workflows/workflow-security-audit.yml" '|| true' 'managed audit does not swallow findings'
reject_literal "$REPO_ROOT/workflows/workflow-security-audit.yml" '--min-severity' 'managed audit gates every finding severity'

if cmp -s \
  "$REPO_ROOT/workflows/dependabot-auto-merge.yml" \
  "$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml" &&
  cmp -s \
    "$REPO_ROOT/workflows/require-linked-issue.yml" \
    "$REPO_ROOT/.github/workflows/require-linked-issue.yml"; then
  pass 'active privileged workflows exactly match their managed sources'
else
  fail 'active privileged workflows must exactly match their managed sources'
fi

if node "$REPO_ROOT/tests/privileged-pr-workflow-behavior.mjs" "$REPO_ROOT"; then
  pass 'privileged workflow behavior matches its API contract'
else
  fail 'privileged workflow behavior must match its API contract'
fi

if node "$REPO_ROOT/tests/antigravity-ci-feature-uat.mjs" "$REPO_ROOT"; then
  pass 'Antigravity reviewer and translator feature behavior matches its trust contract'
else
  fail 'Antigravity reviewer and translator feature behavior must match its trust contract'
fi

if [ "$FAIL" -eq 0 ]; then
  printf 'PASS: privileged pull-request workflow contracts are secure\n'
else
  printf 'FAIL: privileged pull-request workflow contracts are incomplete\n' >&2
fi
exit "$FAIL"
