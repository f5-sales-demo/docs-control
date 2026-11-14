"""Keep the toolchain canary confined to its exact provider jobs and pool."""

import copy
import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "f5-sales-demo/terraform-provider-xcsh"
PROFILE = "compute-toolchain-canary"
LABEL = "terraform-provider-xcsh-toolchain-canary"
CONTRACT = {PROFILE: {"label": LABEL, "attestation": LABEL}}
GRANTS = frozenset(
    (REPOSITORY, workflow, job)
    for workflow, job in (
        (".github/workflows/_build-test.yml", "build"),
        (".github/workflows/_build-test.yml", "vet"),
        (".github/workflows/_build-test.yml", "race"),
        (".github/workflows/_build-test.yml", "lint"),
        (".github/workflows/_generate-docs.yml", "generate"),
        (".github/workflows/_generate-provider.yml", "generate"),
        (".github/workflows/_tag-release.yml", "preflight"),
        (".github/workflows/_tag-release.yml", "publish"),
        (".github/workflows/ci.yml", "validate-docs-generation"),
        (".github/workflows/ci.yml", "validate-mock-fixtures"),
        (".github/workflows/on-merge.yml", "publish-regeneration"),
    )
)


def load(name):
    spec = importlib.util.spec_from_file_location(
        "canary_test_" + name.replace("-", "_"), ROOT / "scripts" / (name + ".py")
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


MODULES = [
    load(name)
    for name in (
        "workflow_security_validator",
        "audit-runner-workflows",
        "ephemeral-runner-controller",
    )
]


def policy_error(module):
    return next(
        getattr(module, name)
        for name in ("PolicyError", "AuditError", "FleetError")
        if hasattr(module, name)
    )


def assert_refuses(error, function, *args):
    refused = False
    try:
        function(*args)
    except error:
        refused = True
    assert refused


class GovernedProviderCanaryTest(unittest.TestCase):
    def test_canonical_policy_binds_the_observed_compute_pool(self):
        path = ROOT / ".github/config/self-hosted-runner-policy.json"
        policy = json.loads(path.read_text())
        parsed = MODULES[2].FleetPolicy(path)
        attestation = parsed.arc_attestations[LABEL]
        assert attestation["runner_profile"] == "compute"
        assert attestation["vm_size"] == "m6a.4xlarge"
        assert attestation["cpu_limit"] == 15
        assert attestation["memory_limit_bytes"] == 60129542144
        assert attestation["docker_socket"] is False
        assert attestation["repositories"] == [REPOSITORY]
        assert parsed.restricted_routes[LABEL] == GRANTS
        audit_routes = MODULES[1].repository_routes(policy, REPOSITORY)
        assert LABEL in audit_routes["attestations_by_label"]
        validation_routes = MODULES[0].repository_runner_routes(
            policy["repositories"][REPOSITORY],
            policy["profiles"],
            policy["defaults"]["profile"],
            REPOSITORY,
            policy["arc_attestations"],
            policy["restricted_routes"],
        )
        assert LABEL in validation_routes["attestations_by_label"]

    def test_only_exact_provider_canary_extension_is_admitted(self):
        for module in MODULES:
            with self.subTest(module=module.__name__):
                stable = copy.deepcopy(module.expected_arc_scale_sets(REPOSITORY))
                candidate = module.PROVIDER_CANDIDATE_SCALE_SETS
                assert module.arc_scale_sets_match_contract(REPOSITORY, stable)
                assert module.arc_scale_sets_match_contract(
                    REPOSITORY, {**stable, **CONTRACT}
                )
                assert module.arc_scale_sets_match_contract(
                    REPOSITORY, {**stable, **candidate, **CONTRACT}
                )
                foreign = copy.deepcopy(
                    module.expected_arc_scale_sets("f5-sales-demo/xcsh")
                )
                assert not module.arc_scale_sets_match_contract(
                    "f5-sales-demo/xcsh", {**foreign, **CONTRACT}
                )
                changed = copy.deepcopy(CONTRACT)
                changed[PROFILE]["label"] = "foreign-canary"
                assert not module.arc_scale_sets_match_contract(
                    REPOSITORY, {**stable, **changed}
                )

    def test_canary_grants_are_exact_and_do_not_include_the_foreign_benchmark(self):
        for module in MODULES:
            with self.subTest(module=module.__name__):
                assert module.PROVIDER_TOOLCHAIN_CANARY_GRANTS == GRANTS
                stable = module.expected_arc_scale_sets(REPOSITORY)
                scales = {**stable, **CONTRACT}
                grants = [
                    {"repository": repository, "workflow": workflow, "job": job}
                    for repository, workflow, job in sorted(GRANTS)
                ]
                module.validate_provider_toolchain_canary_grants(
                    REPOSITORY, scales, {LABEL: grants}
                )
                for altered in (
                    grants[:-1],
                    [
                        *grants,
                        {
                            "repository": REPOSITORY,
                            "workflow": ".github/workflows/workload-benchmark.yml",
                            "job": "eks-candidate",
                        },
                    ],
                    [
                        *grants,
                        {
                            "repository": "f5-sales-demo/xcsh",
                            "workflow": ".github/workflows/_build-test.yml",
                            "job": "build",
                        },
                    ],
                ):
                    assert_refuses(
                        policy_error(module),
                        module.validate_provider_toolchain_canary_grants,
                        REPOSITORY,
                        scales,
                        {LABEL: altered},
                    )

    def test_duplicate_unknown_and_untyped_grants_refuse(self):
        for module in MODULES:
            with self.subTest(module=module.__name__):
                scales = {**module.expected_arc_scale_sets(REPOSITORY), **CONTRACT}
                grants = [
                    {"repository": repository, "workflow": workflow, "job": job}
                    for repository, workflow, job in sorted(GRANTS)
                ]
                wrong_type = copy.deepcopy(grants)
                wrong_type[0]["job"] = ["build"]
                unknown_field = copy.deepcopy(grants)
                unknown_field[0]["extra"] = "unreviewed"
                duplicate = [grants[0], *grants[:-1]]
                error = (
                    module.PolicyError
                    if hasattr(module, "PolicyError")
                    else module.AuditError
                    if hasattr(module, "AuditError")
                    else module.FleetError
                )
                for altered in (wrong_type, unknown_field, duplicate):
                    with self.subTest(altered=altered):
                        assert_refuses(
                            error,
                            module.validate_provider_toolchain_canary_grants,
                            REPOSITORY,
                            scales,
                            {LABEL: altered},
                        )

    def test_existing_candidate_grant_check_remains_active_with_canary(self):
        for module in MODULES[:2]:
            with self.subTest(module=module.__name__):
                stable = module.expected_arc_scale_sets(REPOSITORY)
                scales = {**stable, **module.PROVIDER_CANDIDATE_SCALE_SETS, **CONTRACT}
                error = (
                    module.PolicyError
                    if hasattr(module, "PolicyError")
                    else module.AuditError
                )
                assert_refuses(
                    error,
                    module.validate_provider_candidate_grants,
                    REPOSITORY,
                    scales,
                    {},
                )


if __name__ == "__main__":
    unittest.main()
