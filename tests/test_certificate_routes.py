"""Exercise generated Certificate Management workflows against the fleet runner policy."""

# ruff: noqa: INP001 -- Match repository unittest layout.
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class CertificateRoutesTests(unittest.TestCase):
    def test_generated_workflow_routes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/config").mkdir()
            shutil.copyfile(
                ROOT / ".github/config/self-hosted-runner-policy.json",
                root / ".github/config/self-hosted-runner-policy.json",
            )
            for name in [
                "certificate-current-artifacts.yml",
                "certificate-current-artifacts-pr.yml",
                "workflow-security-audit.yml",
            ]:
                shutil.copyfile(
                    ROOT / "workflows" / name, root / ".github/workflows" / name
                )
            result = subprocess.run(  # noqa: S603 -- Fixed trusted policy auditor argv.
                [
                    sys.executable,
                    str(ROOT / "scripts/audit-runner-workflows.py"),
                    "--repository",
                    "f5-sales-demo/certificate-management",
                    "--root",
                    str(root),
                    "--policy",
                    str(root / ".github/config/self-hosted-runner-policy.json"),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            assert result.returncode == 0, result.stdout + result.stderr

    def test_workflow_dispatch_and_pr_are_separate(self):
        scheduled = yaml.safe_load(
            (ROOT / "workflows/certificate-current-artifacts.yml").read_text()
        )
        pull = yaml.safe_load(
            (ROOT / "workflows/certificate-current-artifacts-pr.yml").read_text()
        )
        assert set(scheduled.get("on", scheduled.get(True))) == {
            "schedule",
            "workflow_dispatch",
        }
        assert set(pull.get("on", pull.get(True))) == {"pull_request"}
        config = json.loads((ROOT / ".github/config/repo-settings.json").read_text())
        mapping = next(
            entry
            for entry in config["managed_files"]["files"]
            if entry["src"] == "workflows/certificate-current-artifacts-pr.yml"
        )
        assert mapping["only_repos"] == ["certificate-management"]


if __name__ == "__main__":
    unittest.main()
