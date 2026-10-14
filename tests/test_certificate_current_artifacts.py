"""Governed Certificate Management trigger and credential separation contracts."""

# ruff: noqa: INP001, PT009 -- Match repository unittest conventions.
import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class CertificateWorkflowTests(unittest.TestCase):
    def test_terraform_sources_deploy(self):
        workflow = yaml.safe_load(
            (ROOT / "workflows/github-pages-deploy.yml").read_text()
        )
        events = workflow.get("on", workflow.get(True))
        self.assertIn("terraform/**", events["push"]["paths"])

    def test_current_checks_are_governed_and_credential_free(self):
        config = json.loads((ROOT / ".github/config/repo-settings.json").read_text())
        mapping = next(
            entry
            for entry in config["managed_files"]["files"]
            if entry["src"] == "workflows/certificate-current-artifacts.yml"
        )
        self.assertEqual(mapping["only_repos"], ["certificate-management"])
        source = (ROOT / mapping["src"]).read_text()
        workflow = yaml.safe_load(source)
        events = workflow.get("on", workflow.get(True))
        self.assertIn("pull_request", events)
        self.assertIn("schedule", events)
        self.assertIn("workflow_dispatch", events)
        self.assertIn("repository_dispatch", events)
        self.assertNotIn("secrets.", source)
        self.assertIn("--check", source)
        commands = "\n".join(
            step.get("run", "")
            for job in workflow["jobs"].values()
            for step in job["steps"]
        )
        self.assertNotIn("qualify_certificates.py", commands)


if __name__ == "__main__":
    unittest.main()
