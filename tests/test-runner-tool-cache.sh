#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
initializer="$repo_root/scripts/prepare-runner-tool-cache.sh"
test -x "$initializer"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

runtime="$scratch/runtime"
image_cache="$scratch/image-cache"
mkdir -p "$runtime" "$image_cache/go/1.25.12/x64"
printf 'go tool\n' >"$image_cache/go/1.25.12/x64/go"
touch "$image_cache/go/1.25.12/x64.complete"

RUNNER_RUNTIME_DIR="$runtime" \
  RUNNER_TOOL_CACHE="$runtime/_tool" \
  AGENT_TOOLSDIRECTORY="$image_cache" \
  "$initializer"

test -f "$runtime/_tool/go/1.25.12/x64.complete"
test "$(cat "$runtime/_tool/go/1.25.12/x64/go")" = "go tool"
test "$(stat -c '%a' "$runtime/_tool")" = "700"

if RUNNER_RUNTIME_DIR="$runtime" \
  RUNNER_TOOL_CACHE="$scratch/outside" \
  AGENT_TOOLSDIRECTORY="$image_cache" \
  "$initializer" 2>/dev/null; then
  echo "initializer accepted a cache outside the runner workspace" >&2
  exit 1
fi
