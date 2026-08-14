#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
auditor="$repo_root/scripts/audit-runner-workflows.py"

uvx --from 'ruff==0.15.17' ruff format --check --isolated \
  --config 'line-length = 88' "$auditor"
uvx --from 'ruff==0.15.17' ruff format --check --isolated \
  --config 'line-length = 120' "$auditor"

# Some governed repositories make scripts/ an importable package. In that
# context Ruff evaluates managed CLI filenames as modules, so the auditor must
# carry its own portability exception instead of relying on docs-control's
# per-file config.
portability_root=$(mktemp -d)
trap 'rm -rf "$portability_root"' EXIT
mkdir -p "$portability_root/scripts"
cp "$auditor" "$portability_root/scripts/audit-runner-workflows.py"
touch "$portability_root/scripts/__init__.py"
# Repositories that keep stricter local Ruff policies must not need to carry
# config exceptions for the governed compatibility auditor.
uvx --from 'ruff==0.15.17' ruff check --isolated \
  --select ANN,ARG001,D,EM,N999,PLR2004,RUF100,TRY003 \
  "$portability_root/scripts/audit-runner-workflows.py"
uvx --from 'pylint==4.0.6' pylint \
  --disable=all \
  --enable=import-error,unused-argument \
  "$auditor"

echo "runner auditor is portable across governed downstream Python lint settings"
