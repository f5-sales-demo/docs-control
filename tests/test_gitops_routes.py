"""Exact route guards for credentialed GitOps jobs."""

# unittest follows the existing validator suite.
# ruff: noqa: INP001, PT009
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class GitOpsRouteTests(unittest.TestCase):
    def test_only_exact_deploy_and_cleanup_events_are_accepted(self):
        for filename in ("audit-runner-workflows.py", "workflow_security_validator.py"):
            spec = importlib.util.spec_from_file_location(
                "gitops_routes", ROOT / "scripts" / filename
            )
            assert spec is not None
            assert spec.loader is not None
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            check = module.benchmark_trust_guard_is_allowed
            for workflow, job, event in (
                ("terraform-deploy.yml", "deploy", "push"),
                ("terraform-cleanup.yml", "cleanup", "delete"),
            ):
                path = ".github/workflows/" + workflow
                guard = (
                    "github.repository == 'f5-sales-demo/gitops' && "
                    f"(github.event_name == '{event}' || github.event_name == 'workflow_dispatch')"
                )
                self.assertTrue(
                    check("f5-sales-demo/gitops", path, job, "gitops-terraform", guard)
                )
                for repository, route, job_id, unsafe in (
                    ("foreign/gitops", path, job, guard),
                    ("f5-sales-demo/gitops", ".github/workflows/other.yml", job, guard),
                    ("f5-sales-demo/gitops", path, "other", guard),
                    (
                        "f5-sales-demo/gitops",
                        path,
                        job,
                        guard.replace(event, "pull_request"),
                    ),
                ):
                    self.assertFalse(
                        check(repository, route, job_id, "gitops-terraform", unsafe)
                    )
