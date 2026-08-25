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
    return "f5-actions-runner" + chr(64) + f"docs-control--{profile}--0.service"


SPEC.loader.exec_module(MODULE)


class ProvisionRunnerTests(unittest.TestCase):  # pylint: disable=too-many-public-methods
    def test_rootless_daemon_and_slice_are_hard_bounded(self):
        unit = MODULE.rootless_docker_unit_text()
        slice_unit = MODULE.container_build_slice_text()
        config = json.loads(MODULE.rootless_docker_config_text(MODULE.active_policy()))
        self.assertIn("User=gha-ephemeral", unit)
        self.assertIn("PrivateMounts=true", unit)
        self.assertIn(
            "DOCKERD=/opt/f5-actions-runner/rootless-dockerd-wrapper.sh", unit
        )
        self.assertNotIn("BindPaths=", unit)
        self.assertIn("Slice=f5-actions-container-build.slice", unit)
        self.assertIn("MemoryHigh=14G", slice_unit)
        self.assertIn("MemoryMax=16G", slice_unit)
        self.assertIn("MemorySwapMax=0", slice_unit)
        self.assertIn("CPUQuota=600%", slice_unit)
        self.assertEqual(
            config["data-root"], "/data/actions-runners/container-build-docker"
        )
        self.assertEqual(config["builder"]["gc"]["defaultKeepStorage"], "20g")
        self.assertNotIn("cgroup-parent", config)
        self.assertEqual(config["exec-opts"], ["native.cgroupdriver=cgroupfs"])
        self.assertIn("ProtectKernelTunables=false", unit)
        self.assertIn("ProtectKernelModules=false", unit)
        self.assertIn(str(MODULE.STATE_ROOT), unit)

    def test_socketless_runners_share_a_hard_bounded_fleet_slice(self):
        unit = MODULE.runner_unit_text()
        slice_unit = MODULE.runner_slice_text()
        self.assertIn("Slice=f5-actions-runner.slice", unit)
        self.assertIn("MemoryHigh=44G", slice_unit)
        self.assertIn("MemoryMax=48G", slice_unit)
        self.assertIn("CPUQuota=1800%", slice_unit)

    def test_common_fleet_parent_enforces_the_aggregate_capacity_limit(self):
        slice_unit = MODULE.fleet_slice_text()
        self.assertEqual(MODULE.FLEET_SLICE_UNIT, "f5-actions.slice")
        self.assertIn("MemoryHigh=44G", slice_unit)
        self.assertIn("MemoryMax=48G", slice_unit)
        self.assertIn("CPUQuota=1800%", slice_unit)
        self.assertTrue(MODULE.RUNNER_SLICE_UNIT.startswith("f5-actions-"))
        self.assertTrue(MODULE.CONTAINER_BUILD_SLICE_UNIT.startswith("f5-actions-"))

    def test_fleet_admission_caps_three_socketless_runners_at_48g_and_18_cpus(self):
        policy = MODULE.active_policy()
        xcsh = "f5-sales-demo/xcsh"
        primary = next(
            item
            for item in MODULE.instances(policy)
            if item.repository == xcsh and item.profile == "ubuntu-24.04"
        )
        builder = next(
            item
            for item in MODULE.instances(policy)
            if item.repository == xcsh and item.profile == "container-build"
        )
        standby = next(
            item for item in MODULE.standby_instances(policy) if item.repository == xcsh
        )
        with mock.patch.object(
            MODULE, "active_fleet_instances", return_value=[primary, builder]
        ):
            self.assertTrue(MODULE.admission_allows(policy, standby))
        extra = MODULE.Instance(
            xcsh,
            "xcsh",
            "ubuntu-24.04",
            2,
            False,
            "8g",
            "4",
            4096,
            300,
            "bridge",
            "once",
        )
        with mock.patch.object(
            MODULE,
            "active_fleet_instances",
            return_value=[primary, builder, standby],
        ):
            self.assertTrue(MODULE.admission_allows(policy, extra))

    def test_clean_break_removes_legacy_dispatch_paths(self):
        legacy = (
            "dispatch_xcsh",
            "dispatch_queued_profiles",
            "standby_scale",
            "rotate_idle",
            "enable",
            "xcsh_dispatcher_unit_text",
            "profile_dispatcher_unit_text",
            "standby_scaler_unit_text",
        )
        self.assertTrue(all(not hasattr(MODULE, item) for item in legacy))
        self.assertEqual(
            set(MODULE.RETIRED_LEGACY_DISPATCH_TIMERS),
            {
                "f5-actions-runner-standby.timer",
                "f5-actions-runner-profile-dispatch.timer",
                "f5-actions-runner-xcsh-dispatch.timer",
            },
        )

    def test_admission_check_requires_an_exact_enabled_policy_instance(self):
        policy = MODULE.active_policy()
        with (
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "reserved_fleet_instances") as reservations,
            self.assertRaisesRegex(MODULE.ProvisionError, "exact enabled"),
        ):
            MODULE.admission_check("f5-sales-demo/xcsh", "ubuntu-24.04", 999)
        reservations.assert_not_called()
        self.assertEqual(
            MODULE.configured_fleet_instance(
                policy, "f5-sales-demo/xcsh", "container-build", 0
            ).repository,
            "f5-sales-demo/xcsh",
        )

    def test_reserved_fleet_instances_counts_active_and_activating_units(self):
        policy = MODULE.active_policy()
        standard = [
            item for item in MODULE.instances(policy) if item.profile == "ubuntu-24.04"
        ][:3]
        states = {
            standard[0].unit: "active\n",
            standard[1].unit: "activating\n",
            standard[2].unit: "inactive\n",
        }

        def systemd_show(argv, **_kwargs):
            return SimpleNamespace(returncode=0, stdout=states[argv[-1]])

        with (
            mock.patch.object(MODULE, "fleet_instances", return_value=standard),
            mock.patch.object(MODULE, "command", side_effect=systemd_show),
        ):
            self.assertEqual(MODULE.reserved_fleet_instances(policy), standard[:2])

    def test_admission_check_rejects_manual_start_when_global_pool_is_full(self):
        policy = MODULE.active_policy()
        standard = [
            item for item in MODULE.instances(policy) if item.profile == "ubuntu-24.04"
        ]
        builder = next(
            item
            for item in MODULE.instances(policy)
            if item.profile == "container-build"
        )
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "consume_runner_start_authorization"),
            mock.patch.object(
                MODULE,
                "reserved_fleet_instances",
                return_value=[*standard[:3], builder],
            ),
            mock.patch.object(
                MODULE, "ADMISSION_LOCK", Path(temporary) / "admission.lock"
            ),
            self.assertRaisesRegex(MODULE.ProvisionError, "shared capacity exhausted"),
        ):
            MODULE.admission_check(
                standard[3].repository, standard[3].profile, standard[3].slot
            )

    def test_activating_reservation_prevents_concurrent_candidates_passing(self):
        policy = MODULE.active_policy()
        standard = [
            item for item in MODULE.instances(policy) if item.profile == "ubuntu-24.04"
        ]
        builder = next(
            item
            for item in MODULE.instances(policy)
            if item.profile == "container-build"
        )
        active_and_activating = [*standard[:2], standard[2], builder]
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "consume_runner_start_authorization"),
            mock.patch.object(
                MODULE, "reserved_fleet_instances", return_value=active_and_activating
            ),
            mock.patch.object(
                MODULE, "ADMISSION_LOCK", Path(temporary) / "admission.lock"
            ),
            self.assertRaisesRegex(MODULE.ProvisionError, "shared capacity exhausted"),
        ):
            MODULE.admission_check(
                standard[3].repository, standard[3].profile, standard[3].slot
            )

    def test_admission_check_enforces_single_container_builder(self):
        policy = MODULE.active_policy()
        builders = [
            item
            for item in MODULE.instances(policy)
            if item.profile == "container-build"
        ]
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(MODULE, "consume_runner_start_authorization"),
            mock.patch.object(
                MODULE, "reserved_fleet_instances", return_value=[builders[0]]
            ),
            mock.patch.object(
                MODULE, "ADMISSION_LOCK", Path(temporary) / "admission.lock"
            ),
            self.assertRaisesRegex(MODULE.ProvisionError, "shared capacity exhausted"),
        ):
            MODULE.admission_check(
                builders[1].repository, builders[1].profile, builders[1].slot
            )

    def test_admission_totals_enforce_memory_and_cpu_bounds(self):
        reserved = [object(), object()]
        profile = SimpleNamespace(docker_socket=False, memory="12g", cpus="3")
        with mock.patch.object(MODULE, "instance_profile", return_value=profile):
            memory_limited = SimpleNamespace(
                dispatcher=SimpleNamespace(
                    standard_runners=4,
                    container_build_runners=2,
                    memory="16g",
                    cpus="100",
                )
            )
            cpu_limited = SimpleNamespace(
                dispatcher=SimpleNamespace(
                    standard_runners=4,
                    container_build_runners=2,
                    memory="100g",
                    cpus="4",
                )
            )
            self.assertFalse(
                MODULE.admission_allows_instances(memory_limited, reserved)
            )
            self.assertFalse(MODULE.admission_allows_instances(cpu_limited, reserved))

    def test_admission_check_rejects_unpermitted_manual_start(self):
        policy = MODULE.active_policy()
        candidate = next(iter(MODULE.instances(policy)))
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(
                MODULE, "ADMISSION_LOCK", Path(temporary) / "admission.lock"
            ),
            mock.patch.object(
                MODULE, "ADMISSION_PERMIT_ROOT", Path(temporary) / "permits"
            ),
            self.assertRaisesRegex(MODULE.ProvisionError, "lacks fleet dispatcher"),
        ):
            MODULE.admission_check(
                candidate.repository, candidate.profile, candidate.slot
            )

    def test_dispatcher_permit_is_consumed_by_admission_check(self):
        policy = MODULE.active_policy()
        candidate = next(iter(MODULE.instances(policy)))
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(MODULE, "require_root"),
            mock.patch.object(
                MODULE, "ADMISSION_LOCK", Path(temporary) / "admission.lock"
            ),
            mock.patch.object(
                MODULE, "ADMISSION_PERMIT_ROOT", Path(temporary) / "permits"
            ),
            mock.patch.object(MODULE.time, "time", return_value=1000),
            mock.patch.object(MODULE, "reserved_fleet_instances", return_value=[]),
        ):
            MODULE.authorize_runner_start(candidate)
            MODULE.admission_check(
                candidate.repository, candidate.profile, candidate.slot
            )
            with self.assertRaisesRegex(
                MODULE.ProvisionError, "lacks fleet dispatcher"
            ):
                MODULE.admission_check(
                    candidate.repository, candidate.profile, candidate.slot
                )

    def test_admission_fails_closed_when_systemd_state_is_unavailable(self):
        policy = MODULE.active_policy()
        item = next(iter(MODULE.instances(policy)))
        with (
            mock.patch.object(
                MODULE,
                "command",
                return_value=SimpleNamespace(returncode=1, stdout=""),
            ),
            self.assertRaisesRegex(MODULE.ProvisionError, "cannot read runner unit"),
        ):
            MODULE.unit_active_state(item)

    def test_installed_provisioner_resolves_installed_runner_assets(self):
        installed = MODULE.INSTALL_ROOT / "provision-ephemeral-runners.py"
        root, controller, entrypoint, initializer, wrapper, policy = (
            MODULE.source_paths(installed)
        )
        self.assertEqual(root, MODULE.INSTALL_ROOT)
        self.assertEqual(
            controller, MODULE.INSTALL_ROOT / "ephemeral-runner-controller.py"
        )
        self.assertEqual(entrypoint, MODULE.INSTALL_ROOT / "runner-entrypoint.sh")
        self.assertEqual(
            initializer, MODULE.INSTALL_ROOT / "prepare-runner-tool-cache.sh"
        )
        self.assertEqual(wrapper, MODULE.INSTALL_ROOT / "rootless-dockerd-wrapper.sh")
        self.assertEqual(policy, MODULE.INSTALL_ROOT / "self-hosted-runner-policy.json")
        self.assertEqual(
            MODULE.source_paths(MODULE.PROVISIONER_SOURCE),
            (
                MODULE.SOURCE_ROOT,
                MODULE.CONTROLLER_SOURCE,
                MODULE.ENTRYPOINT_SOURCE,
                MODULE.TOOL_CACHE_INITIALIZER_SOURCE,
                MODULE.ROOTLESS_DOCKER_WRAPPER_SOURCE,
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
        self.assertIn("admission-check ${RUNNER_REPOSITORY}", unit)
        self.assertLess(
            unit.index("admission-check"), unit.index("ephemeral-runner-controller.py")
        )
        self.assertIn("Restart=on-failure", unit)
        self.assertNotIn("Restart=always", unit)
        self.assertIn("TimeoutStopSec=6min", unit)
        self.assertIn("KillMode=mixed", unit)
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

    def test_retire_orphans_removes_only_a_verified_idle_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            instance_root = Path(directory)
            retired = instance_root / "fixture--ubuntu-24.04--1.env"
            retired.write_text(
                "RUNNER_REPOSITORY=f5-sales-demo/fixture\n"
                "RUNNER_PROFILE=ubuntu-24.04\n"
                "RUNNER_SLOT=1\n"
                "RUNNER_MODE=once\n",
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
                mock.patch.object(MODULE, "standby_instances", return_value=()),
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
                "once",
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
                "RUNNER_MODE=once\n",
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
                mock.patch.object(MODULE, "standby_instances", return_value=()),
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
