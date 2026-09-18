#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

live_paths=(
  workflows/require-linked-issue.yml
  .claude/governance.json
  .github/actionlint.yaml
  .github/config/docs-sites.json
  .github/config/downstream-repos.json
  .github/config/repo-settings.json
  .github/config/self-hosted-runner-policy.json
  scripts/audit-runner-workflows.py
  scripts/ephemeral-runner-controller.py
  scripts/fleet_backlog_inventory.py
  scripts/workflow_security_validator.py
  tests/test_audit_runner_workflows.py
  tests/test_fleet_backlog_inventory.py
  tests/test-lint-mdx-prose.sh
  tests/test-linter-configs.sh
  tests/test-privileged-pr-workflows.sh
)

if findings=$(rg -n '\bmcn\b|f5-sales-demo/mcn|github\.io/mcn' "${live_paths[@]}"); then
  printf 'old live repository identity remains:\n%s\n' "$findings" >&2
  exit 1
fi

jq -e 'index("multi-cloud-networking") != null and index("mcn") == null' \
  .github/config/downstream-repos.json >/dev/null
jq -e '.repo_classes.repos["multi-cloud-networking"] == "content" and (.repo_classes.repos.mcn | not)' \
  .claude/governance.json >/dev/null
jq -e '.secrets_manifest.repo_roles["multi-cloud-networking"] == ["governance"] and (.secrets_manifest.repo_roles.mcn | not)' \
  .github/config/repo-settings.json >/dev/null
jq -e '.repositories["f5-sales-demo/multi-cloud-networking"].runner.arc_scale_sets | keys == ["container-build", "socketless"]' \
  .github/config/self-hosted-runner-policy.json >/dev/null
jq -e '.hosted_exceptions["f5-sales-demo/multi-cloud-networking"] | type == "object"' \
  .github/config/self-hosted-runner-policy.json >/dev/null

printf 'multi-cloud-networking governance identity checks passed\n'
