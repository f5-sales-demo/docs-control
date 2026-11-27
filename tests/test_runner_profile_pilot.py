"""Exercise the governed profile pilots with hermetic tool and socket fixtures."""

import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent


class RunnerProfilePilotTests(unittest.TestCase):
    """Verify catalog failure propagation and Docker isolation before deployment."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
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


if __name__ == "__main__":
    unittest.main()
