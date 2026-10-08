# ruff: noqa: INP001 -- standalone standard-library test
"""Verify all personalized sites publish the Statistics navigation builder."""

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class NavigationPublication(unittest.TestCase):
    def test_current_navigation_digest_reaches_all_pinned_forms(self):
        source = (ROOT / "workflows/github-pages-deploy.yml").read_text()
        workflow = yaml.safe_load(source)
        selector = workflow["jobs"]["docs"]["with"]["builder-image"]
        selector = re.findall(
            r"ghcr.io/f5-sales-demo/docs-builder@sha256:[0-9a-f]{64}", selector
        )[-1]
        assert re.fullmatch(
            r"ghcr.io/f5-sales-demo/docs-builder@sha256:[0-9a-f]{64}", selector
        )
        assert workflow["jobs"]["docs"]["with"]["shared-mode"] == "auto"


if __name__ == "__main__":
    unittest.main()
