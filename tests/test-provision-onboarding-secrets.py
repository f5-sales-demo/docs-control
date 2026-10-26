# ruff: noqa: INP001, PT009, PT027, SIM117
# Standalone standard-library unittest fixtures run without pytest installation.
"""Hermetic enrollment, credential transport and GitHub failure fixtures."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/provision-onboarding-secrets.py"
SPEC = importlib.util.spec_from_file_location("onboarding_secrets", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SETTINGS = "CANONICAL_SETTINGS_SENTINEL"
SYNC = "CANONICAL_SYNC_SENTINEL"


def response(names: list[str], code: int = 0) -> subprocess.CompletedProcess[str]:
    """Simulate the exact metadata-only CLI contract."""
    return subprocess.CompletedProcess(
        ["gh"], code, json.dumps([{"name": name} for name in names]), SYNC
    )


class ProvisionTests(unittest.TestCase):
    """Every fixture stays local and checks the concrete transport boundary."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / ".github/config"
        self.config.mkdir(parents=True)
        (self.config / "downstream-repos.json").write_text(json.dumps(["target"]))
        self.settings = {
            "secrets_manifest": {
                "roles": {"governance": list(MODULE.SECRETS)},
                "repo_roles": {"_default": ["governance"]},
            }
        }
        self.write_settings()
        env = patch.dict(
            os.environ,
            {
                "GH_TOKEN": SETTINGS,
                "REPO_SETTINGS_TOKEN": SETTINGS,
                "REPO_SYNC_TOKEN": SYNC,
            },
        )
        cli = patch.object(MODULE.shutil, "which", return_value="/usr/bin/gh")
        cli.start()
        self.addCleanup(cli.stop)
        env.start()
        self.addCleanup(env.stop)

    def write_settings(self) -> None:
        (self.config / "repo-settings.json").write_text(json.dumps(self.settings))

    def test_preview_never_writes(self) -> None:
        with patch.object(MODULE.subprocess, "run", return_value=response([])) as run:
            result = MODULE.provision(self.root, "target", dry_run=True)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(result["written_secret_names"], [])
        self.assertEqual(result["missing_before"], list(MODULE.SECRETS))

    def test_only_missing_secret_crosses_stdin(self) -> None:
        with patch.object(
            MODULE.subprocess,
            "run",
            side_effect=[
                response([MODULE.SECRETS[0]]),
                response([]),
                response(list(MODULE.SECRETS)),
            ],
        ) as run:
            result = MODULE.provision(self.root, "target", dry_run=False)
        call = run.call_args_list[1]
        self.assertEqual(
            call.args[0],
            [
                "/usr/bin/gh",
                "secret",
                "set",
                MODULE.SECRETS[1],
                "--repo",
                "f5-sales-demo/target",
            ],
        )
        self.assertEqual(call.kwargs["input"], SYNC)
        self.assertNotIn(SYNC, json.dumps(call.args))
        self.assertNotIn(SETTINGS, json.dumps(result))
        self.assertNotIn(SYNC, json.dumps(result))

    def test_both_missing_credentials_cross_stdin(self) -> None:
        with patch.object(
            MODULE.subprocess,
            "run",
            side_effect=[
                response([]),
                response([]),
                response([]),
                response(list(MODULE.SECRETS)),
            ],
        ) as run:
            result = MODULE.provision(self.root, "target", dry_run=False)
        self.assertEqual(
            [call.kwargs["input"] for call in run.call_args_list[1:3]], [SETTINGS, SYNC]
        )
        self.assertEqual(result["written_secret_names"], list(MODULE.SECRETS))
        for call in run.call_args_list:
            self.assertNotIn(SETTINGS, json.dumps(call.args))
            self.assertNotIn(SYNC, json.dumps(call.args))

    def test_missing_cli_is_safe(self) -> None:
        with patch.object(MODULE.shutil, "which", return_value=None):
            with self.assertRaises(MODULE.ProvisionError):
                MODULE.provision(self.root, "target", dry_run=True)

    def test_existing_secrets_are_not_rewritten(self) -> None:
        with patch.object(
            MODULE.subprocess, "run", return_value=response(list(MODULE.SECRETS))
        ) as run:
            result = MODULE.provision(self.root, "target", dry_run=False)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(result["written_secret_names"], [])

    def test_invalid_and_unenrolled_names_fail_before_cli(self) -> None:
        for name in ("../target", "owner/target", "target\n", "unknown"):
            with self.subTest(name=name), patch.object(MODULE.subprocess, "run") as run:
                with self.assertRaises(MODULE.ProvisionError):
                    MODULE.provision(self.root, name, dry_run=False)
                run.assert_not_called()

    def test_changed_secret_role_is_rejected(self) -> None:
        self.settings["secrets_manifest"]["roles"]["governance"] = ["OTHER"]
        self.write_settings()
        with patch.object(MODULE.subprocess, "run") as run:
            with self.assertRaises(MODULE.ProvisionError):
                MODULE.provision(self.root, "target", dry_run=False)
            run.assert_not_called()

    def test_duplicate_inventory_is_rejected(self) -> None:
        (self.config / "downstream-repos.json").write_text('["target", "target"]')
        with self.assertRaises(MODULE.ProvisionError):
            MODULE.provision(self.root, "target", dry_run=True)

    def test_missing_or_wrong_source_credentials_fail_before_cli(self) -> None:
        for name in (*MODULE.SECRETS, "GH_TOKEN"):
            with (
                self.subTest(name=name),
                patch.dict(os.environ, {name: ""}),
                patch.object(MODULE.subprocess, "run") as run,
            ):
                with self.assertRaises(MODULE.ProvisionError):
                    MODULE.provision(self.root, "target", dry_run=False)
                run.assert_not_called()

    def test_api_failures_do_not_disclose_responses(self) -> None:
        for responses in ([response([], 1)], [response([]), response([], 1)]):
            with (
                self.subTest(responses=responses),
                patch.object(MODULE.subprocess, "run", side_effect=responses),
            ):
                with self.assertRaises(MODULE.ProvisionError) as error:
                    MODULE.provision(self.root, "target", dry_run=False)
                self.assertNotIn(SYNC, str(error.exception))

    def test_malformed_secret_metadata_is_rejected(self) -> None:
        for raw in (
            "{}",
            "not JSON",
            '[{"name":"bad\\nname"}]',
            '[{"name":"A"},{"name":"A"}]',
        ):
            with (
                self.subTest(raw=raw),
                patch.object(
                    MODULE.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess(["gh"], 0, raw, SYNC),
                ),
            ):
                with self.assertRaises(MODULE.ProvisionError):
                    MODULE.provision(self.root, "target", dry_run=True)

    def test_unconfirmed_write_cannot_pass(self) -> None:
        with patch.object(
            MODULE.subprocess,
            "run",
            side_effect=[
                response([MODULE.SECRETS[0]]),
                response([]),
                response([MODULE.SECRETS[0]]),
            ],
        ):
            with self.assertRaises(MODULE.ProvisionError):
                MODULE.provision(self.root, "target", dry_run=False)


if __name__ == "__main__":
    unittest.main()
