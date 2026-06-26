#!/usr/bin/env bash
# tests/fixtures/fetch-governed.sh
#
# Canonical source of the fetch-from-Pages-with-API-fallback helper.
# This file is the source of truth; consumer workflows inline its
# functions verbatim. tests/test-inlined-helpers-match.sh asserts the
# inlined copies stay in sync with this file.
#
# Environment:
#   PAGES_BASE   e.g. "https://f5-sales-demo.github.io/docs-control"
#   GH_TOKEN     used by fallback `gh api` path
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

# fetch_governed <pages-key> <api-fallback-path>
#   pages-key          : relative path under ${PAGES_BASE}/api/ (e.g. "repo-settings.json")
#   api-fallback-path  : argument for `gh api` when Pages is unavailable
#                        (e.g. "repos/f5-sales-demo/docs-control/contents/.github/config/repo-settings.json")
# Prints: raw file content to stdout.
# Returns: 0 on success (via Pages or API), non-zero if both fail.
fetch_governed() {
  local key="$1" fallback="$2" body err_file
  local url="${PAGES_BASE}/api/${key}"

  body=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 10 "$url" 2>/dev/null || true)
  if [ -n "$body" ]; then
    printf '%s' "$body"
    return 0
  fi

  echo "[WARN] Pages unavailable for ${key} — falling back to API" >&2
  err_file=$(mktemp)
  if ! body=$(retry 3 gh api "$fallback" 2>"$err_file"); then
    echo "[ERROR] gh api failed for ${key}:" >&2
    cat "$err_file" >&2
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  if [ -z "$body" ]; then
    echo "[ERROR] gh api returned empty body for ${key}" >&2
    return 1
  fi

  # API returns {"content": "<base64>", "encoding": "base64"} envelope.
  # Unwrap to raw bytes.
  printf '%s' "$body" | jq -r '.content' | tr -d '\n' | base64 -d
}

# revision_is_fresh <source-sha>
#   Fetch ${PAGES_BASE}/api/revision.json and compare its .commit
#   against source-sha (the SHA that triggered the consumer run).
# Returns: 0 when the Pages deploy has caught up to source-sha;
#          non-zero when Pages is stale or unreachable or when
#          source-sha is empty.
revision_is_fresh() {
  local source_sha="${1:-}" rev pages_sha
  [ -z "$source_sha" ] && return 1

  rev=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 10 \
    "${PAGES_BASE}/api/revision.json" 2>/dev/null || true)
  [ -z "$rev" ] && return 1

  pages_sha=$(printf '%s' "$rev" | jq -r '.commit // empty')
  [ "$pages_sha" = "$source_sha" ]
}
