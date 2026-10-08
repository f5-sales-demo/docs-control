# ruff: noqa: INP001
"""Shared shell workflow routes preserve local documentation and provider receipts."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class SharedShellPublication(unittest.TestCase):
    def test_mounts_only_root_and_transports_mode(self):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/github-pages-deploy.yml").read_text()
        )
        shell = next(
            step["run"]
            for step in workflow["jobs"]["build"]["steps"]
            if step.get("name") == "Build docs with container"
        )
        assert "f5-sales-demo/f5-sales-demo.github.io" in shell
        assert '-v "$WORKSPACE/shared:/content/shared:ro"' in shell
        assert "-e SHARED_ASSETS_DIR=/content/shared" in shell
        assert '"${SHARED_ARGS[@]}"' in shell
        assert "DOCS_PROFILE=canonical-provider" in shell
        assert "BUILDER_DIGEST=$BUILDER_IMAGE" in shell
        assert "verify_canonical_hierarchy.py" in shell


if __name__ == "__main__":
    unittest.main()
