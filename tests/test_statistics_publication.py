# ruff: noqa: PT009 -- standard-library unittest assertions
"""Verify Statistics publication shares the qualified immutable builder."""

import json
import unittest
from pathlib import Path

import yaml

from tests.builder_publication_contract import (
    SHARED_BUILDER_IMAGE,
    require_shared_builder_selector,
)

ROOT = Path(__file__).resolve().parents[1]


class StatisticsPublicationTests(unittest.TestCase):
    def test_immutable_builder_selector_preserves_other_routes(self):
        workflow = yaml.safe_load(
            (ROOT / "workflows/github-pages-deploy.yml").read_text()
        )
        selector = workflow["jobs"]["docs"]["with"]["builder-image"]
        selector = require_shared_builder_selector(selector)
        self.assertRegex(
            selector, r"^ghcr.io/f5-sales-demo/docs-builder@sha256:[0-9a-f]{64}$"
        )
        self.assertEqual(workflow["jobs"]["docs"]["with"]["shared-mode"], "auto")
        self.assertEqual(
            workflow["jobs"]["docs"]["with"]["content-ref"], "${{ github.sha }}"
        )

    def test_statistics_and_other_guides_share_the_qualified_builder(self):
        workflow = yaml.safe_load(
            (ROOT / "workflows/github-pages-deploy.yml").read_text()
        )
        selector = workflow["jobs"]["docs"]["with"]["builder-image"]
        self.assertEqual(
            require_shared_builder_selector(selector), SHARED_BUILDER_IMAGE
        )

    def test_statistics_identity_and_existing_source_destinations(self):
        config = json.loads((ROOT / ".github/config/repo-settings.json").read_text())
        identity = config["repo_overrides"]["statistics"]["repository"]
        self.assertEqual(
            identity["homepage"], "https://f5-sales-demo.github.io/statistics/"
        )
        self.assertIn("across resource types", identity["description"])
        destinations = [entry["dest"] for entry in config["managed_files"]["files"]]
        self.assertEqual(len(destinations), len(set(destinations)))
        sites = json.loads((ROOT / ".github/config/docs-sites.json").read_text())
        site = next(entry for entry in sites if entry["label"] == "Statistics")
        self.assertTrue(site["readme_english_only"])
        self.assertEqual(
            site["url"], "https://f5-sales-demo.github.io/statistics/llms-full.txt"
        )


if __name__ == "__main__":
    unittest.main()
