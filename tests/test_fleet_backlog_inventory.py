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
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.catalog = Path(self.temp.name) / "catalog.json"
        self.catalog.write_text(
            json.dumps({"repositories": {"f5-sales-demo/example": {}}}),
            encoding="utf-8",
        )
        taxonomy = {"lifecycle": "active", "priority": "p2", "area": "product"}
        self.inventory = {
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
                            "disposition": "execute",
                        }
                    ],
                }
            ],
        }

    def tearDown(self):
        self.temp.cleanup()

    def test_valid_inventory(self):
        self.assertEqual(MODULE.validate(self.inventory, self.catalog), [])

    def test_catalog_drift_and_duplicate_are_reported(self):
        self.inventory["repositories"].append(self.inventory["repositories"][0])
        problems = MODULE.validate(self.inventory, self.catalog)
        self.assertTrue(any("catalog drift" in problem for problem in problems))
        self.assertTrue(any("duplicate issue" in problem for problem in problems))

    def test_taxonomy_cardinality_is_exact(self):
        self.inventory["repositories"][0]["issues"][0]["labels"].append(
            "status:blocked"
        )
        problems = MODULE.validate(self.inventory, self.catalog)
        self.assertTrue(any("taxonomy labels" in problem for problem in problems))

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
