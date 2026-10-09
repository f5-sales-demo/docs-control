#!/usr/bin/env python3
# ruff: noqa: D103, EM101, EM102, PLR2004, TRY003, TRY004
# pylint: disable=invalid-name
"""Verify and extract one immutable html-to-markdown snapshot publication."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import re
import tarfile
from pathlib import Path, PurePosixPath

MIB = 1024 * 1024
MAX_ARCHIVE_BYTES = 1024 * MIB
MAX_EXPANDED_BYTES = 1024 * MIB
MAX_MEMBERS = 20_000
MAX_MARKDOWN_BYTES = 2 * MIB
MAX_ASSET_BYTES = 20 * MIB
MAX_METADATA_BYTES = 20 * MIB
TAG_PATTERN = re.compile(r"^content-[0-9]{8}T[0-9]{6}Z$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
TIMESTAMP_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
)
ARCHIVE_NAME = "html-to-markdown-content.tar.gz"
RELEASE_ASSETS = {
    ARCHIVE_NAME,
    f"{ARCHIVE_NAME}.sha256",
    "manifest.json",
    "quality-report.json",
    "quality-report.md",
}
ALL_RELEASE_ASSETS = RELEASE_ASSETS | {"publication.json"}
ARCHIVE_METADATA = {
    "manifest.json",
    "quality-report.json",
    "quality-report.md",
    "SHA256SUMS",
}


def sha256_file(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(MIB), b""):
            value.update(chunk)
    return value.hexdigest()


def _safe_path(value: object, label: str) -> PurePosixPath:
    if not isinstance(value, str):
        raise ValueError(f"{label} is not a string")
    path = PurePosixPath(value)
    encoded = value.casefold()
    if not value or value.startswith("/") or "\\" in value:
        raise ValueError(f"{label} is unsafe: {value}")
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError(f"{label} is unsafe: {value}")
    if "%2f" in encoded or "%5c" in encoded:
        raise ValueError(f"{label} is unsafe: {value}")
    return path


def _json_bytes(value: bytes, label: str) -> object:
    if len(value) > MAX_METADATA_BYTES:
        raise ValueError(f"{label} exceeds {MAX_METADATA_BYTES} bytes")
    try:
        return json.loads(value.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not valid UTF-8 JSON") from error


def _normalize_body(body: str) -> str:
    value = body.replace("\r\n", "\n").replace("\r", "\n")
    value = "\n".join(line.rstrip() for line in value.splitlines())
    value = re.sub(r"\n{3,}", "\n\n", value).strip()
    return f"{value}\n"


def _frontmatter(document: bytes, path: str) -> tuple[dict[str, str], str]:
    try:
        text = document.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"Markdown member is not UTF-8: {path}") from error
    match = re.match(r"^---\n(.*?)\n---\n\n?(.*)$", text, re.DOTALL)
    if not match:
        raise ValueError(f"Markdown member has invalid frontmatter: {path}")
    values: dict[str, str] = {}
    for line in match.group(1).splitlines():
        field = re.match(r"^(sourceId|url):\s*(.*?)\s*$", line)
        if field:
            raw = field.group(2)
            if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {'"', "'"}:
                raw = raw[1:-1]
            values[field.group(1)] = raw
    return values, _normalize_body(match.group(2))


def _parse_sums(raw: bytes) -> dict[str, str]:
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValueError("SHA256SUMS is not UTF-8") from error
    result: dict[str, str] = {}
    for line in lines:
        fields = line.split("  ", 1)
        if len(fields) != 2 or not SHA256_PATTERN.fullmatch(fields[0]):
            raise ValueError("SHA256SUMS contains a malformed entry")
        name = fields[1]
        _safe_path(name, "SHA256SUMS path")
        if name in result:
            raise ValueError(f"SHA256SUMS contains a duplicate entry: {name}")
        result[name] = fields[0]
    return result


def _read_archive(archive_path: Path) -> dict[str, bytes]:
    if archive_path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError(f"archive exceeds {MAX_ARCHIVE_BYTES} bytes")
    files: dict[str, bytes] = {}
    expanded = 0
    with tarfile.open(archive_path, mode="r:gz") as archive:
        members = archive.getmembers()
        if not members or len(members) > MAX_MEMBERS:
            raise ValueError("archive member count is invalid")
        for member in members:
            _safe_path(member.name, "archive member path")
            if member.name in files:
                raise ValueError(f"archive contains a duplicate member: {member.name}")
            if not member.isfile():
                raise ValueError(f"archive member type is not allowed: {member.name}")
            if member.name.endswith("/index.md") and member.size > MAX_MARKDOWN_BYTES:
                raise ValueError(
                    f"Markdown member exceeds {MAX_MARKDOWN_BYTES} bytes: {member.name}"
                )
            if "/assets/" in member.name and member.size > MAX_ASSET_BYTES:
                raise ValueError(
                    f"asset member exceeds {MAX_ASSET_BYTES} bytes: {member.name}"
                )
            if member.name in ARCHIVE_METADATA and member.size > MAX_METADATA_BYTES:
                raise ValueError(
                    f"metadata member exceeds {MAX_METADATA_BYTES} bytes: {member.name}"
                )
            expanded += member.size
            if expanded > MAX_EXPANDED_BYTES:
                raise ValueError(f"expanded payload exceeds {MAX_EXPANDED_BYTES} bytes")
            handle = archive.extractfile(member)
            if handle is None:
                raise ValueError(f"archive member cannot be read: {member.name}")
            data = handle.read(member.size + 1)
            if len(data) != member.size:
                raise ValueError(f"archive member size mismatch: {member.name}")
            files[member.name] = data
    return files


def _validate_document(
    entry: object,
    files: dict[str, bytes],
    source_roots: dict[str, object],
    seen: set[str],
) -> None:
    if not isinstance(entry, dict):
        raise ValueError("manifest document entry must be an object")
    source = entry.get("sourceId")
    path = entry.get("path")
    if not isinstance(source, str) or "/" in source:
        raise ValueError("manifest document source is invalid")
    _safe_path(source, "manifest document source")
    if source not in source_roots or not isinstance(source_roots[source], str):
        raise ValueError(f"manifest document source is undeclared: {source}")
    _safe_path(path, "manifest document path")
    prefix = f"content/{source}/"
    if (
        not isinstance(path, str)
        or not path.startswith(prefix)
        or not path.endswith("/index.md")
        or path in seen
        or path not in files
    ):
        raise ValueError(
            f"manifest document is missing, duplicated, or misplaced: {path}"
        )
    seen.add(path)
    data = files[path]
    metadata, body = _frontmatter(data, path)
    if metadata.get("sourceId") != source:
        raise ValueError(f"manifest document source mismatch: {path}")
    if metadata.get("url") != entry.get("url"):
        raise ValueError(f"manifest document URL mismatch: {path}")
    if entry.get("size_bytes") != len(data):
        raise ValueError(f"manifest document size mismatch: {path}")
    if entry.get("file_sha256") != hashlib.sha256(data).hexdigest():
        raise ValueError(f"manifest document file hash mismatch: {path}")
    if entry.get("body_sha256") != hashlib.sha256(body.encode()).hexdigest():
        raise ValueError(f"manifest document body hash mismatch: {path}")


def _validate_asset(
    entry: object,
    files: dict[str, bytes],
    source_roots: dict[str, object],
    seen: set[str],
) -> None:
    if not isinstance(entry, dict):
        raise ValueError("manifest asset entry must be an object")
    path = entry.get("path")
    parsed = _safe_path(path, "manifest asset path")
    source = parsed.parts[1] if len(parsed.parts) > 1 else ""
    if not isinstance(path, str):
        raise ValueError(f"manifest asset is missing, duplicated, or misplaced: {path}")
    if (
        len(parsed.parts) < 5
        or parsed.parts[0] != "content"
        or source not in source_roots
        or "assets" not in parsed.parts[2:-1]
    ):
        raise ValueError(f"manifest asset is missing, duplicated, or misplaced: {path}")
    if path in seen or path not in files:
        raise ValueError(f"manifest asset is missing, duplicated, or misplaced: {path}")
    seen.add(path)
    data = files[path]
    if entry.get("size_bytes") != len(data):
        raise ValueError(f"manifest asset size mismatch: {path}")
    if entry.get("sha256") != hashlib.sha256(data).hexdigest():
        raise ValueError(f"manifest asset hash mismatch: {path}")
    media_type = mimetypes.guess_type(parsed.name)[0] or "application/octet-stream"
    if entry.get("media_type") != media_type:
        raise ValueError(f"manifest asset media type mismatch: {path}")


def validate_enrichment_aliases(manifest: dict[str, object]) -> None:
    enrichment = manifest.get("enrichment")
    if enrichment is None:
        return
    if not isinstance(enrichment, dict) or not re.fullmatch(
        r"[0-9a-f]{64}", str(enrichment.get("artifact_sha256", ""))
    ):
        raise ValueError("invalid enrichment artifact pin")
    aliases = enrichment.get("aliases")
    if not isinstance(aliases, list):
        raise ValueError("invalid enrichment alias mapping")
    documents = manifest["documents"]
    roots = manifest["source_roots"]
    if not isinstance(documents, list) or not isinstance(roots, dict):
        raise ValueError("invalid enrichment corpus inventory")
    paths = {document["path"] for document in documents}
    seen: set[str] = set()
    for alias in aliases:
        if not isinstance(alias, dict) or set(alias) != {"path", "target", "url"}:
            raise ValueError("invalid enrichment alias entry")
        source = alias["path"]
        parsed = _safe_path(source, "alias path")
        if (
            len(parsed.parts) < 4
            or parsed.parts[0] != "content"
            or parsed.parts[1] not in roots
            or not source.endswith("/index.md")
        ):
            raise ValueError("alias source is outside the corpus")
        if (
            source in seen
            or source in paths
            or alias["target"] not in paths
            or source == alias["target"]
        ):
            raise ValueError("alias collision or missing canonical target")
        if not isinstance(alias["url"], str) or not alias["url"].startswith("https://"):
            raise ValueError("invalid alias URL")
        seen.add(source)


def _validate_manifest(raw: bytes, files: dict[str, bytes]) -> None:
    manifest = _json_bytes(raw, "manifest")
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 2:
        raise ValueError("manifest schema version is invalid")
    source_roots = manifest.get("source_roots")
    documents = manifest.get("documents")
    assets = manifest.get("assets")
    if not isinstance(source_roots, dict) or not source_roots:
        raise ValueError("manifest source roots are invalid")
    if not isinstance(documents, list) or not isinstance(assets, list):
        raise ValueError("manifest documents and assets must be lists")
    validate_enrichment_aliases(manifest)
    for source, url in source_roots.items():
        _safe_path(source, "manifest source")
        if "/" in source or not isinstance(url, str) or not url.startswith("https://"):
            raise ValueError(f"manifest source root is invalid: {source}")
    seen: set[str] = set()
    for document in documents:
        _validate_document(document, files, source_roots, seen)
    for asset in assets:
        _validate_asset(asset, files, source_roots, seen)
    if manifest.get("page_count") != len(documents):
        raise ValueError("manifest page count does not match entries")
    if manifest.get("asset_count") != len(assets):
        raise ValueError("manifest asset count does not match entries")
    content_files = {name for name in files if name.startswith("content/")}
    if seen != content_files:
        raise ValueError("manifest content member set mismatch")
    if set(files) != seen | ARCHIVE_METADATA:
        raise ValueError("archive contains an unknown or missing member")


def _validate_snapshot_identity(
    tag: str, publication_sha256: str, source_commit: str
) -> None:
    if not TAG_PATTERN.fullmatch(tag):
        raise ValueError("snapshot tag is invalid")
    if not SHA256_PATTERN.fullmatch(publication_sha256):
        raise ValueError("publication digest is invalid")
    if not COMMIT_PATTERN.fullmatch(source_commit):
        raise ValueError("snapshot source commit is invalid")


def _validate_receipt_timestamps(receipt: dict[str, object]) -> None:
    for key in ("created_at", "published_at"):
        value = receipt.get(key)
        if not isinstance(value, str) or not TIMESTAMP_PATTERN.fullmatch(value):
            raise ValueError(f"publication receipt {key} is invalid")


def _validate_publication(
    release_dir: Path,
    *,
    tag: str,
    publication_sha256: str,
    source_commit: str,
) -> None:
    _validate_snapshot_identity(tag, publication_sha256, source_commit)
    entries = list(release_dir.iterdir())
    if any(path.is_symlink() or not path.is_file() for path in entries):
        raise ValueError("release download contains a non-regular asset")
    if {path.name for path in entries} != ALL_RELEASE_ASSETS:
        raise ValueError("publication asset set mismatch")
    receipt_path = release_dir / "publication.json"
    if sha256_file(receipt_path) != publication_sha256:
        raise ValueError("publication receipt digest mismatch")
    receipt = _json_bytes(receipt_path.read_bytes(), "publication receipt")
    if not isinstance(receipt, dict) or receipt.get("schema_version") != 1:
        raise ValueError("publication receipt schema is invalid")
    if receipt.get("release_tag") != tag:
        raise ValueError("publication receipt tag mismatch")
    if receipt.get("source_commit") != source_commit:
        raise ValueError("publication receipt source commit mismatch")
    _validate_receipt_timestamps(receipt)
    assets = receipt.get("assets")
    if not isinstance(assets, list):
        raise ValueError("publication receipt assets must be a list")
    by_name: dict[str, dict[str, object]] = {}
    for asset in assets:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            raise ValueError("publication receipt asset entry is invalid")
        name = asset["name"]
        if name in by_name:
            raise ValueError(f"publication receipt asset is duplicated: {name}")
        by_name[name] = asset
    if set(by_name) != RELEASE_ASSETS:
        raise ValueError("publication receipt asset set mismatch")
    for name, entry in by_name.items():
        path = release_dir / name
        if entry.get("size_bytes") != path.stat().st_size:
            raise ValueError(f"publication asset size mismatch: {name}")
        if entry.get("sha256") != sha256_file(path):
            raise ValueError(f"publication asset digest mismatch: {name}")


def verify_and_extract(
    release_dir: Path,
    *,
    tag: str,
    publication_sha256: str,
    source_commit: str,
    output: Path,
) -> None:
    """Verify every publication layer before writing the extracted corpus."""
    release_dir = release_dir.resolve(strict=True)
    _validate_publication(
        release_dir,
        tag=tag,
        publication_sha256=publication_sha256,
        source_commit=source_commit,
    )
    archive_path = release_dir / ARCHIVE_NAME
    checksum = (release_dir / f"{ARCHIVE_NAME}.sha256").read_bytes()
    sums = _parse_sums(checksum)
    if sums != {ARCHIVE_NAME: sha256_file(archive_path)}:
        raise ValueError("outer archive checksum is invalid")
    files = _read_archive(archive_path)
    if not set(files) >= ARCHIVE_METADATA:
        raise ValueError("archive is missing required metadata")
    inner_sums = _parse_sums(files["SHA256SUMS"])
    expected = set(files) - {"SHA256SUMS"}
    if set(inner_sums) != expected:
        raise ValueError("SHA256SUMS member set mismatch")
    for name, expected_digest in inner_sums.items():
        if hashlib.sha256(files[name]).hexdigest() != expected_digest:
            raise ValueError(f"SHA256SUMS digest mismatch: {name}")
    for name in ("manifest.json", "quality-report.json", "quality-report.md"):
        if files[name] != (release_dir / name).read_bytes():
            raise ValueError(f"outer and archived {name} differ")
    _validate_manifest(files["manifest.json"], files)
    if output.exists() and any(output.iterdir()):
        raise ValueError("snapshot output directory must be empty")
    output.mkdir(parents=True, exist_ok=True)
    for name in sorted(files):
        target = output.joinpath(*PurePosixPath(name).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(files[name])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-dir", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--publication-sha256", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    verify_and_extract(
        args.release_dir,
        tag=args.tag,
        publication_sha256=args.publication_sha256,
        source_commit=args.source_commit,
        output=args.output,
    )
    print(f"Verified immutable snapshot {args.tag} from {args.source_commit}")


if __name__ == "__main__":
    main()
