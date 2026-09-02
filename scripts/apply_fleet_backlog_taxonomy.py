#!/usr/bin/env python3
# ruff: noqa: ANN001, ANN204, D101, D102, D103, D107, EM101, EM102, PIE810, PLR2004, TRY003, TRY301
"""Apply a reviewed schema-v2 fleet taxonomy and native workstream links."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from fleet_backlog_inventory import (
    AREAS,
    CONTROL_ISSUES,
    LIFECYCLES,
    PRIORITIES,
    InventoryError,
    load_object,
)

LABELS = {
    **{
        f"status:{name}": (
            "B60205" if name == "blocked" else "0E8A16",
            f"Fleet lifecycle: {name}",
        )
        for name in LIFECYCLES
    },
    "p0": ("B60205", "Priority 0: fleet-blocking or urgent security work"),
    "p1": ("D93F0B", "Priority 1: high-impact active work"),
    "p2": ("FBCA04", "Priority 2: normal planned work"),
    "p3": ("0E8A16", "Priority 3: low-priority, deferred, or tracking work"),
    **{f"area:{name}": ("1D76DB", f"Primary fleet area: {name}") for name in AREAS},
}


class GitHubWriter:
    def __init__(self, runner=subprocess.run):
        self.runner = runner

    def call(self, command: list[str], payload: dict[str, Any] | None = None) -> Any:
        full = ["gh", "api", *command]
        encoded = None
        if payload is not None:
            full.extend(["--input", "-"])
            encoded = json.dumps(payload)
        result = self.runner(
            full, input=encoded, capture_output=True, text=True, check=False
        )
        if result.returncode:
            raise InventoryError(
                f"GitHub mutation failed for {' '.join(command)}: {result.stderr.strip()}"
            )
        return json.loads(result.stdout) if result.stdout.strip() else None


def _taxonomy_labels(item: dict[str, Any]) -> set[str]:
    taxonomy = item["taxonomy"]
    lifecycle = taxonomy.get("lifecycle")
    priority = taxonomy.get("priority")
    area = taxonomy.get("area")
    if lifecycle not in LIFECYCLES or priority not in PRIORITIES or area not in AREAS:
        raise InventoryError(f"invalid taxonomy for {item.get('url')}")
    return {f"status:{lifecycle}", priority, f"area:{area}"}


def _is_taxonomy(label: str) -> bool:
    return (
        label.startswith("status:") or label.startswith("area:") or label in PRIORITIES
    )


def preflight(inventory: dict[str, Any], writer: GitHubWriter) -> None:
    for repository in inventory["repositories"]:
        name = repository["name"]
        for key in ("issues", "pull_requests"):
            for item in repository[key]:
                _taxonomy_labels(item)
                endpoint = f"repos/{name}/{'pulls' if key == 'pull_requests' else 'issues'}/{item['number']}"
                live = writer.call([endpoint])
                if (
                    live.get("state") != "open"
                    or live.get("updated_at") != item["updated_at"]
                ):
                    raise InventoryError(
                        f"concurrent update detected for {name}#{item['number']}"
                    )
                if key == "pull_requests" and (live.get("head") or {}).get(
                    "sha"
                ) != item.get("head_sha"):
                    raise InventoryError(
                        f"head SHA changed for {name}#{item['number']}"
                    )


def apply(
    inventory: dict[str, Any], writer: GitHubWriter, *, dry_run: bool
) -> dict[str, int]:
    counts = {
        "labels_created": 0,
        "items_labeled": 0,
        "relationships_removed": 0,
        "relationships_added": 0,
    }
    parent_ids: dict[str, str] = {}
    for repository in inventory["repositories"]:
        name = repository["name"]
        items = [*repository["issues"], *repository["pull_requests"]]
        required = (
            sorted(set().union(*(_taxonomy_labels(item) for item in items)))
            if items
            else []
        )
        existing_raw = writer.call(
            ["--paginate", "--slurp", f"repos/{name}/labels?per_page=100"]
        )
        if not isinstance(existing_raw, list) or not all(
            isinstance(page, list) for page in existing_raw
        ):
            raise InventoryError(f"malformed label pagination for {name}")
        existing = {label["name"] for page in existing_raw for label in page}
        for label in required:
            if label in existing:
                continue
            counts["labels_created"] += 1
            if not dry_run:
                color, description = LABELS[label]
                writer.call(
                    ["--method", "POST", f"repos/{name}/labels"],
                    {"name": label, "color": color, "description": description},
                )
        for item in items:
            desired = sorted(
                {label for label in item["labels"] if not _is_taxonomy(label)}
                | _taxonomy_labels(item)
            )
            if desired == sorted(item["labels"]):
                continue
            counts["items_labeled"] += 1
            if not dry_run:
                writer.call(
                    ["--method", "PATCH", f"repos/{name}/issues/{item['number']}"],
                    {"labels": desired},
                )
        for issue in repository["issues"]:
            if (
                name == "f5-sales-demo/docs-control"
                and issue["number"] in CONTROL_ISSUES
            ):
                continue
            desired_parent = issue["workstream"]
            current_parent = issue.get("parent")
            if current_parent == desired_parent:
                continue
            if not isinstance(issue.get("node_id"), str):
                raise InventoryError(f"missing node ID for {name}#{issue['number']}")
            if desired_parent not in parent_ids:
                parent_repo, parent_number = desired_parent.split("#")
                parent = writer.call([f"repos/{parent_repo}/issues/{parent_number}"])
                parent_ids[desired_parent] = parent["node_id"]
            if current_parent:
                counts["relationships_removed"] += 1
                if not dry_run:
                    old_repo, old_number = current_parent.split("#")
                    old_parent = writer.call([f"repos/{old_repo}/issues/{old_number}"])
                    writer.call(
                        ["graphql"],
                        {
                            "query": "mutation($parent:ID!,$child:ID!){removeSubIssue(input:{issueId:$parent,subIssueId:$child}){issue{number}}}",
                            "variables": {
                                "parent": old_parent["node_id"],
                                "child": issue["node_id"],
                            },
                        },
                    )
            counts["relationships_added"] += 1
            if not dry_run:
                writer.call(
                    ["graphql"],
                    {
                        "query": "mutation($parent:ID!,$child:ID!){addSubIssue(input:{issueId:$parent,subIssueId:$child}){issue{number}}}",
                        "variables": {
                            "parent": parent_ids[desired_parent],
                            "child": issue["node_id"],
                        },
                    },
                )
    return counts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument(
        "--apply", action="store_true", help="perform writes; default is a dry run"
    )
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        inventory = load_object(args.inventory)
        if inventory.get("schema_version") != 2:
            raise InventoryError("schema-v2 inventory is required")
        writer = GitHubWriter()
        preflight(inventory, writer)
        counts = apply(inventory, writer, dry_run=not args.apply)
    except InventoryError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {"mode": "apply" if args.apply else "dry-run", **counts}, sort_keys=True
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
