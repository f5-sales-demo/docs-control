"""Exercise stale-reference rejection and exact historical classifications."""

import hashlib
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "rename_audit", ROOT / "scripts/audit-repository-rename.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
OLD_NAME = "c" + "sd"


class RenameAuditTests(unittest.TestCase):
    def test_rejects_repository_urls_relative_base_paths_runner_and_registry_keys(self):
        fixtures = {
            "docs/en/index.mdx": f"https://f5-sales-demo.github.io/{OLD_NAME}/en/",
            "README.md": f"https://github.com/f5-sales-demo/{OLD_NAME}/actions",
            "arc/config.json": f"arc-runners-{OLD_NAME}-socketless",
            ".github/config/downstream-repos.json": f'["{OLD_NAME}"]',
            "docs/en/assets.mdx": f"/{OLD_NAME}/images/hero.svg",
        }
        for name, value in fixtures.items():
            with self.subTest(name=name):
                assert MODULE.findings(name, value.encode())

    def test_accepts_product_api_script_resource_and_environment_identifiers(self):
        text = f"/api/shape/{OLD_NAME}/domains CSD XCSH_CSD_DEPLOYMENT_MODE scripts/{OLD_NAME}-traffic.mjs f5xc_{OLD_NAME}.demo"
        assert MODULE.findings("docs/en/api-reference.mdx", text.encode()) == []

    def test_hidden_untracked_source_is_scanned_and_history_cannot_hide_changed_bytes(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["/usr/bin/git", "init", "-q"], cwd=root, check=True)
            path = root / ".github/evidence.json"
            path.parent.mkdir()
            content = f'{{"previous":"f5-sales-demo/{OLD_NAME}"}}\n'.encode()
            path.write_bytes(content)
            repository = "f5-sales-demo/client-side-defense"
            assert MODULE.audit(root, repository, {})["stale_operational_references"]
            record = {
                "category": "historical",
                "reason": "Dated prior deployment receipt",
                "sha256": hashlib.sha256(content).hexdigest(),
                "matches": 1,
            }
            classifications = {
                "repositories": {repository: {".github/evidence.json": record}}
            }
            assert MODULE.audit(root, repository, classifications)["errors"] == []
            path.write_bytes(content + b"changed\n")
            assert MODULE.audit(root, repository, classifications)["errors"]


if __name__ == "__main__":
    unittest.main()
