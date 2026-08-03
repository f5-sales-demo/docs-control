#!/usr/bin/env bash
# Contracts for exact Pages publication identity and governed source receipts.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEPLOY_WORKFLOW="$REPO_ROOT/.github/workflows/github-pages-deploy.yml"
SELF_CALLER="$REPO_ROOT/.github/workflows/docs-site-deploy.yml"
PAGES_CALLER="$REPO_ROOT/workflows/github-pages-deploy.yml"
GOVERNANCE_CALLER="$REPO_ROOT/workflows/enforce-repo-settings.yml"
SYNC_WORKFLOW="$REPO_ROOT/.github/workflows/sync-managed-files.yml"
FAIL=0

ok() { echo "[OK] $1"; }
bad() {
  echo "[FAIL] $1"
  FAIL=1
}

input_block=$(sed -n '/^      content-ref:/,/^        type: string/p' "$DEPLOY_WORKFLOW")
builder_input_block=$(sed -n '/^      builder-image:/,/^        type: string/p' "$DEPLOY_WORKFLOW")
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

if grep -qF "default: 'ghcr.io/f5-sales-demo/docs-builder:latest'" <<<"$builder_input_block" &&
  ! grep -qF '@sha256:' <<<"$builder_input_block"; then
  ok "Pages deploy selects the latest approved builder release"
else
  bad "Pages deploy does not select the latest approved builder release"
fi

if python3 - "$DEPLOY_WORKFLOW" <<'PY'; then
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as workflow_file:
    workflow = yaml.safe_load(workflow_file)

steps = workflow["jobs"]["build"]["steps"]
names = [step.get("name") for step in steps]
login = names.index("Login to GHCR")
resolve = names.index("Resolve latest documentation builder")
if resolve != login + 1:
    raise SystemExit(1)
PY
  ok "Pages deploy authenticates immediately before resolving latest"
else
  bad "Pages deploy can resolve the builder before registry authentication"
fi

resolver_script=$(mktemp)
resolver_tmp=$(mktemp -d)
trap 'rm -f "$resolver_script"; rm -rf "$resolver_tmp"' EXIT
if python3 - "$DEPLOY_WORKFLOW" "$resolver_script" <<'PY'; then
import sys

import yaml

workflow_path, script_path = sys.argv[1:]
with open(workflow_path, encoding="utf-8") as workflow_file:
    workflow = yaml.safe_load(workflow_file)

matching = [
    step
    for step in workflow["jobs"]["build"]["steps"]
    if step.get("name") == "Resolve latest documentation builder"
]
if len(matching) != 1 or not isinstance(matching[0].get("run"), str):
    raise SystemExit(1)
with open(script_path, "w", encoding="utf-8") as script_file:
    script_file.write(matching[0]["run"])
PY
  :
else
  bad "Pages deploy has no executable latest-builder resolver"
fi

mkdir -p "$resolver_tmp/bin"
cat >"$resolver_tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "pull" ]; then
  printf '%s\n' "$2" >>"$DOCKER_CALLS"
  exit 0
fi
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
  printf '%s\n' "$STUB_RESOLVED_IMAGE"
  exit 0
fi
echo "unexpected docker invocation: $*" >&2
exit 2
STUB
chmod +x "$resolver_tmp/bin/docker"

approved_tag='ghcr.io/f5-sales-demo/docs-builder:latest'
approved_digest='ghcr.io/f5-sales-demo/docs-builder@sha256:1111111111111111111111111111111111111111111111111111111111111111'
export DOCKER_CALLS="$resolver_tmp/docker-calls"
export STUB_RESOLVED_IMAGE="$approved_digest"

if PATH="$resolver_tmp/bin:$PATH" \
  REQUESTED_IMAGE="$approved_tag" \
  GITHUB_OUTPUT="$resolver_tmp/approved-output" \
  bash "$resolver_script" >/dev/null 2>&1 &&
  grep -qxF "$approved_tag" "$DOCKER_CALLS" &&
  grep -qxF "builder_image=$approved_digest" "$resolver_tmp/approved-output"; then
  ok "Pages deploy resolves latest to one immutable approved digest"
else
  bad "Pages deploy does not resolve latest to the digest it records"
fi

for rejected_image in \
  'ghcr.io/unapproved/docs-builder:latest' \
  'ghcr.io/f5-sales-demo/docs-builder:older'; do
  if PATH="$resolver_tmp/bin:$PATH" \
    REQUESTED_IMAGE="$rejected_image" \
    GITHUB_OUTPUT="$resolver_tmp/rejected-output" \
    bash "$resolver_script" >/dev/null 2>&1; then
    bad "Pages deploy accepts unapproved builder selector: $rejected_image"
  else
    ok "Pages deploy rejects unapproved builder selector: $rejected_image"
  fi
done

export STUB_RESOLVED_IMAGE='ghcr.io/unapproved/docs-builder@sha256:2222222222222222222222222222222222222222222222222222222222222222'
if PATH="$resolver_tmp/bin:$PATH" \
  REQUESTED_IMAGE="$approved_tag" \
  GITHUB_OUTPUT="$resolver_tmp/unapproved-output" \
  bash "$resolver_script" >/dev/null 2>&1; then
  bad "Pages deploy accepts a resolved digest from an unapproved repository"
else
  ok "Pages deploy rejects a resolved digest from an unapproved repository"
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

if grep -qF '${{ steps.builder.outputs.builder_image }}' "$DEPLOY_WORKFLOW" &&
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
  grep -qF 'BUILDER_IMAGE: ${{ steps.builder.outputs.builder_image }}' <<<"$revision_block" &&
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
    grep -q 'Docs-control protected main advanced; enqueued its exact receipt' "$workflow_file" &&
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

downstream_input=$(sed -n '/^      downstream_sha:/,/^        type: string/p' "$SYNC_WORKFLOW")
if grep -q '^        required: true$' <<<"$downstream_input" &&
  grep -qF 'ref: ${{ inputs.downstream_sha }}' "$SYNC_WORKFLOW" &&
  grep -qF 'downstream_sha: ${{ github.sha }}' "$GOVERNANCE_CALLER" &&
  grep -q 'CHECKED_OUT_SHA=$(git rev-parse HEAD)' "$SYNC_WORKFLOW" &&
  [ "$(grep -c 'require_current_downstream_main' "$SYNC_WORKFLOW")" -ge 3 ]; then
  ok "managed sync binds comparisons and mutations to one downstream protected-main receipt"
else
  bad "managed sync can compare one downstream commit and mutate another"
fi

exit "$FAIL"
