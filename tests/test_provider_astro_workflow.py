# ruff: noqa: INP001
"""Contract for canonical provider publication through the shared builder."""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class ProviderAstroWorkflow(unittest.TestCase):
    def test_canonical_builder_uses_qualified_digest_consistently(self):
        text = (ROOT / ".github/workflows/github-pages-deploy.yml").read_text()
        digest = (
            "sha256:72ab6ad2488d391b86d737c1375f782876cce16501f567d327db1caae0f3a7ae"
        )
        assert text.count("ghcr.io/f5-sales-demo/docs-builder@" + digest) == 2

    def test_named_content_callers_use_the_verified_builder(self):
        image = "ghcr.io/f5-sales-demo/docs-builder@sha256:72ab6ad2488d391b86d737c1375f782876cce16501f567d327db1caae0f3a7ae"
        pages = (ROOT / "workflows/github-pages-deploy.yml").read_text()
        config_sources = (
            ROOT / "workflows/github-pages-config-sources.yml"
        ).read_text()
        assert pages.count(image) == 2
        assert "f5-sales-demo/canada" in pages
        assert "f5-sales-demo/custom-responses" in pages
        assert config_sources.count(image) == 1

    def test_hierarchy_output_replaces_flat_index_comparison(self):
        text = (ROOT / ".github/workflows/github-pages-deploy.yml").read_text()
        assert 'cmp "$CONTENT_PATH/llms.txt"' not in text
        assert "verify_canonical_hierarchy.py" in text

    def test_provider_builds_current_documentation_once(self):
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
        assert "preview_output=" not in shell
        assert "version_path" not in shell
        assert "documentation-versions.json" not in shell
        assert "stage_documentation_versions.py" not in str(workflow)
        assert 'CONTENT_PATH="documentation"' in shell
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
