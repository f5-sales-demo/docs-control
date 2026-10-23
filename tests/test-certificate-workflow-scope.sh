#!/usr/bin/env bash
# Every certificate artifact job must stay in its owning repository.
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$TASK_ROOT/workflows/certificate-current-artifacts-pr.yml" <<'PY'
import sys
from pathlib import Path
import re

source = Path(sys.argv[1]).read_text()
# Check the known canonical job layout without adding a YAML runtime dependency.
job_source = source.split('jobs:\n', 1)[1].split("'on':", 1)[0]
jobs = dict(re.findall(r'(?ms)^  ([\w-]+):\n(.*?)(?=^  [\w-]+:|\Z)', job_source))
owner = "github.repository == 'f5-sales-demo/certificate-management'"
trust = "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository"
assert set(jobs) == {'schema', 'customization', 'trust-gate'}
for name, job in jobs.items():
    match = re.search(r'^    if: (.*)$', job, re.MULTILINE)
    predicate = match.group(1) if match else '' 
    assert predicate == owner or predicate.startswith(owner + ' && '), (name, predicate)
    if name in {'customization', 'trust-gate'}:
        assert trust in predicate, (name, 'existing same-repository PR trust gate lost')
assert '    needs: trust-gate' in jobs['customization']
assert 'resolve_current_artifacts.py' in jobs['schema']
assert 'run: test "$GITHUB_REPOSITORY" = "f5-sales-demo/certificate-management"' in jobs['trust-gate']
print('Certificate workflow job ownership and original trust boundaries verified')
PY
