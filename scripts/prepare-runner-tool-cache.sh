#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_RUNTIME_DIR:?RUNNER_RUNTIME_DIR is required}"
: "${RUNNER_TOOL_CACHE:?RUNNER_TOOL_CACHE is required}"
: "${AGENT_TOOLSDIRECTORY:?AGENT_TOOLSDIRECTORY is required}"

runtime_dir="$(realpath -m -- "$RUNNER_RUNTIME_DIR")"
tool_cache="$(realpath -m -- "$RUNNER_TOOL_CACHE")"
image_tool_cache="$(realpath -m -- "$AGENT_TOOLSDIRECTORY")"

if [[ "$runtime_dir" != /* || ! -d "$runtime_dir" ]]; then
  echo "runner runtime workspace is invalid" >&2
  exit 1
fi
if [[ "$tool_cache" != "$runtime_dir"/* ]]; then
  echo "runner tool cache must be inside the runtime workspace" >&2
  exit 1
fi
if [[ "$image_tool_cache" != /* || ! -d "$image_tool_cache" ]]; then
  echo "immutable image tool cache is invalid" >&2
  exit 1
fi

# The runner root filesystem is read-only. Copy the immutable, catalogued cache
# into this job's private workspace so setup actions can use cache hits and can
# safely install a version that is not yet catalogued. The controller removes
# this workspace after the ephemeral runner exits.
install -d -m 0700 "$tool_cache"
find "$image_tool_cache" -mindepth 1 -maxdepth 1 \
  -exec cp --archive --no-preserve=ownership --target-directory="$tool_cache" {} +
