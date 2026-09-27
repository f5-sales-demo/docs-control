# ruff: noqa: EM101, INP001, PT009, PT027, TRY003
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
SCRIPT_PATH = ROOT / "scripts" / "stage-machine-root.py"


def load_module():
    spec = importlib.util.spec_from_file_location("stage_machine_root", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("cannot load machine-root staging helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StageMachineRootTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()

    def test_keeps_only_machine_routes_and_rewrites_project_urls(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "docs-output"
            (output / "_llms-txt" / "source").mkdir(parents=True)
            (output / "snapshot" / "assets").mkdir(parents=True)
            (output / "_astro").mkdir()
            project_url = "https://f5-sales-demo.github.io/html-to-markdown/"
            root_url = "https://f5-sales-demo.github.io/"
            (output / "llms.txt").write_text(
                f"[Source]({project_url}_llms-txt/source.txt)\n"
            )
            (output / "llms-full.txt").write_text(
                f"[Leaf]({project_url}_llms-txt/source/leaf.txt)\n"
            )
            (output / "_llms-txt" / "source.txt").write_text(
                f"[Leaf]({project_url}_llms-txt/source/leaf.txt)\n"
            )
            (output / "_llms-txt" / "source" / "leaf.txt").write_text(
                f"![Asset]({project_url}snapshot/assets/image.png)\n"
            )
            asset = b"png fixture"
            (output / "snapshot" / "assets" / "image.png").write_bytes(asset)
            (output / "snapshot" / "manifest.json").write_text("{}\n")
            (output / "index.html").write_text("human page")
            (output / "404.html").write_text("not found")
            (output / "_astro" / "bundle.js").write_text("javascript")

            self.module.stage_machine_root(
                output=output,
                site="https://f5-sales-demo.github.io",
                project="html-to-markdown",
            )

            self.assertEqual(
                {path.name for path in output.iterdir()},
                {"_llms-txt", "llms-full.txt", "llms.txt", "snapshot"},
            )
            for route in [output / "llms.txt", *output.glob("_llms-txt/**/*.txt")]:
                text = route.read_text()
                self.assertNotIn(project_url, text)
                self.assertIn(root_url, text)
            self.assertEqual(
                (output / "snapshot" / "assets" / "image.png").read_bytes(), asset
            )
            self.assertFalse(any(output.rglob("*.html")))

    def test_rejects_symlinks_in_preserved_routes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "docs-output"
            (output / "_llms-txt").mkdir(parents=True)
            (output / "snapshot").mkdir()
            (output / "llms.txt").write_text("entry\n")
            (output / "llms-full.txt").write_text("inventory\n")
            (output / "outside.txt").write_text("outside\n")
            (output / "_llms-txt" / "escape.txt").symlink_to(output / "outside.txt")

            with self.assertRaises(ValueError):
                self.module.stage_machine_root(
                    output=output,
                    site="https://f5-sales-demo.github.io",
                    project="html-to-markdown",
                )

    def test_rejects_invalid_site_or_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with self.assertRaises(ValueError):
                self.module.stage_machine_root(
                    output=output,
                    site="http://f5-sales-demo.github.io",
                    project="../html-to-markdown",
                )


if __name__ == "__main__":
    unittest.main()
