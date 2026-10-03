# ruff: noqa: INP001
"""Contract for canonical provider publication through the shared builder."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class ProviderAstroWorkflow(unittest.TestCase):
    def test_canonical_builder_uses_qualified_digest_consistently(self):
        text = (ROOT / ".github/workflows/github-pages-deploy.yml").read_text()
        digest = "sha256:f0236866ff6cf36eef78635520262af9f443f390018e605a90cd1cfa33c872da"
        assert text.count("ghcr.io/f5-sales-demo/docs-builder@" + digest) == 2

    def test_provider_builds_preview_before_stable_with_isolated_versions(self):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/github-pages-deploy.yml").read_text()
        )
        build = workflow["jobs"]["build"]
        step = next(
            item
            for item in build["steps"]
            if item.get("name") == "Build docs with container"
        )
        shell = step["run"]
        assert "--entrypoint node" not in shell
        assert "render-doc-collections" not in shell
        assert shell.index("preview_output=") < shell.index("COLLECTION_ARGS=()")
        assert "DOCS_BASE=/terraform-provider-xcsh/preview/main/" in shell
        assert "DOCS_BASE=/terraform-provider-xcsh/$prefix/" in shell
        assert "DOCS_PROFILE=canonical-provider" in shell
        assert "BUILDER_DIGEST=$BUILDER_IMAGE" in shell
        assert "canonical provider requires the accepted immutable builder" in shell
        verify = next(
            item for item in build["steps"] if item.get("name") == "Verify build output"
        )["run"]
        assert "10000000000" in verify
        assert "Assembled Pages artifact:" in verify


if __name__ == "__main__":
    unittest.main()
