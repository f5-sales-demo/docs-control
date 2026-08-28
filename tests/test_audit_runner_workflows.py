#!/usr/bin/env python3
# pylint: disable=consider-using-with,too-many-lines
"""Tests for workflow runner routing and immutable action pins."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "audit_runner_workflows", ROOT / "scripts/audit-runner-workflows.py"
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


# pylint: disable-next=too-many-public-methods
class WorkflowAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / ".github/workflows").mkdir(parents=True)
        self.policy = self.root / "policy.json"
        self.data: dict[str, Any] = {
            "schema_version": 4,
            "docker": {
                "socket": "/run/docker.sock",
                "minimum_version": "29.2.1",
                "target_version": "29.7.2",
            },
            "defaults": {"replicas": 1, "profile": "ubuntu-24.04"},
            "profiles": {
                "ubuntu-24.04": {
                    "image": "example@sha256:" + "a" * 64,
                    "labels": ["ubuntu-24.04"],
                    "memory": "4g",
                    "cpus": "2",
                    "pids_limit": 512,
                    "stop_timeout": 300,
                    "network": "bridge",
                    "docker_socket": False,
                },
                "container-build": {
                    "image": "example@sha256:" + "b" * 64,
                    "labels": ["container-build"],
                    "memory": "8g",
                    "cpus": "4",
                    "pids_limit": 1024,
                    "stop_timeout": 300,
                    "network": "bridge",
                    "docker_socket": True,
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

    def audit(self, repository="f5-sales-demo/fixture"):
        return MODULE.audit_repository(self.root, repository, self.policy)

    def use_xcsh_arc_routes(self):
        self.data["repositories"] = {
            "f5-sales-demo/xcsh": {
                "runner": {
                    "arc_scale_sets": {
                        "socketless": {
                            "label": "xcsh-socketless",
                            "profile": "ubuntu-24.04",
                        },
                        "container-build": {
                            "label": "xcsh-container-build",
                            "profile": "container-build",
                        },
                    }
                }
            }
        }
        self.write_policy()

    def test_arc_routes_accept_only_scalar_contract_labels(self):
        self.use_xcsh_arc_routes()
        for label in ("xcsh-socketless", "xcsh-container-build"):
            self.write_workflow(
                f"""name: ARC
on: [workflow_dispatch]
jobs:
  test:
    runs-on: {label}
    steps:
      - run: true
"""
            )
            with self.subTest(label=label):
                self.assertEqual(self.audit("f5-sales-demo/xcsh"), [])

        for route in (
            "xcsh-unknown",
            ["self-hosted", "Linux", "X64", "xcsh", "ubuntu-24.04"],
            ["self-hosted", "Linux", "X64", "xcsh", "container-build"],
        ):
            workflow = {
                "name": "ARC",
                "on": ["workflow_dispatch"],
                "jobs": {"test": {"runs-on": route, "steps": [{"run": True}]}},
            }
            self.write_workflow(yaml.safe_dump(workflow, sort_keys=False))
            with self.subTest(route=route):
                errors = self.audit("f5-sales-demo/xcsh")
                self.assertTrue(
                    any("canonical repository route" in item for item in errors)
                )

    def test_arc_reusable_call_requires_exact_approved_label_pair(self):
        self.use_xcsh_arc_routes()
        workflow: dict[str, Any] = {
            "name": "Reusable",
            "on": ["workflow_dispatch"],
            "jobs": {
                "lint": {
                    "uses": (
                        "f5-sales-demo/docs-control/.github/workflows/"
                        "super-linter.yml@" + "a" * 40
                    ),
                    "with": {
                        "socketless_runner_label": "xcsh-socketless",
                        "container_build_runner_label": "xcsh-container-build",
                    },
                }
            },
        }
        self.write_workflow(yaml.safe_dump(workflow, sort_keys=False))
        self.assertEqual(self.audit("f5-sales-demo/xcsh"), [])

        mutations = (
            {"socketless_runner_label": "xcsh-socketless"},
            {
                "socketless_runner_label": "xcsh-container-build",
                "container_build_runner_label": "xcsh-socketless",
            },
            {
                "socketless_runner_label": "xcsh-unknown",
                "container_build_runner_label": "xcsh-container-build",
            },
            {
                "socketless_runner_label": "${{ matrix.runner }}",
                "container_build_runner_label": "xcsh-container-build",
            },
        )
        for inputs in mutations:
            workflow["jobs"]["lint"]["with"] = inputs
            self.write_workflow(yaml.safe_dump(workflow, sort_keys=False))
            with self.subTest(inputs=inputs):
                self.assertTrue(self.audit("f5-sales-demo/xcsh"))

        workflow["jobs"]["lint"].pop("with")
        self.write_workflow(yaml.safe_dump(workflow, sort_keys=False))
        self.assertTrue(self.audit("f5-sales-demo/xcsh"))

    def test_legacy_reusable_call_keeps_canonical_fallback(self):
        self.write_workflow(
            """name: Reusable
on: [workflow_dispatch]
jobs:
  pages:
    uses: f5-sales-demo/docs-control/.github/workflows/github-pages-deploy.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    with:
      content-ref: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"""
        )
        self.assertEqual(self.audit(), [])

        path = self.root / ".github/workflows/ci.yml"
        workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
        workflow["jobs"]["pages"]["with"].update(
            {
                "socketless_runner_label": "xcsh-socketless",
                "container_build_runner_label": "xcsh-container-build",
            }
        )
        path.write_text(yaml.safe_dump(workflow, sort_keys=False), encoding="utf-8")
        self.assertTrue(self.audit())

    def test_reusable_definitions_use_declared_routes(self):
        expectations = {
            ".github/workflows/github-pages-deploy.yml": (
                "",
                "",
                {
                    "trust-gate": MODULE.SOCKETLESS_ROUTE_EXPRESSION,
                    "build": MODULE.CONTAINER_ROUTE_EXPRESSION,
                    "deploy": MODULE.SOCKETLESS_ROUTE_EXPRESSION,
                },
            ),
            ".github/workflows/super-linter.yml": (
                "managed-socketless",
                "managed-container-build",
                {
                    "trust-gate": MODULE.ARC_SOCKET_EXPR,
                    "lint": MODULE.BUILD_EXPR,
                    "shell-unit-tests": MODULE.ARC_SOCKET_EXPR,
                },
            ),
        }
        for relative, (
            socketless_default,
            container_default,
            jobs,
        ) in expectations.items():
            workflow = yaml.safe_load((ROOT / relative).read_text(encoding="utf-8"))
            inputs = workflow.get("on", workflow.get(True))["workflow_call"]["inputs"]
            self.assertEqual(
                socketless_default, inputs["socketless_runner_label"]["default"]
            )
            self.assertEqual(
                container_default, inputs["container_build_runner_label"]["default"]
            )
            for job_id, expected in jobs.items():
                self.assertEqual(expected, workflow["jobs"][job_id]["runs-on"])
        pages = (ROOT / ".github/workflows/github-pages-deploy.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("docker run --rm --pull=never", pages)
        self.assertNotIn("docker run --rm --pull always", pages)

    def test_reusable_definition_routes_are_exact(self):
        self.assertEqual(
            MODULE.reusable_definition_profile(
                "f5-sales-demo/docs-control",
                ".github/workflows/super-linter.yml",
                "lint",
                MODULE.BUILD_EXPR,
            ),
            "container-build",
        )
        self.assertIsNone(
            MODULE.reusable_definition_profile(
                "f5-sales-demo/docs-control",
                ".github/workflows/super-linter.yml",
                "lint",
                MODULE.CONTAINER_ROUTE_EXPRESSION,
            )
        )

    def test_arc_docker_route_requires_container_pool_and_socketless_trust_gate(self):
        self.use_xcsh_arc_routes()
        self.write_workflow(
            """name: ARC Docker
on:
  pull_request:
jobs:
  trust-gate:
    runs-on: xcsh-socketless
    steps:
      - run: true
  build:
    needs: trust-gate
    if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
    runs-on: xcsh-container-build
    steps:
      - run: docker version
"""
        )
        self.assertEqual(self.audit("f5-sales-demo/xcsh"), [])

        workflow_path = self.root / ".github/workflows/ci.yml"
        workflow = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
        workflow["jobs"]["build"]["runs-on"] = "xcsh-socketless"
        workflow_path.write_text(
            yaml.safe_dump(workflow, sort_keys=False), encoding="utf-8"
        )
        errors = self.audit("f5-sales-demo/xcsh")
        self.assertTrue(
            any("requires a Docker socket profile" in item for item in errors)
        )

        workflow["jobs"]["build"]["runs-on"] = "xcsh-container-build"
        workflow["jobs"]["trust-gate"]["runs-on"] = "xcsh-container-build"
        workflow_path.write_text(
            yaml.safe_dump(workflow, sort_keys=False), encoding="utf-8"
        )
        errors = self.audit("f5-sales-demo/xcsh")
        self.assertTrue(any("socketless trust-gate job" in item for item in errors))

    def test_arc_tag_only_docker_route_accepts_transitive_trust_gate(self):
        self.use_xcsh_arc_routes()
        self.write_workflow(
            """name: ARC release
on: [push, pull_request, workflow_dispatch]
jobs:
  trust-gate:
    runs-on: xcsh-socketless
    steps:
      - run: true
  container-test:
    if: github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && (github.ref == format('refs/heads/{0}', github.event.repository.default_branch) || startsWith(github.ref, 'refs/tags/v'))) || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository)
    needs: trust-gate
    runs-on: xcsh-container-build
    steps:
      - run: true
  publish:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: [container-test]
    runs-on: xcsh-container-build
    steps:
      - run: docker version
"""
        )
        self.assertEqual(self.audit("f5-sales-demo/xcsh"), [])
        workflow_path = self.root / ".github/workflows/ci.yml"
        workflow = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))

        workflow["jobs"]["container-test"]["needs"] = []
        workflow_path.write_text(
            yaml.safe_dump(workflow, sort_keys=False), encoding="utf-8"
        )
        errors = self.audit("f5-sales-demo/xcsh")
        self.assertTrue(any("socketless trust-gate" in item for item in errors))

        workflow["jobs"]["container-test"]["needs"] = "trust-gate"
        workflow["jobs"]["trust-gate"]["needs"] = "publish"
        workflow_path.write_text(
            yaml.safe_dump(workflow, sort_keys=False), encoding="utf-8"
        )
        errors = self.audit("f5-sales-demo/xcsh")
        self.assertTrue(
            any("dependency graph must be acyclic" in item for item in errors)
        )

    def test_arc_policy_rejects_malformed_and_duplicate_routes(self):
        self.use_xcsh_arc_routes()
        base = self.data["repositories"]["f5-sales-demo/xcsh"]["runner"]
        mutations = []

        combined = json.loads(json.dumps(base))
        combined["profiles"] = ["ubuntu-24.04", "container-build"]
        mutations.append(combined)

        duplicate = json.loads(json.dumps(base))
        duplicate["arc_scale_sets"]["container-build"]["label"] = "xcsh-socketless"
        mutations.append(duplicate)

        unknown = json.loads(json.dumps(base))
        unknown["arc_scale_sets"]["socketless"]["profile"] = "missing"
        mutations.append(unknown)

        malformed = json.loads(json.dumps(base))
        malformed["arc_scale_sets"]["socketless"]["extra"] = True
        mutations.append(malformed)

        for runner in mutations:
            policy = {
                "profiles": self.data["profiles"],
                "repositories": {"f5-sales-demo/xcsh": {"runner": runner}},
            }
            with self.subTest(runner=runner), self.assertRaises(MODULE.AuditError):
                MODULE.repository_routes(policy, "f5-sales-demo/xcsh")

    def test_managed_shared_labels_are_exact_and_cohort_bound(self):
        managed = {
            "arc_scale_sets": {
                "socketless": {
                    "label": "managed-socketless",
                    "profile": "ubuntu-24.04",
                },
                "container-build": {
                    "label": "managed-container-build",
                    "profile": "container-build",
                },
            }
        }
        policy = {
            "profiles": self.data["profiles"],
            "repositories": {"f5-sales-demo/administration": {"runner": managed}},
        }
        routes = MODULE.repository_routes(policy, "f5-sales-demo/administration")
        self.assertEqual(
            "ubuntu-24.04", routes["profiles_by_label"]["managed-socketless"]
        )
        self.assertEqual(
            "container-build", routes["profiles_by_label"]["managed-container-build"]
        )
        for repository, runner in (
            ("f5-sales-demo/fixture", managed),
            (
                "f5-sales-demo/administration",
                {
                    "arc_scale_sets": {
                        "socketless": {
                            "label": "managed-container-build",
                            "profile": "ubuntu-24.04",
                        },
                        "container-build": {
                            "label": "managed-socketless",
                            "profile": "container-build",
                        },
                    }
                },
            ),
        ):
            with (
                self.subTest(repository=repository),
                self.assertRaises(MODULE.AuditError),
            ):
                MODULE.repository_routes(
                    {
                        "profiles": self.data["profiles"],
                        "repositories": {repository: {"runner": runner}},
                    },
                    repository,
                )

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

    def test_equivalent_profiles_can_share_a_scheduling_label(self):
        self.data["profiles"]["ubuntu-24.04-secondary"] = dict(
            self.data["profiles"]["ubuntu-24.04"]
        )
        self.write_policy()
        self.write_workflow(
            """name: Docker
on:
  pull_request:
jobs:
  trust-gate:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - run: true
  build:
    needs: trust-gate
    if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, Linux, X64, fixture, container-build]
    steps:
      - run: docker version
"""
        )
        self.assertEqual(self.audit(), [])

    def test_same_label_profiles_must_be_equivalent(self):
        secondary = dict(self.data["profiles"]["ubuntu-24.04"])
        secondary["memory"] = "8g"
        self.data["profiles"]["ubuntu-24.04-secondary"] = secondary
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
        self.assertTrue(any("canonical repository route" in item for item in errors))

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
            any("requires a Docker socket profile" in item for item in errors)
        )

        self.write_workflow(
            """name: Lint
on:
  pull_request:
jobs:
  trust-gate:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - run: true
  lint:
    needs: trust-gate
    if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, Linux, X64, fixture, container-build]
    steps:
      - uses: super-linter/super-linter@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"""
        )
        self.assertEqual(self.audit(), [])

    def test_docker_profile_pull_request_requires_complete_same_repository_guard(self):
        guards = (
            None,
            "github.event_name == 'pull_request'",
            "github.event.pull_request.head.repo.full_name == github.repository",
            "github.event_name == 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository",
        )
        for guard in guards:
            rendered_guard = "" if guard is None else f"    if: {guard}\n"
            self.write_workflow(
                """name: Docker
on:
  pull_request:
jobs:
  trust-gate:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - run: true
  build:
    needs: trust-gate
"""
                + rendered_guard
                + """    runs-on: [self-hosted, Linux, X64, fixture, container-build]
    steps:
      - run: true
"""
            )
            with self.subTest(guard=guard):
                errors = self.audit()
                self.assertTrue(any("same-repository guard" in item for item in errors))

    def test_docker_profile_rejects_pull_request_without_socketless_trust_gate(self):
        self.write_workflow(
            """name: Docker
on:
  pull_request:
jobs:
  build:
    if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, Linux, X64, fixture, container-build]
    steps:
      - run: docker version
"""
        )
        errors = self.audit()
        self.assertTrue(any("socketless trust-gate" in item for item in errors))

    def test_docker_profile_allows_trusted_manual_workflow_only(self):
        self.write_workflow(
            """name: Docker
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: [self-hosted, Linux, X64, fixture, container-build]
    steps:
      - run: docker version
"""
        )
        self.assertEqual(self.audit(), [])

        self.write_workflow(
            """name: Docker
on: [push]
jobs:
  build:
    runs-on: [self-hosted, Linux, X64, fixture, container-build]
    steps:
      - run: docker version
"""
        )
        errors = self.audit()
        self.assertTrue(any("same-repository guard" in item for item in errors))

    def test_callable_docker_profile_allows_protected_branch_and_tag_guard(self):
        self.write_workflow(
            """name: Docs
on:
  workflow_call:
jobs:
  prepare:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - run: true
  trust-gate:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - run: true
  build:
    needs: [prepare, trust-gate]
    if: github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && (github.ref == format('refs/heads/{0}', github.event.repository.default_branch) || startsWith(github.ref, 'refs/tags/v'))) || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository)
    runs-on: [self-hosted, Linux, X64, fixture, container-build]
    steps:
      - run: docker version
"""
        )
        self.assertEqual(self.audit(), [])

    def test_default_branch_docker_guard_requires_protected_tag_clause(self):
        self.write_workflow(
            """name: Docker
on:
  push:
jobs:
  trust-gate:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - run: true
  build:
    needs: trust-gate
    if: github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch)) || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository)
    runs-on: [self-hosted, Linux, X64, fixture, container-build]
    steps:
      - run: docker version
"""
        )
        errors = self.audit()
        self.assertTrue(any("same-repository guard" in item for item in errors))

    def test_scheduled_docker_profile_requires_exact_protected_default_guard(self):
        exact_guard = (
            "github.event_name == 'workflow_dispatch' || "
            "github.event_name == 'schedule' || "
            "(github.event_name == 'push' && "
            "github.ref == format('refs/heads/{0}', "
            "github.event.repository.default_branch) && "
            "github.ref_protected == true)"
        )
        workflow: dict[str, Any] = {
            "name": "Scheduled Docker",
            "on": {
                "push": {"branches": ["main"]},
                "schedule": [{"cron": "0 5 * * *"}],
                "workflow_dispatch": None,
            },
            "jobs": {
                "trust-gate": {
                    "runs-on": [
                        "self-hosted",
                        "Linux",
                        "X64",
                        "fixture",
                        "ubuntu-24.04",
                    ],
                    "steps": [{"run": True}],
                },
                "build": {
                    "needs": "trust-gate",
                    "if": exact_guard,
                    "runs-on": [
                        "self-hosted",
                        "Linux",
                        "X64",
                        "fixture",
                        "container-build",
                    ],
                    "steps": [{"run": "docker version"}],
                },
            },
        }
        self.write_workflow(yaml.safe_dump(workflow, sort_keys=False))
        self.assertEqual(self.audit(), [])

        workflow["jobs"]["build"]["if"] = exact_guard.replace(
            " && github.ref_protected == true", ""
        )
        self.write_workflow(yaml.safe_dump(workflow, sort_keys=False))
        errors = self.audit()
        self.assertTrue(any("same-repository guard" in item for item in errors))

    def test_docker_steps_and_privileged_package_installs_are_detected(self):
        self.write_workflow(
            """name: CI
on: [push]
jobs:
  test:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - uses: docker/login-action@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      - run: |
          # docker is only a comment
          apt-get install thing
"""
        )
        errors = self.audit()
        self.assertTrue(any("Docker workload" in item for item in errors))
        self.assertTrue(any("sudo or apt" in item for item in errors))

    def test_unlisted_self_hosted_repository_fails_then_schema_v3_policy_passes(self):
        self.write_workflow(
            """name: CI
on: [pull_request]
jobs:
  audit:
    runs-on: [self-hosted, Linux, X64, fixture, ubuntu-24.04]
    steps:
      - run: true
"""
        )
        del self.data["repositories"]["f5-sales-demo/fixture"]
        self.write_policy()
        with self.assertRaisesRegex(
            MODULE.AuditError, "repository is not governed: f5-sales-demo/fixture"
        ):
            self.audit()

        self.data["repositories"]["f5-sales-demo/fixture"] = {
            "runner": {"profiles": ["ubuntu-24.04"]}
        }
        self.write_policy()
        self.assertEqual(self.audit(), [])

    def test_github_hosted_audit_requires_an_exact_policy_exception(self):
        self.write_workflow(
            """name: Workflow Security Audit
on: [pull_request]
jobs:
  workflow-security-audit:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - run: true
"""
        )
        errors = self.audit()
        self.assertTrue(any("canonical repository route" in item for item in errors))

        self.data["hosted_exceptions"] = {
            "f5-sales-demo/fixture": {
                ".github/workflows/ci.yml": {
                    "workflow-security-audit": {
                        "runs_on": "ubuntu-latest",
                        "reason": "read-only pull request workflow security audit",
                    }
                }
            }
        }
        self.write_policy()
        self.assertEqual(self.audit(), [])

    def test_linked_issue_has_no_retired_hosted_exception(self):
        policy = json.loads(
            (ROOT / ".github/config/self-hosted-runner-policy.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(set(policy["hosted_exceptions"]), set(policy["repositories"]))
        for repository in policy["repositories"]:
            self.assertNotIn(
                ".github/workflows/require-linked-issue.yml",
                policy["hosted_exceptions"][repository],
                repository,
            )
        exception = policy["hosted_exceptions"]["f5-sales-demo/docs-control"]
        self.assertEqual(
            exception,
            {
                ".github/workflows/workflow-security-audit.yml": {
                    "workflow-security-audit": {
                        "runs_on": "ubuntu-latest",
                        "reason": "read-only pull request workflow security audit",
                    }
                },
            },
        )
        self.assertNotIn(
            ".github/workflows/require-linked-issue.yml",
            policy["hosted_exceptions"]["f5-sales-demo/xcsh"],
        )

    def test_api_specs_enriched_hosted_audit_exception_is_exact(self):
        policy = json.loads(
            (ROOT / ".github/config/self-hosted-runner-policy.json").read_text(
                encoding="utf-8"
            )
        )
        exception = policy["hosted_exceptions"]["f5-sales-demo/api-specs-enriched"]
        self.assertEqual(
            exception,
            {
                ".github/workflows/workflow-security-audit.yml": {
                    "workflow-security-audit": {
                        "runs_on": "ubuntu-latest",
                        "reason": "read-only pull request workflow security audit",
                    }
                },
            },
        )

    def test_vscode_xcsh_hosted_exceptions_are_only_native_and_release_boundaries(self):
        policy = json.loads(
            (ROOT / ".github/config/self-hosted-runner-policy.json").read_text(
                encoding="utf-8"
            )
        )
        exception = policy["hosted_exceptions"]["f5-sales-demo/vscode-xcsh"]
        self.assertEqual(
            exception,
            {
                ".github/workflows/ci.yml": {
                    "test-native": {
                        "runs_on": "matrix",
                        "reason": "extension integration tests require native hosted macOS and Windows platforms",
                    },
                    "release": {
                        "runs_on": "ubuntu-latest",
                        "reason": "extension publication uses GitHub-hosted release credentials",
                    },
                    "stage-spec-delivery": {
                        "runs_on": "ubuntu-latest",
                        "reason": "spec staging uses GitHub-hosted delivery credentials",
                    },
                    "record-spec-delivery": {
                        "runs_on": "ubuntu-latest",
                        "reason": "delivery recording uses GitHub-hosted publication credentials",
                    },
                },
                ".github/workflows/workflow-security-audit.yml": {
                    "workflow-security-audit": {
                        "runs_on": "ubuntu-latest",
                        "reason": "read-only pull request workflow security audit",
                    }
                },
            },
        )

    def test_xcsh_npm_backfill_hosted_exception_is_exact(self):
        policy = json.loads(
            (ROOT / ".github/config/self-hosted-runner-policy.json").read_text(
                encoding="utf-8"
            )
        )
        exception = policy["hosted_exceptions"]["f5-sales-demo/xcsh"][
            ".github/workflows/release-npm-backfill.yml"
        ]
        self.assertEqual(
            exception,
            {
                "backfill": {
                    "runs_on": "ubuntu-22.04",
                    "reason": "npm backfill publication uses the hosted release environment",
                }
            },
        )

    def test_terraform_hosted_reusable_workflow_exceptions_are_exact(self):
        policy = json.loads(
            (ROOT / ".github/config/self-hosted-runner-policy.json").read_text(
                encoding="utf-8"
            )
        )
        exception = policy["hosted_exceptions"]["f5-sales-demo/terraform-provider-xcsh"]
        self.assertEqual(
            exception,
            {
                ".github/workflows/_build-test.yml": {
                    "build": {
                        "runs_on": "ubuntu-latest",
                        "reason": "CGO race tests require the hosted compiler toolchain",
                    },
                    "lint": {
                        "runs_on": "ubuntu-latest",
                        "reason": "repository Go lint uses the hosted toolchain",
                    },
                },
                ".github/workflows/_generate-docs.yml": {
                    "generate": {
                        "runs_on": "ubuntu-latest",
                        "reason": "read-only documentation generation uses hosted Terraform tooling",
                    }
                },
                ".github/workflows/_generate-provider.yml": {
                    "generate": {
                        "runs_on": "ubuntu-latest",
                        "reason": "read-only provider generation uses the hosted Go toolchain",
                    }
                },
                ".github/workflows/_tag-release.yml": {
                    "preflight": {
                        "runs_on": "ubuntu-latest",
                        "reason": "release reproducibility verification uses isolated hosted tooling",
                    },
                    "publish": {
                        "runs_on": "ubuntu-latest",
                        "reason": "release signing and publication use isolated hosted execution",
                    },
                    "tag": {
                        "runs_on": "ubuntu-latest",
                        "reason": "release tag signing uses isolated hosted execution",
                    },
                },
                ".github/workflows/workflow-security-audit.yml": {
                    "workflow-security-audit": {
                        "runs_on": "ubuntu-latest",
                        "reason": "read-only pull request workflow security audit",
                    }
                },
            },
        )


if __name__ == "__main__":
    unittest.main()
