# ruff: noqa: INP001 -- standalone standard-library test
"""Verify active personalized form sites use one immutable builder."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class SharedFormPublication(unittest.TestCase):
    def test_form_consumers_use_one_digest(self):
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
        pins = [choices.get("f5-sales-demo/" + site, "") for site in sites]
        assert len(set(pins)) == 1
        assert re.fullmatch(
            r"ghcr.io/f5-sales-demo/docs-builder@sha256:[0-9a-f]{64}", pins[0]
        )


if __name__ == "__main__":
    unittest.main()
