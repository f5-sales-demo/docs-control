#!/usr/bin/env bash
# Hermetic regression test for the Pages-freshness guard in the governed-read
# workflows (sync-managed-files.yml, enforce-repo-settings.yml).
#
# WHY: `fetch_governed` prefers the Pages-published governance mirror, which lags a
# docs-control merge by however long its deploy takes. The guard must force an API
# fallback whenever Pages is behind. It previously ran ONLY when a source_sha was
# passed, so schedule/manual runs read a STALE manifest and drift detection reported
# "[OK] All managed files match canonical" for files that had genuinely drifted —
# governance changes silently never propagated. enforce-repo-settings.yml defined
# revision_is_fresh but never called it at all.
#
# This test locks two properties, statically (no network):
#   1. Both workflows CALL the guard, and do so UNCONDITIONALLY on SOURCE_SHA
#      (i.e. an empty source_sha must still be checked, via a main-HEAD fallback).
#   2. The revision_is_fresh comparison semantics stay exact-match.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0

WORKFLOWS=(
  "${REPO_ROOT}/.github/workflows/sync-managed-files.yml"
  "${REPO_ROOT}/.github/workflows/enforce-repo-settings.yml"
)

ok() { echo "[OK] $1"; }
bad() {
  echo "[FAIL] $1"
  FAIL=1
}

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
