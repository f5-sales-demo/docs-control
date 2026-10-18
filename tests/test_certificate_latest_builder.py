# ruff: noqa: INP001 -- standalone standard-library test
"""Ensure prerelease Certificate Management resolves the latest builder."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CertificateLatestBuilder(unittest.TestCase):
    def test_certificate_selector_uses_latest(self):
        source = (ROOT / "workflows/github-pages-deploy.yml").read_text()
        assert (
            "github.repository == 'f5-sales-demo/certificate-management' && "
            "'ghcr.io/f5-sales-demo/docs-builder:latest'"
        ) in source


if __name__ == "__main__":
    unittest.main()
