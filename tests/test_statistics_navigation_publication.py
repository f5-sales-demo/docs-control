# ruff: noqa: INP001 -- standalone standard-library test
"""Verify all personalized sites publish the Statistics navigation builder."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class NavigationPublication(unittest.TestCase):
    def test_current_navigation_digest_reaches_all_pinned_forms(self):
        source = (ROOT / "workflows/github-pages-deploy.yml").read_text()
        choices = dict(
            re.findall(r"github.repository == '([^']+)' && '([^']+)'", source)
        )
        sites = [
            "statistics",
            "csd",
            "dns",
            "ddos",
            "webapp-api-protection",
            "traffic-generator",
            "demo-resource-template",
        ]
        assert len({choices["f5-sales-demo/" + name] for name in sites}) == 1
        assert choices["f5-sales-demo/statistics"] == (
            "ghcr.io/f5-sales-demo/docs-builder@sha256:"
            "028e44347401ab5d4ae3ce782f5da11907e04b3f90ad22723e8fd04f56968d28"
        )


if __name__ == "__main__":
    unittest.main()
