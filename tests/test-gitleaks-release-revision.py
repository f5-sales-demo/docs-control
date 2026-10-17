import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_REVISION = "".join(["e04c5d45", "f7a4e103", "e2dc84bf", "52b76718", "2b4de3bc"])
SYNTHETIC = hashlib.sha1(b"noncredential regression fixture").hexdigest()
CASES = [
    ("public revision metadata", "const redactionPrefix = 'sgp_';\ncommit = '" + PUBLIC_REVISION + "',\n", False),
    ("legacy Sourcegraph credential", "sourcegraph_token = '" + SYNTHETIC + "';\n", True),
    ("prefixed Sourcegraph credential", "const token = 'sgp_" + SYNTHETIC + "';\n", True),
    ("local Sourcegraph credential", "const token = 'sgp_local_" + SYNTHETIC + "';\n", True),
    ("same revision used as a credential", "sourcegraph_token = '" + PUBLIC_REVISION + "';\n", True),
    ("unverified revision metadata", "const redactionPrefix = 'sgp_';\ncommit = '" + SYNTHETIC + "',\n", True),
]
for label, body, should_detect in CASES:
    with tempfile.TemporaryDirectory(prefix="gitleaks-revision-") as directory:
        root = Path(directory)
        (root / "candidate.js").write_text(body)
        report = root / "findings.json"
        result = subprocess.run(["gitleaks", "dir", str(root), "--config", str(ROOT / ".gitleaks.toml"),
                                 "--redact", "--report-path", str(report)], capture_output=True)
        if result.returncode not in (0, 1):
            raise SystemExit("Scanner operational failure in " + label)
        findings = json.loads(report.read_text()) if report.exists() else []
        detected = any(row["RuleID"] == "sourcegraph-access-token" for row in findings)
        if detected != should_detect:
            raise SystemExit("Unexpected Sourcegraph result for " + label)
        print("PASS " + label)
