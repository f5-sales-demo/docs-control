#!/usr/bin/env bash
# Contracts for exact Pages publication identity and governed source receipts.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEPLOY_WORKFLOW="$REPO_ROOT/.github/workflows/github-pages-deploy.yml"
SELF_CALLER="$REPO_ROOT/.github/workflows/docs-site-deploy.yml"
PAGES_CALLER="$REPO_ROOT/workflows/github-pages-deploy.yml"
GOVERNANCE_CALLER="$REPO_ROOT/workflows/enforce-repo-settings.yml"
FAIL=0

ok() { echo "[OK] $1"; }
bad() {
  echo "[FAIL] $1"
  FAIL=1
}

input_block=$(sed -n '/^      content-ref:/,/^        type: string/p' "$DEPLOY_WORKFLOW")
checkout_block=$(sed -n '/^      - name: Checkout content repo/,/^      - name: Login to GHCR/p' "$DEPLOY_WORKFLOW")
validation_block=$(sed -n '/^      - name: Resolve immutable content commit/,/^      - name: Checkout content repo/p' "$DEPLOY_WORKFLOW")
revision_block=$(sed -n '/^      - name: Stage governance assets for \/api\//,/^      - name: Upload artifact/p' "$DEPLOY_WORKFLOW")

if grep -q '^        required: true$' <<<"$input_block" &&
  grep -q '^        type: string$' <<<"$input_block"; then
  ok "Pages deploy requires an explicit workflow_call content-ref"
else
  bad "Pages deploy workflow_call content-ref is not required"
fi

if grep -qF 'CONTENT_REF="$REQUESTED_REF"' <<<"$validation_block" &&
  grep -qF '^[0-9a-f]{40}$' <<<"$validation_block" &&
  ! grep -qE 'GITHUB_SHA|\|\|' <<<"$validation_block"; then
  ok "Pages deploy accepts only a full immutable commit"
else
  bad "Pages deploy has a mutable or fallback content identity"
fi

if grep -qF 'BUILDER_IMAGE="$REQUESTED_IMAGE"' <<<"$validation_block" &&
  grep -qF '^ghcr\.io/f5-sales-demo/docs-builder@sha256:[0-9a-f]{64}$' <<<"$validation_block" &&
  grep -qF 'builder_image=$BUILDER_IMAGE' <<<"$validation_block"; then
  ok "Pages deploy accepts only the approved digest-pinned builder"
else
  bad "Pages deploy permits a mutable or unapproved builder image"
fi

if grep -qF 'ref: ${{ steps.content.outputs.content_ref }}' <<<"$checkout_block" &&
  grep -qF 'CHECKED_OUT_SHA=$(git rev-parse HEAD)' <<<"$checkout_block" &&
  grep -qF 'if [ "$CHECKED_OUT_SHA" != "$CONTENT_REF" ]' <<<"$checkout_block"; then
  ok "Pages checkout resolves and verifies the requested commit"
else
  bad "Pages checkout is not bound to the requested commit"
fi

if grep -qF 'DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}' <<<"$checkout_block" &&
  grep -qF 'refs/remotes/origin/main' <<<"$checkout_block" &&
  grep -qF '[ "$PROTECTED_MAIN_SHA" != "$CONTENT_REF" ]' <<<"$checkout_block"; then
  ok "Pages publication proves content-ref is current protected main"
else
  bad "manual Pages dispatch can publish an unmerged commit"
fi

if grep -qF '${{ steps.content.outputs.builder_image }}' "$DEPLOY_WORKFLOW" &&
  ! grep -qF 'inputs.builder-image ||' "$DEPLOY_WORKFLOW"; then
  ok "Pages build uses the validated builder identity without fallback"
else
  bad "Pages build bypasses the validated builder identity"
fi

if ! grep -qE '^  (push|workflow_dispatch):' "$DEPLOY_WORKFLOW" &&
  [ -f "$SELF_CALLER" ] &&
  grep -qF 'uses: ./.github/workflows/github-pages-deploy.yml' "$SELF_CALLER" &&
  grep -qF 'content-ref: ${{ github.sha }}' "$SELF_CALLER"; then
  ok "direct docs-control triggers use a thin exact-ref caller"
else
  bad "reusable Pages workflow owns a direct trigger or lacks an exact-ref caller"
fi

if grep -qF 'CONTENT_REF: ${{ steps.content.outputs.content_ref }}' <<<"$revision_block" &&
  grep -qF 'BUILDER_IMAGE: ${{ steps.content.outputs.builder_image }}' <<<"$revision_block" &&
  grep -qF 'CHECKED_OUT_SHA=$(git rev-parse HEAD)' <<<"$revision_block" &&
  grep -qF -- '--arg content_ref "${CONTENT_REF}"' <<<"$revision_block" &&
  grep -qF -- '--arg commit "${CHECKED_OUT_SHA}"' <<<"$revision_block" &&
  grep -qF -- '--arg builder_image "${BUILDER_IMAGE}"' <<<"$revision_block" &&
  grep -qF "'{content_ref:\$content_ref, commit:\$commit, builder_image:\$builder_image}'" <<<"$revision_block"; then
  ok "revision.json binds content and validated builder identities"
else
  bad "revision.json does not identify the exact published content and builder"
fi

if grep -qE 'GITHUB_SHA|generated_at|date -u' <<<"$revision_block"; then
  bad "revision.json contains incidental or wall-clock inputs"
else
  ok "revision.json is deterministic for one content commit"
fi

if grep -qF 'content-ref: ${{ github.sha }}' "$PAGES_CALLER"; then
  ok "governed Pages caller forwards its exact commit"
else
  bad "governed Pages caller omits content-ref"
fi

for workflow_file in \
  "$REPO_ROOT/.github/workflows/sync-managed-files.yml" \
  "$REPO_ROOT/.github/workflows/enforce-repo-settings.yml"; do
  workflow_name=$(basename "$workflow_file")
  source_block=$(sed -n '/^      source_sha:/,/^        type: string/p' "$workflow_file" | head -4)

  if grep -q '^        required: true$' <<<"$source_block" &&
    ! grep -q 'default:' <<<"$source_block"; then
    ok "$workflow_name requires an exact workflow_call receipt"
  else
    bad "$workflow_name permits an empty workflow_call receipt"
  fi

  if grep -Fq '?ref=${expected_source_sha}' "$workflow_file" &&
    ! grep -qE 'PAGES_BASE|revision_is_fresh|curl .*github\.io' "$workflow_file"; then
    ok "$workflow_name reads governance only from the exact API ref"
  else
    bad "$workflow_name can consume mutable governance bytes"
  fi

  if grep -q 'compare/${expected_source_sha}...${current_source_sha}' "$workflow_file" &&
    grep -q 'Historical protected-main receipt; enqueueing current main' "$workflow_file" &&
    grep -q 'gh workflow run' "$workflow_file"; then
    ok "$workflow_name independently enforces monotonic protected-main delivery"
  else
    bad "$workflow_name can apply a historical or unmerged receipt"
  fi
done

if grep -q 'docs-control/commits/main' "$GOVERNANCE_CALLER" &&
  grep -q 'compare/${source_sha}...${current_source_sha}' "$GOVERNANCE_CALLER" &&
  grep -q '\[DEFER\].*historical docs-control receipt' "$GOVERNANCE_CALLER" &&
  grep -q 'ready=false' "$GOVERNANCE_CALLER"; then
  ok "managed governance caller resolves one monotonic receipt"
else
  bad "managed governance caller can invoke reusable jobs with a stale receipt"
fi

if grep -q 'DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}' "$GOVERNANCE_CALLER" &&
  grep -Fq 'repos/${GITHUB_REPOSITORY}/commits/main' "$GOVERNANCE_CALLER" &&
  grep -q 'compare/${DOWNSTREAM_SHA}...${current_downstream_sha}' "$GOVERNANCE_CALLER" &&
  grep -q -- '--ref main' "$GOVERNANCE_CALLER" &&
  grep -q 'ready=false' "$GOVERNANCE_CALLER"; then
  ok "managed caller accepts only current downstream protected main"
else
  bad "manual or historical downstream refs can feed reusable governance jobs"
fi

exit "$FAIL"
