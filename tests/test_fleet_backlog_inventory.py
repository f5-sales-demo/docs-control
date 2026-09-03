#!/usr/bin/env python3
# ruff: noqa: EXE001, PT009, PT018, PT027
"""Unit tests for schema-v2 governed fleet inventory."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "fleet_backlog_inventory", ROOT / "scripts/fleet_backlog_inventory.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
APPLY_SPEC = importlib.util.spec_from_file_location(
    "apply_fleet_backlog_taxonomy",
    ROOT / "scripts/apply_fleet_backlog_taxonomy.py",
)
assert APPLY_SPEC and APPLY_SPEC.loader
APPLY_MODULE = importlib.util.module_from_spec(APPLY_SPEC)
APPLY_SPEC.loader.exec_module(APPLY_MODULE)


class InventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp: tempfile.TemporaryDirectory[str] = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.catalog = Path(self.temp.name) / "catalog.json"
        self.catalog.write_text(
            json.dumps({"repositories": {"f5-sales-demo/example": {}}}),
            encoding="utf-8",
        )
        taxonomy = {"lifecycle": "active", "priority": "p2", "area": "product"}
        self.inventory: dict[str, Any] = {
            "schema_version": 2,
            "summary": {"open_issues": 1, "open_pull_requests": 1},
            "repositories": [
                {
                    "name": "f5-sales-demo/example",
                    "url": "https://github.com/f5-sales-demo/example",
                    "default_branch": "main",
                    "updated_at": "2026-09-01T00:00:00Z",
                    "issues": [
                        {
                            "number": 1,
                            "node_id": "ISSUE_1",
                            "title": "Product issue",
                            "url": "https://github.com/f5-sales-demo/example/issues/1",
                            "created_at": "2026-08-01T00:00:00Z",
                            "updated_at": "2026-09-01T00:00:00Z",
                            "labels": ["status:active", "p2", "area:product"],
                            "taxonomy": taxonomy,
                            "workstream": "f5-sales-demo/docs-control#1961",
                            "parent": "f5-sales-demo/docs-control#1961",
                            "dependencies": [],
                            "evidence": [
                                "https://github.com/f5-sales-demo/example/issues/1"
                            ],
                            "execution_wave": 4,
                            "gate": None,
                            "disposition": "execute",
                        }
                    ],
                    "pull_requests": [
                        {
                            "number": 2,
                            "node_id": "PR_2",
                            "title": "Product PR",
                            "url": "https://github.com/f5-sales-demo/example/pull/2",
                            "created_at": "2026-08-01T00:00:00Z",
                            "updated_at": "2026-09-01T00:00:00Z",
                            "labels": ["status:active", "p2", "area:product"],
                            "taxonomy": taxonomy,
                            "workstream": "f5-sales-demo/docs-control#1961",
                            "head_ref": "fix/1",
                            "head_sha": "a" * 40,
                            "head_repository": "f5-sales-demo/example",
                            "base_ref": "main",
                            "draft": False,
                            "mergeable_state": "clean",
                            "changed_paths": ["README.md"],
                            "checks": [],
                            "dependencies": [],
                            "evidence": [
                                "https://github.com/f5-sales-demo/example/pull/2"
                            ],
                            "execution_wave": 4,
                            "gate": None,
                            "disposition": "execute",
                        }
                    ],
                }
            ],
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_valid_inventory(self):
        self.assertEqual(MODULE.validate(self.inventory, self.catalog), [])

    def test_catalog_drift_and_duplicate_are_reported(self):
        self.inventory["repositories"].append(self.inventory["repositories"][0])
        problems = MODULE.validate(self.inventory, self.catalog)
        self.assertTrue(any("catalog drift" in problem for problem in problems))
        self.assertTrue(any("duplicate issue" in problem for problem in problems))

    def test_title_purpose_precedes_incidental_body_terms(self):
        taxonomy = MODULE.infer_taxonomy(
            "origin-server",
            "ci: use immutable Node toolchain",
            "Verification found 0 vulnerabilities.",
            [],
        )
        self.assertEqual(
            taxonomy,
            {"area": "dependencies", "lifecycle": "active", "priority": "p1"},
        )

    def test_dependency_update_title_precedes_release_policy_body(self):
        taxonomy = MODULE.infer_taxonomy(
            "starlight-mega-menu",
            "chore(deps): update npm-minor-patch",
            "Translation changes are deferred until a major release.",
            [],
        )
        self.assertEqual(
            taxonomy,
            {"area": "dependencies", "lifecycle": "active", "priority": "p1"},
        )

    def test_api_contract_title_precedes_documentation_scope(self):
        taxonomy = MODULE.infer_taxonomy(
            "mcn",
            "fix(terraform): pin the published provider and API contract",
            "Update all governed English and locale technical literals.",
            [],
        )
        self.assertEqual(
            taxonomy,
            {"area": "api-contracts", "lifecycle": "active", "priority": "p1"},
        )

    def test_program_policy_overrides_incidental_lint_wording(self):
        inferred = MODULE.infer_taxonomy(
            "xcsh",
            "feat(model): browse models by authenticated provider",
            "Run lint and type checks after implementing provider tabs.",
            [],
        )
        policy = MODULE.execution_policy("xcsh", 3611, inferred, pull=False)
        self.assertEqual(
            policy["taxonomy"],
            {"area": "product", "lifecycle": "active", "priority": "p1"},
        )
        self.assertEqual(policy["execution_wave"], 4)

    def test_stale_dependency_pull_is_superseded_in_wave_two(self):
        policy = MODULE.execution_policy(
            "docs-theme",
            1424,
            {"area": "dependencies", "lifecycle": "deferred", "priority": "p3"},
            pull=True,
        )
        self.assertEqual(policy["taxonomy"]["lifecycle"], "superseded")
        self.assertEqual(policy["disposition"], "supersede-and-rebuild")
        self.assertEqual(policy["execution_wave"], 2)

    def test_provider_compute_benchmark_is_deferred_to_next_month(self):
        issue = MODULE.execution_policy(
            "terraform-provider-xcsh",
            1885,
            {"area": "api-contracts", "lifecycle": "active", "priority": "p1"},
            pull=False,
        )
        pull = MODULE.execution_policy(
            "terraform-provider-xcsh",
            1895,
            {"area": "api-contracts", "lifecycle": "active", "priority": "p1"},
            pull=True,
        )
        for policy in (issue, pull):
            self.assertEqual(policy["taxonomy"]["lifecycle"], "deferred")
            self.assertEqual(policy["disposition"], "deferred-next-month-benchmark")
            self.assertIn("next monthly benchmark window", policy["gate"])
        self.assertNotIn(
            1895, MODULE.CONTINUE_PRS.get("terraform-provider-xcsh", set())
        )

    def test_i18n_release_identity_waits_for_its_external_readiness_gate(self):
        policy = MODULE.execution_policy(
            "i18n-core",
            488,
            {"area": "developer-tooling", "lifecycle": "active", "priority": "p2"},
            pull=True,
        )
        self.assertEqual(policy["taxonomy"]["lifecycle"], "deferred")
        self.assertEqual(
            policy["disposition"], "deferred-external-release-app-readiness"
        )
        self.assertIn("f5-sales-demo-release App", policy["gate"])

    def test_archived_repository_policy_records_owner_decommission(self):
        policy = MODULE.archived_execution_policy()
        self.assertEqual(
            policy["taxonomy"],
            {
                "area": "developer-tooling",
                "lifecycle": "blocked",
                "priority": "p3",
            },
        )
        self.assertEqual(policy["disposition"], "archived-decommission")
        self.assertIn("organization owner", policy["gate"])

    def test_archived_repository_allows_historical_read_only_labels(self):
        self.inventory["repositories"][0]["archived"] = True
        issue = self.inventory["repositories"][0]["issues"][0]
        issue["taxonomy"] = {
            "area": "developer-tooling",
            "lifecycle": "blocked",
            "priority": "p3",
        }
        issue["execution_wave"] = 5
        issue["gate"] = (
            "repository archived by organization owner during decommission; "
            "unarchive required to resume"
        )
        issue["disposition"] = "archived-decommission"
        issue["parent"] = None
        self.assertEqual(MODULE.validate(self.inventory, self.catalog), [])

    def test_execution_wave_and_gate_are_required(self):
        del self.inventory["repositories"][0]["issues"][0]["execution_wave"]
        problems = MODULE.validate(self.inventory, self.catalog)
        self.assertTrue(any("execution wave" in problem for problem in problems))

    def test_taxonomy_cardinality_is_exact(self):
        self.inventory["repositories"][0]["issues"][0]["labels"].append(
            "status:blocked"
        )
        problems = MODULE.validate(self.inventory, self.catalog)
        self.assertTrue(any("taxonomy labels" in problem for problem in problems))

    def test_pre_mutation_inventory_preserves_unapplied_taxonomy(self):
        self.inventory["phase"] = "pre-mutation"
        self.inventory["repositories"][0]["issues"][0]["labels"] = []
        self.inventory["repositories"][0]["issues"][0]["parent"] = None
        self.assertEqual(MODULE.validate(self.inventory, self.catalog), [])

    def test_missing_native_relationship_is_reported(self):
        self.inventory["repositories"][0]["issues"][0]["parent"] = None
        problems = MODULE.validate(self.inventory, self.catalog)
        self.assertTrue(any("native sub-issue" in problem for problem in problems))

    def test_live_comparison_detects_timestamp_and_sha_updates(self):
        live = json.loads(json.dumps(self.inventory))
        live["repositories"][0]["issues"][0]["updated_at"] = "2026-09-02T00:00:00Z"
        live["repositories"][0]["pull_requests"][0]["head_sha"] = "b" * 40
        problems = MODULE.compare(self.inventory, live)
        self.assertTrue(any("updated_at" in problem for problem in problems))
        self.assertTrue(any("head_sha" in problem for problem in problems))

    def test_malformed_paginated_response_fails_closed(self):
        def runner(*_args, **_kwargs):
            return subprocess.CompletedProcess(
                [], 0, stdout=json.dumps({"items": []}), stderr=""
            )

        with self.assertRaisesRegex(MODULE.InventoryError, "pagination was malformed"):
            MODULE.GitHub(runner=runner).get("repos/x/y/issues", paginate=True)

    def test_github_client_pins_current_api_version_for_sub_issues(self):
        calls: list[list[str]] = []

        def runner(command, **_kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="{}", stderr="")

        MODULE.GitHub(runner=runner).get("repos/x/y/issues/1/parent", missing_ok=True)
        self.assertIn("Accept: application/vnd.github+json", calls[0])
        self.assertIn("X-GitHub-Api-Version: 2026-03-10", calls[0])

    def test_taxonomy_apply_dry_run_is_non_mutating(self):
        class Writer:
            def __init__(self):
                self.calls = []

            def call(self, command, payload=None):
                self.calls.append((command, payload))
                if "labels?" in command[-1]:
                    return [[]]
                return {"node_id": "PARENT"}

        for item in (
            self.inventory["repositories"][0]["issues"]
            + self.inventory["repositories"][0]["pull_requests"]
        ):
            item["labels"] = []
        for item in self.inventory["repositories"][0]["issues"]:
            item["parent"] = None
        writer = Writer()
        counts = APPLY_MODULE.apply(self.inventory, writer, dry_run=True)
        self.assertEqual(counts["labels_created"], 3)
        self.assertEqual(counts["items_labeled"], 2)
        self.assertEqual(counts["relationships_added"], 1)
        self.assertFalse(any(payload for _, payload in writer.calls))

    def test_preflight_rejects_concurrent_updates(self):
        class Writer:
            def call(self, _command, payload=None):
                del payload
                return {
                    "state": "open",
                    "updated_at": "changed",
                    "head": {"sha": "a" * 40},
                }

        with self.assertRaisesRegex(MODULE.InventoryError, "concurrent update"):
            APPLY_MODULE.preflight(self.inventory, Writer())


if __name__ == "__main__":
    unittest.main()
