#!/usr/bin/env python3
"""Verify canonical discovery outputs independently from source machine indexes."""

import hashlib
import json
import sys
from pathlib import Path


def main() -> None:
    """Validate the rendered hierarchy against canonical source receipts."""
    source, output = map(Path, sys.argv[1:])
    receipt = json.loads((output / "llms-hierarchy-receipt.json").read_text())
    manifest_bytes = (source / "generated-manifest.json").read_bytes()
    expected = "sha256:" + hashlib.sha256(manifest_bytes).hexdigest()
    if receipt["sourceManifestSha256"] != expected or not receipt["linksVerified"]:
        message = "canonical hierarchy source or discovery verification mismatch"
        raise ValueError(message)
    pages = set()
    for name in json.loads(manifest_bytes)["files"]:
        if (
            name.startswith("documentation/")
            and name.endswith(".md")
            and "/_data/" not in name
        ):
            text = (source / name.removeprefix("documentation/")).read_text()
            line = next(
                line for line in text.splitlines() if line.startswith("xcsh_docs: ")
            )
            pages.add(json.loads(line.removeprefix("xcsh_docs: "))["id"])
    leaves = receipt["leaves"]
    if {leaf["id"] for leaf in leaves} != pages or len(leaves) != len(pages):
        message = "canonical hierarchy page coverage mismatch"
        raise ValueError(message)
    for leaf in leaves:
        data = (output / leaf["route"]).read_bytes()
        if (
            len(data) != leaf["bytes"]
            or "sha256:" + hashlib.sha256(data).hexdigest() != leaf["sha256"]
        ):
            message = "canonical leaf digest mismatch"
            raise ValueError(message)
    for scope in receipt["scopes"]:
        directory = output / scope
        for name, limit in (
            ("llms-small.txt", 4096),
            ("llms.txt", 16384),
            ("llms-full.txt", 16384),
        ):
            data = (directory / name).read_bytes()
            if scope == "" and name == "llms-full.txt":
                continue
            if len(data) > limit:
                message = "canonical index byte budget exceeded"
                raise ValueError(message)
    print(f"Verified hierarchy: {len(pages)} complete canonical leaves")


if __name__ == "__main__":
    main()
