#!/usr/bin/env bash
# Hermetic regression tests for the Pages publication identity contract and the
# Pages-freshness guard in the governed-read workflows (sync-managed-files.yml,
# enforce-repo-settings.yml).
#
# WHY: `fetch_governed` prefers the Pages-published governance mirror, which lags a
# docs-control merge by however long its deploy takes. The guard must force an API
# fallback whenever Pages is behind. It previously ran ONLY when a source_sha was
# passed, so schedule/manual runs read a STALE manifest and drift detection reported
# "[OK] All managed files match canonical" for files that had genuinely drifted —
# governance changes silently never propagated. enforce-repo-settings.yml defined
# revision_is_fresh but never called it at all.
#
# This test locks the publication identity and freshness contracts statically
# (no network): the deploy checks out its explicit caller ref and publishes the
# resolved commit without volatile data; both readers call the freshness guard
# unconditionally; and revision_is_fresh remains an exact comparison.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0
DEPLOY_WORKFLOW="${REPO_ROOT}/.github/workflows/github-pages-deploy.yml"
CALLER_TEMPLATE="${REPO_ROOT}/workflows/github-pages-deploy.yml"

WORKFLOWS=(
  "${REPO_ROOT}/.github/workflows/sync-managed-files.yml"
  "${REPO_ROOT}/.github/workflows/enforce-repo-settings.yml"
)

ok() { echo "[OK] $1"; }
bad() {
  echo "[FAIL] $1"
  FAIL=1
}

# The reusable workflow must build the requested caller revision, not the SHA of
# whichever commit happens to contain the reusable workflow invocation. Its
# revision marker is an artifact identity: it records the requested ref and the
# commit checkout resolved, and contains no wall-clock data.
input_block=$(sed -n '/^      content-ref:/,/^        type: string/p' "$DEPLOY_WORKFLOW")
checkout_block=$(sed -n '/^      - name: Checkout content repo/,/^      - name: Login to GHCR/p' "$DEPLOY_WORKFLOW")
validation_block=$(sed -n '/^      - name: Validate immutable content commit/,/^      - name: Checkout content repo/p' "$DEPLOY_WORKFLOW")
revision_block=$(sed -n '/^      - name: Stage governance assets for \/api\//,/^      - name: Upload artifact/p' "$DEPLOY_WORKFLOW")

if grep -q '^        required: true$' <<<"$input_block" &&
  grep -q '^        type: string$' <<<"$input_block"; then
  ok "Pages deploy requires an explicit workflow_call content-ref"
else
  bad "Pages deploy workflow_call content-ref is not required"
fi

if grep -qF 'ref: ${{ inputs.content-ref || github.sha }}' <<<"$checkout_block"; then
  ok "Pages deploy checks out the requested content ref"
else
  bad "Pages deploy checkout does not use content-ref"
fi

if grep -qF '^[0-9a-f]{40}$' <<<"$validation_block" &&
  grep -qF 'CHECKED_OUT_SHA=$(git rev-parse HEAD)' <<<"$checkout_block" &&
  grep -qF 'if [ "$CHECKED_OUT_SHA" != "$CONTENT_REF" ]' <<<"$checkout_block"; then
  ok "Pages deploy requires and verifies an immutable full commit SHA"
else
  bad "Pages deploy does not enforce immutable full-SHA content identity"
fi

if grep -qF 'CONTENT_REF: ${{ inputs.content-ref || github.sha }}' <<<"$revision_block" &&
  grep -qF 'CHECKED_OUT_SHA=$(git rev-parse HEAD)' <<<"$revision_block" &&
  grep -qF -- '--arg content_ref "${CONTENT_REF}"' <<<"$revision_block" &&
  grep -qF -- '--arg commit "${CHECKED_OUT_SHA}"' <<<"$revision_block" &&
  grep -qF "'{content_ref:\$content_ref, commit:\$commit}'" <<<"$revision_block"; then
  ok "revision.json records requested ref and checked-out commit"
else
  bad "revision.json does not bind requested ref to checked-out commit"
fi

if grep -qE 'GITHUB_SHA|generated_at|date -u' <<<"$revision_block"; then
  bad "revision.json still contains caller-SHA or wall-clock inputs"
else
  ok "revision.json is independent of caller SHA and wall-clock time"
fi

if grep -qF 'content-ref: ${{ github.sha }}' "$CALLER_TEMPLATE"; then
  ok "governed caller supplies the required content ref"
else
  bad "governed caller omits the required content ref"
fi

for wf in "${WORKFLOWS[@]}"; do
  name=$(basename "$wf")

  # 1. The guard must actually be invoked, not merely defined.
  if grep -qE '^\s*(elif ! |if ! )?revision_is_fresh "' "$wf"; then
    ok "$name calls revision_is_fresh"
  else
    bad "$name never calls revision_is_fresh (guard defined but unused = no protection)"
  fi

  # 2. The invocation must NOT be gated on a non-empty SOURCE_SHA. The old bug was
  #    `if [ -n "${SOURCE_SHA:-}" ] && ! revision_is_fresh ...`, which skipped the
  #    check entirely on schedule/manual runs.
  if grep -qE '\[ -n "\$\{SOURCE_SHA:-\}" \][[:space:]]*&&[[:space:]]*! revision_is_fresh' "$wf"; then
    bad "$name gates the freshness check on a non-empty SOURCE_SHA (stale reads on schedule/manual runs)"
  else
    ok "$name does not gate the freshness check on SOURCE_SHA"
  fi

  # 3. There must be a fallback that resolves the expected sha when SOURCE_SHA is
  #    empty (docs-control main HEAD), so the guard has something to compare.
  if grep -q 'expected_source_sha' "$wf" &&
    grep -qE 'docs-control/commits/main' "$wf"; then
    ok "$name resolves docs-control main HEAD when source_sha is empty"
  else
    bad "$name has no main-HEAD fallback for the expected sha"
  fi

  # 4. A failed/indeterminate freshness check must force the API fallback by
  #    poisoning PAGES_BASE (that is how fetch_governed is made to error).
  if grep -q 'PAGES_BASE="https://invalid.pages.local"' "$wf"; then
    ok "$name forces API fallback when Pages is stale"
  else
    bad "$name does not force an API fallback on stale Pages"
  fi

  # 5. Freshness must be an EXACT sha match (no prefix/substring comparison).
  if grep -qE '\[ "\$pages_sha" = "\$source_sha" \]' "$wf"; then
    ok "$name compares pages_sha to source_sha exactly"
  else
    bad "$name freshness comparison is not an exact sha match"
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "pages-staleness-guard tests FAILED"
  exit 1
fi
echo "pages-staleness-guard tests passed"
