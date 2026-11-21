"""Behavioral coverage for current xcsh hosted route policy."""

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "xcsh_hosted_auditor", ROOT / "scripts/audit-runner-workflows.py"
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class XcshHostedPolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy, self.exceptions = MODULE.load_policy(
            ROOT / ".github/config/self-hosted-runner-policy.json",
            "f5-sales-demo/xcsh",
        )
        self.routes = MODULE.repository_routes(self.policy, "f5-sales-demo/xcsh")

    def audit(self, path, name, label, docker=False):
        job = {
            "runs-on": label,
            "steps": [{"run": "docker version" if docker else "echo verify"}],
        }
        workflow = {"on": {"pull_request": {}}, "jobs": {name: job}}
        return MODULE.audit_job(
            "f5-sales-demo/xcsh",
            path,
            name,
            job,
            self.policy["profiles"],
            self.routes,
            self.exceptions,
            (self.policy["defaults"]["profile"], workflow),
        )

    def test_current_mac_release_and_recovery_routes(self):
        for path, name, label in [
            (".github/workflows/ci.yml", "create-release", "macos-26"),
            (".github/workflows/ci.yml", "update-homebrew", "macos-26"),
            (
                ".github/workflows/release-github-backfill.yml",
                "backfill",
                "macos-latest",
            ),
        ]:
            with self.subTest(job=name):
                assert self.audit(path, name, label) == []

    def test_old_mac_label_cannot_replace_current_routes(self):
        for path, name in [
            (".github/workflows/ci.yml", "create-release"),
            (".github/workflows/ci.yml", "update-homebrew"),
            (".github/workflows/release-github-backfill.yml", "backfill"),
        ]:
            with self.subTest(job=name):
                assert self.audit(path, name, "macos-14")

    def test_exact_native_arm_container_build_route(self):
        assert (
            self.audit(
                ".github/workflows/container.yml",
                "container-build-arm64",
                "ubuntu-24.04-arm",
                docker=True,
            )
            == []
        )

    def test_wrong_arm_label_and_unknown_hosted_job_are_rejected(self):
        for name, label in [
            ("container-build-arm64", "ubuntu-24.04"),
            ("unqualified-arm-build", "ubuntu-24.04-arm"),
        ]:
            with self.subTest(job=name, label=label):
                assert self.audit(
                    ".github/workflows/container.yml", name, label, docker=True
                )

    def test_socketless_route_still_cannot_run_docker(self):
        errors = self.audit(
            ".github/workflows/container.yml",
            "unqualified-build",
            "xcsh-socketless",
            docker=True,
        )
        assert any(
            "Docker workload requires a Docker socket profile" in e for e in errors
        )


if __name__ == "__main__":
    unittest.main()
