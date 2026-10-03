import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CanadaInventoryTests(unittest.TestCase):
    def test_enrollment(self):
        config = ROOT / ".github/config"
        self.assertIn("canada-topology", json.loads((config / "downstream-repos.json").read_text()))
        governance = json.loads((ROOT / ".claude/governance.json").read_text())
        self.assertEqual(governance["repo_classes"]["repos"]["canada-topology"], "content")
        sites = json.loads((config / "docs-sites.json").read_text())
        site = next(s for s in sites if s["url"] == "https://f5-sales-demo.github.io/canada-topology/llms-full.txt")
        self.assertTrue(site["readme_english_only"])
        policy = json.loads((config / "self-hosted-runner-policy.json").read_text())
        self.assertEqual(set(policy["repositories"]["f5-sales-demo/canada-topology"]["runner"]["arc_scale_sets"]), {"socketless", "container-build"})

    def test_managed_readme(self):
        config = json.loads((ROOT / ".github/config/repo-settings.json").read_text())
        entry = next(e for e in config["managed_files"]["files"] if e["dest"] == "README.md")
        self.assertEqual(entry["only_repos"], ["canada-topology"])
        readme = (ROOT / entry["src"]).read_text()
        self.assertIn("https://f5-sales-demo.github.io/canada-topology/", readme)
        self.assertNotIn("enforce-repo-settings.yml", readme)
        self.assertIn("canada-topology", readme)


if __name__ == "__main__":
    unittest.main()
