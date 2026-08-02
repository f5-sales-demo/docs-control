#!/usr/bin/env bash
# tests/fixtures/fetch-governed.sh
#
# Canonical source of the fetch-from-Pages-with-API-fallback helper.
# This file is the source of truth; consumer workflows inline its
# functions verbatim. tests/test-inlined-helpers-match.sh asserts the
# inlined copies stay in sync with this file.
#
# Environment:
#   expected_source_sha  exact docs-control commit for every governed read
#   GH_TOKEN             used by `gh api`
#
# Dependencies:
#   retry(max_attempts, cmd...)   consumer workflows define a richer
#                                 retry with rate-limit sleep-to-reset.
#                                 Fixture provides a minimal pass-through
#                                 stub below so the file works standalone
#                                 in unit tests.
#
# All functions are safe to source multiple times.

# Minimal retry stub for standalone testing. Workflows define a richer
# retry that shadows this one; the declare -F guard prevents redefinition.
declare -F retry >/dev/null 2>&1 || retry() {
  shift # drop max-attempts
  "$@"
}

# fetch_governed <label> <api-content-path>
# Reads one GitHub Contents object at the exact source receipt, validates the
# response metadata against the decoded bytes, and prints those bytes.
fetch_governed() {
  local key="$1" fallback="$2" api_file decoded_file err_file
  local receipt_sha receipt_size decoded_sha decoded_size

  if ! printf '%s' "${expected_source_sha:-}" | grep -qE '^[0-9a-f]{40}$'; then
    echo "[ERROR] Could not resolve an exact docs-control source commit" >&2
    return 1
  fi
  if [[ "$fallback" == *[?#]* ]]; then
    echo "[ERROR] Governed API path already contains a query or fragment for ${key}" >&2
    return 1
  fi

  api_file=$(mktemp)
  decoded_file=$(mktemp)
  err_file=$(mktemp)
  if ! retry 3 gh api "${fallback}?ref=${expected_source_sha}" >"$api_file" 2>"$err_file"; then
    echo "[ERROR] gh api failed for ${key}:" >&2
    cat "$err_file" >&2
    rm -f "$api_file" "$decoded_file" "$err_file"
    return 1
  fi
  if ! jq -e '
    .type == "file" and .encoding == "base64" and
    (.sha | type == "string" and test("^[0-9a-f]{40}$")) and
    (.size | type == "number" and floor == . and . >= 0) and
    (.content | type == "string") and
    (.size == 0 or (.content | length > 0))
  ' "$api_file" >/dev/null 2>&1; then
    echo "[ERROR] gh api returned an invalid content envelope for ${key}" >&2
    rm -f "$api_file" "$decoded_file" "$err_file"
    return 1
  fi
  if ! jq -r '.content' "$api_file" | tr -d '\n' | base64 -d >"$decoded_file"; then
    echo "[ERROR] gh api returned invalid base64 content for ${key}" >&2
    rm -f "$api_file" "$decoded_file" "$err_file"
    return 1
  fi
  receipt_sha=$(jq -r '.sha' "$api_file")
  receipt_size=$(jq -r '.size' "$api_file")
  decoded_sha=$(git hash-object "$decoded_file")
  decoded_size=$(wc -c <"$decoded_file" | tr -d ' ')
  if [ "$decoded_sha" != "$receipt_sha" ] || [ "$decoded_size" != "$receipt_size" ]; then
    echo "[ERROR] Decoded bytes do not match the content receipt for ${key}" >&2
    rm -f "$api_file" "$decoded_file" "$err_file"
    return 1
  fi
  cat "$decoded_file"
  rm -f "$api_file" "$decoded_file" "$err_file"
}
