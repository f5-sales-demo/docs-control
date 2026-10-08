# ruff: noqa: PT009, INP001 -- standard-library unittest assertions
"""Execute the governed Custom Responses preparation step exactly."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class CustomResponsePagesTests(unittest.TestCase):
    def test_exact_step_propagates_preparation_failure(self):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/github-pages-deploy.yml").read_text()
        )
        steps = workflow["jobs"]["build"]["steps"]
        names = [s.get("name") for s in steps]
        name = "Prepare Custom Responses configuration snippets"
        self.assertIn(name, names)
        self.assertLess(
            names.index("Verify checked-out content commit"), names.index(name)
        )
        self.assertLess(names.index(name), names.index("Build docs with container"))
        step = steps[names.index(name)]
        self.assertEqual(
            step["if"], "github.repository == 'f5-sales-demo/custom-responses'"
        )
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "scripts").mkdir()
            script = root / "scripts/prepare_snippets.py"
            for status in [0, 9]:
                script.write_text(f"raise SystemExit({status})\n")
                result = subprocess.run(  # noqa: S603 -- execute the trusted repository workflow block
                    ["/bin/bash", "-c", step["run"]],
                    cwd=root,
                    env=os.environ.copy(),
                    check=False,
                )
                self.assertEqual(result.returncode, status)

    def test_source_caller_is_scoped_and_complete(self):
        path = ".github/workflows/github-pages-config-sources.yml"
        source = ROOT / "workflows/github-pages-config-sources.yml"
        workflow = yaml.safe_load(source.read_text())
        # PyYAML's YAML 1.1 boolean interpretation of 'on'.
        trigger = workflow.get("on", workflow.get(True))
        paths = trigger["push"]["paths"]
        for entry in [
            "terraform/scenarios.tf.json",
            "examples/bot-defense.json",
            "scripts/prepare_snippets.py",
        ]:
            self.assertIn(entry, paths)
        self.assertEqual(trigger["push"]["branches"], ["main"])
        self.assertIn(
            "github.repository == 'f5-sales-demo/custom-responses'",
            workflow["jobs"]["docs"]["if"],
        )
        config = json.loads((ROOT / ".github/config/repo-settings.json").read_text())
        entries = [e for e in config["managed_files"]["files"] if e["dest"] == path]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["only_repos"], ["custom-responses"])
        prose_caller = (ROOT / "workflows/github-pages-deploy.yml").read_text()
        self.assertIn("shared-mode: auto", prose_caller)
        self.assertIn(
            "sha256:eaf57b7f92b26ab11e69420564dad4d3ad194ac7203ed7e292a04a230ed83d29",
            prose_caller,
        )


if __name__ == "__main__":
    unittest.main()
