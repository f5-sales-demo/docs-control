#!/usr/bin/env python3
# pylint: disable=consider-using-with
"""Tests for workflow runner routing and immutable action pins."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "audit_runner_workflows", ROOT / "scripts/audit-runner-workflows.py"
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class WorkflowAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / ".github/workflows").mkdir(parents=True)
        self.policy = self.root / "policy.json"
        self.data = {
            "schema_version": 2,
            "defaults": {"replicas": 1, "profile": "ubuntu-24.04"},
            "profiles": {
                "ubuntu-24.04": {
                    "image": "example@sha256:" + "a" * 64,
                    "labels": ["ubuntu-24.04"],
                    "memory": "4g",
                    "cpus": "2",
                    "pids_limit": 512,
                    "container_socket": False,
                },
                "container-build": {
                    "image": "example@sha256:" + "b" * 64,
                    "labels": ["container-build"],
                    "memory": "8g",
                    "cpus": "4",
                    "pids_limit": 1024,
                    "container_socket": True,
                },
            },
            "hosted_exceptions": {},
            "repositories": {"f5-sales-demo/fixture": {}},
        }
        self.write_policy()

    def tearDown(self):
        self.temp.cleanup()

    def write_policy(self):
        self.policy.write_text(json.dumps(self.data), encoding="utf-8")

    def write_workflow(self, text):
        (self.root / ".github/workflows/ci.yml").write_text(text, encoding="utf-8")

    def audit(self):
        return MODULE.audit_repository(self.root, "f5-sales-demo/fixture", self.policy)

    def test_canonical_route_and_sha_pin_pass(self):
        self.write_workflow(
            """name: CI
on: [push]
jobs:
  test:
    runs-on: [self-hosted, Linux, X64, \"${{ github.event.repository.name }}\", ubuntu-24.04]
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      - uses: ./local-action
      - uses: docker://alpine:3.22
"""
        )
        self.assertEqual(self.audit(), [])

    def test_mutable_action_and_hosted_label_fail(self):
        self.write_workflow(
            """name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
"""
        )
        errors = self.audit()
        self.assertTrue(any("canonical repository route" in item for item in errors))
        self.assertTrue(any("not commit-pinned" in item for item in errors))

    def test_exact_hosted_exception_passes(self):
        self.data["hosted_exceptions"] = {
            "f5-sales-demo/fixture": {
                ".github/workflows/ci.yml": {
                    "native": {
                        "runs_on": "macos-14",
                        "reason": "native Apple signing test",
                    }
                }
            }
        }
        self.write_policy()
        self.write_workflow(
            """name: CI
on: [push]
jobs:
  native:
    runs-on: macos-14
    steps:
      - run: uname -a
"""
        )
        self.assertEqual(self.audit(), [])

    def test_unused_exception_fails(self):
        self.data["hosted_exceptions"] = {
            "f5-sales-demo/fixture": {
                ".github/workflows/ci.yml": {
                    "missing": {
                        "runs_on": "macos-14",
                        "reason": "native Apple signing test",
                    }
                }
            }
        }
        self.write_policy()
        self.write_workflow(
            """name: CI
on: [push]
jobs:
  test:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - run: true
"""
        )
        errors = self.audit()
        self.assertTrue(any("unused hosted exception" in item for item in errors))

    def test_missing_profile_label_fails(self):
        self.write_workflow(
            """name: CI
on: [push]
jobs:
  test:
    runs-on: [self-hosted, Linux, X64, fixture]
    steps:
      - run: true
"""
        )
        errors = self.audit()
        self.assertTrue(any("canonical repository route" in item for item in errors))

    def test_profile_label_is_validated(self):
        self.write_workflow(
            """name: CI
on: [push]
jobs:
  test:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - run: true
"""
        )
        self.assertEqual(self.audit(), [])

    def test_super_linter_requires_container_build_profile(self):
        self.write_workflow(
            """name: Lint
on: [push]
jobs:
  lint:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - uses: super-linter/super-linter@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"""
        )
        errors = self.audit()
        self.assertTrue(
            any("requires a container socket profile" in item for item in errors)
        )

        self.write_workflow(
            """name: Lint
on: [push]
jobs:
  lint:
    runs-on: [self-hosted, Linux, X64, fixture, container-build]
    steps:
      - uses: super-linter/super-linter@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"""
        )
        self.assertEqual(self.audit(), [])


if __name__ == "__main__":
    unittest.main()
