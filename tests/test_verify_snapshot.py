from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
VERIFIER_PATH = ROOT / "scripts" / "verify-snapshot.py"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "github-pages-deploy.yml"
TAG = "content-20260926T210000Z"
COMMIT = "1" * 40


def load_verifier():
    spec = importlib.util.spec_from_file_location("verify_snapshot", VERIFIER_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("cannot load snapshot verifier")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def markdown(source: str, title: str, asset: str) -> bytes:
    return (
        "---\n"
        f"sourceId: {source}\n"
        f"title: {title}\n"
        f"url: https://{source}.example.invalid/page\n"
        "---\n\n"
        f"# {title}\n\n![asset](assets/{asset})\n"
    ).encode()


def body_digest(data: bytes) -> str:
    body = data.decode().split("---\n", 2)[2].strip()
    return digest((body + "\n").encode())


def fixture_files() -> tuple[dict[str, bytes], dict[str, object]]:
    first = markdown("source-a", "Source A", "a.png")
    second = markdown("source-b", "Source B", "b.svg")
    asset_a = b"png\n"
    asset_b = b'<svg xmlns="http://www.w3.org/2000/svg"/>\n'
    documents: list[dict[str, object]] = []
    for source, path, data in (
        ("source-a", "content/source-a/page/index.md", first),
        ("source-b", "content/source-b/page/index.md", second),
    ):
        documents.append(
            {
                "sourceId": source,
                "url": f"https://{source}.example.invalid/page",
                "path": path,
                "body_sha256": body_digest(data),
                "file_sha256": digest(data),
                "size_bytes": len(data),
            }
        )
    assets: list[dict[str, object]] = []
    for path, data, media_type in (
        ("content/source-a/page/assets/a.png", asset_a, "image/png"),
        ("content/source-b/page/assets/b.svg", asset_b, "image/svg+xml"),
    ):
        assets.append(
            {
                "path": path,
                "sha256": digest(data),
                "media_type": media_type,
                "size_bytes": len(data),
            }
        )
    manifest = {
        "schema_version": 2,
        "source_roots": {
            "source-a": "https://source-a.example.invalid/",
            "source-b": "https://source-b.example.invalid/",
        },
        "page_count": 2,
        "asset_count": 2,
        "documents": documents,
        "assets": assets,
    }
    files: dict[str, bytes] = {
        str(documents[0]["path"]): first,
        str(documents[1]["path"]): second,
        str(assets[0]["path"]): asset_a,
        str(assets[1]["path"]): asset_b,
        "manifest.json": (json.dumps(manifest, sort_keys=True) + "\n").encode(),
        "quality-report.json": b'{"status":"accepted"}\n',
        "quality-report.md": b"# Quality\n\nAccepted.\n",
    }
    sums = "".join(f"{digest(files[name])}  {name}\n" for name in sorted(files))
    files["SHA256SUMS"] = sums.encode()
    return files, manifest


def write_archive(path: Path, files: dict[str, bytes], extra_members=()) -> None:
    with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for name, data in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        for info, data in extra_members:
            archive.addfile(info, io.BytesIO(data) if data is not None else None)


def write_release(
    root: Path, *, receipt_tag: str = TAG, receipt_commit: str = COMMIT
) -> str:
    files, _ = fixture_files()
    archive = root / "html-to-markdown-content.tar.gz"
    write_archive(archive, files)
    outer = {
        "html-to-markdown-content.tar.gz": archive.read_bytes(),
        "html-to-markdown-content.tar.gz.sha256": (
            f"{digest(archive.read_bytes())}  html-to-markdown-content.tar.gz\n"
        ).encode(),
        "manifest.json": files["manifest.json"],
        "quality-report.json": files["quality-report.json"],
        "quality-report.md": files["quality-report.md"],
    }
    for name, data in outer.items():
        (root / name).write_bytes(data)
    receipt = {
        "schema_version": 1,
        "release_tag": receipt_tag,
        "source_commit": receipt_commit,
        "created_at": "2026-09-26T20:00:00Z",
        "published_at": "2026-09-26T21:00:00Z",
        "assets": [
            {"name": name, "size_bytes": len(data), "sha256": digest(data)}
            for name, data in outer.items()
        ],
    }
    receipt_path = root / "publication.json"
    receipt_path.write_text(
        json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8"
    )
    return digest(receipt_path.read_bytes())


class SnapshotVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        temp_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, temp_dir)
        self.root = Path(temp_dir)
        self.release = self.root / "release"
        self.output = self.root / "output"
        self.release.mkdir()
        self.receipt_sha = write_release(self.release)
        self.verifier = load_verifier()

    def verify(self) -> None:
        self.verifier.verify_and_extract(
            self.release,
            tag=TAG,
            publication_sha256=self.receipt_sha,
            source_commit=COMMIT,
            output=self.output,
        )

    def test_valid_release_extracts_the_exact_verified_tree(self) -> None:
        self.verify()
        self.assertTrue((self.output / "manifest.json").is_file())
        self.assertTrue((self.output / "content/source-a/page/index.md").is_file())
        self.assertTrue((self.output / "quality-report.md").is_file())

    def test_publication_contract_rejects_closed_set_and_identity_mismatches(
        self,
    ) -> None:
        cases = (
            "missing",
            "extra",
            "receipt-digest",
            "asset-size",
            "asset-digest",
            "tag",
            "commit",
        )
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as raw:
                release = Path(raw)
                receipt_sha = write_release(release)
                receipt = json.loads((release / "publication.json").read_text())
                expected_tag = TAG
                expected_commit = COMMIT
                if case == "missing":
                    (release / "quality-report.md").unlink()
                elif case == "extra":
                    (release / "unexpected.txt").write_text("extra")
                elif case == "receipt-digest":
                    receipt_sha = "0" * 64
                elif case == "asset-size":
                    receipt["assets"][0]["size_bytes"] += 1
                    (release / "publication.json").write_text(json.dumps(receipt))
                    receipt_sha = digest((release / "publication.json").read_bytes())
                elif case == "asset-digest":
                    receipt["assets"][0]["sha256"] = "0" * 64
                    (release / "publication.json").write_text(json.dumps(receipt))
                    receipt_sha = digest((release / "publication.json").read_bytes())
                elif case == "tag":
                    expected_tag = "content-20260926T220000Z"
                elif case == "commit":
                    expected_commit = "2" * 40
                with self.assertRaises(ValueError):
                    self.verifier.verify_and_extract(
                        release,
                        tag=expected_tag,
                        publication_sha256=receipt_sha,
                        source_commit=expected_commit,
                        output=release / "out",
                    )

    def test_archive_rejects_checksum_manifest_and_outer_copy_mismatches(self) -> None:
        for case in ("archive-checksum", "member-checksum", "manifest", "outer-copy"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as raw:
                release = Path(raw)
                receipt_sha = write_release(release)
                if case == "archive-checksum":
                    (release / "html-to-markdown-content.tar.gz.sha256").write_text(
                        f"{'0' * 64}  html-to-markdown-content.tar.gz\n"
                    )
                else:
                    files, manifest = fixture_files()
                    if case == "member-checksum":
                        files["SHA256SUMS"] = files["SHA256SUMS"].replace(b"a", b"b", 1)
                    elif case == "manifest":
                        manifest["schema_version"] = 1
                        files["manifest.json"] = (json.dumps(manifest) + "\n").encode()
                        files["SHA256SUMS"] = "".join(
                            f"{digest(files[name])}  {name}\n"
                            for name in sorted(files)
                            if name != "SHA256SUMS"
                        ).encode()
                    elif case == "outer-copy":
                        (release / "manifest.json").write_text("{}\n")
                    if case != "outer-copy":
                        write_archive(
                            release / "html-to-markdown-content.tar.gz", files
                        )
                receipt_sha = refresh_receipt(release)
                with self.assertRaises(ValueError):
                    self.verifier.verify_and_extract(
                        release,
                        tag=TAG,
                        publication_sha256=receipt_sha,
                        source_commit=COMMIT,
                        output=release / "out",
                    )

    def test_archive_rejects_traversal_links_duplicates_and_limits(self) -> None:
        cases = (
            "traversal",
            "symlink",
            "duplicate",
            "members",
            "expanded",
            "markdown",
            "asset",
        )
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as raw:
                release = Path(raw)
                write_release(release)
                files, _ = fixture_files()
                extra: list[tuple[tarfile.TarInfo, bytes | None]] = []
                if case == "traversal":
                    info = tarfile.TarInfo("../escape")
                    info.size = 1
                    extra = [(info, b"x")]
                elif case == "symlink":
                    info = tarfile.TarInfo("content/source-a/page/assets/link")
                    info.type = tarfile.SYMTYPE
                    info.linkname = "/etc/passwd"
                    extra = [(info, None)]
                elif case == "duplicate":
                    name = "manifest.json"
                    info = tarfile.TarInfo(name)
                    info.size = len(files[name])
                    extra = [(info, files[name])]
                elif case == "members":
                    self.verifier.MAX_MEMBERS = 1
                elif case == "expanded":
                    self.verifier.MAX_EXPANDED_BYTES = 1
                elif case == "markdown":
                    self.verifier.MAX_MARKDOWN_BYTES = 1
                elif case == "asset":
                    self.verifier.MAX_ASSET_BYTES = 1
                write_archive(release / "html-to-markdown-content.tar.gz", files, extra)
                receipt_sha = refresh_receipt(release)
                with self.assertRaises(ValueError):
                    self.verifier.verify_and_extract(
                        release,
                        tag=TAG,
                        publication_sha256=receipt_sha,
                        source_commit=COMMIT,
                        output=release / "out",
                    )


def refresh_receipt(release: Path) -> str:
    receipt = json.loads((release / "publication.json").read_text())
    for entry in receipt["assets"]:
        data = (release / entry["name"]).read_bytes()
        entry["size_bytes"] = len(data)
        entry["sha256"] = digest(data)
    path = release / "publication.json"
    path.write_text(json.dumps(receipt, sort_keys=True) + "\n")
    return digest(path.read_bytes())


class SnapshotWorkflowTests(unittest.TestCase):
    def test_reusable_workflow_has_fail_closed_snapshot_contract(self) -> None:
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        inputs = workflow[True]["workflow_call"]["inputs"]
        for name in (
            "snapshot-tag",
            "publication-sha256",
            "snapshot-verifier-ref",
        ):
            self.assertIn(name, inputs)
        self.assertFalse(inputs["snapshot-verifier-ref"]["required"])
        self.assertEqual(inputs["snapshot-verifier-ref"]["default"], "")
        steps = workflow["jobs"]["build"]["steps"]
        by_name = {step.get("name"): step for step in steps}
        resolve = by_name["Resolve immutable content commit"]
        self.assertNotIn("REQUESTED_REPOSITORY", resolve["env"])
        checkout_content = by_name["Checkout content repo"]
        self.assertNotIn("repository", checkout_content["with"])
        checked_out = by_name["Verify checked-out content commit"]
        self.assertEqual(
            checked_out["env"]["SNAPSHOT_TAG"], "${{ inputs.snapshot-tag }}"
        )
        self.assertIn(
            '"repos/${CONTENT_REPOSITORY}/compare/${CONTENT_REF}...${PROTECTED_MAIN_SHA}"',
            checked_out["run"],
        )
        self.assertIn('[ "$relation" != ahead ]', checked_out["run"])
        self.assertIn("Checkout immutable snapshot verifier", by_name)
        self.assertIn("Download and verify exact snapshot", by_name)
        self.assertNotIn("Stage root machine-only artifact", by_name)
        validation = by_name["Validate immutable snapshot request"]
        self.assertEqual(
            validation["env"]["SNAPSHOT_VERIFIER_REF"],
            "${{ inputs.snapshot-verifier-ref }}",
        )
        self.assertIn(
            '[[ ! "$SNAPSHOT_VERIFIER_REF" =~ ^[0-9a-f]{40}$ ]]',
            validation["run"],
        )
        checkout = by_name["Checkout immutable snapshot verifier"]
        self.assertEqual(checkout["with"]["ref"], "${{ inputs.snapshot-verifier-ref }}")
        verify = by_name["Download and verify exact snapshot"]["run"]
        self.assertIn('gh release download "$SNAPSHOT_TAG"', verify)
        self.assertNotIn("latest", verify.casefold())
        self.assertIn("verify-snapshot.py", verify)
        build = by_name["Build docs with container"]["run"]
        self.assertIn(":/content/machine-corpus:ro", build)
        self.assertIn("MACHINE_CORPUS_DIR=/content/machine-corpus", build)
        builder = by_name["Resolve approved documentation builder"]["run"]
        self.assertIn("snapshot builds require an immutable builder digest", builder)

    def test_registry_and_governance_preserve_the_repository_local_corpus(self) -> None:
        sites = json.loads((ROOT / ".github/config/docs-sites.json").read_text())
        site = next(item for item in sites if item["label"] == "F5 Docs Corpus")
        self.assertEqual(
            site["url"], "https://f5-sales-demo.github.io/html-to-markdown/llms.txt"
        )
        self.assertFalse(site["rebuild_dispatch"])
        governance = json.loads((ROOT / ".claude/governance.json").read_text())
        self.assertIn(
            ".github/workflows/github-pages-deploy.yml",
            governance["skip_files"]["html-to-markdown"],
        )
        self.assertIn("f5-sales-demo.github.io", governance["repo_classes"]["repos"])
        self.assertIn("f5-sales-demo.github.io", governance["skip_files"])


if __name__ == "__main__":
    unittest.main()
