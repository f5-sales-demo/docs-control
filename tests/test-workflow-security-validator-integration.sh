#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [/path/to/terraform-provider-xcsh]" >&2
  exit 2
fi

DOCS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VALIDATOR="$DOCS_ROOT/scripts/workflow-security-validator.py"
FIXTURE="$DOCS_ROOT/tests/fixtures/workflow-security"
TMP=$(mktemp -d /tmp/workflow-security-integration-XXXXXX)
trap 'find "$TMP" -depth -delete' EXIT

run_zizmor() {
  local root=$1 findings=$2 diagnostics=$3 expected=$4
  local rc=0
  (
    cd "$root"
    uvx --from 'zizmor==1.29.0' zizmor --no-config --no-ignores \
      --persona=auditor --format=json .github/workflows/
  ) >"$findings" 2>"$diagnostics" || rc=$?
  [[ $rc -eq 13 ]] || {
    echo "expected Zizmor exit 13, got $rc" >&2
    return 1
  }
  python3 - "$findings" "$expected" <<'PY'
import json, sys
findings = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(findings, list)
assert sum(item.get("ident") == "self-hosted-runner" for item in findings) == int(sys.argv[2])
PY
}

validate_fixture() {
  local findings=$1 root=${2:-$FIXTURE}
  (
    cd "$root"
    uv run --with 'PyYAML==6.0.2' --no-project python "$VALIDATOR" \
      --repository f5-sales-demo/fixture \
      --policy "$FIXTURE/policy.json" \
      --governance "$FIXTURE/governance.json" \
      --zizmor-exit 13 \
      "$findings"
  )
}

# The checked-in capture proves compatibility with the precise Zizmor 1.29 schema.
validate_fixture "$FIXTURE/zizmor-1.29-findings.json"

# Running the pinned binary makes this a required end-to-end check in every checkout.
run_zizmor "$FIXTURE" "$TMP/fixture-findings.json" "$TMP/fixture-diagnostics.log" 2
validate_fixture "$TMP/fixture-findings.json"

mkdir -p "$TMP/mutated/.github"
cp -R "$FIXTURE/.github/workflows" "$TMP/mutated/.github/workflows"
cat >>"$TMP/mutated/.github/workflows/audit.yml" <<'YAML'
  unapproved-self-hosted:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    permissions: {}
    steps:
      - run: echo mutation
YAML
run_zizmor "$TMP/mutated" "$TMP/mutated-findings.json" "$TMP/mutated-diagnostics.log" 3
if validate_fixture "$TMP/mutated-findings.json" "$TMP/mutated"; then
  echo "mutation unexpectedly passed validator" >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  PROVIDER_ROOT=$(cd "$1" && pwd)
  POLICY="$DOCS_ROOT/.github/config/self-hosted-runner-policy.json"
  GOVERNANCE="$DOCS_ROOT/.claude/governance.json"
  run_zizmor "$PROVIDER_ROOT" "$TMP/provider-findings.json" "$TMP/provider-diagnostics.log" 3
  (
    cd "$PROVIDER_ROOT"
    uv run --with 'PyYAML==6.0.2' --no-project python "$VALIDATOR" \
      --repository f5-sales-demo/terraform-provider-xcsh \
      --policy "$POLICY" \
      --governance "$GOVERNANCE" \
      --zizmor-exit 13 \
      "$TMP/provider-findings.json"
  )
fi

echo "PASS: captured and live Zizmor 1.29 findings passed; ungoverned mutation failed closed"
