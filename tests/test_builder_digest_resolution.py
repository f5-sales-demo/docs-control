"""Exercise the real workflow resolver before any builder image executes."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

from tests.builder_publication_contract import (
    SHARED_BUILDER_SELECTOR,
    require_shared_builder_selector,
)

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "ghcr.io/f5-sales-demo/docs-builder"
DIGEST = IMAGE + "@sha256:" + "0" * 64
OTHER_DIGEST = IMAGE + "@sha256:" + "1" * 64
DOCKER_FIXTURE = r"""
docker() {
  printf '%s\n' "$*" >> "$DOCKER_LOG"
  case "$1" in
    pull) return 0 ;;
    image) printf '%s\n' "$DIGEST_OUTPUT" ;;
    *) return 99 ;;
  esac
}
"""


class BuilderDigestResolutionTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="builder-resolver-test-"))
        self.addCleanup(shutil.rmtree, self.root)
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/github-pages-deploy.yml").read_text()
        )
        matches = [
            step
            for job in workflow["jobs"].values()
            for step in job.get("steps", [])
            if step.get("name") == "Resolve approved documentation builder"
        ]
        assert len(matches) == 1
        self.script = DOCKER_FIXTURE + matches[0]["run"]
        self.log = self.root / "docker.log"
        self.output = self.root / "outputs"

    def resolve(self, requested, returned=DIGEST, snapshot="false"):
        self.log.unlink(missing_ok=True)
        self.output.unlink(missing_ok=True)
        env = {
            **os.environ,
            "REQUESTED_IMAGE": requested,
            "SNAPSHOT_ENABLED": snapshot,
            "DIGEST_OUTPUT": returned,
            "DOCKER_LOG": str(self.log),
            "GITHUB_OUTPUT": str(self.output),
        }
        return subprocess.run(
            ["/bin/bash", "-e", "-o", "pipefail"],
            input=self.script,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_latest_and_pinned_inputs_export_only_the_verified_digest(self):
        for requested in (IMAGE + ":latest", DIGEST):
            with self.subTest(requested=requested):
                result = self.resolve(requested)
                assert result.returncode == 0, result.stderr
                assert self.output.read_text() == "builder_image=" + DIGEST + "\n"
                assert ":latest" not in self.output.read_text()

    def test_ambiguous_foreign_missing_and_mismatched_digest_refuse(self):
        cases = (
            (IMAGE + ":latest", DIGEST + "\n" + OTHER_DIGEST),
            (IMAGE + ":latest", "ghcr.io/foreign/docs-builder@sha256:" + "0" * 64),
            (IMAGE + ":latest", ""),
            (DIGEST, OTHER_DIGEST),
        )
        for requested, returned in cases:
            with self.subTest(requested=requested, returned=returned):
                result = self.resolve(requested, returned)
                assert result.returncode != 0
                assert not self.output.exists()

    def test_foreign_tag_injection_and_mutable_snapshot_refuse_before_pull(self):
        marker = self.root / "injection-marker"
        for requested, snapshot in (
            ("ghcr.io/foreign/docs-builder:latest", "false"),
            (IMAGE + ":unreviewed", "false"),
            (IMAGE + ":latest; touch " + str(marker), "false"),
            (IMAGE + ":latest", "true"),
        ):
            with self.subTest(requested=requested, snapshot=snapshot):
                result = self.resolve(requested, snapshot=snapshot)
                assert result.returncode != 0
                assert not self.log.exists()
                assert not self.output.exists()
                assert not marker.exists()
        assert self.resolve(DIGEST, snapshot="true").returncode == 0

    def test_selector_rejects_extra_or_foreign_branches_and_shared_pin_changes(self):
        assert require_shared_builder_selector(SHARED_BUILDER_SELECTOR)
        for changed in (
            SHARED_BUILDER_SELECTOR.replace("certificate-management", "foreign"),
            SHARED_BUILDER_SELECTOR.replace(" || ", " || 'unreviewed' || "),
            SHARED_BUILDER_SELECTOR.replace("8fcc5e", "9fcc5e"),
        ):
            refused = False
            try:
                require_shared_builder_selector(changed)
            except AssertionError:
                refused = True
            assert refused


if __name__ == "__main__":
    unittest.main()
