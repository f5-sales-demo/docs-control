# mypy: ignore-errors
# pylint: disable=consider-using-with,too-many-public-methods
"""Behavioral tests for exact self-hosted workflow exception enforcement."""

import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

import yaml

SCRIPT = (
    Path(__file__).resolve().parent.parent / "scripts/workflow-security-validator.py"
)
SPEC = importlib.util.spec_from_file_location("workflow_security_validator", SCRIPT)
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class WorkflowSecurityValidatorTests(unittest.TestCase):
    repository = "f5-sales-demo/terraform-provider-xcsh"
    workflow_path = ".github/workflows/acc-tests.yml"
    job_id = "real-api-tests"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.policy_path = self.root / "policy.json"
        self.governance_path = self.root / "governance.json"
        self.workflow = {
            "name": "Acceptance",
            "on": {
                "pull_request": {"branches": ["main"]},
                "workflow_dispatch": {},
            },
            "permissions": {},
            "jobs": {
                self.job_id: {
                    "runs-on": [
                        "self-hosted",
                        "Linux",
                        "X64",
                        "terraform-provider-xcsh",
                        "ubuntu-24.04",
                    ],
                    "environment": "acceptance-tests",
                    "if": "github.event_name != 'pull_request'",
                    "permissions": {"contents": "read"},
                    "steps": [
                        {
                            "uses": "actions/checkout@immutable",
                            "with": {"persist-credentials": False},
                        },
                        {
                            "env": {"TOKEN": "${{ secrets.XCSH_API_TOKEN }}"},
                            "run": 'test -n "$TOKEN"',
                        },
                    ],
                }
            },
        }
        self.spec = {
            "runs_on": [
                "self-hosted",
                "Linux",
                "X64",
                "terraform-provider-xcsh",
                "ubuntu-24.04",
            ],
            "environment": "acceptance-tests",
            "permissions": {"contents": "read"},
            "allowed_secrets": ["XCSH_API_TOKEN"],
            "triggers": copy.deepcopy(self.workflow["on"]),
            "if": "github.event_name != 'pull_request'",
        }
        self.policy = {
            "schema_version": 4,
            "docker": {
                "host_socket": "/run/f5-actions-runner/container-build/docker.sock",
                "runner_socket": "/run/docker.sock",
                "data_root": "/data/actions-runners/container-build-docker",
                "cache_max": "20g",
                "cgroup_parent": "f5-actions-container-build.slice",
                "minimum_version": "29.2.1",
                "target_version": "29.7.2",
            },
            "dispatcher": copy.deepcopy(validator.DISPATCHER_POLICY),
            "defaults": {"profile": "ubuntu-24.04"},
            "profiles": {"ubuntu-24.04": {}, "container-build": {}},
            "hosted_exceptions": {},
            "repositories": {
                self.repository: {
                    "runner": {"profiles": ["ubuntu-24.04", "container-build"]},
                    self.workflow_path: {self.job_id: self.spec},
                }
            },
        }
        self.findings = [self.finding()]
        self.governance = {
            "repo_classes": {"repos": {"terraform-provider-xcsh": "developer"}}
        }

    def test_all_arc_cohorts_are_excluded_from_dispatcher_contract(self):
        self.assertEqual(validator.DISPATCHER_POLICY["repositories"], [])
        self.assertEqual(len(validator.MANAGED_ARC_COHORT), 32)
        self.assertIn("f5-sales-demo/docs-control", validator.MANAGED_ARC_COHORT)

        fixture_path = (
            Path(__file__).resolve().parent / "fixtures/workflow-security/policy.json"
        )
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        self.assertEqual(validator.DISPATCHER_POLICY, fixture["dispatcher"])

    def tearDown(self):
        self.temp.cleanup()

    def finding(
        self,
        ident="self-hosted-runner",
        route=None,
        locations=None,
        severity="Medium",
        path=None,
    ):
        if route is None:
            route = [{"Key": "jobs"}, {"Key": self.job_id}, {"Key": "runs-on"}]
        location = {
            "symbolic": {
                "key": {"Local": {"verbatim_path": path or self.workflow_path}},
                "route": {"route": route},
            }
        }
        return {
            "ident": ident,
            "locations": locations if locations is not None else [location],
            "determinations": {"severity": severity},
            "ignored": False,
        }

    def write_fixture(self, workflow=None, policy=None, governance=None):
        path = self.root / self.workflow_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            yaml.safe_dump(workflow or self.workflow, sort_keys=False), encoding="utf-8"
        )
        self.policy_path.write_text(json.dumps(policy or self.policy), encoding="utf-8")
        self.governance_path.write_text(
            json.dumps(governance or self.governance), encoding="utf-8"
        )

    @staticmethod
    def xcsh_arc_runner():
        return {
            "arc_scale_sets": {
                "socketless": {
                    "label": "xcsh-socketless",
                    "profile": "ubuntu-24.04",
                },
                "container-build": {
                    "label": "xcsh-container-build",
                    "profile": "container-build",
                },
                "compute": {
                    "label": "xcsh-compute",
                    "profile": "ubuntu-24.04",
                },
            }
        }

    @staticmethod
    def managed_arc_runner():
        return {
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

    def test_managed_arc_labels_are_exact_and_cohort_bound(self):
        routes = validator.repository_runner_routes(
            {"runner": self.managed_arc_runner()},
            self.policy["profiles"],
            "ubuntu-24.04",
            "f5-sales-demo/administration",
        )
        self.assertEqual(
            "ubuntu-24.04", validator.resolve_route("managed-socketless", routes)
        )
        self.assertEqual(
            "container-build",
            validator.resolve_route("managed-container-build", routes),
        )
        for repository, runner in (
            ("f5-sales-demo/fixture", self.managed_arc_runner()),
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
                self.assertRaises(validator.PolicyError),
            ):
                validator.repository_runner_routes(
                    {"runner": runner},
                    self.policy["profiles"],
                    "ubuntu-24.04",
                    repository,
                )

    def test_arc_route_model_accepts_only_exact_scalar_labels(self):
        routes = validator.repository_runner_routes(
            {"runner": self.xcsh_arc_runner()},
            self.policy["profiles"],
            "ubuntu-24.04",
            "f5-sales-demo/xcsh",
        )
        self.assertEqual("arc", routes["kind"])
        self.assertEqual(
            "ubuntu-24.04", validator.resolve_route("xcsh-socketless", routes)
        )
        self.assertEqual(
            "container-build",
            validator.resolve_route("xcsh-container-build", routes),
        )
        self.assertIsNone(validator.resolve_route("xcsh-unknown", routes))
        self.assertIsNone(
            validator.resolve_route(
                ["self-hosted", "Linux", "X64", "xcsh", "ubuntu-24.04"],
                routes,
            )
        )

    def test_arc_route_model_rejects_malformed_and_duplicate_labels(self):
        base = self.xcsh_arc_runner()
        mutations = []

        combined = copy.deepcopy(base)
        combined["profiles"] = ["ubuntu-24.04", "container-build"]
        mutations.append(combined)

        duplicate = copy.deepcopy(base)
        duplicate["arc_scale_sets"]["container-build"]["label"] = "xcsh-socketless"
        mutations.append(duplicate)

        unknown = copy.deepcopy(base)
        unknown["arc_scale_sets"]["socketless"]["profile"] = "missing"
        mutations.append(unknown)

        malformed = copy.deepcopy(base)
        malformed["arc_scale_sets"]["socketless"]["extra"] = True
        mutations.append(malformed)

        for runner in mutations:
            with self.subTest(runner=runner), self.assertRaises(validator.PolicyError):
                validator.repository_runner_routes(
                    {"runner": runner},
                    self.policy["profiles"],
                    "ubuntu-24.04",
                    "f5-sales-demo/xcsh",
                )

    def test_arc_reusable_call_requires_exact_approved_label_pair(self):
        repository = "f5-sales-demo/xcsh"
        workflow = {
            "name": "Reusable",
            "on": {"workflow_dispatch": {}},
            "permissions": {},
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
        policy = copy.deepcopy(self.policy)
        policy["repositories"] = {repository: {"runner": self.xcsh_arc_runner()}}
        governance = {"repo_classes": {"repos": {"xcsh": "developer"}}}
        self.write_fixture(workflow, policy, governance)
        self.assertEqual(
            validator.validate(
                [], self.root, repository, self.policy_path, self.governance_path
            ),
            [],
        )

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
            self.write_fixture(workflow, policy, governance)
            with self.subTest(inputs=inputs), self.assertRaises(validator.PolicyError):
                validator.validate(
                    [], self.root, repository, self.policy_path, self.governance_path
                )

        workflow["jobs"]["lint"].pop("with")
        self.write_fixture(workflow, policy, governance)
        with self.assertRaises(validator.PolicyError):
            validator.validate(
                [], self.root, repository, self.policy_path, self.governance_path
            )

    def test_legacy_reusable_call_without_overrides_is_unchanged(self):
        workflow = {
            "name": "Reusable",
            "on": {"workflow_dispatch": {}},
            "permissions": {},
            "jobs": {
                "pages": {
                    "uses": (
                        "f5-sales-demo/docs-control/.github/workflows/"
                        "github-pages-deploy.yml@" + "a" * 40
                    ),
                    "with": {"content-ref": "a" * 40},
                }
            },
        }
        policy = copy.deepcopy(self.policy)
        policy["repositories"][self.repository] = {
            "runner": {"profiles": ["ubuntu-24.04", "container-build"]}
        }
        self.write_fixture(workflow, policy, self.governance)
        self.assertEqual(
            validator.validate(
                [],
                self.root,
                self.repository,
                self.policy_path,
                self.governance_path,
            ),
            [],
        )
        workflow["jobs"]["pages"]["with"].update(
            {
                "socketless_runner_label": "xcsh-socketless",
                "container_build_runner_label": "xcsh-container-build",
            }
        )
        self.write_fixture(workflow, policy, self.governance)
        with self.assertRaises(validator.PolicyError):
            validator.validate(
                [],
                self.root,
                self.repository,
                self.policy_path,
                self.governance_path,
            )

    def test_arc_inventory_accepts_socketless_and_rejects_retired_routes(self):
        repository = "f5-sales-demo/xcsh"
        workflow = {
            "name": "ARC",
            "on": {"push": {"branches": ["main"]}},
            "permissions": {},
            "jobs": {
                self.job_id: {
                    "runs-on": "xcsh-socketless",
                    "steps": [{"run": "true"}],
                }
            },
        }
        path = self.root / self.workflow_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(workflow, sort_keys=False), encoding="utf-8")
        routes = validator.repository_runner_routes(
            {"runner": self.xcsh_arc_runner()},
            self.policy["profiles"],
            "ubuntu-24.04",
            repository,
        )
        spec = {
            "runs_on": "xcsh-socketless",
            "environment": None,
            "permissions": {},
            "allowed_secrets": [],
            "triggers": {"push": {"branches": ["main"]}},
            "if": None,
        }
        policy = {(self.workflow_path, self.job_id): spec}
        self.assertEqual(
            {(self.workflow_path, self.job_id)},
            validator.inventory(self.root, repository, policy, "ubuntu-24.04", routes),
        )

        for label in ("xcsh-compute", "xcsh-container-build"):
            workflow["jobs"][self.job_id]["runs-on"] = label
            spec["runs_on"] = label
            path.write_text(yaml.safe_dump(workflow, sort_keys=False), encoding="utf-8")
            with self.subTest(approved_label=label):
                self.assertEqual(
                    {(self.workflow_path, self.job_id)},
                    validator.inventory(
                        self.root, repository, policy, "ubuntu-24.04", routes
                    ),
                )

        for rejected in (
            "xcsh-unknown",
            ["self-hosted", "Linux", "X64", "xcsh", "ubuntu-24.04"],
            ["self-hosted", "Linux", "X64", "xcsh", "container-build"],
        ):
            workflow["jobs"][self.job_id]["runs-on"] = rejected
            path.write_text(yaml.safe_dump(workflow, sort_keys=False), encoding="utf-8")
            with self.subTest(route=rejected), self.assertRaises(validator.PolicyError):
                validator.inventory(
                    self.root, repository, policy, "ubuntu-24.04", routes
                )

    def _assert_arc_route_contract_authorizes_ordinary_job_without_exception(self):
        repository = "f5-sales-demo/xcsh"
        workflow = {
            "name": "ARC",
            "on": {"push": {"branches": ["main"]}},
            "permissions": {},
            "jobs": {
                "ordinary": {
                    "runs-on": "xcsh-socketless",
                    "steps": [{"run": "true"}],
                }
            },
        }
        policy = copy.deepcopy(self.policy)
        policy["repositories"] = {repository: {"runner": self.xcsh_arc_runner()}}
        governance = {"repo_classes": {"repos": {"xcsh": "developer"}}}
        self.write_fixture(workflow, policy, governance)

        self.assertEqual(
            validator.validate(
                [],
                self.root,
                repository,
                self.policy_path,
                self.governance_path,
            ),
            [(self.workflow_path, "ordinary", ["jobs", "ordinary", "runs-on"])],
        )

    def validate(self, findings=None, repository=None, policy_path=None):
        self.write_fixture()
        return validator.validate(
            self.findings if findings is None else findings,
            self.root,
            repository or self.repository,
            policy_path or self.policy_path,
            self.governance_path,
        )

    def assert_rejected(
        self, workflow=None, policy=None, findings=None, repository=None
    ):
        self.write_fixture(workflow, policy)
        with self.assertRaises(validator.PolicyError):
            validator.validate(
                self.findings if findings is None else findings,
                self.root,
                repository or self.repository,
                self.policy_path,
                self.governance_path,
            )

    def test_arc_routes_are_internally_validated_without_zizmor_findings(self):
        self._assert_arc_route_contract_authorizes_ordinary_job_without_exception()
        repository = "f5-sales-demo/xcsh"
        workflow = copy.deepcopy(self.workflow)
        workflow["jobs"][self.job_id]["runs-on"] = "xcsh-socketless"
        spec = copy.deepcopy(self.spec)
        spec["runs_on"] = "xcsh-socketless"
        policy = copy.deepcopy(self.policy)
        policy["repositories"] = {
            repository: {
                "runner": self.xcsh_arc_runner(),
                self.workflow_path: {self.job_id: spec},
            }
        }
        governance = {"repo_classes": {"repos": {"xcsh": "developer"}}}
        self.write_fixture(workflow, policy, governance)

        self.assertEqual(
            validator.validate(
                [],
                self.root,
                repository,
                self.policy_path,
                self.governance_path,
            ),
            [(self.workflow_path, self.job_id, ["jobs", self.job_id, "runs-on"])],
        )

        workflow["jobs"][self.job_id]["runs-on"] = "xcsh-unknown"
        self.write_fixture(workflow, policy, governance)
        with self.assertRaises(validator.PolicyError):
            validator.validate(
                [],
                self.root,
                repository,
                self.policy_path,
                self.governance_path,
            )

        workflow["jobs"][self.job_id]["runs-on"] = "xcsh-socketless"
        self.write_fixture(workflow, policy, governance)
        with self.assertRaisesRegex(validator.PolicyError, "unexpected Zizmor finding"):
            validator.validate(
                [self.finding()],
                self.root,
                repository,
                self.policy_path,
                self.governance_path,
            )

    def test_real_zizmor_1_29_nested_route_is_normalized(self):
        routes = self.validate()
        self.assertEqual(
            routes,
            [(self.workflow_path, self.job_id, ["jobs", self.job_id, "runs-on"])],
        )

    def test_managed_template_self_hosted_route_is_accounted_for(self):
        template_path = "workflows/acc-tests.yml"
        self.write_fixture()
        path = self.root / template_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            yaml.safe_dump(self.workflow, sort_keys=False), encoding="utf-8"
        )
        findings = [self.finding(), self.finding(path=template_path)]
        routes = validator.validate(
            findings,
            self.root,
            self.repository,
            self.policy_path,
            self.governance_path,
        )
        self.assertEqual(
            routes,
            [
                (self.workflow_path, self.job_id, ["jobs", self.job_id, "runs-on"]),
                (template_path, self.job_id, ["jobs", self.job_id, "runs-on"]),
            ],
        )

    def test_malformed_missing_duplicate_and_ambiguous_routes_fail(self):
        bad_routes = [
            [],
            ["jobs", self.job_id, "runs-on"],
            [{"Key": "jobs"}, {"Key": self.job_id}],
            [{"Key": "jobs"}, {"Key": self.job_id}, {"Key": "steps"}],
            [{"Key": "jobs"}, {"Nope": self.job_id}, {"Key": "runs-on"}],
            [
                {"Key": "jobs"},
                {"Key": self.job_id},
                {"Key": "jobs"},
                {"Key": "x"},
                {"Key": "runs-on"},
            ],
        ]
        for route in bad_routes:
            with self.subTest(route=route):
                self.assert_rejected(findings=[self.finding(route=route)])
        duplicated_location = self.finding()["locations"] * 2
        self.assert_rejected(findings=[self.finding(locations=duplicated_location)])
        self.assert_rejected(findings=self.findings * 2)

    def test_one_to_one_accounting_rejects_missing_finding_and_unused_policy(self):
        self.assert_rejected(findings=[])
        policy = copy.deepcopy(self.policy)
        policy["repositories"][self.repository][self.workflow_path]["unused"] = (
            copy.deepcopy(self.spec)
        )
        self.assert_rejected(policy=policy)

    def test_repository_identity_and_runner_label_are_exact(self):
        self.assert_rejected(repository="f5-sales-demo/another-repo")
        for labels in (
            ["self-hosted"],
            ["self-hosted", "Linux", "X64", "another-repo"],
            ["self-hosted", "Linux", "X64", "terraform-provider-xcsh", "extra"],
            ["self-hosted", "Linux", "X64", "ubuntu-latest"],
            "${{ matrix.runner }}",
        ):
            workflow = copy.deepcopy(self.workflow)
            workflow["jobs"][self.job_id]["runs-on"] = labels
            with self.subTest(labels=labels):
                self.assert_rejected(workflow=workflow)

    def test_declared_nondefault_runner_profile_is_canonical(self):
        workflow = copy.deepcopy(self.workflow)
        workflow["jobs"][self.job_id]["runs-on"][-1] = "container-build"
        policy = copy.deepcopy(self.policy)
        policy["repositories"][self.repository] = {
            "runner": {"profiles": ["ubuntu-24.04", "container-build"]}
        }
        self.write_fixture(workflow=workflow, policy=policy)
        validator.validate(
            self.findings,
            self.root,
            self.repository,
            self.policy_path,
            self.governance_path,
        )
        policy["repositories"][self.repository]["runner"]["profiles"] = ["ubuntu-24.04"]
        self.assert_rejected(workflow=workflow, policy=policy)

    def test_known_repository_with_no_exceptions_accepts_empty_inventory(self):
        clean_repository = "f5-sales-demo/api-specs"
        policy = copy.deepcopy(self.policy)
        policy["repositories"][clean_repository] = {
            "runner": {"profiles": ["ubuntu-24.04", "container-build"]}
        }
        governance = copy.deepcopy(self.governance)
        governance["repo_classes"]["repos"]["api-specs"] = "developer"
        clean_root = self.root / "clean"
        (clean_root / ".github/workflows").mkdir(parents=True)
        (clean_root / ".github/workflows/ci.yml").write_text(
            yaml.safe_dump(
                {
                    "on": {"push": {"branches": ["main"]}},
                    "permissions": {},
                    "jobs": {
                        "test": {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]}
                    },
                }
            ),
            encoding="utf-8",
        )
        self.policy_path.write_text(json.dumps(policy), encoding="utf-8")
        self.governance_path.write_text(json.dumps(governance), encoding="utf-8")
        self.assertEqual(
            validator.validate(
                [], clean_root, clean_repository, self.policy_path, self.governance_path
            ),
            [],
        )

    def test_environment_policy_and_schema_fail_closed(self):
        for environment in (None, "wrong"):
            workflow = copy.deepcopy(self.workflow)
            workflow["jobs"][self.job_id]["environment"] = environment
            self.assert_rejected(workflow=workflow)
        self.write_fixture()
        self.policy_path.unlink()
        with self.assertRaises(validator.PolicyError):
            validator.validate(
                self.findings,
                self.root,
                self.repository,
                self.policy_path,
                self.governance_path,
            )
        for change in (
            {"schema_version": 2},
            {"unknown": True},
        ):
            policy = copy.deepcopy(self.policy)
            policy.update(change)
            self.assert_rejected(policy=policy)

    def test_guard_trigger_and_permission_mutations_fail(self):
        mutations = []
        for guard in (
            None,
            "github.event_name == 'pull_request'",
            "github.event_name != 'pull_request' || true",
        ):
            workflow = copy.deepcopy(self.workflow)
            workflow["jobs"][self.job_id]["if"] = guard
            mutations.append((workflow, None))
        for trigger in (
            "pull_request_target",
            "workflow_run",
            "repository_dispatch",
            "issue_comment",
        ):
            workflow = copy.deepcopy(self.workflow)
            policy = copy.deepcopy(self.policy)
            workflow["on"] = {trigger: {}}
            policy["repositories"][self.repository][self.workflow_path][self.job_id][
                "triggers"
            ] = {trigger: {}}
            mutations.append((workflow, policy))
        workflow = copy.deepcopy(self.workflow)
        policy = copy.deepcopy(self.policy)
        workflow["on"] = {"push": {}}
        policy["repositories"][self.repository][self.workflow_path][self.job_id][
            "triggers"
        ] = {"push": {}}
        mutations.append((workflow, policy))
        for permissions in (None, "write-all", {"contents": "write"}):
            workflow = copy.deepcopy(self.workflow)
            workflow["jobs"][self.job_id]["permissions"] = permissions
            mutations.append((workflow, None))
        workflow = copy.deepcopy(self.workflow)
        policy = copy.deepcopy(self.policy)
        workflow["jobs"][self.job_id]["permissions"] = {"issues": "write"}
        policy["repositories"][self.repository][self.workflow_path][self.job_id][
            "permissions"
        ] = {"issues": "write"}
        mutations.append((workflow, policy))
        for workflow, policy in mutations:
            self.assert_rejected(workflow=workflow, policy=policy)

    def test_checkout_secret_and_finding_mutations_fail(self):
        workflow = copy.deepcopy(self.workflow)
        del workflow["jobs"][self.job_id]["steps"][0]["with"]["persist-credentials"]
        self.assert_rejected(workflow=workflow)
        workflow = copy.deepcopy(self.workflow)
        workflow["jobs"][self.job_id]["steps"][0]["with"]["persist-credentials"] = True
        self.assert_rejected(workflow=workflow)
        workflow = copy.deepcopy(self.workflow)
        workflow["jobs"][self.job_id]["steps"][1]["run"] = (
            "echo ${{ secrets.XCSH_API_TOKEN }}"
        )
        self.assert_rejected(workflow=workflow)
        workflow = copy.deepcopy(self.workflow)
        workflow["jobs"][self.job_id]["steps"][1]["env"]["TOKEN"] = (
            "${{ secrets[matrix.secret_name] }}"  # noqa: S105 - expression fixture
        )
        self.assert_rejected(workflow=workflow)
        workflow = copy.deepcopy(self.workflow)
        workflow["jobs"][self.job_id]["steps"][1]["env"]["TOKEN"] = (
            "${{ secrets['XCSH_API_TOKEN'] }}"  # noqa: S105 - expression fixture
        )
        self.write_fixture(workflow=workflow)
        validator.validate(
            self.findings,
            self.root,
            self.repository,
            self.policy_path,
            self.governance_path,
        )
        self.assert_rejected(findings=[self.finding(ident="template-injection")])
        fallback = self.finding()
        fallback.pop("ident")
        fallback["rule"] = "self-hosted-runner"
        self.assert_rejected(findings=[fallback])
        structured = self.finding(ident={"slug": "self-hosted-runner"})
        self.assert_rejected(findings=[structured])

    def test_policy_inventory_must_exactly_match_governance(self):
        self.write_fixture()
        governance = copy.deepcopy(self.governance)
        governance["repo_classes"]["repos"]["api-specs"] = "developer"
        self.governance_path.write_text(json.dumps(governance), encoding="utf-8")
        with self.assertRaises(validator.PolicyError):
            validator.validate(
                self.findings,
                self.root,
                self.repository,
                self.policy_path,
                self.governance_path,
            )

    def test_policy_secret_names_are_literal_and_unique(self):
        for secrets in (["VALID", "VALID"], ["VALID", 7], ["not-valid"]):
            policy = copy.deepcopy(self.policy)
            policy["repositories"][self.repository][self.workflow_path][self.job_id][
                "allowed_secrets"
            ] = secrets
            with self.subTest(secrets=secrets):
                self.assert_rejected(policy=policy)

    def test_pull_request_guard_is_proved_independently_of_policy(self):
        workflow = copy.deepcopy(self.workflow)
        policy = copy.deepcopy(self.policy)
        unsafe = "always() && (github.event_name != 'pull_request' || true)"
        workflow["jobs"][self.job_id]["if"] = unsafe
        policy["repositories"][self.repository][self.workflow_path][self.job_id][
            "if"
        ] = unsafe
        self.assert_rejected(workflow=workflow, policy=policy)

    def test_zizmor_exit_and_json_contract(self):
        severities = {
            "Informational": 11,
            "Low": 12,
            "Medium": 13,
            "High": 14,
        }
        validator.validate_zizmor_result(0, [])
        for severity, code in severities.items():
            validator.validate_zizmor_result(code, [self.finding(severity=severity)])

        rejected = [
            (0, self.findings),
            (11, []),
            (12, [self.finding(severity="Informational")]),
            (13, [self.finding(severity="High")]),
            (14, [self.finding(severity="Low")]),
            (1, []),
            (15, [self.finding(severity="High")]),
        ]
        for code, findings in rejected:
            with (
                self.subTest(code=code, findings=findings),
                self.assertRaises(validator.PolicyError),
            ):
                validator.validate_zizmor_result(code, findings)

        malformed = self.finding()
        del malformed["determinations"]
        with self.assertRaises(validator.PolicyError):
            validator.validate_zizmor_result(13, [malformed])
        with self.assertRaises(validator.PolicyError):
            validator.validate_zizmor_result(13, {"findings": self.findings})
        with self.assertRaises(json.JSONDecodeError):
            json.loads('[{"ident":')


if __name__ == "__main__":
    unittest.main()
