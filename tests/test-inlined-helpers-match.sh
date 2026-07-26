#!/usr/bin/env bash
# Ensures the inlined fetch_governed/revision_is_fresh functions in
# consumer workflows stay byte-identical with the canonical source at
# tests/fixtures/fetch-governed.sh.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
SOURCE="${REPO_ROOT}/tests/fixtures/fetch-governed.sh"

# Extract just the two function definitions from the canonical source,
# stripping shebang, comments, and blank lines. This is what we expect
# to find verbatim (modulo leading whitespace) inside each consumer.
canonical=$(awk '
  /^fetch_governed\(\)/,/^}$/ { print; next }
  /^revision_is_fresh\(\)/,/^}$/ { print }
' "$SOURCE" | sed -e 's/^[[:space:]]*//' -e '/^$/d' -e '/^#/d')

FAIL=0
for wf in \
  "${REPO_ROOT}/.github/workflows/sync-managed-files.yml" \
  "${REPO_ROOT}/.github/workflows/enforce-repo-settings.yml"; do
  inlined=$(awk '
    /fetch_governed\(\)/,/^[[:space:]]*}[[:space:]]*$/ { print; next }
    /revision_is_fresh\(\)/,/^[[:space:]]*}[[:space:]]*$/ { print }
  ' "$wf" | sed -e 's/^[[:space:]]*//' -e '/^$/d' -e '/^#/d')
  if [ "$inlined" = "$canonical" ]; then
    echo "[OK] $(basename "$wf") helper matches canonical"
  else
    echo "[FAIL] $(basename "$wf") helper drifted from canonical"
    diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$inlined") || true
    FAIL=1
  fi
done

# retry() is duplicated in both consumers with no canonical fixture. It has no
# single source of truth to compare against, so pin the two copies to each other:
# a fix applied to one and not the other would otherwise ship silently, and its
# captured output feeds enforcement decisions (issue #805).
extract_retry() {
  awk '/^[[:space:]]*retry\(\)[[:space:]]*\{/,/^[[:space:]]*\}[[:space:]]*$/' "$1" |
    sed -e 's/^[[:space:]]*//' -e '/^$/d' -e '/^#/d'
}

retry_sync=$(extract_retry "${REPO_ROOT}/.github/workflows/sync-managed-files.yml")
retry_enforce=$(extract_retry "${REPO_ROOT}/.github/workflows/enforce-repo-settings.yml")

if [ -z "$retry_sync" ] || [ -z "$retry_enforce" ]; then
  echo "[FAIL] retry() not found in one or both consumers"
  FAIL=1
elif [ "$retry_sync" = "$retry_enforce" ]; then
  echo "[OK] retry() matches across both consumers"
else
  echo "[FAIL] retry() drifted between consumers"
  diff <(printf '%s\n' "$retry_sync") <(printf '%s\n' "$retry_enforce") || true
  FAIL=1
fi

# The stdout-isolation fix is the whole point of #805; assert it is present rather
# than only that the two copies agree, so they cannot regress together.
for wf in \
  "${REPO_ROOT}/.github/workflows/sync-managed-files.yml" \
  "${REPO_ROOT}/.github/workflows/enforce-repo-settings.yml"; do
  if extract_retry "$wf" | grep -qF '"$@" >"$out_file" 2>"$err_file"'; then
    echo "[OK] $(basename "$wf") retry() buffers stdout per attempt"
  else
    echo "[FAIL] $(basename "$wf") retry() does not isolate stdout per attempt"
    FAIL=1
  fi
done

exit "$FAIL"
