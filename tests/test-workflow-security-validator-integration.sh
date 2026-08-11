#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [/path/to/terraform-provider-xcsh]" >&2
  exit 2
fi

DOCS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROVIDER_CANDIDATE=${1:-"$DOCS_ROOT/../terraform-provider-xcsh"}
if [[ ! -d "$PROVIDER_CANDIDATE/.github/workflows" ]]; then
  echo "SKIP: provider checkout unavailable for real Zizmor integration"
  exit 0
fi
PROVIDER_ROOT=$(cd "$PROVIDER_CANDIDATE" && pwd)
POLICY="$DOCS_ROOT/.github/config/self-hosted-runner-policy.json"
VALIDATOR="$DOCS_ROOT/scripts/workflow-security-validator.py"
TMP=$(mktemp -d /tmp/workflow-security-integration-XXXXXX)
trap 'find "$TMP" -depth -delete' EXIT

run_zizmor() {
  local root=$1 findings=$2 diagnostics=$3
  local rc=0
  (
    cd "$root"
    uvx --from 'zizmor==1.29.0' zizmor --no-config --no-ignores \
      --persona=auditor --format=json .github/workflows/
  ) >"$findings" 2>"$diagnostics" || rc=$?
  [[ $rc -eq 13 ]] || { echo "expected Zizmor exit 13, got $rc" >&2; return 1; }
  python3 - "$findings" <<'PY'
import json, sys
findings = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(findings, list) and findings
PY
}

run_zizmor "$PROVIDER_ROOT" "$TMP/findings.json" "$TMP/diagnostics.log"
[[ $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$TMP/findings.json") -eq 3 ]]
(
  cd "$PROVIDER_ROOT"
  uv run --with 'PyYAML==6.0.2' --no-project python "$VALIDATOR" \
    --repository f5-sales-demo/terraform-provider-xcsh \
    --policy "$POLICY" "$TMP/findings.json"
)

mkdir -p "$TMP/mutated/.github"
cp -R "$PROVIDER_ROOT/.github/workflows" "$TMP/mutated/.github/workflows"
cat >>"$TMP/mutated/.github/workflows/discover-defaults.yml" <<'YAML'
  unapproved-self-hosted:
    runs-on: [self-hosted, Linux, X64, terraform-provider-xcsh]
    permissions: {}
    steps:
      - run: echo mutation
YAML
run_zizmor "$TMP/mutated" "$TMP/mutated-findings.json" "$TMP/mutated-diagnostics.log"
if (
  cd "$TMP/mutated"
  uv run --with 'PyYAML==6.0.2' --no-project python "$VALIDATOR" \
    --repository f5-sales-demo/terraform-provider-xcsh \
    --policy "$POLICY" "$TMP/mutated-findings.json"
); then
  echo "mutation unexpectedly passed validator" >&2
  exit 1
fi

echo "PASS: real Zizmor 1.29 integration approved exactly three findings and rejected mutation"
