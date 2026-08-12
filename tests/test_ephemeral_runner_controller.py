#!/usr/bin/env python3
"""Hermetic tests for the ephemeral runner lifecycle."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "ephemeral_runner_controller", ROOT / "scripts/ephemeral-runner-controller.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeGitHub:
    def __init__(self):
        self.requested = []
        self.records = []

    def registration_token(self, repository):
        self.requested.append(repository)
        return "registration-secret"

    def runners(self, _repository):
        return self.records


class CommandRecorder:
    def __init__(self):
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append((command, kwargs))
        return SimpleNamespace(returncode=0, stdout="", stderr="")


class EphemeralRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.policy_path = self.root / "policy.json"
        self.policy_data = {
            "schema_version": 2,
            "defaults": {"replicas": 1, "profile": "ubuntu-24.04"},
            "profiles": {
                "ubuntu-24.04": {
                    "image": "ghcr.io/f5-sales-demo/runner@sha256:" + "a" * 64,
                    "labels": ["ubuntu-24.04"],
                    "memory": "4g",
                    "cpus": "2",
                    "pids_limit": 512,
                    "container_socket": False,
                },
                "container-build": {
                    "image": "ghcr.io/f5-sales-demo/runner@sha256:" + "b" * 64,
                    "labels": ["container-build"],
                    "memory": "8g",
                    "cpus": "4",
                    "pids_limit": 1024,
                    "container_socket": True,
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
        self.temp.cleanup()

    def write_policy(self):
        self.policy_path.write_text(json.dumps(self.policy_data), encoding="utf-8")

    def policy(self):
        return MODULE.FleetPolicy(self.policy_path)

    def test_policy_builds_exact_repository_profiles(self):
        spec = self.policy().repository("f5-sales-demo/fixture")
        self.assertEqual(spec.account, "gha-fixture")
        self.assertEqual(spec.account_for(spec.profiles[1]), "ghb-fixture")
        self.assertEqual(
            [item.name for item in spec.profiles], ["ubuntu-24.04", "container-build"]
        )
        self.assertEqual(spec.replicas, 1)

    def test_policy_rejects_mutable_image_and_reserved_label(self):
        profile = self.policy_data["profiles"]["ubuntu-24.04"]
        profile["image"] = "ghcr.io/example/runner:latest"
        profile["labels"].append("ubuntu-latest")
        self.write_policy()
        with self.assertRaises(MODULE.FleetError):
            self.policy()

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
        podman_calls = [call for call in recorder.calls if "run" in call[0]]
        self.assertEqual(len(podman_calls), 1)
        command, kwargs = podman_calls[0]
        self.assertNotIn("registration-secret", " ".join(command))
        self.assertEqual(kwargs["input_text"], "registration-secret\n")
        self.assertIn("--read-only", command)
        self.assertIn("--cap-drop=all", command)
        self.assertIn("--security-opt=no-new-privileges", command)
        self.assertIn("slirp4netns:allow_host_loopback=false", command)
        self.assertNotIn("/var/run/docker.sock", " ".join(command))
        self.assertIn("--userns=keep-id:uid=1001,gid=1001", command)
        install_calls = [call for call in recorder.calls if call[0][0] == "install"]
        self.assertEqual(len(install_calls), 1)

    def test_container_profile_uses_isolated_repository_socket(self):
        recorder = CommandRecorder()
        controller = MODULE.EphemeralController(
            self.policy(), FakeGitHub(), self.root / "state", recorder
        )
        controller.run_once("f5-sales-demo/fixture", "container-build")
        command = next(call[0] for call in recorder.calls if "run" in call[0])
        rendered = " ".join(command)
        self.assertIn("/run/f5-actions-podman/fixture/podman.sock", rendered)
        self.assertIn("DOCKER_HOST=unix:///run/podman/podman.sock", command)
        self.assertNotIn("--privileged", command)
        self.assertNotIn("/dev/fuse", command)

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


if __name__ == "__main__":
    unittest.main()
