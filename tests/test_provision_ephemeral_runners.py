#!/usr/bin/env python3
# pylint: disable=consider-using-with
"""Hermetic tests for ephemeral runner host provisioning."""

import importlib.util
import io
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "provision_ephemeral_runners", ROOT / "scripts/provision-ephemeral-runners.py"
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ProvisionRunnerTests(unittest.TestCase):
    def test_inventory_is_repository_and_profile_scoped(self):
        items = MODULE.all_instances()
        self.assertGreaterEqual(len(items), 39)
        docs = [
            item for item in items if item.repository == "f5-sales-demo/docs-control"
        ]
        self.assertEqual(
            {item.profile for item in docs},
            {"ubuntu-24.04", "container-build"},
        )
        accounts = {item.profile: item.account for item in docs}
        self.assertEqual(accounts["ubuntu-24.04"], "gha-docs-control")
        self.assertEqual(accounts["container-build"], "ghb-docs-control")

    def test_runner_unit_keeps_credential_out_of_argv(self):
        unit = MODULE.runner_unit_text()
        self.assertIn("RUNNER_FLEET_GITHUB_TOKEN_FILE=", unit)
        self.assertIn("ProtectSystem=strict", unit)
        self.assertNotIn("ProtectKernelTunables=true", unit)
        self.assertIn("ProtectKernelModules=true", unit)
        self.assertIn("ProtectControlGroups=true", unit)
        self.assertNotIn("github.token serve", unit)
        self.assertNotIn("RuntimeDirectory=", unit)
        self.assertIn("/run/f5-actions-runner", unit)
        self.assertTrue(MODULE.ENTRYPOINT_SOURCE.is_file())

    def test_systemd_dropin_enforces_profile_resource_limits(self):
        item = next(
            item
            for item in MODULE.all_instances()
            if item.repository == "f5-sales-demo/docs-control"
            and item.profile == "ubuntu-24.04"
        )
        dropin = MODULE.resource_dropin_text(item)
        self.assertIn("RuntimeDirectory=f5-actions-runner/gha-docs-control", dropin)
        self.assertIn("MemoryMax=8G", dropin)
        self.assertIn("CPUQuota=400%", dropin)
        self.assertIn("TasksMax=4096", dropin)

    def test_container_socket_unit_uses_builder_account(self):
        item = next(
            item
            for item in MODULE.all_instances()
            if item.repository == "f5-sales-demo/docs-control" and item.container_socket
        )
        unit = MODULE.podman_unit_text(item)
        self.assertIn("User=ghb-docs-control", unit)
        self.assertIn(
            "unix:///run/f5-actions-podman/docs-control/podman.sock",
            unit,
        )

    def test_safe_write_is_atomic_and_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "credential"
            MODULE.safe_write(destination, "secret\n", 0o600)
            self.assertEqual(destination.read_text(), "secret\n")
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
            link = root / "link"
            link.symlink_to(destination)
            with self.assertRaises(MODULE.ProvisionError):
                MODULE.safe_write(link, "replacement")

    def test_credential_reads_stdin_and_writes_root_only(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "github.token"
            with (
                mock.patch.object(MODULE, "TOKEN_PATH", destination),
                mock.patch.object(MODULE.os, "geteuid", return_value=0),
                mock.patch.object(
                    MODULE.sys,
                    "stdin",
                    io.StringIO("x" * 40 + "\n"),
                ),
            ):
                MODULE.install_credential()
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
            self.assertEqual(destination.read_text(), "x" * 40 + "\n")


if __name__ == "__main__":
    unittest.main()
