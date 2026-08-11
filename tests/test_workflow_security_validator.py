#!/usr/bin/env python3
"""Behavioral tests for exact self-hosted workflow exception enforcement."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

import yaml

SCRIPT = Path(__file__).resolve().parent.parent / "scripts/workflow-security-validator.py"
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
                    "runs-on": ["self-hosted", "Linux", "X64", "terraform-provider-xcsh"],
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
                            "run": "test -n \"$TOKEN\"",
                        },
                    ],
                }
            },
        }
        self.spec = {
            "runs_on": ["self-hosted", "Linux", "X64", "terraform-provider-xcsh"],
            "environment": "acceptance-tests",
            "permissions": {"contents": "read"},
            "allowed_secrets": ["XCSH_API_TOKEN"],
            "triggers": copy.deepcopy(self.workflow["on"]),
            "if": "github.event_name != 'pull_request'",
        }
        self.policy = {
            "schema_version": 1,
            "repositories": {
                self.repository: {self.workflow_path: {self.job_id: self.spec}}
            },
        }
        self.findings = [self.finding()]
        self.governance = {
            "repo_classes": {"repos": {"terraform-provider-xcsh": "developer"}}
        }

    def tearDown(self):
        self.temp.cleanup()

    def finding(self, ident="self-hosted-runner", route=None, locations=None):
        if route is None:
            route = [{"Key": "jobs"}, {"Key": self.job_id}, {"Key": "runs-on"}]
        location = {
            "symbolic": {
                "key": {"Local": {"verbatim_path": self.workflow_path}},
                "route": {"route": route},
            }
        }
        return {"ident": ident, "locations": locations if locations is not None else [location]}

    def write_fixture(self, workflow=None, policy=None, governance=None):
        path = self.root / self.workflow_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(workflow or self.workflow, sort_keys=False), encoding="utf-8")
        self.policy_path.write_text(json.dumps(policy or self.policy), encoding="utf-8")
        self.governance_path.write_text(
            json.dumps(governance or self.governance), encoding="utf-8"
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

    def assert_rejected(self, workflow=None, policy=None, findings=None, repository=None):
        self.write_fixture(workflow, policy)
        with self.assertRaises(validator.PolicyError):
            validator.validate(
                self.findings if findings is None else findings,
                self.root,
                repository or self.repository,
                self.policy_path,
                self.governance_path,
            )

    def test_real_zizmor_1_29_nested_route_is_normalized(self):
        routes = self.validate()
        self.assertEqual(routes, [(self.workflow_path, self.job_id, ["jobs", self.job_id, "runs-on"])])

    def test_malformed_missing_duplicate_and_ambiguous_routes_fail(self):
        bad_routes = [
            [],
            [{"Key": "jobs"}, {"Key": self.job_id}],
            [{"Key": "jobs"}, {"Key": self.job_id}, {"Key": "steps"}],
            [{"Key": "jobs"}, {"Nope": self.job_id}, {"Key": "runs-on"}],
            [{"Key": "jobs"}, {"Key": self.job_id}, {"Key": "jobs"}, {"Key": "x"}, {"Key": "runs-on"}],
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
        policy["repositories"][self.repository][self.workflow_path]["unused"] = copy.deepcopy(self.spec)
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

    def test_known_repository_with_no_exceptions_accepts_empty_inventory(self):
        clean_repository = "f5-sales-demo/api-specs"
        policy = copy.deepcopy(self.policy)
        policy["repositories"][clean_repository] = {}
        governance = copy.deepcopy(self.governance)
        governance["repo_classes"]["repos"]["api-specs"] = "developer"
        clean_root = self.root / "clean"
        (clean_root / ".github/workflows").mkdir(parents=True)
        (clean_root / ".github/workflows/ci.yml").write_text(
            yaml.safe_dump({"on": {"push": {"branches": ["main"]}}, "permissions": {}, "jobs": {"test": {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]}}}),
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
        for guard in (None, "github.event_name == 'pull_request'", "github.event_name != 'pull_request' || true"):
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
            policy["repositories"][self.repository][self.workflow_path][self.job_id]["triggers"] = {trigger: {}}
            mutations.append((workflow, policy))
        workflow = copy.deepcopy(self.workflow)
        policy = copy.deepcopy(self.policy)
        workflow["on"] = {"push": {}}
        policy["repositories"][self.repository][self.workflow_path][self.job_id]["triggers"] = {"push": {}}
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
        workflow["jobs"][self.job_id]["steps"][1]["run"] = "echo ${{ secrets.XCSH_API_TOKEN }}"
        self.assert_rejected(workflow=workflow)
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
        validator.validate_zizmor_result(0, [])
        validator.validate_zizmor_result(13, self.findings)
        for code, findings in ((0, self.findings), (13, []), (1, [])):
            with self.subTest(code=code, findings=findings):
                with self.assertRaises(validator.PolicyError):
                    validator.validate_zizmor_result(code, findings)
        with self.assertRaises(validator.PolicyError):
            validator.validate_zizmor_result(13, {"findings": self.findings})
        with self.assertRaises(json.JSONDecodeError):
            json.loads('[{"ident":')


if __name__ == "__main__":
    unittest.main()
