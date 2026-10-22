"""Keep the CE revision exception narrower than credential-shaped input."""

# ruff: noqa: INP001 - tests are collected as standalone modules.
from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REVISION = "".join(("c25d01b0ae4bb828e2af", "ec9152e579ea6178e397"))


class TestCeRevisionGitleaks:
    def scan(self, key, value):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "input.json").write_text(
                "// sourcegraph\n" + json.dumps({key: value}, indent=2) + "\n"
            )
            report = path / "report.json"
            result = subprocess.run(  # noqa: S603 - fixed scanner argv and generated private fixtures.
                [
                    shutil.which("gitleaks"),
                    "dir",
                    str(path),
                    "--config",
                    str(ROOT / ".gitleaks.toml"),
                    "--redact",
                    "--no-banner",
                    "--report-format",
                    "json",
                    "--report-path",
                    str(report),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            assert result.returncode in (0, 1), result.stderr
            return result.returncode, json.loads(
                report.read_text()
            ) if report.exists() else []

    def test_exact_archive_source_metadata_passes(self):
        assert self.scan("sourceCommit", REVISION)[0] == 0

    def test_same_revision_under_credential_key_is_rejected(self):
        status, findings = self.scan("sourcegraph", REVISION)
        assert status == 1
        assert "sourcegraph-access-token" in [row["RuleID"] for row in findings]

    def test_prefixed_sourcegraph_token_is_rejected_under_metadata_key(self):
        status, findings = self.scan("sourceCommit", "sgp_" + REVISION)
        assert status == 1
        assert "sourcegraph-access-token" in [row["RuleID"] for row in findings]

    def test_other_hash_under_metadata_key_is_rejected(self):
        status, _ = self.scan("sourceCommit", "b" + REVISION[1:])
        assert status == 1
