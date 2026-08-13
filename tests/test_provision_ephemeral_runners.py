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
    def test_runner_images_include_pyyaml_and_separate_docker_target(self):
        content = (ROOT / "runner-images/Containerfile").read_text(encoding="utf-8")
        self.assertIn("python3-yaml", content)
        self.assertLess(content.index("python3-yaml"), content.index("AS socketless"))
        socketless = content.split("FROM runner-base AS socketless", 1)[1].split(
            "FROM runner-base AS docker-capable", 1
        )[0]
        docker_capable = content.split("FROM runner-base AS docker-capable", 1)[1]
        self.assertNotIn("/usr/local/bin/docker", socketless)
        self.assertIn("/usr/local/bin/docker", docker_capable)
        self.assertIn("docker-buildx", docker_capable)
        self.assertIn("docker-compose", docker_capable)
        self.assertNotIn(
            "apt-get install --yes --no-install-recommends docker.io", content
        )
        self.assertNotIn(" podman", content)
        digest = (
            "sha256:e650b7a58d7f56be91d4f7be799196380a3bbc1bcbc41f1f4dff1b36ac309e1e"
        )
        self.assertIn(f"docker:29.7.2-cli@{digest}", content)

    def test_runner_image_publish_uses_buildx_metadata_and_smoke_tests(self):
        content = (ROOT / ".github/workflows/publish-runner-images.yml").read_text(
            encoding="utf-8"
        )
        for required in (
            'docker --config "$auth_dir" buildx build',
            '--metadata-file "$metadata_file"',
            "--push",
            "containerimage.digest",
            "imagetools inspect --raw",
            "sha256sum",
            "DOCKER_CLI_PLUGIN_EXTRA_DIRS",
            "docker cp",
            'runner_root="${RUNNER_RUNTIME_DIR:?}"',
            'python3 -c "import yaml"',
            "docker buildx version",
            "docker compose version",
        ):
            self.assertIn(required, content)
        self.assertIn(
            "e650b7a58d7f56be91d4f7be799196380a3bbc1bcbc41f1f4dff1b36ac309e1e",
            content,
        )
        self.assertNotIn("podman", content)

    def test_every_governed_repository_has_container_build_profile(self):
        by_repository = {}
        for item in MODULE.all_instances():
            by_repository.setdefault(item.repository, set()).add(item.profile)
        self.assertEqual(len(by_repository), 39)
        self.assertTrue(
            all("container-build" in profiles for profiles in by_repository.values())
        )

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
        sockets = {item.profile: item.docker_socket for item in docs}
        self.assertFalse(sockets["ubuntu-24.04"])
        self.assertTrue(sockets["container-build"])

    def test_runner_unit_keeps_credential_out_of_argv(self):
        unit = MODULE.runner_unit_text()
        self.assertIn("RUNNER_FLEET_GITHUB_TOKEN_FILE=", unit)
        self.assertIn("ProtectSystem=strict", unit)
        self.assertIn("ProtectKernelTunables=true", unit)
        self.assertIn("ProtectKernelModules=true", unit)
        self.assertIn("ProtectControlGroups=true", unit)
        self.assertIn("Requires=docker.service", unit)
        self.assertIn("After=docker.service", unit)
        self.assertIn("Restart=on-failure", unit)
        self.assertNotIn("Restart=always", unit)
        self.assertNotIn("github.token serve", unit)
        self.assertNotIn("RuntimeDirectory=", unit)
        self.assertIn("/run/docker.sock", unit)
        self.assertNotIn("f5-actions-podman", unit)
        self.assertTrue(MODULE.ENTRYPOINT_SOURCE.is_file())

    def test_profile_resource_limits_are_owned_by_docker_controller(self):
        item = next(
            item
            for item in MODULE.all_instances()
            if item.repository == "f5-sales-demo/docs-control"
            and item.profile == "ubuntu-24.04"
        )
        self.assertEqual(item.memory, "8g")
        self.assertEqual(item.cpus, "4")
        self.assertEqual(item.pids_limit, 4096)
        self.assertEqual(item.stop_timeout, 300)
        self.assertEqual(item.network, "bridge")

    def test_install_removes_only_exact_legacy_resource_dropin(self):
        item = MODULE.all_instances()[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dropin_dir = root / f"{item.unit}.d"
            dropin_dir.mkdir()
            legacy = dropin_dir / "resources.conf"
            unrelated = dropin_dir / "operator.conf"
            legacy.write_text("RuntimeDirectory=legacy\n", encoding="utf-8")
            unrelated.write_text("RestartSec=10\n", encoding="utf-8")
            with mock.patch.object(MODULE, "SYSTEMD_ROOT", root):
                MODULE.remove_legacy_resource_dropin(item)
            self.assertFalse(legacy.exists())
            self.assertEqual(unrelated.read_text(encoding="utf-8"), "RestartSec=10\n")

    def test_enable_requires_shared_docker_service_before_runner(self):
        calls = []
        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "TOKEN_PATH") as token_path,
            mock.patch.object(
                MODULE, "select", return_value=[MODULE.all_instances()[0]]
            ),
            mock.patch.object(
                MODULE,
                "command",
                side_effect=lambda argv, **_kwargs: calls.append(argv),
            ),
        ):
            token_path.is_file.return_value = True
            MODULE.enable("f5-sales-demo/docs-control")
        self.assertEqual(calls[0], ["systemctl", "start", "docker.service"])
        self.assertEqual(calls[1][0:3], ["systemctl", "enable", "--now"])

    def test_retirement_removes_only_known_inactive_legacy_units(self):
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "f5-actions-podman-docs-control.service"
            legacy.write_text("legacy", encoding="utf-8")

            def command(argv, **_kwargs):
                calls.append(argv)
                if argv[:2] == ["systemctl", "is-active"]:
                    return mock.Mock(returncode=3, stdout="inactive\n", stderr="")
                return mock.Mock(returncode=0, stdout="", stderr="")

            with (
                mock.patch.object(MODULE, "require_root"),
                mock.patch.object(MODULE, "SYSTEMD_ROOT", root),
                mock.patch.object(MODULE, "command", side_effect=command),
            ):
                MODULE.retire_legacy_podman_units()
            self.assertFalse(legacy.exists())
        self.assertIn(
            ["systemctl", "disable", "--now", "f5-actions-podman-docs-control.service"],
            calls,
        )

    def test_retirement_fails_when_runner_unit_is_active(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "f5-actions-podman-docs-control.service"
            legacy.write_text("legacy", encoding="utf-8")
            active = mock.Mock(returncode=0, stdout="active\n", stderr="")
            with (
                mock.patch.object(MODULE, "require_root"),
                mock.patch.object(MODULE, "SYSTEMD_ROOT", root),
                mock.patch.object(MODULE, "command", return_value=active),
                self.assertRaises(MODULE.ProvisionError),
            ):
                MODULE.retire_legacy_podman_units()
            self.assertTrue(legacy.exists())

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
