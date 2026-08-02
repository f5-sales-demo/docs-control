"""Roll every governed docs-control workflow caller to one immutable revision."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REVISION = re.compile(r"[0-9a-f]{40}")
CALL = re.compile(
    r"(?P<prefix>uses:\s*f5-sales-demo/docs-control/\.github/workflows/"
    r"(?P<workflow>[^@\s]+)@)[0-9a-f]{40}(?P<suffix>\s*(?:#.*)?)$",
    re.MULTILINE,
)


class PinUpdateError(ValueError):
    """Raised when governed workflow pin inputs are incomplete or invalid."""


def update(root: Path, revision: str) -> tuple[int, tuple[str, ...]]:
    """Update governed callers and return the change count and reusable paths."""
    if not REVISION.fullmatch(revision):
        message = "revision must be a full lowercase 40-character commit SHA"
        raise PinUpdateError(message)

    workflow_dir = root / "workflows"
    paths = sorted((*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")))
    if not paths:
        message = f"no governed workflow callers found under {workflow_dir}"
        raise PinUpdateError(message)

    workflow_names: set[str] = set()
    rendered: dict[Path, str] = {}
    total_calls = 0
    for path in paths:
        source = path.read_text(encoding="utf-8")
        matches = list(CALL.finditer(source))
        workflow_names.update(match.group("workflow") for match in matches)
        total_calls += len(matches)
        rendered[path] = CALL.sub(
            lambda match: f"{match.group('prefix')}{revision}{match.group('suffix')}",
            source,
        )

    if not total_calls:
        message = "no f5-sales-demo/docs-control reusable-workflow calls found"
        raise PinUpdateError(message)

    config_path = root / ".github/config/governed-workflow-pin.json"
    config = {"revision": revision}
    rendered_config = json.dumps(config, indent=2) + "\n"

    changed = 0
    for path, content in rendered.items():
        if content != path.read_text(encoding="utf-8"):
            path.write_text(content, encoding="utf-8")
            changed += 1
    if (
        not config_path.exists()
        or config_path.read_text(encoding="utf-8") != rendered_config
    ):
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(rendered_config, encoding="utf-8")
        changed += 1
    return changed, tuple(sorted(workflow_names))


def main() -> int:
    """Update caller files and print the reusable paths for revision verification."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()

    changed, workflows = update(args.root.resolve(), args.revision)
    print(f"updated {changed} file(s) to docs-control@{args.revision}")
    for workflow in workflows:
        print(workflow)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
