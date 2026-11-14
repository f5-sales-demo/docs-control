"""Verify all personalized sites publish the Statistics navigation builder."""

import unittest
from pathlib import Path

import yaml

from tests.builder_publication_contract import require_shared_builder_selector

ROOT = Path(__file__).resolve().parents[1]


class NavigationPublication(unittest.TestCase):
    def test_current_navigation_digest_reaches_all_pinned_forms(self):
        source = (ROOT / "workflows/github-pages-deploy.yml").read_text()
        workflow = yaml.safe_load(source)
        selector = workflow["jobs"]["docs"]["with"]["builder-image"]
        require_shared_builder_selector(selector)
        assert workflow["jobs"]["docs"]["with"]["shared-mode"] == "auto"


if __name__ == "__main__":
    unittest.main()
