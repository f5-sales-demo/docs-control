#!/usr/bin/env python3
# pylint: disable=consider-using-with,too-many-lines
"""Hermetic tests for ephemeral runner host provisioning."""

import importlib.util
import io
import json
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "provision_ephemeral_runners", ROOT / "scripts/provision-ephemeral-runners.py"
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE


def runner_service(profile: str) -> str:
    return "f5-actions-runner" + f"@docs-control--{profile}--0.service"


SPEC.loader.exec_module(MODULE)


class ProvisionRunnerTests(unittest.TestCase):  # pylint: disable=too-many-public-methods
    def test_installed_provisioner_resolves_installed_runner_assets(self):
        installed = MODULE.INSTALL_ROOT / "provision-ephemeral-runners.py"
        root, controller, entrypoint, initializer, policy = MODULE.source_paths(
            installed
        )
        self.assertEqual(root, MODULE.INSTALL_ROOT)
        self.assertEqual(
            controller, MODULE.INSTALL_ROOT / "ephemeral-runner-controller.py"
        )
        self.assertEqual(entrypoint, MODULE.INSTALL_ROOT / "runner-entrypoint.sh")
        self.assertEqual(
            initializer, MODULE.INSTALL_ROOT / "prepare-runner-tool-cache.sh"
        )
        self.assertEqual(policy, MODULE.INSTALL_ROOT / "self-hosted-runner-policy.json")
        self.assertEqual(
            MODULE.source_paths(MODULE.PROVISIONER_SOURCE),
            (
                MODULE.SOURCE_ROOT,
                MODULE.CONTROLLER_SOURCE,
                MODULE.ENTRYPOINT_SOURCE,
                MODULE.TOOL_CACHE_INITIALIZER_SOURCE,
                MODULE.POLICY_SOURCE,
            ),
        )

    def test_runner_image_authority_is_external_and_digest_pinned(self):
        self.assertFalse((ROOT / "runner-images/Containerfile").exists())
        self.assertFalse(
            (ROOT / ".github/workflows/publish-runner-images.yml").exists()
        )
        for profile in MODULE.active_policy().profiles.values():
            self.assertTrue(
                profile.image.startswith(
                    "ghcr.io/f5-sales-demo/self-hosted-runner@sha256:"
                )
            )

    def test_every_governed_repository_has_container_build_profile(self):
        by_repository: dict[str, set[str]] = {}
        for item in MODULE.all_instances():
            by_repository.setdefault(item.repository, set()).add(item.profile)
        self.assertEqual(len(by_repository), 39)
        self.assertTrue(
            all("container-build" in profiles for profiles in by_repository.values())
        )

    def test_inventory_is_repository_and_profile_scoped(self):
        items = MODULE.all_instances()
        self.assertEqual(len(items), 81)
        docs = [
            item for item in items if item.repository == "f5-sales-demo/docs-control"
        ]
        self.assertEqual(
            {item.profile for item in docs},
            {
                "ubuntu-24.04",
                "ubuntu-24.04-secondary",
                "automation",
                "container-build",
            },
        )
        sockets = {item.profile: item.docker_socket for item in docs}
        self.assertFalse(sockets["ubuntu-24.04"])
        self.assertFalse(sockets["ubuntu-24.04-secondary"])
        self.assertFalse(sockets["automation"])
        self.assertTrue(sockets["container-build"])

    def test_api_specs_enriched_has_secondary_socketless_capacity(self):
        runners = {
            item.profile: item
            for item in MODULE.all_instances()
            if item.repository == "f5-sales-demo/api-specs-enriched"
        }

        self.assertEqual(
            set(runners),
            {"ubuntu-24.04", "ubuntu-24.04-secondary", "container-build"},
        )
        self.assertFalse(runners["ubuntu-24.04"].docker_socket)
        self.assertFalse(runners["ubuntu-24.04-secondary"].docker_socket)

    def test_fleet_watcher_uses_dedicated_socketless_automation_profile(self):
        workflow = (ROOT / ".github/workflows/antigravity-fleet-watcher.yml").read_text(
            encoding="utf-8"
        )
        route = (
            "runs-on: [self-hosted, Linux, X64, "
            '"${{ github.event.repository.name }}", automation]'
        )
        self.assertEqual(workflow.count(route), 3)
        self.assertNotIn(
            "runs-on: [self-hosted, Linux, X64, "
            '"${{ github.event.repository.name }}", ubuntu-24.04]',
            workflow,
        )

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
        self.assertTrue(MODULE.TOOL_CACHE_INITIALIZER_SOURCE.is_file())

    def test_capacity_guard_installs_a_persistent_systemd_timer(self):
        unit = MODULE.capacity_unit_text()
        timer = MODULE.capacity_timer_text()
        self.assertIn("capacity-check", unit)
        self.assertIn("/opt/f5-actions-runner/provision-ephemeral-runners.py", unit)
        self.assertIn("OnCalendar=*:0/15", timer)
        self.assertIn("Persistent=true", timer)
        self.assertNotIn("OnUnitActiveSec=", timer)

    def test_standby_scaler_uses_a_persistent_calendar_timer(self):
        timer = MODULE.standby_scaler_timer_text()
        self.assertIn("OnCalendar=*:*:00", timer)
        self.assertIn("Persistent=true", timer)
        self.assertNotIn("OnUnitActiveSec=", timer)

    def test_retired_reconciler_uses_a_persistent_calendar_timer(self):
        unit = MODULE.retired_reconciler_unit_text()
        timer = MODULE.retired_reconciler_timer_text()
        self.assertIn("retire-orphans --apply", unit)
        self.assertIn("OnCalendar=*:0/15", timer)
        self.assertIn("Persistent=true", timer)
        self.assertNotIn("OnBootSec=", timer)
        self.assertNotIn("OnUnitActiveSec=", timer)

    def test_capacity_guard_fails_closed_below_either_free_space_limit(self):
        healthy = type("Usage", (), {"total": 1000, "used": 800, "free": 200})()
        low_bytes = type("Usage", (), {"total": 1000, "used": 901, "free": 99})()
        low_percent = type("Usage", (), {"total": 1000, "used": 950, "free": 50})()

        def check(usage):
            with (
                mock.patch.object(
                    MODULE, "capacity_paths", return_value=(Path("/data"),)
                ),
                mock.patch.object(MODULE, "CAPACITY_MIN_FREE_BYTES", 100),
                mock.patch.object(MODULE, "CAPACITY_MIN_FREE_PERCENT", 10),
                mock.patch.object(MODULE.shutil, "disk_usage", return_value=usage),
            ):
                return MODULE.capacity_check()

        self.assertEqual(check(healthy), 0)
        self.assertEqual(check(low_bytes), 1)
        self.assertEqual(check(low_percent), 1)

    def test_install_enables_capacity_timer(self):
        calls = []
        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(Path, "mkdir"),
            mock.patch.object(MODULE, "active_policy", return_value=object()),
            mock.patch.object(MODULE, "instances", return_value=()),
            mock.patch.object(MODULE, "standby_instances", return_value=()),
            mock.patch.object(MODULE, "safe_write"),
            mock.patch.object(
                MODULE,
                "command",
                side_effect=lambda argv, **_kwargs: calls.append(argv),
            ),
        ):
            MODULE.install_definition()
        self.assertIn(["systemctl", "enable", "--now", MODULE.CAPACITY_TIMER], calls)
        self.assertIn(["systemctl", "enable", "--now", MODULE.STANDBY_TIMER], calls)
        self.assertIn(
            ["systemctl", "enable", "--now", MODULE.PROFILE_DISPATCH_TIMER], calls
        )
        self.assertIn(["systemctl", "enable", "--now", MODULE.RETIRED_TIMER], calls)
        self.assertIn(
            [
                "install",
                "-o",
                "root",
                "-g",
                "root",
                "-m",
                "0755",
                str(MODULE.PROVISIONER_SOURCE),
                str(MODULE.INSTALL_ROOT / MODULE.PROVISIONER_SOURCE.name),
            ],
            calls,
        )
        self.assertTrue(
            any(
                call[-2:]
                == [
                    str(MODULE.TOOL_CACHE_INITIALIZER_SOURCE),
                    str(
                        MODULE.INSTALL_ROOT / MODULE.TOOL_CACHE_INITIALIZER_SOURCE.name
                    ),
                ]
                for call in calls
            )
        )

    def test_install_can_preserve_disabled_fleet_timers(self):
        calls = []
        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(Path, "mkdir"),
            mock.patch.object(MODULE, "active_policy", return_value=object()),
            mock.patch.object(MODULE, "instances", return_value=()),
            mock.patch.object(MODULE, "standby_instances", return_value=()),
            mock.patch.object(MODULE, "safe_write"),
            mock.patch.object(
                MODULE,
                "command",
                side_effect=lambda argv, **_kwargs: calls.append(argv),
            ),
        ):
            MODULE.install_definition(enable_timers=False)
        for timer in (
            MODULE.STANDBY_TIMER,
            MODULE.PROFILE_DISPATCH_TIMER,
            MODULE.CAPACITY_TIMER,
            MODULE.RETIRED_TIMER,
        ):
            self.assertNotIn(["systemctl", "enable", "--now", timer], calls)

    def test_profile_resource_limits_are_owned_by_docker_controller(self):
        for profile in ("ubuntu-24.04", "automation"):
            item = next(
                item
                for item in MODULE.all_instances()
                if item.repository == "f5-sales-demo/docs-control"
                and item.profile == profile
            )
            self.assertEqual(item.memory, "8g")
            self.assertEqual(item.cpus, "4")
            self.assertEqual(item.pids_limit, 4096)
            self.assertEqual(item.stop_timeout, 300)
            self.assertEqual(item.network, "bridge")

    def test_audit_fails_when_capacity_guard_reports_exhaustion(self):
        controller = type("Controller", (), {"audit_containers": lambda *_args: ()})()
        controller_module = type(
            "ControllerModule",
            (),
            {"EphemeralController": lambda *_args: controller},
        )()
        with (
            mock.patch.object(MODULE, "capacity_check", return_value=1),
            mock.patch.object(MODULE, "select", return_value=[]),
            mock.patch.object(MODULE, "docker_host_errors", return_value=[]),
            mock.patch.object(
                MODULE, "load_controller", return_value=controller_module
            ),
        ):
            self.assertEqual(MODULE.audit("f5-sales-demo/docs-control"), 1)

    def test_automation_uses_current_socketless_runner_image(self):
        policy = json.loads(
            (ROOT / ".github/config/self-hosted-runner-policy.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            policy["profiles"]["automation"]["image"],
            policy["profiles"]["ubuntu-24.04"]["image"],
        )

    def test_secondary_standard_lane_matches_primary_profile(self):
        policy = json.loads(
            (ROOT / ".github/config/self-hosted-runner-policy.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            policy["profiles"]["ubuntu-24.04-secondary"],
            policy["profiles"]["ubuntu-24.04"],
        )

    def test_socketless_standby_instances_and_scaler_are_fleet_wide(self):
        policy = json.loads(
            (ROOT / ".github/config/self-hosted-runner-policy.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(policy["defaults"]["standby_profiles"], ["ubuntu-24.04"])
        standby = MODULE.standby_instances()
        self.assertEqual(len(standby), 39)
        self.assertTrue(
            all(
                item.profile == "ubuntu-24.04" and not item.docker_socket
                for item in standby
            )
        )
        unit = MODULE.standby_scaler_unit_text()
        for expected in (
            "RUNNER_FLEET_GITHUB_TOKEN_FILE=",
            "standby-scale",
            "NoNewPrivileges=true",
            "ProtectSystem=strict",
            "ProtectHome=true",
            "ReadWritePaths=/data/actions-runners",
        ):
            self.assertIn(expected, unit)
        self.assertNotIn("/run/docker.sock", unit)
        self.assertIn("${RUNNER_MODE}", MODULE.runner_unit_text())
        self.assertEqual({item.mode for item in MODULE.all_instances()}, {"serve"})
        self.assertEqual({item.mode for item in standby}, {"once"})

    def test_profile_dispatcher_has_a_persistent_calendar_timer(self):
        unit = MODULE.profile_dispatcher_unit_text()
        timer = MODULE.profile_dispatcher_timer_text()
        self.assertIn("dispatch-queued-profiles", unit)
        self.assertIn("TimeoutStartSec=55", unit)
        self.assertIn("OnCalendar=*:*:00", timer)
        self.assertIn("Persistent=true", timer)
        self.assertNotIn("OnUnitActiveSec=", timer)

    def test_docker_trust_gate_accepts_only_canonical_direct_or_reusable_names(self):
        self.assertTrue(
            MODULE.successful_docker_trust_gate(
                {"name": "Trust Docker-capable job", "conclusion": "success"}
            )
        )
        self.assertTrue(
            MODULE.successful_docker_trust_gate(
                {"name": "lint / Trust Docker-capable job", "conclusion": "success"}
            )
        )
        for job in (
            {"name": "release / Trust Docker-capable job", "conclusion": "success"},
            {"name": "lint / Trust Docker-capable job", "conclusion": "failure"},
            {"name": "Trust Docker-capable job", "conclusion": None},
        ):
            self.assertFalse(MODULE.successful_docker_trust_gate(job))

    def test_profile_dispatcher_routes_only_exact_labels_after_docker_trust(self):
        policy = MODULE.active_policy()
        docs = "f5-sales-demo/docs-control"
        standard = ["self-hosted", "Linux", "X64", "docs-control", "ubuntu-24.04"]
        builder = ["self-hosted", "Linux", "X64", "docs-control", "container-build"]
        automation = ["self-hosted", "Linux", "X64", "docs-control", "automation"]

        class GitHub:
            def request(self, _method, request_path):
                if (
                    "runs?status=queued&per_page=100" in request_path
                    or "runs?status=in_progress&per_page=100" in request_path
                ):
                    return (
                        {"workflow_runs": [{"id": 1}]}
                        if docs in request_path
                        else {"workflow_runs": []}
                    )
                return {
                    "jobs": [
                        {
                            "name": "lint / Trust Docker-capable job",
                            "conclusion": "success",
                        },
                        {"status": "queued", "labels": standard},
                        {"status": "queued", "labels": builder},
                        {"status": "queued", "labels": automation},
                    ]
                }

        github = GitHub()
        controller = SimpleNamespace(
            expected_labels=lambda spec, profile: {
                "self-hosted",
                "Linux",
                "X64",
                spec.name,
                *profile.labels,
            }
        )
        controller_module = SimpleNamespace(
            GitHubClient=lambda _token: github,
            token_from_environment=lambda: "credential",
            EphemeralController=lambda _policy, _base: controller,
        )
        calls = []

        def command(argv, **_kwargs):
            calls.append(argv)
            if argv[1:2] == ["is-active"]:
                return SimpleNamespace(returncode=3, stdout="inactive\n")
            return SimpleNamespace(returncode=0, stdout="")

        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "active_policy", return_value=policy),
            mock.patch.object(
                MODULE, "load_controller", return_value=controller_module
            ),
            mock.patch.object(MODULE, "command", side_effect=command),
        ):
            MODULE.dispatch_queued_profiles()
        started = [call[-1] for call in calls if call[:2] == ["systemctl", "start"]]
        self.assertIn(runner_service("ubuntu-24.04"), started)
        self.assertIn(runner_service("container-build"), started)
        self.assertIn(runner_service("automation"), started)
        self.assertNotIn(
            runner_service("ubuntu-24.04-secondary"),
            started,
        )

    def test_profile_dispatcher_scales_only_for_an_exact_queued_job_when_primary_is_busy(self):
        policy = MODULE.active_policy()
        docs = "f5-sales-demo/docs-control"
        standard = ["self-hosted", "Linux", "X64", "docs-control", "ubuntu-24.04"]

        class GitHub:
            def request(self, _method, request_path):
                if "runs?status=" in request_path:
                    return {"workflow_runs": [{"id": 1}]} if docs in request_path else {"workflow_runs": []}
                return {"jobs": [{"name": "lint", "status": "queued", "labels": standard}]}

            def runners(self, repository):
                if repository != docs:
                    raise AssertionError(f"unexpected repository: {repository}")
                return [{"name": "gha-docs-control-ubuntu-24.04-0-active", "status": "online", "busy": True}]

        github = GitHub()
        controller = SimpleNamespace(
            expected_labels=lambda spec, profile: {
                "self-hosted", "Linux", "X64", spec.name, *profile.labels
            }
        )
        controller_module = SimpleNamespace(
            GitHubClient=lambda _token: github,
            token_from_environment=lambda: "credential",
            EphemeralController=lambda _policy, _base: controller,
        )
        calls = []

        def command(argv, **_kwargs):
            calls.append(argv)
            if argv[:2] == ["systemctl", "is-active"]:
                unit = argv[-1]
                return SimpleNamespace(
                    returncode=0 if unit.endswith("--0.service") else 3,
                    stdout="active\n" if unit.endswith("--0.service") else "inactive\n",
                )
            return SimpleNamespace(returncode=0, stdout="")

        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "active_policy", return_value=policy),
            mock.patch.object(MODULE, "load_controller", return_value=controller_module),
            mock.patch.object(MODULE, "command", side_effect=command),
        ):
            MODULE.dispatch_queued_profiles()

        self.assertIn(
            ["systemctl", "start", "f5-actions-runner@docs-control--ubuntu-24.04--1.service"],
            calls,
        )

    def test_profile_dispatcher_refuses_untrusted_docker_job(self):
        policy = MODULE.active_policy()
        docs = "f5-sales-demo/docs-control"
        builder = ["self-hosted", "Linux", "X64", "docs-control", "container-build"]

        class GitHub:
            def request(self, _method, request_path):
                if (
                    "runs?status=queued&per_page=100" in request_path
                    or "runs?status=in_progress&per_page=100" in request_path
                ):
                    return (
                        {"workflow_runs": [{"id": 1}]}
                        if docs in request_path
                        else {"workflow_runs": []}
                    )
                return {"jobs": [{"status": "queued", "labels": builder}]}

        controller = SimpleNamespace(
            expected_labels=lambda spec, profile: {
                "self-hosted",
                "Linux",
                "X64",
                spec.name,
                *profile.labels,
            }
        )
        controller_module = SimpleNamespace(
            GitHubClient=lambda _token: GitHub(),
            token_from_environment=lambda: "credential",
            EphemeralController=lambda _policy, _base: controller,
        )
        calls: list[list[str]] = []

        def command(argv, **_kwargs):
            calls.append(argv)
            return SimpleNamespace(returncode=3, stdout="inactive")

        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "active_policy", return_value=policy),
            mock.patch.object(
                MODULE, "load_controller", return_value=controller_module
            ),
            mock.patch.object(MODULE, "command", side_effect=command),
        ):
            MODULE.dispatch_queued_profiles()
        self.assertNotIn(
            [
                "systemctl",
                "start",
                runner_service("container-build"),
            ],
            calls,
        )

    def test_standby_scaler_covers_busy_or_unavailable_warm_capacity(self):
        standby = MODULE.Instance(
            "f5-sales-demo/fixture",
            "fixture",
            "ubuntu-24.04",
            1,
            False,
            "4g",
            "2",
            512,
            300,
            "bridge",
            "once",
        )
        profile = SimpleNamespace(name="ubuntu-24.04")
        spec = SimpleNamespace(name="fixture", replicas=1, standby_profiles=(profile,))
        policy = SimpleNamespace(
            governed=lambda: ("f5-sales-demo/fixture",),
            repository=lambda _repository: spec,
        )
        cache_directory = tempfile.TemporaryDirectory()
        self.addCleanup(cache_directory.cleanup)
        cache_path = Path(cache_directory.name) / "standby-inventory.json"

        def run(records, active):
            cache_path.unlink(missing_ok=True)
            calls = []
            github = SimpleNamespace(runners=lambda _repository: records)
            controller = SimpleNamespace(
                token_from_environment=lambda: "credential",
                GitHubClient=lambda _token: github,
            )

            def command(argv, **_kwargs):
                calls.append(argv)
                if argv[1:2] == ["is-active"]:
                    return SimpleNamespace(
                        returncode=0 if active else 3,
                        stdout="active\n" if active else "inactive\n",
                    )
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with (
                mock.patch.object(MODULE, "require_root"),
                mock.patch.object(MODULE, "load_controller", return_value=controller),
                mock.patch.object(MODULE, "active_policy", return_value=policy),
                mock.patch.object(MODULE, "standby_instances", return_value=(standby,)),
                mock.patch.object(MODULE, "STANDBY_INVENTORY_CACHE", cache_path),
                mock.patch.object(MODULE, "command", side_effect=command),
            ):
                MODULE.standby_scale()
            return calls

        warm_busy = {
            "name": "gha-fixture-ubuntu-24.04-0-token",
            "status": "online",
            "busy": True,
        }
        warm_idle = {
            "name": "gha-fixture-ubuntu-24.04-0-token",
            "status": "online",
            "busy": False,
        }
        warm_offline = {
            "name": "gha-fixture-ubuntu-24.04-0-token",
            "status": "offline",
            "busy": False,
        }
        standby_idle = {
            "name": "gha-fixture-ubuntu-24.04-1-token",
            "status": "online",
            "busy": False,
        }
        standby_busy = {
            "name": "gha-fixture-ubuntu-24.04-1-token",
            "status": "online",
            "busy": True,
        }
        self.assertIn(["systemctl", "start", standby.unit], run([warm_busy], False))
        self.assertNotIn(["systemctl", "start", standby.unit], run([warm_busy], True))
        self.assertNotIn(["systemctl", "start", standby.unit], run([warm_idle], False))
        self.assertIn(
            ["systemctl", "stop", standby.unit], run([warm_idle, standby_idle], True)
        )
        self.assertNotIn(
            ["systemctl", "stop", standby.unit], run([warm_idle, standby_busy], True)
        )
        self.assertIn(["systemctl", "start", standby.unit], run([warm_offline], False))
        self.assertIn(["systemctl", "start", standby.unit], run([], False))
        self.assertNotIn(["systemctl", "start", standby.unit], run([], True))
        self.assertNotIn(["systemctl", "stop", standby.unit], run([], True))

        cache_path.unlink(missing_ok=True)
        calls = []
        failed_github = SimpleNamespace(
            runners=lambda _repository: (_ for _ in ()).throw(
                RuntimeError("rate limited")
            )
        )
        controller = SimpleNamespace(
            token_from_environment=lambda: "credential",
            GitHubClient=lambda _token: failed_github,
        )
        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "load_controller", return_value=controller),
            mock.patch.object(MODULE, "active_policy", return_value=policy),
            mock.patch.object(MODULE, "standby_instances", return_value=(standby,)),
            mock.patch.object(MODULE, "STANDBY_INVENTORY_CACHE", cache_path),
            mock.patch.object(
                MODULE,
                "command",
                side_effect=lambda argv, **_kwargs: calls.append(argv),
            ),
            self.assertRaisesRegex(RuntimeError, "rate limited"),
        ):
            MODULE.standby_scale()
        self.assertEqual(calls, [])

        cache_path.unlink(missing_ok=True)
        malformed_github = SimpleNamespace(
            runners=lambda _repository: [
                {
                    "name": "gha-fixture-ubuntu-24.04-0-token",
                    "status": "unknown",
                    "busy": False,
                }
            ]
        )
        controller = SimpleNamespace(
            token_from_environment=lambda: "credential",
            GitHubClient=lambda _token: malformed_github,
        )
        calls = []
        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "load_controller", return_value=controller),
            mock.patch.object(MODULE, "active_policy", return_value=policy),
            mock.patch.object(MODULE, "standby_instances", return_value=(standby,)),
            mock.patch.object(MODULE, "STANDBY_INVENTORY_CACHE", cache_path),
            mock.patch.object(
                MODULE,
                "command",
                side_effect=lambda argv, **_kwargs: calls.append(argv),
            ),
            self.assertRaisesRegex(MODULE.ProvisionError, "inventory is malformed"),
        ):
            MODULE.standby_scale()
        self.assertEqual(calls, [])

    def test_standby_scaler_refreshes_before_stopping_idle_capacity(self):
        standby = MODULE.Instance(
            "f5-sales-demo/fixture",
            "fixture",
            "ubuntu-24.04",
            1,
            False,
            "4g",
            "2",
            512,
            300,
            "bridge",
            "once",
        )
        profile = SimpleNamespace(name="ubuntu-24.04")
        spec = SimpleNamespace(name="fixture", replicas=1, standby_profiles=(profile,))
        policy = SimpleNamespace(
            governed=lambda: ("f5-sales-demo/fixture",),
            repository=lambda _repository: spec,
        )
        warm_idle = {
            "name": "gha-fixture-ubuntu-24.04-0-token",
            "status": "online",
            "busy": False,
        }
        standby_idle = {
            "name": "gha-fixture-ubuntu-24.04-1-token",
            "status": "online",
            "busy": False,
        }
        standby_busy = {**standby_idle, "busy": True}
        calls = []
        github = SimpleNamespace(runners=lambda _repository: [warm_idle, standby_busy])
        controller = SimpleNamespace(
            token_from_environment=lambda: "credential",
            GitHubClient=lambda _token: github,
        )

        def command(argv, **_kwargs):
            calls.append(argv)
            return SimpleNamespace(returncode=0, stdout="active\n")

        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "load_controller", return_value=controller),
            mock.patch.object(MODULE, "active_policy", return_value=policy),
            mock.patch.object(MODULE, "standby_instances", return_value=(standby,)),
            mock.patch.object(
                MODULE,
                "standby_inventories",
                return_value={"f5-sales-demo/fixture": [warm_idle, standby_idle]},
            ),
            mock.patch.object(MODULE, "command", side_effect=command),
        ):
            MODULE.standby_scale()
        self.assertNotIn(["systemctl", "stop", standby.unit], calls)

    def test_standby_inventory_cache_bounds_github_refreshes(self):
        calls = []

        policy = SimpleNamespace(governed=lambda: ("f5-sales-demo/fixture",))

        def runners(repository):
            calls.append(repository)
            return []

        github = SimpleNamespace(runners=runners)
        controller = SimpleNamespace(
            token_from_environment=lambda: "credential",
            GitHubClient=lambda _token: github,
        )
        with tempfile.TemporaryDirectory() as directory:
            cache_path = Path(directory) / "standby-inventory.json"
            with (
                mock.patch.object(MODULE, "STANDBY_INVENTORY_CACHE", cache_path),
                mock.patch.object(MODULE.time, "time", side_effect=[1000, 1001, 1121]),
            ):
                self.assertEqual(
                    MODULE.standby_inventories(policy, controller),
                    {"f5-sales-demo/fixture": []},
                )
                self.assertEqual(
                    MODULE.standby_inventories(policy, controller),
                    {"f5-sales-demo/fixture": []},
                )
                self.assertEqual(
                    MODULE.standby_inventories(policy, controller),
                    {"f5-sales-demo/fixture": []},
                )

        self.assertEqual(calls, ["f5-sales-demo/fixture", "f5-sales-demo/fixture"])

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

    def test_rotate_idle_requires_a_verified_idle_runner_before_replacement(self):
        item = MODULE.Instance(
            "f5-sales-demo/fixture",
            "fixture",
            "ubuntu-24.04",
            0,
            False,
            "4g",
            "2",
            512,
            300,
            "bridge",
            "serve",
        )
        profile = SimpleNamespace(
            name="ubuntu-24.04",
            image="ghcr.io/f5-sales-demo/self-hosted-runner@sha256:new",
        )
        spec = SimpleNamespace(profiles=(profile,))
        policy = SimpleNamespace(repository=lambda _repository: spec)
        runner = {
            "name": "gha-fixture-ubuntu-24.04-0-token",
            "id": 7,
            "status": "online",
            "busy": False,
        }
        deleted, commands = [], []
        github = SimpleNamespace(
            runners=lambda _repository: [runner],
            delete_runner=lambda repository, runner_id: deleted.append(
                (repository, runner_id)
            ),
        )
        controller = SimpleNamespace(
            container_name=lambda _spec, _profile, _slot: "gha-fixture-ubuntu-24.04-0",
            outer_image=lambda _spec, _profile, _slot: (
                "ghcr.io/f5-sales-demo/actions-runner@sha256:old"
            ),
        )
        controller_module = SimpleNamespace(
            EphemeralController=lambda _policy, _base_dir: controller,
            GitHubClient=lambda _token: github,
            token_from_environment=lambda: "credential",
        )
        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "active_policy", return_value=policy),
            mock.patch.object(MODULE, "all_instances", return_value=(item,)),
            mock.patch.object(
                MODULE, "load_controller", return_value=controller_module
            ),
            mock.patch.object(
                MODULE,
                "command",
                side_effect=lambda argv, **_kwargs: commands.append(argv),
            ),
        ):
            self.assertEqual(MODULE.rotate_idle(apply=True), 0)
        self.assertEqual(deleted, [("f5-sales-demo/fixture", 7)])
        self.assertEqual(
            commands,
            [
                ["systemctl", "stop", item.unit],
                ["systemctl", "start", item.unit],
            ],
        )

    def test_rotate_idle_never_replaces_a_busy_runner(self):
        item = MODULE.Instance(
            "f5-sales-demo/fixture",
            "fixture",
            "ubuntu-24.04",
            0,
            False,
            "4g",
            "2",
            512,
            300,
            "bridge",
            "serve",
        )
        profile = SimpleNamespace(name="ubuntu-24.04", image="new-image")
        policy = SimpleNamespace(
            repository=lambda _repository: SimpleNamespace(profiles=(profile,))
        )
        deleted = []
        github = SimpleNamespace(
            runners=lambda _repository: [
                {
                    "name": "gha-fixture-ubuntu-24.04-0-token",
                    "id": 7,
                    "status": "online",
                    "busy": True,
                }
            ],
            delete_runner=lambda *_args: deleted.append(True),
        )
        controller = SimpleNamespace(
            container_name=lambda _spec, _profile, _slot: "gha-fixture-ubuntu-24.04-0",
            outer_image=lambda _spec, _profile, _slot: "old-image",
        )
        controller_module = SimpleNamespace(
            EphemeralController=lambda _policy, _base_dir: controller,
            GitHubClient=lambda _token: github,
            token_from_environment=lambda: "credential",
        )
        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "active_policy", return_value=policy),
            mock.patch.object(MODULE, "all_instances", return_value=(item,)),
            mock.patch.object(
                MODULE, "load_controller", return_value=controller_module
            ),
            mock.patch.object(MODULE, "command") as command,
        ):
            self.assertEqual(MODULE.rotate_idle(apply=True), 0)
        self.assertEqual(deleted, [])
        command.assert_not_called()

    def test_rotate_idle_plans_without_deregistering_or_stopping(self):
        item = MODULE.Instance(
            "f5-sales-demo/fixture",
            "fixture",
            "ubuntu-24.04",
            0,
            False,
            "4g",
            "2",
            512,
            300,
            "bridge",
            "serve",
        )
        profile = SimpleNamespace(name="ubuntu-24.04", image="new-image")
        policy = SimpleNamespace(
            repository=lambda _repository: SimpleNamespace(profiles=(profile,))
        )
        controller = SimpleNamespace(
            outer_image=lambda _spec, _profile, _slot: "old-image",
        )
        controller_module = SimpleNamespace(
            EphemeralController=lambda _policy, _base_dir: controller
        )
        with (
            mock.patch.object(MODULE, "active_policy", return_value=policy),
            mock.patch.object(MODULE, "all_instances", return_value=(item,)),
            mock.patch.object(
                MODULE, "load_controller", return_value=controller_module
            ),
            mock.patch.object(MODULE, "command") as command,
        ):
            self.assertEqual(MODULE.rotate_idle(), 0)
        command.assert_not_called()

    def test_retire_orphans_removes_only_a_verified_idle_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            instance_root = Path(directory)
            retired = instance_root / "fixture--ubuntu-24.04--1.env"
            retired.write_text(
                "RUNNER_REPOSITORY=f5-sales-demo/fixture\n"
                "RUNNER_PROFILE=ubuntu-24.04\n"
                "RUNNER_SLOT=1\n"
                "RUNNER_MODE=serve\n",
                encoding="utf-8",
            )
            deleted, commands = [], []
            github = SimpleNamespace(
                runners=lambda _repository: [
                    {
                        "name": "gha-fixture-ubuntu-24.04-1-token",
                        "id": 7,
                        "status": "online",
                        "busy": False,
                    }
                ],
                delete_runner=lambda repository, runner_id: deleted.append(
                    (repository, runner_id)
                ),
            )
            controller_module = SimpleNamespace(
                GitHubClient=lambda _token: github,
                token_from_environment=lambda: "credential",
            )

            def run(argv, **_kwargs):
                commands.append(argv)
                if argv[:2] == ["systemctl", "is-active"]:
                    return SimpleNamespace(returncode=0, stdout="active\n")
                return SimpleNamespace(returncode=0, stdout="")

            with (
                mock.patch.object(MODULE, "require_root"),
                mock.patch.object(MODULE, "INSTANCE_ROOT", instance_root),
                mock.patch.object(MODULE, "all_instances", return_value=()),
                mock.patch.object(MODULE, "all_standby_instances", return_value=()),
                mock.patch.object(
                    MODULE, "load_controller", return_value=controller_module
                ),
                mock.patch.object(MODULE, "command", side_effect=run),
            ):
                self.assertEqual(MODULE.retire_orphans(apply=True), 0)

            self.assertEqual(deleted, [("f5-sales-demo/fixture", 7)])
            expected_unit = MODULE.RetiredInstance(
                "f5-sales-demo/fixture",
                "fixture",
                "ubuntu-24.04",
                1,
                "serve",
                retired,
            ).unit
            self.assertEqual(
                commands,
                [
                    [
                        "systemctl",
                        "is-active",
                        expected_unit,
                    ],
                    [
                        "systemctl",
                        "stop",
                        expected_unit,
                    ],
                ],
            )
            self.assertFalse(retired.exists())

    def test_retire_orphans_keeps_a_busy_runner_and_definition(self):
        with tempfile.TemporaryDirectory() as directory:
            instance_root = Path(directory)
            retired = instance_root / "fixture--ubuntu-24.04--1.env"
            retired.write_text(
                "RUNNER_REPOSITORY=f5-sales-demo/fixture\n"
                "RUNNER_PROFILE=ubuntu-24.04\n"
                "RUNNER_SLOT=1\n"
                "RUNNER_MODE=serve\n",
                encoding="utf-8",
            )
            deleted = []
            github = SimpleNamespace(
                runners=lambda _repository: [
                    {
                        "name": "gha-fixture-ubuntu-24.04-1-token",
                        "id": 7,
                        "status": "online",
                        "busy": True,
                    }
                ],
                delete_runner=lambda *_args: deleted.append(True),
            )
            controller_module = SimpleNamespace(
                GitHubClient=lambda _token: github,
                token_from_environment=lambda: "credential",
            )
            with (
                mock.patch.object(MODULE, "require_root"),
                mock.patch.object(MODULE, "INSTANCE_ROOT", instance_root),
                mock.patch.object(MODULE, "all_instances", return_value=()),
                mock.patch.object(MODULE, "all_standby_instances", return_value=()),
                mock.patch.object(
                    MODULE, "load_controller", return_value=controller_module
                ),
                mock.patch.object(
                    MODULE,
                    "command",
                    return_value=SimpleNamespace(returncode=0, stdout="active\n"),
                ) as command,
            ):
                self.assertEqual(MODULE.retire_orphans(apply=True), 0)

            self.assertEqual(deleted, [])
            command.assert_not_called()
            self.assertTrue(retired.exists())


if __name__ == "__main__":
    unittest.main()
