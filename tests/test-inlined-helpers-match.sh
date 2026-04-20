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
' "$SOURCE" | sed 's/^[[:space:]]*//' | grep -v '^$' | grep -v '^#')

FAIL=0
for wf in \
  "${REPO_ROOT}/.github/workflows/sync-managed-files.yml" \
  "${REPO_ROOT}/.github/workflows/enforce-repo-settings.yml"; do
  inlined=$(awk '
    /fetch_governed\(\)/,/^[[:space:]]*}[[:space:]]*$/ { print; next }
    /revision_is_fresh\(\)/,/^[[:space:]]*}[[:space:]]*$/ { print }
  ' "$wf" | sed 's/^[[:space:]]*//' | grep -v '^$' | grep -v '^#')
  if [ "$inlined" = "$canonical" ]; then
    echo "[OK] $(basename "$wf") helper matches canonical"
  else
    echo "[FAIL] $(basename "$wf") helper drifted from canonical"
    diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$inlined") || true
    FAIL=1
  fi
done

exit "$FAIL"
