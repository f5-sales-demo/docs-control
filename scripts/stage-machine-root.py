#!/usr/bin/env python3
# ruff: noqa: D103, EM101, EM102, TRY003
"""Reduce a built project Pages tree to the organization-root machine corpus."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

PROJECT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
REQUIRED_FILES = ("llms.txt", "llms-full.txt")
REQUIRED_DIRECTORIES = ("_llms-txt", "snapshot")


def _validate_identity(site: str, project: str) -> tuple[str, str]:
    parsed = urlsplit(site)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
        or not PROJECT_PATTERN.fullmatch(project)
    ):
        raise ValueError("site must be an HTTPS origin and project must be a safe slug")
    return site.rstrip("/"), project


def _validate_tree(root: Path) -> None:
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"required machine route is not a directory: {root.name}")
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in [*directories, *files]:
            path = current_path / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise ValueError(
                    f"symbolic link is forbidden in machine routes: {path}"
                )
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError(f"special file is forbidden in machine routes: {path}")
            if (
                stat.S_ISREG(mode)
                and root.name == "_llms-txt"
                and path.suffix != ".txt"
            ):
                raise ValueError(f"unexpected progressive route type: {path}")


def stage_machine_root(*, output: Path, site: str, project: str) -> None:
    site, project = _validate_identity(site, project)
    if output.is_symlink() or not output.is_dir():
        raise ValueError("documentation output must be a real directory")

    for name in REQUIRED_FILES:
        path = output / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"required machine route is missing or invalid: {name}")
    for name in REQUIRED_DIRECTORIES:
        _validate_tree(output / name)

    source_base = f"{site}/{project}/"
    target_base = f"{site}/"
    source_path = f"/{project}/"
    rewrites: dict[Path, str] = {}
    text_routes = [output / name for name in REQUIRED_FILES]
    text_routes.extend(sorted((output / "_llms-txt").rglob("*.txt")))
    for path in text_routes:
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError as error:
            raise ValueError(f"machine route is not UTF-8: {path}") from error
        rewrites[path.relative_to(output)] = text.replace(
            source_base, target_base
        ).replace(source_path, "/")

    staging = Path(tempfile.mkdtemp(prefix="machine-root-", dir=output.parent))
    backup = output.parent / f".{output.name}.machine-root-backup"
    try:
        for name in REQUIRED_FILES:
            shutil.copy2(output / name, staging / name)
        for name in REQUIRED_DIRECTORIES:
            shutil.copytree(output / name, staging / name)
        for relative, text in rewrites.items():
            (staging / relative).write_text(text, encoding="utf-8")
        if backup.exists() or backup.is_symlink():
            raise ValueError(f"machine-root backup path already exists: {backup}")
        output.rename(backup)
        try:
            staging.rename(output)
        except BaseException:
            backup.rename(output)
            raise
        shutil.rmtree(backup)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--site", required=True)
    parser.add_argument("--project", required=True)
    args = parser.parse_args()
    stage_machine_root(output=args.output, site=args.site, project=args.project)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
