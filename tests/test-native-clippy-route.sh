#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
from pathlib import Path
import os
import subprocess
import tempfile
import yaml
workflow = yaml.safe_load(Path('.github/workflows/super-linter.yml').read_text())
step = next(s for s in workflow['jobs']['lint']['steps'] if s.get('name') == 'Validate Rust edition input')
for repository in ['f5-sales-demo/xcsh', 'f5-sales-demo/another-repo']:
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / 'environment'
        output.touch()
        env = {**os.environ, 'RUST_EDITION': '2024', 'REPOSITORY': repository, 'GITHUB_ENV': str(output)}
        subprocess.run(['bash', '-c', step['run']], env=env, check=True)
        declarations = output.read_text().splitlines()
        assert ('VALIDATE_RUST_CLIPPY=false' in declarations) == (repository == 'f5-sales-demo/xcsh')
        assert 'VALIDATE_RUST_2024=false' not in declarations
        assert 'VALIDATE_RUST_2021=false' in declarations
print('Clippy routes verified; selected Rust formatting remains enabled')
PY
