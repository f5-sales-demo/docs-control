#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
python3 -m unittest discover -s tests -p test_repository_rename_audit.py
python3 scripts/audit_repository_rename.py --repository f5-sales-demo/docs-control \
  --classifications .github/config/repository-rename-classifications.json
python3 - <<'PY'
import json
from pathlib import Path
name = 'client-side-defense'
old = 'c' + 'sd'
registry = json.loads(Path('.github/config/downstream-repos.json').read_text())
assert registry.count(name) == 1 and old not in registry
governance = json.loads(Path('.claude/governance.json').read_text())
assert governance['repo_classes']['repos'][name] == 'content'
assert old not in governance['repo_classes']['repos']
settings = json.loads(Path('.github/config/repo-settings.json').read_text())
assert settings['secrets_manifest']['repo_roles'][name] == ['governance']
assert settings['readme_sources'][name] == f'content/{name}/README.md'
assert settings['repo_overrides'][name]['repository']['homepage'] == f'https://f5-sales-demo.github.io/{name}/'
policy = json.loads(Path('.github/config/self-hosted-runner-policy.json').read_text())
identity = 'f5-sales-demo/' + name
assert set(policy['repositories'][identity]['runner']['arc_scale_sets']) == {'socketless', 'container-build'}
assert identity in policy['hosted_exceptions']
assert Path(settings['readme_sources'][name]).is_file()
print('PASS: canonical client-side-defense identity and README ownership')
PY
