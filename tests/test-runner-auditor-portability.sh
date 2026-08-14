#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
auditor="$repo_root/scripts/audit-runner-workflows.py"

uvx --from 'ruff==0.15.17' ruff format --check --isolated \
  --config 'line-length = 88' "$auditor"
uvx --from 'ruff==0.15.17' ruff format --check --isolated \
  --config 'line-length = 120' "$auditor"
uvx --from 'pylint==4.0.6' pylint \
  --disable=all \
  --enable=import-error,unused-argument \
  "$auditor"

echo "runner auditor is portable across governed downstream Python lint settings"
