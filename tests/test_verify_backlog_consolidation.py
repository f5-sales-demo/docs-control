#!/usr/bin/env python3
# ruff: noqa: PT009, PT027
"""Unit tests for the read-only backlog-consolidation verifier."""

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "verify_backlog_consolidation",
    ROOT / "scripts/verify_backlog_consolidation.py",
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def base_policy():
    return {
        "schema_version": 1,
        "source_repository": "example/source",
        "expected_open_issues": [1],
        "issues": {
            "1": {
                "state": "open",
                "title": "Active work",
                "status": "status:active",
                "area": "area:governance",
            },
            "2": {
                "state": "closed",
                "state_reason": "completed",
                "title": "Finished work",
                "status": "status:resolved",
                "area": "area:security",
            },
        },
        "relationships": {"1": [2]},
        "transfers": [
            {
                "source_number": 3,
                "repository": "example/target",
                "number": 9,
                "state": "open",
                "status": "status:active",
                "area": "area:docs-publishing",
                "labels": ["bug"],
            }
        ],
        "pull_requests": [
            {
                "number": 7,
                "state": "closed",
                "head_ref": "fix/old-work",
                "head_sha": "a" * 40,
                "body_forbidden_patterns": [r"(?i)\bcloses\s+#2\b"],
                "head_branch": "absent",
            }
        ],
    }


def base_snapshot():
    return {
        "repositories": {
            "example/source": {
                "open_issues": [1],
                "issues": {
                    "1": {
                        "state": "open",
                        "state_reason": None,
                        "title": "Active work",
                        "labels": ["enhancement", "status:active", "area:governance"],
                        "parent": None,
                        "children": [2],
                    },
                    "2": {
                        "state": "closed",
                        "state_reason": "completed",
                        "title": "Finished work",
                        "labels": ["bug", "status:resolved", "area:security"],
                        "parent": 1,
                        "children": [],
                    },
                },
                "pull_requests": {
                    "7": {
                        "state": "closed",
                        "head_ref": "fix/old-work",
                        "head_sha": "a" * 40,
                        "body": "Historical reference: #2 (does not close).",
                    }
                },
                "branches": ["main"],
            },
            "example/target": {
                "open_issues": [9],
                "issues": {
                    "9": {
                        "state": "open",
                        "state_reason": None,
                        "title": "Transferred work",
                        "labels": ["bug", "status:active", "area:docs-publishing"],
                        "parent": None,
                        "children": [],
                    }
                },
                "pull_requests": {},
                "branches": ["main"],
            },
        }
    }


class AuditSnapshotTests(unittest.TestCase):
    def assert_problem(self, problems, fragment):
        self.assertTrue(
            any(fragment in problem for problem in problems),
            f"missing {fragment!r} in {problems!r}",
        )

    def test_valid_snapshot_passes(self):
        self.assertEqual(MODULE.audit_snapshot(base_policy(), base_snapshot()), [])

    def test_open_issue_set_drift_is_actionable(self):
        snapshot = base_snapshot()
        snapshot["repositories"]["example/source"]["open_issues"] = [2, 4]

        problems = MODULE.audit_snapshot(base_policy(), snapshot)

        self.assert_problem(problems, "missing open issues: #1")
        self.assert_problem(problems, "unexpected open issues: #2, #4")

    def test_taxonomy_requires_exactly_one_status_and_area(self):
        snapshot = base_snapshot()
        labels = snapshot["repositories"]["example/source"]["issues"]["1"]["labels"]
        labels.extend(["status:tracking", "area:security"])

        problems = MODULE.audit_snapshot(base_policy(), snapshot)

        self.assert_problem(problems, "#1 has 2 status labels")
        self.assert_problem(problems, "#1 has 2 area labels")

    def test_issue_state_reason_title_and_expected_labels_are_checked(self):
        snapshot = base_snapshot()
        issue = snapshot["repositories"]["example/source"]["issues"]["2"]
        issue.update(state="open", state_reason=None, title="Drifted title")
        issue["labels"] = ["bug", "status:superseded", "area:linting"]

        problems = MODULE.audit_snapshot(base_policy(), snapshot)

        for fragment in (
            "#2 state is open, expected closed",
            "#2 state reason is null, expected completed",
            "#2 title is 'Drifted title', expected 'Finished work'",
            "#2 status is status:superseded, expected status:resolved",
            "#2 area is area:linting, expected area:security",
        ):
            self.assert_problem(problems, fragment)

    def test_relationship_drift_checks_both_directions(self):
        snapshot = base_snapshot()
        source = snapshot["repositories"]["example/source"]["issues"]
        source["1"]["children"] = []
        source["2"]["parent"] = None

        problems = MODULE.audit_snapshot(base_policy(), snapshot)

        self.assert_problem(problems, "#1 children are [], expected [2]")
        self.assert_problem(problems, "#2 parent is null, expected #1")

    def test_unexpected_child_relationship_is_rejected(self):
        snapshot = base_snapshot()
        snapshot["repositories"]["example/source"]["issues"]["2"]["children"] = [99]

        problems = MODULE.audit_snapshot(base_policy(), snapshot)

        self.assert_problem(problems, "#2 children are [99], expected []")

    def test_transferred_issue_state_and_labels_are_checked(self):
        snapshot = base_snapshot()
        issue = snapshot["repositories"]["example/target"]["issues"]["9"]
        issue["state"] = "closed"
        issue["labels"] = ["status:deferred", "area:i18n"]

        problems = MODULE.audit_snapshot(base_policy(), snapshot)

        self.assert_problem(problems, "transferred source #3 -> example/target#9 state")
        self.assert_problem(problems, "expected label bug")
        self.assert_problem(
            problems, "status is status:deferred, expected status:active"
        )
        self.assert_problem(
            problems, "area is area:i18n, expected area:docs-publishing"
        )

    def test_pull_request_and_forbidden_branch_drift_are_checked(self):
        snapshot = base_snapshot()
        source = snapshot["repositories"]["example/source"]
        pull = source["pull_requests"]["7"]
        pull.update(
            state="open",
            head_ref="fix/wrong",
            head_sha="b" * 40,
            body="Closes #2",
        )
        source["branches"].append("fix/old-work")

        problems = MODULE.audit_snapshot(base_policy(), snapshot)

        for fragment in (
            "PR #7 state is open, expected closed",
            "PR #7 head ref is fix/wrong, expected fix/old-work",
            "PR #7 head SHA is",
            "PR #7 body matches forbidden pattern",
            "branch fix/old-work is present, expected absent",
        ):
            self.assert_problem(problems, fragment)

    def test_missing_repository_data_fails_closed(self):
        problems = MODULE.audit_snapshot(base_policy(), {"repositories": {}})
        self.assert_problem(problems, "repository example/source is unavailable")
        self.assert_problem(problems, "repository example/target is unavailable")

    def test_malformed_policy_is_rejected(self):
        policy = base_policy()
        policy["issues"]["1"]["status"] = "active"
        with self.assertRaisesRegex(MODULE.AuditInputError, "status: prefix"):
            MODULE.audit_snapshot(policy, base_snapshot())

    def test_nonnumeric_relationship_key_is_rejected(self):
        policy = base_policy()
        policy["relationships"] = {"invalid": [2]}

        with self.assertRaisesRegex(
            MODULE.AuditInputError, "relationships key 'invalid'"
        ):
            MODULE.audit_snapshot(policy, base_snapshot())

    def test_nonnumeric_snapshot_issue_key_is_rejected(self):
        snapshot = base_snapshot()
        snapshot["repositories"]["example/source"]["issues"]["invalid"] = {}

        with self.assertRaisesRegex(
            MODULE.AuditInputError, "snapshot issue key 'invalid'"
        ):
            MODULE.audit_snapshot(base_policy(), snapshot)

    def test_load_json_rejects_malformed_input(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "broken.json"
            path.write_text("{", encoding="utf-8")
            with self.assertRaisesRegex(MODULE.AuditInputError, "invalid JSON"):
                MODULE.load_json(path)


class GitHubClientTests(unittest.TestCase):
    def test_api_failure_is_not_treated_as_empty_data(self):
        def runner(*_args, **_kwargs):
            return subprocess.CompletedProcess([], 1, stdout="", stderr="denied")

        client = MODULE.GitHubClient(runner=runner)
        with self.assertRaisesRegex(MODULE.AuditInputError, "gh api failed.*denied"):
            client.get("repos/example/source/issues/1")

    def test_paginated_arrays_are_flattened(self):
        def runner(*_args, **_kwargs):
            return subprocess.CompletedProcess(
                [], 0, stdout=json.dumps([[{"number": 1}], [{"number": 2}]]), stderr=""
            )

        client = MODULE.GitHubClient(runner=runner)
        self.assertEqual(
            client.get("repos/example/source/issues", paginate=True),
            [{"number": 1}, {"number": 2}],
        )


class OfflineCliTests(unittest.TestCase):
    def test_valid_snapshot_cli_succeeds(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            policy_path = root / "policy.json"
            snapshot_path = root / "snapshot.json"
            policy_path.write_text(json.dumps(base_policy()), encoding="utf-8")
            snapshot_path.write_text(json.dumps(base_snapshot()), encoding="utf-8")
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                result = MODULE.main(
                    ["--policy", str(policy_path), "--snapshot", str(snapshot_path)]
                )

            self.assertEqual(result, 0)
            self.assertIn("Backlog consolidation verified", output.getvalue())


if __name__ == "__main__":
    unittest.main()
