"""Run actionlint on an equivalent view of GitHub self-repository references."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

import yaml
from yaml.nodes import MappingNode, ScalarNode, SequenceNode

if TYPE_CHECKING:
    from collections.abc import Iterator

    from yaml.nodes import Node


def values(node: Node | None, key: str) -> Iterator[Node]:
    """Keep duplicate keys and aliases while selecting a mapping field."""
    if isinstance(node, MappingNode):
        for name, value in node.value:
            if isinstance(name, ScalarNode) and name.value == key:
                yield value


def use_scalars(document: Node | None) -> Iterator[ScalarNode]:
    """Select only workflow job and step action references."""
    for jobs in values(document, "jobs"):
        if not isinstance(jobs, MappingNode):
            continue
        for _, job in jobs.value:
            for reference in values(job, "uses"):
                if isinstance(reference, ScalarNode):
                    yield reference
            for steps in values(job, "steps"):
                if not isinstance(steps, SequenceNode):
                    continue
                for step in steps.value:
                    for reference in values(step, "uses"):
                        if isinstance(reference, ScalarNode):
                            yield reference


def actionlint_source(source: str) -> str:
    """Adapt valid references without changing source positions or other data."""
    try:
        document = yaml.compose(source, Loader=yaml.SafeLoader)
    except yaml.YAMLError:
        return source  # actionlint still owns malformed YAML diagnostics.
    offsets = set()
    for reference in use_scalars(document):
        if not reference.value.startswith("$/"):
            continue
        token = source[reference.start_mark.index : reference.end_mark.index]
        match = re.match(r"(?:&[^\s]+\s+)?[\"\x27]?(?P<marker>\$)/", token)
        if match is not None:
            offsets.add(reference.start_mark.index + match.start("marker"))
    characters = list(source)
    for offset in offsets:
        characters[offset] = "."
    return "".join(characters)


def main() -> int:
    """Lint every workflow with the original repository configuration."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--actionlint", default="actionlint")
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    directory = root / ".github/workflows"
    workflows = sorted((*directory.glob("*.yml"), *directory.glob("*.yaml")))
    if not workflows:
        print("actionlint: no workflow files found", file=sys.stderr)
        return 2
    status = 0
    for workflow in workflows:
        command = [
            arguments.actionlint,
            "-config-file",
            str(root / ".github/actionlint.yaml"),
            "-stdin-filename",
            str(workflow),
            "-",
        ]
        result = subprocess.run(  # noqa: S603 -- exact CLI argv, no shell.
            command,
            input=actionlint_source(workflow.read_text(encoding="utf-8")),
            text=True,
            cwd=root,
            check=False,
        )
        if result.returncode:
            status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
