#!/usr/bin/env python3
# ruff: noqa: PT009, PT018
"""Hermetic tests for the bounded fleet runner dispatcher."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "fleet_runner_dispatch", ROOT / "scripts/fleet-runner-dispatch.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class GitHub:
    def __init__(self, responses):
        self.responses, self.calls = responses, []

    def request(self, method, path, headers=None, include_headers=False):
        self.calls.append((method, path, headers, include_headers))
        return self.responses[path]


class FleetRunnerDispatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.patchers = (
            mock.patch.object(MODULE, "DISPATCH_ROOT", root),
            mock.patch.object(MODULE, "STATE_PATH", root / "state.json"),
            mock.patch.object(MODULE, "LOCK_PATH", root / "dispatch.lock"),
        )
        for patcher in self.patchers:
            patcher.start()

    def tearDown(self):
        for patcher in reversed(self.patchers):
            patcher.stop()
        self.temporary.cleanup()

    def test_etag_cache_reuses_prior_inventory_after_not_modified(self):
        path = "/repos/f5-sales-demo/docs/actions/runs?status=queued&per_page=100"
        github = GitHub({path: ({"workflow_runs": []}, {"ETag": '"fixture"'})})
        self.assertEqual(MODULE.get(github, path), {"workflow_runs": []})
        github.responses[path] = (None, {})
        self.assertEqual(MODULE.get(github, path), {"workflow_runs": []})
        self.assertEqual(github.calls[1][2], {"If-None-Match": '"fixture"'})

    def test_cursor_and_cooldowns_persist_across_recovery(self):
        MODULE.save({"cursor": 7, "cooldowns": {"primary": 1200, "secondary": 1300}})
        self.assertEqual(
            MODULE.state(("one", "two", "three")),
            {"cursor": 1, "cooldowns": {"primary": 1200, "secondary": 1300}},
        )
        self.assertEqual(
            json.loads(MODULE.STATE_PATH.read_text(encoding="utf-8"))["cursor"], 7
        )

    def test_cooldown_suppresses_api_traffic(self):
        policy = self.policy(("f5-sales-demo/docs",), 80)
        MODULE.save({"cursor": 0, "cooldowns": {"primary": 1100, "secondary": 1200}})
        controller = mock.Mock()
        with (
            mock.patch.object(MODULE.PROVISION, "require_root"),
            mock.patch.object(MODULE.PROVISION, "active_policy", return_value=policy),
            mock.patch.object(
                MODULE.PROVISION, "load_controller", return_value=controller
            ),
            mock.patch.object(MODULE.time, "time", return_value=1000),
        ):
            self.assertEqual(MODULE.dispatch(), 0)
        controller.assert_not_called()

    def test_request_budget_resumes_from_the_durable_round_robin_cursor(self):
        repositories = ("f5-sales-demo/alpha", "f5-sales-demo/bravo")
        policy = self.policy(repositories, 1)
        github = GitHub(
            {
                f"/repos/{repo}/actions/runs?status=queued&per_page=100": (
                    {"workflow_runs": []},
                    {},
                )
                for repo in repositories
            }
        )
        controller = self.controller(github)
        self.run_dispatch(policy, controller)
        self.assertIn("/alpha/", github.calls[0][1])
        self.assertEqual(MODULE.state(repositories)["cursor"], 1)
        self.run_dispatch(policy, controller)
        self.assertEqual(len(github.calls), 2)
        self.assertIn("/bravo/", github.calls[1][1])

    def test_exact_labels_and_docker_trust_gate_prevent_starts(self):
        socketless = SimpleNamespace(name="socketless", docker_socket=False)
        docker = SimpleNamespace(name="container-build", docker_socket=True)
        unexpected = self.start_attempt(
            socketless, {"socketless"}, ["socketless", "unexpected"], True
        )
        untrusted = self.start_attempt(
            docker, {"container-build"}, ["container-build"], False
        )
        self.assertEqual(unexpected, [])
        self.assertEqual(untrusted, [])

    def test_standby_does_not_start_until_the_primary_is_verified_busy(self):
        profile = SimpleNamespace(name="socketless", docker_socket=False)
        started = self.start_attempt(
            profile, {"socketless"}, ["socketless"], True, True, False
        )

        self.assertEqual(started, [])

    @staticmethod
    def policy(repositories, budget, profile=None):
        profile = profile or SimpleNamespace(name="socketless", docker_socket=False)
        spec = SimpleNamespace(profiles=(profile,))
        return SimpleNamespace(
            dispatcher=SimpleNamespace(
                repositories=repositories, request_budget=budget
            ),
            repository=lambda _repository: spec,
        )

    @staticmethod
    def controller(github, labels=None):
        return SimpleNamespace(
            GitHubClient=lambda _token: github,
            token_from_environment=lambda: "credential",
            EphemeralController=lambda *_args: SimpleNamespace(
                expected_labels=lambda _spec, _profile: labels or {"socketless"}
            ),
            GitHubRateLimitError=RuntimeError,
        )

    def run_dispatch(self, policy, controller):
        with (
            mock.patch.object(MODULE.PROVISION, "require_root"),
            mock.patch.object(MODULE.PROVISION, "active_policy", return_value=policy),
            mock.patch.object(
                MODULE.PROVISION, "load_controller", return_value=controller
            ),
        ):
            self.assertEqual(MODULE.dispatch(), 0)

    def start_attempt(
        self, profile, labels, job_labels, trusted, primary_active=False, busy=True
    ):
        repository = "f5-sales-demo/docs"
        base = f"/repos/{repository}/actions/runs"
        github = GitHub(
            {
                f"{base}?status=queued&per_page=100": (
                    {"workflow_runs": [{"id": 11, "status": "queued"}]},
                    {},
                ),
                f"{base}?status=in_progress&per_page=100": ({"workflow_runs": []}, {}),
                f"{base}/11/jobs?per_page=100": (
                    {"jobs": [{"status": "queued", "labels": job_labels}]},
                    {},
                ),
            }
        )
        started, primary = [], SimpleNamespace(unit="f5-actions-runner@fixture.service")
        standby = SimpleNamespace(unit="f5-actions-runner@fixture-standby.service")

        def command(argv, **_kwargs):
            if argv[:2] == ["systemctl", "start"]:
                started.append(argv)
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with (
            mock.patch.object(MODULE.PROVISION, "require_root"),
            mock.patch.object(
                MODULE.PROVISION,
                "active_policy",
                return_value=self.policy((repository,), 80, profile),
            ),
            mock.patch.object(
                MODULE.PROVISION,
                "load_controller",
                return_value=self.controller(github, labels),
            ),
            mock.patch.object(MODULE, "candidate_for", return_value=(primary, standby)),
            mock.patch.object(
                MODULE,
                "active",
                side_effect=lambda item: primary_active and item is primary,
            ),
            mock.patch.object(MODULE, "primary_busy", return_value=busy),
            mock.patch.object(MODULE.PROVISION, "admission_allows", return_value=True),
            mock.patch.object(
                MODULE.PROVISION, "successful_docker_trust_gate", return_value=trusted
            ),
            mock.patch.object(MODULE.PROVISION, "command", side_effect=command),
        ):
            self.assertEqual(MODULE.dispatch(), 0)
        return started


if __name__ == "__main__":
    unittest.main()
