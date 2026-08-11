#!/usr/bin/env bash
# Hermetic coverage for next-major-only translation release eligibility.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/translation-release-policy.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PASS=0
FAIL=0

pass() {
  printf '  PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf '  FAIL: %s — %s\n' "$1" "$2"
  FAIL=$((FAIL + 1))
}

assert_decision() {
  local expected=$1 label=$2 head_ref=$3 tags=$4
  printf '%s\n' "$tags" >"$WORK/tags"
  local output
  if ! output=$(bash "$SCRIPT" --head-ref "$head_ref" --tags-file "$WORK/tags" 2>&1); then
    fail "$label" "$output"
    return
  fi
  if grep -qxF "eligible=$expected" <<<"$output"; then
    pass "$label"
  else
    fail "$label" "$output"
  fi
}

echo "Translation major-release policy tests"

assert_decision true "next stable major is eligible" \
  release/v20.0.0 $'v19.105.7\nv19.0.0\nv18.9.2'
assert_decision false "minor release is ineligible" \
  release/v20.1.0 $'v19.105.7\nv19.0.0'
assert_decision false "patch release is ineligible" \
  release/v20.0.1 $'v19.105.7\nv19.0.0'
assert_decision false "ordinary development branch is ineligible" \
  feature/1344-major-release-translations $'v19.105.7\nv19.0.0'
assert_decision false "existing major cannot be reconciled twice" \
  release/v20.0.0 $'v20.0.0\nv19.105.7'
assert_decision false "skipping a major is ineligible" \
  release/v21.0.0 $'v19.105.7\nv19.0.0'
assert_decision true "first stable major starts at v1" \
  release/v1.0.0 $'package/v9.0.0\nv1.0.0-rc.1\nrelease-2026.08'
assert_decision false "first stable major cannot start above v1" \
  release/v2.0.0 $'package/v1.0.0\nv1.0.0-rc.1'
assert_decision true "prerelease and namespaced tags do not alter root stable history" \
  release/v3.0.0 $'v2.9.0\nv3.0.0-rc.1\ngithub/v99.0.0'
assert_decision false "leading-zero major is rejected" \
  release/v03.0.0 $'v2.9.0'

WATCHER="$REPO_ROOT/.github/workflows/antigravity-fleet-watcher.yml"
CALLER="$REPO_ROOT/workflows/antigravity-translate.yml"
TRANSLATE="$REPO_ROOT/.github/workflows/antigravity-translate.yml"
AUDIT="$REPO_ROOT/.github/workflows/translation-audit.yml"

if grep -qF 'scripts/translation-release-policy.sh' "$WATCHER" &&
  grep -qF -- '--argjson reconcile_all true' "$WATCHER"; then
  pass "fleet watcher routes only policy-approved full reconciliation"
else
  fail "fleet watcher routes only policy-approved full reconciliation" \
    "release policy or reconciliation dispatch is absent"
fi

if grep -qF 'reconcile_all:' "$CALLER" && grep -qF 'reconcile_all:' "$TRANSLATE" &&
  grep -qF 'RECONCILE_ALL:' "$TRANSLATE"; then
  pass "caller and reusable workflow bind reconciliation mode"
else
  fail "caller and reusable workflow bind reconciliation mode" \
    "reconcile_all is not bound end to end"
fi

if grep -qF 'working-directory: consumer' "$AUDIT" &&
  grep -qF 'bash ../governance/scripts/translation-release-policy.sh' "$AUDIT" &&
  grep -qF 'bash ../governance/scripts/validate-translations.sh --all' "$AUDIT"; then
  pass "freshness audit is major-release-only and validates the full consumer corpus"
else
  fail "freshness audit is major-release-only and validates the full consumer corpus" \
    "trusted audit policy or full validation route is absent"
fi

if grep -qF 'JOB_CONTEXT: ${{ toJSON(job) }}' "$AUDIT" &&
  grep -qF "repository=\$(jq -r '.workflow_repository // \"\"'" "$AUDIT" &&
  grep -qF "sha=\$(jq -r '.workflow_sha // \"\"'" "$AUDIT" &&
  grep -qF 'repository: ${{ steps.governance.outputs.repository }}' "$AUDIT" &&
  grep -qF 'ref: ${{ steps.governance.outputs.sha }}' "$AUDIT" &&
  grep -qF 'test "$GOVERNANCE_REPOSITORY" = "f5-sales-demo/docs-control"' "$AUDIT" &&
  grep -qF 'test "$(git -C governance rev-parse HEAD)" = "$GOVERNANCE_SHA"' "$AUDIT"; then
  pass "freshness audit binds tooling to its exact reusable-workflow receipt"
else
  fail "freshness audit binds tooling to its exact reusable-workflow receipt" \
    "trusted workflow repository or immutable receipt verification is absent"
fi

if [ "$(grep -cF 'persist-credentials: false' "$AUDIT")" -eq 2 ] &&
  grep -qF 'path: consumer' "$AUDIT" && grep -qF 'path: governance' "$AUDIT"; then
  pass "consumer and governance checkouts are isolated and credential-free"
else
  fail "consumer and governance checkouts are isolated and credential-free" \
    "checkout isolation or credential suppression is incomplete"
fi

if grep -Eq '(^|[[:space:]])bash scripts/(translation-release-policy|validate-translations)\.sh' "$AUDIT"; then
  fail "freshness audit never executes pull-request-controlled policy scripts" \
    "audit invokes a translation policy script from the consumer checkout"
else
  pass "freshness audit never executes pull-request-controlled policy scripts"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
