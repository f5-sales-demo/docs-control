# ruff: noqa: INP001, PT009 -- existing standalone unittest test directory
"""Keep independently enforced ARC cohorts aligned for the new showcase."""

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class EnrollmentTests(unittest.TestCase):
    def test_both_validators_accept_owned_managed_routes(self):
        for script in ["audit-runner-workflows.py", "workflow_security_validator.py"]:
            spec = importlib.util.spec_from_file_location(
                "enrollment_" + script, ROOT / "scripts" / script
            )
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            self.assertIn("f5-sales-demo/custom-responses", module.MANAGED_ARC_COHORT)


if __name__ == "__main__":
    unittest.main()
