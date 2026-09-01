# ruff: noqa: EM101, INP001, PT009, TRY003
"""Tests for the fleet dependency-automation retirement audit."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "audit_dependency_automation", ROOT / "scripts/audit-dependency-automation.py"
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeGitHub:
    def __init__(self):
        self.calls: list[tuple[str, str, object | None]] = []
        self.repositories: dict[str, dict[str, Any]] = {
            "f5-sales-demo/fixture": {
                "default_branch": "main",
                "private": False,
                "pulls": [],
                "branches": [{"name": "main"}],
                "alerts": 404,
                "security": {"enabled": False},
                "files": dict.fromkeys(MODULE.RETIRED_FILES, 404),
            }
        }
        self.defaults: list[object] = []

    def json(self, endpoint):
        if endpoint == "orgs/f5-sales-demo/code-security/configurations/defaults":
            return self.defaults
        prefix, remainder = endpoint.split("/", 2)[0:2], endpoint.split("/", 2)[2]
        self.assert_repo_prefix(prefix)
        repository, _, path = remainder.partition("/")
        state = self.repositories[f"f5-sales-demo/{repository}"]
        if path == "pulls?state=open&per_page=100":
            return state["pulls"]
        if path == "branches?per_page=100":
            return state["branches"]
        if path == "automated-security-fixes":
            return state["security"]
        if path.startswith("contents/"):
            raise AssertionError("contents are checked through status")
        if path:
            raise AssertionError(endpoint)
        return {"default_branch": state["default_branch"], "private": state["private"]}

    @staticmethod
    def assert_repo_prefix(prefix):
        if prefix != ["repos", "f5-sales-demo"]:
            raise AssertionError(prefix)

    def status(self, endpoint):
        _, _, remainder = endpoint.split("/", 2)
        repository, path = remainder.split("/", 1)
        state = self.repositories[f"f5-sales-demo/{repository}"]
        if path == "vulnerability-alerts":
            return state["alerts"]
        if path.startswith("contents/"):
            file_path = path.removeprefix("contents/").split("?", 1)[0]
            return state["files"][file_path]
        raise AssertionError(endpoint)

    def mutate(self, method, endpoint, body=None):
        self.calls.append((method, endpoint, body))


class DependencyAutomationAuditTests(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        self.catalog = ["f5-sales-demo/fixture"]

    def test_clean_fleet_passes(self):
        self.assertEqual(
            MODULE.audit_fleet(self.catalog, self.github, expected_count=1), []
        )

    def test_every_mutable_dependabot_surface_fails_closed(self):
        state = self.github.repositories[self.catalog[0]]
        state["private"] = True
        state["pulls"] = [{"number": 7, "user": {"login": "dependabot[bot]"}}]
        state["branches"] = [{"name": "dependabot/npm/example"}]
        state["alerts"] = 204
        state["security"] = {"enabled": True}
        state["files"][MODULE.RETIRED_FILES[0]] = 200
        self.github.defaults = [{"configuration": {"id": 17}}]
        failures = MODULE.audit_fleet(self.catalog, self.github, expected_count=1)
        receipt = "\n".join(failures)
        for expected in (
            "must remain public",
            "retired file exists",
            "open Dependabot PR #7",
            "Dependabot branch exists",
            "vulnerability alerts are enabled",
            "security updates are enabled",
            "organization code-security defaults are configured",
        ):
            self.assertIn(expected, receipt)

    def test_catalog_rejects_duplicates_foreign_repositories_and_wrong_count(self):
        failures = MODULE.validate_catalog(
            ["f5-sales-demo/fixture", "other/example", "f5-sales-demo/fixture"], 39
        )
        self.assertTrue(any("exactly 39" in item for item in failures))
        self.assertTrue(any("duplicate" in item for item in failures))
        self.assertTrue(any("outside f5-sales-demo" in item for item in failures))

    def test_retirement_orders_pr_closure_before_branch_deletion(self):
        state = self.github.repositories[self.catalog[0]]
        state["alerts"] = 204
        state["security"] = {"enabled": True}
        state["pulls"] = [
            {
                "number": 7,
                "node_id": "PR_node",
                "user": {"login": "dependabot[bot]"},
                "head": {"ref": "dependabot/npm/example"},
                "auto_merge": {"merge_method": "SQUASH"},
            }
        ]
        state["branches"] = [
            {"name": "dependabot/npm/example"},
            {"name": "dependabot/github_actions/orphan"},
        ]
        MODULE.retire_fleet(self.catalog, self.github)
        calls = self.github.calls
        close_index = calls.index(
            ("PATCH", "repos/f5-sales-demo/fixture/pulls/7", {"state": "closed"})
        )
        delete_indices = [
            index
            for index, call in enumerate(calls)
            if call[0] == "DELETE" and "/git/refs/heads/" in call[1]
        ]
        self.assertTrue(
            delete_indices and all(close_index < index for index in delete_indices)
        )
        self.assertIn(
            ("DELETE", "repos/f5-sales-demo/fixture/vulnerability-alerts", None), calls
        )
        self.assertIn(
            ("DELETE", "repos/f5-sales-demo/fixture/automated-security-fixes", None),
            calls,
        )
        self.assertTrue(
            any(
                "superseded by self-hosted renovate" in str(call[2]).lower()
                for call in calls
            )
        )


if __name__ == "__main__":
    unittest.main()
