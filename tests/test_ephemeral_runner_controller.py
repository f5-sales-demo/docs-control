#!/usr/bin/env python3
# pylint: disable=consider-using-with,too-many-lines
"""Hermetic tests for the ephemeral runner lifecycle."""

import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "ephemeral_runner_controller", ROOT / "scripts/ephemeral-runner-controller.py"
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeGitHub:
    def __init__(self):
        self.requested = []
        self.records = []
        self.deleted = []

    def registration_token(self, repository):
        self.requested.append(repository)
        return "registration-secret"

    def runners(self, _repository):
        return self.records

    def delete_runner(self, repository, runner_id):
        self.deleted.append((repository, runner_id))


class CommandRecorder:
    def __init__(self):
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append((command, kwargs))
        if command[:3] == ["docker", "version", "--format"]:
            return SimpleNamespace(returncode=0, stdout="29.2.1\n", stderr="")
        return SimpleNamespace(returncode=0, stdout="", stderr="")


# pylint: disable-next=too-many-public-methods
class EphemeralRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "state").mkdir()
        self.owner_change = mock.patch.object(MODULE.os, "fchown")
        self.owner_change.start()
        self.policy_path = self.root / "policy.json"
        self.policy_data: dict = {
            "schema_version": 3,
            "docker": {
                "socket": "/run/docker.sock",
                "minimum_version": "29.2.1",
                "target_version": "29.7.2",
            },
            "defaults": {"replicas": 1, "profile": "ubuntu-24.04"},
            "profiles": {
                "ubuntu-24.04": {
                    "image": "ghcr.io/f5-sales-demo/runner@sha256:" + "a" * 64,
                    "labels": ["ubuntu-24.04"],
                    "memory": "4g",
                    "cpus": "2",
                    "pids_limit": 512,
                    "stop_timeout": 300,
                    "network": "bridge",
                    "docker_socket": False,
                },
                "container-build": {
                    "image": "ghcr.io/f5-sales-demo/runner@sha256:" + "b" * 64,
                    "labels": ["container-build"],
                    "memory": "8g",
                    "cpus": "4",
                    "pids_limit": 1024,
                    "stop_timeout": 300,
                    "network": "bridge",
                    "docker_socket": True,
                },
            },
            "hosted_exceptions": {},
            "repositories": {
                "f5-sales-demo/fixture": {
                    "runner": {
                        "replicas": 1,
                        "profiles": ["ubuntu-24.04", "container-build"],
                    }
                }
            },
        }
        self.write_policy()

    def tearDown(self):
        self.owner_change.stop()
        self.temp.cleanup()

    def write_policy(self):
        self.policy_path.write_text(json.dumps(self.policy_data), encoding="utf-8")

    def policy(self):
        return MODULE.FleetPolicy(self.policy_path)

    def test_policy_builds_exact_repository_profiles(self):
        spec = self.policy().repository("f5-sales-demo/fixture")
        self.assertEqual(
            [item.name for item in spec.profiles], ["ubuntu-24.04", "container-build"]
        )
        self.assertEqual(spec.replicas, 1)

    def test_policy_requires_exact_schema_v3_docker_contract(self):
        for mutation in (
            {"schema_version": 2},
            {"docker": {"socket": "/var/run/docker.sock"}},
            {"docker": {"minimum_version": "29.2.0"}},
            {"docker": {"target_version": "29.7.1"}},
        ):
            with self.subTest(mutation=mutation):
                original = json.loads(json.dumps(self.policy_data))
                if "schema_version" in mutation:
                    self.policy_data["schema_version"] = mutation["schema_version"]
                else:
                    self.policy_data["docker"].update(mutation["docker"])
                self.write_policy()
                with self.assertRaises(MODULE.FleetError):
                    self.policy()
                self.policy_data = original

    def test_policy_rejects_podman_era_profile_fields(self):
        profile = self.policy_data["profiles"]["ubuntu-24.04"]
        profile["container_socket"] = profile.pop("docker_socket")
        self.write_policy()
        with self.assertRaises(MODULE.FleetError):
            self.policy()

    def test_policy_requires_one_exact_builder_profile_for_every_repository(self):
        for mutation in ("builder-socketless", "default-privileged", "missing-builder"):
            with self.subTest(mutation=mutation):
                original = json.loads(json.dumps(self.policy_data))
                if mutation == "builder-socketless":
                    self.policy_data["profiles"]["container-build"]["docker_socket"] = (
                        False
                    )
                elif mutation == "default-privileged":
                    self.policy_data["profiles"]["ubuntu-24.04"]["docker_socket"] = True
                else:
                    self.policy_data["repositories"]["f5-sales-demo/fixture"]["runner"][
                        "profiles"
                    ] = ["ubuntu-24.04"]
                self.write_policy()
                with self.assertRaises(MODULE.FleetError):
                    self.policy()
                self.policy_data = original

    def test_policy_rejects_mutable_image_and_reserved_label(self):
        profile = self.policy_data["profiles"]["ubuntu-24.04"]
        profile["image"] = "ghcr.io/example/runner:latest"
        profile["labels"].append("ubuntu-latest")
        self.write_policy()
        with self.assertRaises(MODULE.FleetError):
            self.policy()

    def test_policy_rejects_unsafe_resource_limits(self):
        profile = self.policy_data["profiles"]["ubuntu-24.04"]
        for field, value in (("memory", "4g\nDelegate=yes"), ("cpus", "nan")):
            with self.subTest(field=field):
                original = profile[field]
                profile[field] = value
                self.write_policy()
                with self.assertRaises(MODULE.FleetError):
                    self.policy()
                profile[field] = original

    def test_policy_rejects_unknown_fields_and_ungoverned_repository(self):
        self.policy_data["unexpected"] = True
        self.write_policy()
        with self.assertRaises(MODULE.FleetError):
            self.policy()
        del self.policy_data["unexpected"]
        self.write_policy()
        with self.assertRaises(MODULE.FleetError):
            self.policy().repository("f5-sales-demo/other")

    def test_registration_secret_uses_stdin_not_argv(self):
        github = FakeGitHub()
        recorder = CommandRecorder()
        controller = MODULE.EphemeralController(
            self.policy(), github, self.root / "state", recorder
        )
        result = controller.run_once("f5-sales-demo/fixture", "ubuntu-24.04")
        self.assertEqual(result, 0)
        docker_calls = [
            call for call in recorder.calls if call[0][:2] == ["docker", "run"]
        ]
        self.assertEqual(len(docker_calls), 1)
        command, kwargs = docker_calls[0]
        self.assertNotIn("registration-secret", " ".join(command))
        self.assertEqual(kwargs["input_text"], "registration-secret\n")
        self.assertIn("--read-only", command)
        self.assertIn("--cap-drop=all", command)
        self.assertIn("--security-opt=no-new-privileges=true", command)
        self.assertIn("bridge", command)
        self.assertNotIn("/run/docker.sock", " ".join(command))
        self.assertIn("RUNNER_EPHEMERAL=1", command)
        self.assertNotIn("/home/runner:rw,nosuid,nodev,size=4g", command)
        self.assertEqual(command[command.index("--memory") + 1], "4g")
        self.assertEqual(command[command.index("--cpus") + 1], "2")
        self.assertEqual(command[command.index("--pids-limit") + 1], "512")
        self.assertEqual(command[command.index("--stop-timeout") + 1], "300")
        self.assertEqual(
            command[command.index("--tmpfs") + 1],
            "/tmp:rw,nosuid,nodev,exec,size=2g",  # noqa: S108
        )
        runtime_root = (
            self.root / "state" / "workspaces" / "fixture" / "ubuntu-24.04" / "0"
        )
        self.assertIn(f"{runtime_root}:{runtime_root}:rw", command)
        diagnostics = self.root / "state/diagnostics/fixture/ubuntu-24.04/0"
        self.assertIn(f"{diagnostics}:{runtime_root}/_diag:rw", command)
        self.assertLess(
            command.index(f"{runtime_root}:{runtime_root}:rw"),
            command.index(f"{diagnostics}:{runtime_root}/_diag:rw"),
        )
        self.assertNotIn("/runner-runtime:rw,nosuid,nodev,size=20g", command)
        self.assertIn(f"RUNNER_RUNTIME_DIR={runtime_root}", command)
        self.assertIn(
            "/opt/f5-actions-runner/runner-entrypoint.sh:/usr/local/bin/runner-entrypoint:ro",
            command,
        )
        install_calls = [call for call in recorder.calls if call[0][0] == "install"]
        self.assertEqual(len(install_calls), 1)
        chown_calls = [call for call in recorder.calls if call[0][0] == "chown"]
        self.assertEqual(len(chown_calls), 1)
        self.assertEqual(
            chown_calls[0][0],
            [
                "chown",
                "--recursive",
                "--no-dereference",
                "1001:1001",
                str(diagnostics),
            ],
        )
        self.assertNotIn(
            "podman", " ".join(" ".join(call[0]) for call in recorder.calls)
        )

    def test_workspace_reset_removes_stale_runner_state_after_container_cleanup(self):
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", CommandRecorder()
        )
        spec = self.policy().repository("f5-sales-demo/fixture")
        profile = spec.profiles[0]
        workspace = controller.runtime_workspace(spec, profile, 0)
        workspace.mkdir(parents=True)
        (workspace / ".runner").write_text("stale", encoding="utf-8")
        controller.reset_workspace(spec, profile, 0)
        self.assertEqual(list(workspace.iterdir()), [])

    def test_workspace_reset_unlinks_symlinked_state_without_following_it(self):
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", CommandRecorder()
        )
        spec = self.policy().repository("f5-sales-demo/fixture")
        profile = spec.profiles[0]
        workspace = controller.runtime_workspace(spec, profile, 0)
        workspace.mkdir(parents=True)
        link = workspace / "outside"
        link.symlink_to(self.root)
        controller.reset_workspace(spec, profile, 0)
        self.assertFalse(link.exists())
        self.assertTrue(self.root.exists())

    def test_workspace_preparation_rejects_a_symlinked_workspace(self):
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", CommandRecorder()
        )
        spec = self.policy().repository("f5-sales-demo/fixture")
        profile = spec.profiles[0]
        workspace = controller.runtime_workspace(spec, profile, 0)
        workspace.parent.mkdir(parents=True)
        workspace.symlink_to(self.root)
        with self.assertRaises(MODULE.FleetError):
            controller.prepare_workspace(spec, profile, 0)

    def test_workspace_parents_allow_runner_account_traversal(self):
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", CommandRecorder()
        )
        spec = self.policy().repository("f5-sales-demo/fixture")
        profile = spec.profiles[0]
        workspace = controller.prepare_workspace(spec, profile, 0)
        for parent in workspace.parents:
            if parent == controller.base_dir:
                break
            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o711)

    def test_workspace_reset_removes_read_only_artifacts(self):
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", CommandRecorder()
        )
        spec = self.policy().repository("f5-sales-demo/fixture")
        profile = spec.profiles[0]
        workspace = controller.runtime_workspace(spec, profile, 0)
        artifact = workspace / "read-only" / "artifact"
        artifact.parent.mkdir(parents=True)
        artifact.write_text("stale", encoding="utf-8")
        for mode in (0o500, 0o100, 0o300, 0o000):
            with self.subTest(mode=oct(mode)):
                artifact.parent.chmod(mode)
                controller.reset_workspace(spec, profile, 0)
                self.assertEqual(list(workspace.iterdir()), [])
                artifact.parent.mkdir()
                artifact.write_text("stale", encoding="utf-8")

    def test_read_only_cleanup_unlinks_symlink_without_touching_target(self):
        target = self.root / "outside"
        target.mkdir()
        target.chmod(0o500)
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        MODULE.EphemeralController.remove_read_only(
            os.unlink,
            str(link),
            PermissionError("denied"),
        )
        self.assertFalse(link.exists())
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o500)

    def test_read_only_open_retry_does_not_call_open_with_missing_flags(self):
        directory = self.root / "unreadable"
        directory.mkdir()
        directory.chmod(0o000)
        MODULE.EphemeralController.remove_read_only(
            MODULE.os.open,
            str(directory),
            PermissionError("denied"),
        )
        self.assertFalse(directory.exists())

    def test_read_only_scandir_retry_repairs_the_target_directory(self):
        directory = self.root / "unreadable"
        directory.mkdir()
        with (
            mock.patch.object(MODULE.os, "open", return_value=7) as open_call,
            mock.patch.object(MODULE.os, "fchmod"),
            mock.patch.object(MODULE.os, "close"),
            mock.patch.object(MODULE.os, "chmod"),
            mock.patch.object(MODULE.os, "scandir") as scandir_call,
        ):
            MODULE.EphemeralController.remove_read_only(
                MODULE.os.scandir,
                str(directory),
                PermissionError("denied"),
            )
        self.assertEqual(open_call.call_args.args[0], directory)
        scandir_call.assert_called_once_with(str(directory))

    def test_cleanup_failure_blocks_workspace_reset(self):
        recorder = CommandRecorder()
        recorder_result = SimpleNamespace(returncode=1, stdout="", stderr="failed")

        def failing_cleanup(command, **kwargs):
            recorder.calls.append((command, kwargs))
            if "rm" in command:
                return recorder_result
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", failing_cleanup
        )
        with self.assertRaises(MODULE.FleetError):
            controller.run_once("f5-sales-demo/fixture", "ubuntu-24.04")

    def test_shutdown_cleanup_removes_exact_slot_registration(self):
        github = FakeGitHub()
        github.records = [
            {"id": 42, "name": "gha-fixture-ubuntu-24.04-0-deadbeef"},
            {"id": 43, "name": "persistent-fixture"},
        ]
        controller = MODULE.EphemeralController(
            self.policy(), github, self.root / "state", CommandRecorder()
        )
        controller.run_once("f5-sales-demo/fixture", "ubuntu-24.04")
        self.assertEqual(github.deleted, [("f5-sales-demo/fixture", 42)])

    def test_serve_stops_when_blocking_cycle_is_interrupted(self):
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", CommandRecorder()
        )

        def interrupted(*_args):
            raise MODULE.StopRequestedError

        controller.run_once = interrupted
        with mock.patch.object(MODULE.signal, "signal"):
            self.assertEqual(
                controller.serve("f5-sales-demo/fixture", "ubuntu-24.04", backoff=0),
                0,
            )

    def test_stop_request_reaches_exact_blocking_outer_container_then_cleans(self):
        outer_id = "a" * 64
        events = []
        exact_inventories = 0
        github = FakeGitHub()
        github.records = [{"id": 42, "name": "gha-fixture-ubuntu-24.04-0-deadbeef"}]

        class InterruptedRunnerProcess:
            returncode = -MODULE.signal.SIGTERM

            @staticmethod
            def communicate(input_text):
                events.append(("communicate", input_text))
                raise MODULE.StopRequestedError

            @staticmethod
            def terminate():
                events.append(("terminate",))

            @staticmethod
            def wait(timeout=None):
                events.append(("wait", timeout))
                return -MODULE.signal.SIGTERM

        def popen(command, **kwargs):
            events.append(("popen", command, kwargs))
            return InterruptedRunnerProcess()

        def docker_fixture(command, **_kwargs):
            nonlocal exact_inventories
            events.append(("command", command))
            if command[:3] == ["docker", "version", "--format"]:
                return SimpleNamespace(returncode=0, stdout="29.2.1\n", stderr="")
            if command[:4] == ["docker", "container", "ls", "--all"]:
                if "--filter" not in command:
                    return SimpleNamespace(returncode=0, stdout="", stderr="")
                exact_inventories += 1
                output = outer_id + "\n" if exact_inventories == 2 else ""
                return SimpleNamespace(returncode=0, stdout=output, stderr="")
            if command == ["docker", "container", "inspect", outer_id]:
                payload = {
                    "Id": outer_id,
                    "Name": "/gha-fixture-ubuntu-24.04-0",
                    "Config": {
                        "Labels": {
                            "f5.runner.managed": "true",
                            "f5.runner.repository": "f5-sales-demo/fixture",
                            "f5.runner.profile": "ubuntu-24.04",
                            "f5.runner.slot": "0",
                        }
                    },
                    "Mounts": [],
                }
                return SimpleNamespace(
                    returncode=0, stdout=json.dumps(payload), stderr=""
                )
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(),
            github,
            self.root / "state",
            docker_fixture,
            popen=popen,
        )

        with self.assertRaises(MODULE.StopRequestedError):
            controller.run_once("f5-sales-demo/fixture", "ubuntu-24.04")

        runner_command = next(event[1] for event in events if event[0] == "popen")
        self.assertEqual(runner_command[:2], ["docker", "run"])
        self.assertIn(("communicate", "registration-secret\n"), events)
        stop_event = (
            "command",
            ["docker", "container", "stop", "--time", "300", outer_id],
        )
        self.assertIn(stop_event, events)
        self.assertLess(events.index(stop_event), events.index(("wait", 5)))
        self.assertNotIn(("terminate",), events)
        self.assertEqual(github.deleted, [("f5-sales-demo/fixture", 42)])

    def test_completed_outer_process_does_not_request_an_extra_stop(self):
        events = []

        class CompletedRunnerProcess:
            returncode = 0

            @staticmethod
            def communicate(input_text):
                events.append(("communicate", input_text))
                return None, None

            @staticmethod
            def terminate():
                events.append(("terminate",))

            @staticmethod
            def wait():
                events.append(("wait",))
                return 0

        controller = MODULE.EphemeralController(
            self.policy(),
            FakeGitHub(),
            self.root / "state",
            CommandRecorder(),
            popen=lambda *_args, **_kwargs: CompletedRunnerProcess(),
        )

        self.assertEqual(
            controller.run_once("f5-sales-demo/fixture", "ubuntu-24.04"), 0
        )
        self.assertEqual(events, [("communicate", "registration-secret\n")])

    def test_container_profile_uses_exact_host_docker_socket(self):
        recorder = CommandRecorder()
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", recorder
        )
        with mock.patch.object(
            MODULE.EphemeralController, "docker_socket_group", return_value=997
        ):
            controller.run_once("f5-sales-demo/fixture", "container-build")
        command = next(
            call[0] for call in recorder.calls if call[0][:2] == ["docker", "run"]
        )
        rendered = " ".join(command)
        self.assertIn("/run/docker.sock:/run/docker.sock:rw", rendered)
        self.assertIn("DOCKER_HOST=unix:///run/docker.sock", command)
        self.assertIn("997", command)
        runtime_root = (
            self.root / "state" / "workspaces" / "fixture" / "container-build" / "0"
        )
        self.assertIn(f"{runtime_root}:{runtime_root}:rw", command)
        self.assertNotIn("--privileged", command)
        self.assertNotIn("/dev/fuse", command)

    def test_engine_below_minimum_fails_before_runner_launch(self):
        recorder = CommandRecorder()

        def old_engine(command, **kwargs):
            recorder.calls.append((command, kwargs))
            if command[:3] == ["docker", "version", "--format"]:
                return SimpleNamespace(returncode=0, stdout="29.2.0\n", stderr="")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", old_engine
        )
        with self.assertRaises(MODULE.FleetError):
            controller.run_once("f5-sales-demo/fixture", "ubuntu-24.04")
        self.assertFalse(
            any(call[0][:2] == ["docker", "run"] for call in recorder.calls)
        )

    def test_cleanup_stops_exact_outer_then_removes_nested_workspace_container(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        workspace.mkdir(parents=True)
        outer_id = "a" * 64
        nested_id = "b" * 64
        calls = []

        def docker_fixture(command, **_kwargs):
            calls.append(command)
            if command[:3] == ["docker", "version", "--format"]:
                return SimpleNamespace(returncode=0, stdout="29.2.1\n", stderr="")
            if command[:4] == ["docker", "container", "ls", "--all"]:
                if "--filter" in command:
                    return SimpleNamespace(
                        returncode=0, stdout=outer_id + "\n", stderr=""
                    )
                return SimpleNamespace(returncode=0, stdout=nested_id + "\n", stderr="")
            if command[:3] == ["docker", "container", "inspect"]:
                container_id = command[-1]
                if container_id == outer_id:
                    payload: dict[str, Any] = {
                        "Id": outer_id,
                        "Name": "/gha-fixture-ubuntu-24.04-0",
                        "Config": {
                            "Labels": {
                                "f5.runner.managed": "true",
                                "f5.runner.repository": "f5-sales-demo/fixture",
                                "f5.runner.profile": "ubuntu-24.04",
                                "f5.runner.slot": "0",
                            }
                        },
                        "Mounts": [],
                    }
                else:
                    payload = {
                        "Id": nested_id,
                        "Name": "/nested-action",
                        "Config": {"Labels": {}},
                        "Mounts": [
                            {
                                "Type": "bind",
                                "Source": str(workspace / "_work"),
                                "Destination": "/github/workspace",
                            }
                        ],
                    }
                return SimpleNamespace(
                    returncode=0, stdout=json.dumps(payload), stderr=""
                )
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        (workspace / "_work").mkdir()
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", docker_fixture
        )
        spec = self.policy().repository("f5-sales-demo/fixture")
        controller.cleanup(spec, spec.profiles[0], 0)
        outer_stop = ["docker", "container", "stop", "--time", "300", outer_id]
        outer_remove = ["docker", "container", "rm", "--force", outer_id]
        nested_remove = ["docker", "container", "rm", "--force", nested_id]
        self.assertLess(calls.index(outer_stop), calls.index(outer_remove))
        self.assertLess(calls.index(outer_remove), calls.index(nested_remove))

    def test_nested_cleanup_removes_container_after_bind_source_was_deleted(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        workspace.mkdir(parents=True)
        deleted_source = workspace / "deleted" / "source"
        nested_id = "f" * 64
        calls = []

        def docker_fixture(command, **_kwargs):
            calls.append(command)
            if command[:4] == ["docker", "container", "ls", "--all"]:
                if "--filter" in command:
                    return SimpleNamespace(returncode=0, stdout="", stderr="")
                return SimpleNamespace(returncode=0, stdout=nested_id + "\n", stderr="")
            if command[:3] == ["docker", "container", "inspect"]:
                payload = {
                    "Id": nested_id,
                    "Name": "/nested",
                    "Config": {"Labels": {}},
                    "Mounts": [{"Type": "bind", "Source": str(deleted_source)}],
                }
                return SimpleNamespace(
                    returncode=0, stdout=json.dumps(payload), stderr=""
                )
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", docker_fixture
        )
        spec = self.policy().repository("f5-sales-demo/fixture")

        controller.cleanup(spec, spec.profiles[0], 0)

        self.assertIn(
            ["docker", "container", "rm", "--force", nested_id],
            calls,
        )

    def test_cleanup_serializes_host_global_container_inventory(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        workspace.mkdir(parents=True)
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", CommandRecorder()
        )
        spec = self.policy().repository("f5-sales-demo/fixture")

        with mock.patch.object(MODULE.fcntl, "flock") as flock:
            controller.cleanup(spec, spec.profiles[0], 0)

        flock.assert_called_once()
        descriptor, operation = flock.call_args.args
        self.assertIsInstance(descriptor, int)
        self.assertEqual(operation, MODULE.fcntl.LOCK_EX)
        lock_path = self.root / "state/.cleanup.lock"
        metadata = lock_path.stat(follow_symlinks=False)
        self.assertTrue(stat.S_ISREG(metadata.st_mode))
        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)

    def test_cleanup_rejects_symlink_lock_without_following_it(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        workspace.mkdir(parents=True)
        outside = self.root / "outside-lock"
        outside.write_text("preserve", encoding="utf-8")
        (self.root / "state/.cleanup.lock").symlink_to(outside)
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", CommandRecorder()
        )
        spec = self.policy().repository("f5-sales-demo/fixture")

        with self.assertRaises(MODULE.FleetError):
            controller.cleanup(spec, spec.profiles[0], 0)

        self.assertEqual(outside.read_text(encoding="utf-8"), "preserve")

    def test_nested_cleanup_tolerates_confirmed_concurrent_container_removal(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        (workspace / "_work").mkdir(parents=True)
        disappeared_id = "1" * 64
        nested_id = "2" * 64
        calls = []

        def docker_fixture(command, **_kwargs):
            calls.append(command)
            if command[:4] == ["docker", "container", "ls", "--all"]:
                if "--filter" not in command:
                    return SimpleNamespace(
                        returncode=0,
                        stdout=f"{disappeared_id}\n{nested_id}\n",
                        stderr="",
                    )
                container_filter = command[command.index("--filter") + 1]
                if container_filter == f"id={disappeared_id}":
                    return SimpleNamespace(returncode=0, stdout="", stderr="")
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if command == ["docker", "container", "inspect", disappeared_id]:
                return SimpleNamespace(
                    returncode=1,
                    stdout="",
                    stderr=f"No such container: {disappeared_id}",
                )
            if command == ["docker", "container", "inspect", nested_id]:
                payload = {
                    "Id": nested_id,
                    "Name": "/nested",
                    "Config": {"Labels": {}},
                    "Mounts": [
                        {
                            "Type": "bind",
                            "Source": str(workspace / "_work"),
                        }
                    ],
                }
                return SimpleNamespace(
                    returncode=0, stdout=json.dumps(payload), stderr=""
                )
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", docker_fixture
        )
        spec = self.policy().repository("f5-sales-demo/fixture")

        controller.cleanup(spec, spec.profiles[0], 0)

        self.assertIn(
            [
                "docker",
                "container",
                "ls",
                "--all",
                "--quiet",
                "--no-trunc",
                "--filter",
                f"id={disappeared_id}",
            ],
            calls,
        )
        self.assertIn(
            ["docker", "container", "rm", "--force", nested_id],
            calls,
        )

    def test_nested_cleanup_retries_container_removal_in_progress(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        (workspace / "_work").mkdir(parents=True)
        disappearing_id = "5" * 64
        nested_id = "6" * 64
        calls = []
        exact_inventories = 0

        def docker_fixture(command, **_kwargs):
            nonlocal exact_inventories
            calls.append(command)
            if command[:4] == ["docker", "container", "ls", "--all"]:
                if "--filter" not in command:
                    return SimpleNamespace(
                        returncode=0,
                        stdout=f"{disappearing_id}\n{nested_id}\n",
                        stderr="",
                    )
                container_filter = command[command.index("--filter") + 1]
                if container_filter == f"id={disappearing_id}":
                    exact_inventories += 1
                    output = f"{disappearing_id}\n" if exact_inventories <= 7 else ""
                    return SimpleNamespace(returncode=0, stdout=output, stderr="")
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if command == ["docker", "container", "inspect", disappearing_id]:
                return SimpleNamespace(
                    returncode=1,
                    stdout="",
                    stderr="removal in progress",
                )
            if command == ["docker", "container", "inspect", nested_id]:
                payload = {
                    "Id": nested_id,
                    "Name": "/nested",
                    "Config": {"Labels": {}},
                    "Mounts": [
                        {
                            "Type": "bind",
                            "Source": str(workspace / "_work"),
                        }
                    ],
                }
                return SimpleNamespace(
                    returncode=0, stdout=json.dumps(payload), stderr=""
                )
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", docker_fixture
        )
        spec = self.policy().repository("f5-sales-demo/fixture")

        with mock.patch.object(MODULE.time, "sleep") as sleep:
            controller.cleanup(spec, spec.profiles[0], 0)

        self.assertEqual(exact_inventories, 8)
        self.assertEqual(sleep.call_count, 7)
        self.assertEqual(
            calls.count(["docker", "container", "inspect", disappearing_id]), 8
        )
        self.assertIn(
            ["docker", "container", "rm", "--force", nested_id],
            calls,
        )

    def test_nested_cleanup_bounds_persistent_removal_in_progress(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        workspace.mkdir(parents=True)
        container_id = "7" * 64
        calls = []

        def docker_fixture(command, **_kwargs):
            calls.append(command)
            if command[:4] == ["docker", "container", "ls", "--all"]:
                if "--filter" in command:
                    container_filter = command[command.index("--filter") + 1]
                    if container_filter.startswith("name="):
                        return SimpleNamespace(returncode=0, stdout="", stderr="")
                return SimpleNamespace(
                    returncode=0, stdout=f"{container_id}\n", stderr=""
                )
            if command == ["docker", "container", "inspect", container_id]:
                return SimpleNamespace(
                    returncode=1, stdout="", stderr="removal in progress"
                )
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", docker_fixture
        )
        spec = self.policy().repository("f5-sales-demo/fixture")

        with (
            mock.patch.object(MODULE.time, "sleep") as sleep,
            self.assertRaises(MODULE.FleetError),
        ):
            controller.cleanup(spec, spec.profiles[0], 0)

        self.assertEqual(
            calls.count(["docker", "container", "inspect", container_id]),
            MODULE.TRANSIENT_INSPECT_ATTEMPTS,
        )
        self.assertEqual(sleep.call_count, MODULE.TRANSIENT_INSPECT_ATTEMPTS - 1)
        self.assertLessEqual(
            sum(call.args[0] for call in sleep.call_args_list),
            MODULE.TRANSIENT_INSPECT_MAX_TOTAL_SECONDS,
        )

    def test_nested_cleanup_fails_closed_when_disappearance_is_not_proven(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        workspace.mkdir(parents=True)
        container_id = "3" * 64
        other_id = "4" * 64
        for returncode, output in (
            (1, ""),
            (0, container_id + "\n"),
            (0, other_id + "\n"),
            (0, "not-a-container-id\n"),
        ):
            with self.subTest(returncode=returncode, output=output):

                def docker_fixture(
                    command, returncode=returncode, output=output, **_kwargs
                ):
                    if command[:4] == ["docker", "container", "ls", "--all"]:
                        if "--filter" not in command:
                            return SimpleNamespace(
                                returncode=0, stdout=container_id + "\n", stderr=""
                            )
                        container_filter = command[command.index("--filter") + 1]
                        if container_filter == f"id={container_id}":
                            return SimpleNamespace(
                                returncode=returncode, stdout=output, stderr="failed"
                            )
                        return SimpleNamespace(returncode=0, stdout="", stderr="")
                    if command == ["docker", "container", "inspect", container_id]:
                        return SimpleNamespace(
                            returncode=1, stdout="", stderr="inspection failed"
                        )
                    return SimpleNamespace(returncode=0, stdout="", stderr="")

                controller = MODULE.EphemeralController(
                    self.policy(), FakeGitHub(), self.root / "state", docker_fixture
                )
                spec = self.policy().repository("f5-sales-demo/fixture")

                with (
                    mock.patch.object(MODULE.time, "sleep"),
                    self.assertRaises(MODULE.FleetError),
                ):
                    controller.cleanup(spec, spec.profiles[0], 0)

    def test_nested_cleanup_rejects_malformed_or_mixed_bind_mounts(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        (workspace / "_work").mkdir(parents=True)
        nested_id = "c" * 64
        for output in (
            "not-json",
            json.dumps(
                {
                    "Id": nested_id,
                    "Name": "/nested",
                    "Config": {"Labels": {}},
                    "Mounts": [
                        {"Type": "bind", "Source": str(workspace / "_work")},
                        {"Type": "bind", "Source": "/etc"},
                    ],
                }
            ),
        ):
            with self.subTest(output=output):

                def docker_fixture(command, output=output, **_kwargs):
                    if command[:4] == ["docker", "container", "ls", "--all"]:
                        if "--filter" in command:
                            return SimpleNamespace(returncode=0, stdout="", stderr="")
                        return SimpleNamespace(
                            returncode=0, stdout=nested_id + "\n", stderr=""
                        )
                    if command[:3] == ["docker", "container", "inspect"]:
                        return SimpleNamespace(returncode=0, stdout=output, stderr="")
                    return SimpleNamespace(returncode=0, stdout="", stderr="")

                controller = MODULE.EphemeralController(
                    self.policy(), FakeGitHub(), self.root / "state", docker_fixture
                )
                spec = self.policy().repository("f5-sales-demo/fixture")
                with self.assertRaises(MODULE.FleetError):
                    controller.cleanup(spec, spec.profiles[0], 0)

    def test_nested_cleanup_rejects_bind_source_symlink_escape(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        workspace.mkdir(parents=True)
        outside = self.root / "outside"
        (outside / "child").mkdir(parents=True)
        (workspace / "escape").symlink_to(outside, target_is_directory=True)
        nested_id = "9" * 64

        def docker_fixture(command, **_kwargs):
            if command[:4] == ["docker", "container", "ls", "--all"]:
                if "--filter" in command:
                    return SimpleNamespace(returncode=0, stdout="", stderr="")
                return SimpleNamespace(returncode=0, stdout=nested_id + "\n", stderr="")
            if command[:3] == ["docker", "container", "inspect"]:
                payload = {
                    "Id": nested_id,
                    "Name": "/nested",
                    "Config": {"Labels": {}},
                    "Mounts": [
                        {
                            "Type": "bind",
                            "Source": str(workspace / "escape" / "child"),
                        }
                    ],
                }
                return SimpleNamespace(
                    returncode=0, stdout=json.dumps(payload), stderr=""
                )
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", docker_fixture
        )
        spec = self.policy().repository("f5-sales-demo/fixture")

        with self.assertRaises(MODULE.FleetError):
            controller.cleanup(spec, spec.profiles[0], 0)

    def test_nested_removal_failure_blocks_workspace_erasure(self):
        workspace = self.root / "state/workspaces/fixture/ubuntu-24.04/0"
        (workspace / "_work").mkdir(parents=True)
        marker = workspace / "keep"
        marker.write_text("preserve", encoding="utf-8")
        nested_id = "d" * 64

        def docker_fixture(command, **_kwargs):
            if command[:3] == ["docker", "version", "--format"]:
                return SimpleNamespace(returncode=0, stdout="29.2.1\n", stderr="")
            if command[:4] == ["docker", "container", "ls", "--all"]:
                if "--filter" in command:
                    return SimpleNamespace(returncode=0, stdout="", stderr="")
                return SimpleNamespace(returncode=0, stdout=nested_id + "\n", stderr="")
            if command[:3] == ["docker", "container", "inspect"]:
                payload = {
                    "Id": nested_id,
                    "Name": "/nested",
                    "Config": {"Labels": {}},
                    "Mounts": [{"Type": "bind", "Source": str(workspace / "_work")}],
                }
                return SimpleNamespace(
                    returncode=0, stdout=json.dumps(payload), stderr=""
                )
            if command == ["docker", "container", "rm", "--force", nested_id]:
                return SimpleNamespace(returncode=1, stdout="", stderr="failed")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", docker_fixture
        )
        with self.assertRaises(MODULE.FleetError):
            controller.run_once("f5-sales-demo/fixture", "ubuntu-24.04")
        self.assertTrue(marker.is_file())

    def test_slot_and_profile_fail_closed(self):
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", CommandRecorder()
        )
        with self.assertRaises(MODULE.FleetError):
            controller.run_once("f5-sales-demo/fixture", "unknown")
        with self.assertRaises(MODULE.FleetError):
            controller.run_once("f5-sales-demo/fixture", "ubuntu-24.04", slot=2)

    def test_audit_rejects_reserved_and_unexpected_managed_runner(self):
        github = FakeGitHub()
        github.records = [
            {
                "name": "gha-fixture-ubuntu-24.04-9-deadbeef",
                "labels": [{"name": "ubuntu-latest"}],
            }
        ]
        controller = MODULE.EphemeralController(
            self.policy(), github, self.root / "state", CommandRecorder()
        )
        errors = controller.audit("f5-sales-demo/fixture")
        self.assertTrue(any("unexpected managed runner" in item for item in errors))
        self.assertTrue(any("reserved label" in item for item in errors))

    def test_audit_fails_closed_on_malformed_runner_labels(self):
        github = FakeGitHub()
        github.records = [
            {
                "name": "gha-fixture-ubuntu-24.04-0-deadbeef",
                "labels": [None],
            }
        ]
        controller = MODULE.EphemeralController(
            self.policy(), github, self.root / "state", CommandRecorder()
        )

        errors = controller.audit("f5-sales-demo/fixture")

        self.assertTrue(any("labels are malformed" in item for item in errors))

    def test_container_audit_verifies_exact_labels_limits_and_socket_isolation(self):
        container_id = "e" * 64
        payload: dict[str, Any] = {
            "Id": container_id,
            "Name": "/gha-fixture-container-build-0",
            "Config": {
                "Labels": {
                    "f5.runner.managed": "true",
                    "f5.runner.repository": "f5-sales-demo/fixture",
                    "f5.runner.profile": "container-build",
                    "f5.runner.slot": "0",
                },
                "StopTimeout": 300,
            },
            "HostConfig": {
                "Memory": 8 * 1024**3,
                "NanoCpus": 4_000_000_000,
                "PidsLimit": 1024,
                "NetworkMode": "bridge",
                "ReadonlyRootfs": True,
                "CapDrop": ["ALL"],
                "SecurityOpt": ["no-new-privileges=true"],
            },
            "Mounts": [
                {
                    "Type": "bind",
                    "Source": "/run/docker.sock",
                    "Destination": "/run/docker.sock",
                }
            ],
        }

        def docker_fixture(command, **_kwargs):
            if command[:4] == ["docker", "container", "ls", "--all"]:
                return SimpleNamespace(
                    returncode=0, stdout=container_id + "\n", stderr=""
                )
            if command[:3] == ["docker", "container", "inspect"]:
                return SimpleNamespace(
                    returncode=0, stdout=json.dumps(payload), stderr=""
                )
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", docker_fixture
        )
        self.assertEqual(controller.audit_containers("f5-sales-demo/fixture"), [])
        payload["HostConfig"]["Memory"] = 1
        errors = controller.audit_containers("f5-sales-demo/fixture")
        self.assertTrue(any("resource mismatch" in item for item in errors))


if __name__ == "__main__":
    unittest.main()
