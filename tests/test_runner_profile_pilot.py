"""Exercise the governed profile pilots with hermetic tool and socket fixtures."""

import socket
import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent


@contextmanager
def pilot_directory():
    """Keep the hermetic fixture alive until unittest runs its cleanups."""
    with tempfile.TemporaryDirectory() as directory:
        yield Path(directory)


class RunnerProfilePilotTests(unittest.TestCase):
    """Verify catalog failure propagation and Docker isolation before deployment."""

    def setUp(self):
        self.folder = self.enterContext(pilot_directory())
        self.verifications = self.folder / "verifications"
        self.docker_calls = self.folder / "docker-calls"
        self.verifications.touch()
        self.docker_calls.touch()
        self.socket_path = self.folder / "docker.sock"
        self.env = {
            "PATH": str(self.folder),
            "PILOT_VERIFICATIONS": str(self.verifications),
            "PILOT_DOCKER_CALLS": str(self.docker_calls),
            "PILOT_VERIFIER_CODE": "0",
            "EXPECTED_RUNNER_IMAGE": "ghcr.io/f5-sales-demo/self-hosted-runner@sha256:"
            + "a" * 64,
            "RUNNER_IMAGE_DIGEST": "ghcr.io/f5-sales-demo/self-hosted-runner@sha256:"
            + "a" * 64,
        }
        self.tool(
            "verify-runner-tools",
            'printf "%s\\n" "$*" >> "$PILOT_VERIFICATIONS"\n'
            'exit "$PILOT_VERIFIER_CODE"\n',
        )
        self.tool("zig", 'printf "0.16.0\\n"\n')

    def tool(self, name, body):
        path = self.folder / name
        path.write_text("#!/bin/bash\n" + body, encoding="utf-8")
        path.chmod(0o700)

    def run_pilot(self, profile):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/runner-profile-pilot.yml").read_text(
                encoding="utf-8"
            )
        )
        steps = workflow["jobs"][profile]["steps"]
        assert len(steps) == 1
        script = steps[0]["run"].replace("/run/docker.sock", str(self.socket_path))
        script = script.replace("/run/${cli}.sock", str(self.socket_path))
        return subprocess.run(  # noqa: S603 -- trusted workflow with hermetic fixtures
            ["/bin/bash", "-c", script],
            env=self.env,
            check=False,
            capture_output=True,
            text=True,
        )

    def bind_builder(self):
        fixture = socket.socket(socket.AF_UNIX)
        fixture.bind(str(self.socket_path))
        self.addCleanup(fixture.close)
        self.tool("docker", 'printf "%s\\n" "$*" >> "$PILOT_DOCKER_CALLS"\n')

    def test_standard_uses_verified_catalog_without_docker(self):
        result = self.run_pilot("standard")
        assert result.returncode == 0, result.stderr
        assert self.verifications.read_text() == "standard\n"
        assert self.docker_calls.read_text() == ""

    def test_standard_propagates_catalog_failure(self):
        self.env["PILOT_VERIFIER_CODE"] = "42"
        result = self.run_pilot("standard")
        assert result.returncode == 42

    def test_builder_accepts_current_verified_catalog(self):
        self.bind_builder()
        result = self.run_pilot("container-build")
        assert result.returncode == 0, result.stderr
        assert self.verifications.read_text() == "container-build\n"
        assert len(self.docker_calls.read_text().splitlines()) == 3

    def test_builder_catalog_failure_prevents_docker_execution(self):
        self.bind_builder()
        self.env["PILOT_VERIFIER_CODE"] = "42"
        result = self.run_pilot("container-build")
        assert result.returncode == 42
        assert self.docker_calls.read_text() == ""

    def test_builder_missing_socket_prevents_docker_execution(self):
        self.tool("docker", 'printf "%s\\n" "$*" >> "$PILOT_DOCKER_CALLS"\n')
        result = self.run_pilot("container-build")
        assert result.returncode != 0
        assert self.docker_calls.read_text() == ""

    def test_image_mismatch_prevents_catalog_and_docker_execution(self):
        self.bind_builder()
        self.env["RUNNER_IMAGE_DIGEST"] = (
            "ghcr.io/f5-sales-demo/self-hosted-runner@sha256:" + "b" * 64
        )
        result = self.run_pilot("container-build")
        assert result.returncode != 0
        assert self.verifications.read_text() == ""
        assert self.docker_calls.read_text() == ""

    def test_missing_or_invalid_image_identity_is_rejected(self):
        for field in ("EXPECTED_RUNNER_IMAGE", "RUNNER_IMAGE_DIGEST"):
            for value in (
                "",
                "latest",
                "sha256:" + "a" * 64,
                "foreign.example/self-hosted-runner@sha256:" + "a" * 64,
                "ghcr.io/f5-sales-demo/self-hosted-runner@sha256:" + "a" * 63,
            ):
                with self.subTest(field=field, value=value):
                    original = self.env[field]
                    self.env[field] = value
                    try:
                        result = self.run_pilot("standard")
                        assert result.returncode != 0
                    finally:
                        self.env[field] = original
        assert self.verifications.read_text() == ""

    def test_reviewed_registry_mirrors_accept_identical_manifest_digest(self):
        for registry in (
            "280469140135.dkr.ecr.us-east-1.amazonaws.com",
            "f5salesdemoarcca.azurecr.io",
        ):
            with self.subTest(registry=registry):
                self.env["RUNNER_IMAGE_DIGEST"] = (
                    registry + "/self-hosted-runner@sha256:" + "a" * 64
                )
                result = self.run_pilot("standard")
                assert result.returncode == 0, result.stderr

    def test_new_reviewed_image_has_no_version_or_age_hold(self):
        image = "ghcr.io/f5-sales-demo/self-hosted-runner@sha256:" + "c" * 64
        self.env["EXPECTED_RUNNER_IMAGE"] = image
        self.env["RUNNER_IMAGE_DIGEST"] = image
        result = self.run_pilot("standard")
        assert result.returncode == 0, result.stderr

    def test_image_input_is_never_evaluated_as_shell_source(self):
        marker = self.folder / "injection-marker"
        self.env["EXPECTED_RUNNER_IMAGE"] = "$(/usr/bin/touch " + str(marker) + ")"
        result = self.run_pilot("standard")
        assert result.returncode != 0
        assert not marker.exists()
        assert self.verifications.read_text() == ""

    def test_workflow_requires_reviewed_images_without_defaults(self):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/runner-profile-pilot.yml").read_text()
        )
        trigger = workflow.get("on", workflow.get(True))
        inputs = trigger["workflow_dispatch"]["inputs"]
        for profile in ("standard", "container-build"):
            image_input = inputs[profile + "-image"]
            assert image_input["required"] is True
            assert "default" not in image_input
            step = workflow["jobs"][profile]["steps"][0]
            assert (
                step["env"]["EXPECTED_RUNNER_IMAGE"]
                == "${{ inputs." + profile + "-image }}"
            )


if __name__ == "__main__":
    unittest.main()
