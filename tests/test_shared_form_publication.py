# ruff: noqa: INP001 -- standalone standard-library test
"""Verify active personalized form sites use one immutable builder."""

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class SharedFormPublication(unittest.TestCase):
    def test_form_consumers_use_one_digest(self):
        source = (ROOT / "workflows/github-pages-deploy.yml").read_text()
        workflow = yaml.safe_load(source)
        selector = workflow["jobs"]["docs"]["with"]["builder-image"]
        assert re.fullmatch(
            r"ghcr.io/f5-sales-demo/docs-builder@sha256:[0-9a-f]{64}", selector
        )
        assert workflow["jobs"]["docs"]["with"]["shared-mode"] == "auto"


if __name__ == "__main__":
    unittest.main()
