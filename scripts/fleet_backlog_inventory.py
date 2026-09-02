#!/usr/bin/env python3
# ruff: noqa: ANN001, ANN204, D101, D102, D103, D107, EM101, EM102, PERF401, PIE810, SIM102, TRY003
"""Collect and verify the governed fleet backlog without mutating GitHub."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 2
OWNER = "f5-sales-demo"
LIFECYCLES = {"active", "blocked", "deferred", "tracking", "resolved", "superseded"}
PRIORITIES = {"p0", "p1", "p2", "p3"}
AREAS = {
    "governance",
    "runners",
    "dependencies",
    "security",
    "ci",
    "api-contracts",
    "docs-publishing",
    "i18n",
    "developer-tooling",
    "product",
    "ai-automation",
    "linting",
}
WORKSTREAMS = {
    "governance": 1954,
    "runners": 1955,
    "ci": 1955,
    "dependencies": 1956,
    "security": 1957,
    "api-contracts": 1958,
    "docs-publishing": 1959,
    "i18n": 1959,
    "developer-tooling": 1960,
    "linting": 1960,
    "ai-automation": 1960,
    "product": 1961,
}
CONTROL_ISSUES = {1953, *WORKSTREAMS.values()}
CONTINUE_PRS = {
    "api-specs-enriched": {1687, 1657},
    "mcn": {1067},
    "terraform-provider-xcsh": {1895},
}
REBUILD_PRS = {
    "api-specs": {1118},
    "marketplace": {1084},
    "mcn": {814},
    "terraform-provider-xcsh": {1761, 1762},
    "webapp-api-protection": {315},
    "xcsh": {3350},
}


class InventoryError(ValueError):
    """Raised when catalog, inventory, or GitHub data cannot be trusted."""


class GitHub:
    def __init__(self, runner=subprocess.run):
        self.runner = runner

    def get(
        self, endpoint: str, *, paginate: bool = False, missing_ok: bool = False
    ) -> Any:
        command = ["gh", "api"]
        if paginate:
            command.extend(["--paginate", "--slurp"])
        command.append(endpoint)
        result = self.runner(command, capture_output=True, text=True, check=False)
        if result.returncode:
            diagnostic = result.stderr.strip() or "unknown error"
            if missing_ok and "404" in diagnostic:
                return None
            raise InventoryError(f"GitHub API failed for {endpoint}: {diagnostic}")
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise InventoryError(
                f"GitHub API returned malformed JSON for {endpoint}: {exc}"
            ) from exc
        if paginate:
            if not isinstance(data, list) or not all(
                isinstance(page, list) for page in data
            ):
                raise InventoryError(f"GitHub pagination was malformed for {endpoint}")
            return [item for page in data for item in page]
        return data


def load_object(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InventoryError(f"cannot load {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise InventoryError(f"{path} must contain a JSON object")
    return data


def catalog_names(path: Path) -> list[str]:
    policy = load_object(path)
    repositories = policy.get("repositories")
    if not isinstance(repositories, dict) or not repositories:
        raise InventoryError("runner policy repositories must be a non-empty object")
    names = sorted(repositories)
    if any(not re.fullmatch(r"f5-sales-demo/[a-z0-9-]+", name) for name in names):
        raise InventoryError("runner policy contains an invalid repository name")
    if len(names) != len(set(names)):
        raise InventoryError("runner policy contains duplicate repositories")
    return names


def _labels(raw: dict[str, Any]) -> list[str]:
    labels = raw.get("labels", [])
    if not isinstance(labels, list):
        raise InventoryError("GitHub item labels are malformed")
    result = []
    for label in labels:
        name = label.get("name") if isinstance(label, dict) else label
        if not isinstance(name, str):
            raise InventoryError("GitHub item label is malformed")
        result.append(name)
    return sorted(set(result))


def _one_label(labels: list[str], prefix: str, allowed: set[str]) -> str | None:
    values = [
        label.removeprefix(prefix) for label in labels if label.startswith(prefix)
    ]
    if len(values) > 1 or any(value not in allowed for value in values):
        raise InventoryError(f"invalid {prefix.rstrip(':')} taxonomy: {values}")
    return values[0] if values else None


def infer_area(repository: str, title: str, body: str, labels: list[str]) -> str:
    existing = _one_label(labels, "area:", AREAS)
    if existing:
        return existing
    rules = [
        ("i18n", r"\bi18n\b|translat|locale"),
        (
            "security",
            r"security|vulnerab|cve-|secret|pii|privacy|gitleaks|semgrep|zizmor|trust bound",
        ),
        ("runners", r"\brunner|\baks\b|\barc\b|kubernetes|container-build|socketless"),
        (
            "dependencies",
            r"chore\(deps\)|renovate|dependabot|dependenc|supply.chain|lockfile|package update|toolchain|\bnode\b",
        ),
        (
            "api-contracts",
            r"api spec|api contract|openapi|terraform|provider contract|schema contract|sdk",
        ),
        ("ai-automation", r"antigravity|claude|\bai\b|reviewer"),
        ("linting", r"lint|ruff|biome|markdownlint|clippy|pre-commit"),
        ("ci", r"\bci\b|workflow|github actions|check run|build failure|test failure"),
        ("docs-publishing", r"\bdocs?\b|readme|starlight|publish|pages|documentation"),
        ("developer-tooling", r"release|cli|devcontainer|tooling|build|test|packag"),
        ("governance", r"govern|reconcil|managed.sync|policy|catalog|backlog"),
    ]
    for text in (title.lower(), body.lower()):
        for area, pattern in rules:
            if re.search(pattern, text):
                return area
    repo_defaults = {
        "docs-control": "governance",
        "api-specs": "api-contracts",
        "api-specs-enriched": "api-contracts",
        "terraform-provider-xcsh": "api-contracts",
        "docs": "docs-publishing",
        "docs-builder": "docs-publishing",
        "docs-icons": "docs-publishing",
        "docs-theme": "docs-publishing",
        "i18n-core": "i18n",
        "starlight-llms-txt": "docs-publishing",
        "starlight-mega-menu": "docs-publishing",
        "vscode-xcsh": "developer-tooling",
        "xcsh-action": "developer-tooling",
    }
    return repo_defaults.get(repository, "product")


def infer_taxonomy(
    repository: str,
    title: str,
    body: str,
    labels: list[str],
) -> dict[str, str]:
    area = infer_area(repository, title, body, labels)
    lifecycle = _one_label(labels, "status:", LIFECYCLES)
    priority = next((label for label in labels if label in PRIORITIES), None)
    text = f"{title} {body}".lower()
    if not lifecycle:
        if title.lower().startswith("chore(deps):"):
            lifecycle = "active"
        elif title.startswith("Governance reconciliation @"):
            lifecycle = "resolved"
        elif re.search(r"defer|readiness gate|major.release", text) or area == "i18n":
            lifecycle = "deferred"
        elif re.search(
            r"umbrella|tracking|workstream|fleet backlog consolidation", text
        ):
            lifecycle = "tracking"
        else:
            lifecycle = "active"
    if not priority:
        if lifecycle in {"tracking", "deferred", "resolved", "superseded"}:
            priority = "p3"
        elif area in {"security", "runners", "ci"}:
            priority = "p0"
        elif area in {"dependencies", "api-contracts", "governance"}:
            priority = "p1"
        else:
            priority = "p2"
    return {"lifecycle": lifecycle, "priority": priority, "area": area}


def _dependencies(text: str) -> list[str]:
    urls = re.findall(
        r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:issues|pull)/[0-9]+",
        text,
    )
    refs = re.findall(
        r"(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)", text
    )
    return sorted(set(urls + refs))


def _disposition(
    repository: str,
    number: int,
    title: str,
    taxonomy: dict[str, str],
    *,
    pull: bool,
    head_ref: str = "",
) -> str:
    if pull and number in CONTINUE_PRS.get(repository, set()):
        return "continuation-candidate"
    if pull and number in REBUILD_PRS.get(repository, set()):
        return "rebuild-candidate"
    if title.startswith("Governance reconciliation @"):
        return "close-completed"
    if pull and (
        head_ref.startswith("sync/exact-caller-")
        or any(
            head_ref.startswith(f"{prefix}-")
            for prefix in (
                "governance/bootstrap",
                "governance/reconcile",
                "governance/sync-managed-files",
            )
        )
    ):
        return "audit-generated-pr"
    return {
        "tracking": "tracking",
        "deferred": "deferred",
        "blocked": "externally-blocked",
        "resolved": "close-completed",
        "superseded": "close-not-planned",
    }.get(taxonomy["lifecycle"], "execute")


def _required(raw: dict[str, Any], fields: tuple[str, ...], context: str) -> None:
    if any(field not in raw for field in fields):
        raise InventoryError(f"GitHub response is incomplete for {context}")


def collect(catalog_path: Path, api: GitHub | None = None) -> dict[str, Any]:
    client = api or GitHub()
    names = catalog_names(catalog_path)
    repositories = []
    total_issues = total_pulls = 0
    for full_name in names:
        repository = full_name.split("/", 1)[1]
        repo_raw = client.get(f"repos/{full_name}")
        _required(repo_raw, ("html_url", "default_branch", "updated_at"), full_name)
        raw_items = client.get(
            f"repos/{full_name}/issues?state=open&per_page=100", paginate=True
        )
        raw_pulls = client.get(
            f"repos/{full_name}/pulls?state=open&per_page=100", paginate=True
        )
        issues = []
        pulls = []
        seen_issue_numbers: set[int] = set()
        for raw in raw_items:
            if "pull_request" in raw:
                continue
            _required(
                raw,
                (
                    "number",
                    "node_id",
                    "title",
                    "body",
                    "html_url",
                    "created_at",
                    "updated_at",
                ),
                f"{full_name} issue",
            )
            number = raw["number"]
            if number in seen_issue_numbers:
                raise InventoryError(f"duplicate issue {full_name}#{number}")
            seen_issue_numbers.add(number)
            labels = _labels(raw)
            body = raw.get("body") or ""
            taxonomy = infer_taxonomy(repository, raw["title"], body, labels)
            parent = client.get(
                f"repos/{full_name}/issues/{number}/parent", missing_ok=True
            )
            parent_ref = None
            if parent is not None:
                parent_repo = parent.get("repository_url", "").removeprefix(
                    "https://api.github.com/repos/"
                )
                if not parent_repo or not isinstance(parent.get("number"), int):
                    raise InventoryError(f"malformed parent for {full_name}#{number}")
                parent_ref = f"{parent_repo}#{parent['number']}"
            workstream = WORKSTREAMS[taxonomy["area"]]
            issues.append(
                {
                    "number": number,
                    "node_id": raw["node_id"],
                    "title": raw["title"],
                    "url": raw["html_url"],
                    "created_at": raw["created_at"],
                    "updated_at": raw["updated_at"],
                    "labels": labels,
                    "taxonomy": taxonomy,
                    "workstream": f"{OWNER}/docs-control#{workstream}",
                    "parent": parent_ref,
                    "dependencies": _dependencies(body),
                    "evidence": [raw["html_url"]],
                    "disposition": _disposition(
                        repository, number, raw["title"], taxonomy, pull=False
                    ),
                }
            )
        seen_pull_numbers: set[int] = set()
        for raw in raw_pulls:
            _required(
                raw,
                (
                    "number",
                    "node_id",
                    "title",
                    "body",
                    "html_url",
                    "created_at",
                    "updated_at",
                    "head",
                    "base",
                ),
                f"{full_name} pull request",
            )
            number = raw["number"]
            if number in seen_pull_numbers:
                raise InventoryError(f"duplicate pull request {full_name}#{number}")
            seen_pull_numbers.add(number)
            head = raw.get("head") or {}
            base = raw.get("base") or {}
            if not re.fullmatch(r"[0-9a-f]{40}", head.get("sha", "")):
                raise InventoryError(f"missing full head SHA for {full_name}#{number}")
            files = client.get(
                f"repos/{full_name}/pulls/{number}/files?per_page=100", paginate=True
            )
            check_response = client.get(
                f"repos/{full_name}/commits/{head['sha']}/check-runs?per_page=100"
            )
            if not isinstance(check_response, dict) or not isinstance(
                check_response.get("check_runs"), list
            ):
                raise InventoryError(f"malformed check runs for {full_name}#{number}")
            checks_raw = check_response["check_runs"]
            if check_response.get("total_count") != len(checks_raw):
                raise InventoryError(
                    f"check-run pagination is incomplete for {full_name}#{number}"
                )
            statuses = client.get(
                f"repos/{full_name}/commits/{head['sha']}/statuses?per_page=100",
                paginate=True,
            )
            labels = _labels(raw)
            body = raw.get("body") or ""
            taxonomy = infer_taxonomy(repository, raw["title"], body, labels)
            if head.get("ref", "").startswith("sync/exact-caller-"):
                taxonomy = {
                    "lifecycle": "superseded",
                    "priority": "p3",
                    "area": "governance",
                }
            checks = [
                {
                    "name": check.get("name"),
                    "status": check.get("status"),
                    "conclusion": check.get("conclusion"),
                    "url": check.get("html_url"),
                }
                for check in checks_raw
            ] + [
                {
                    "name": status.get("context"),
                    "status": status.get("state"),
                    "conclusion": status.get("state"),
                    "url": status.get("target_url"),
                }
                for status in statuses
            ]
            pulls.append(
                {
                    "number": number,
                    "node_id": raw["node_id"],
                    "title": raw["title"],
                    "url": raw["html_url"],
                    "created_at": raw["created_at"],
                    "updated_at": raw["updated_at"],
                    "labels": labels,
                    "taxonomy": taxonomy,
                    "workstream": f"{OWNER}/docs-control#{WORKSTREAMS[taxonomy['area']]}",
                    "head_ref": head.get("ref"),
                    "head_sha": head["sha"],
                    "head_repository": (head.get("repo") or {}).get("full_name"),
                    "base_ref": base.get("ref"),
                    "draft": bool(raw.get("draft")),
                    "mergeable_state": raw.get("mergeable_state"),
                    "changed_paths": sorted(
                        file.get("filename")
                        for file in files
                        if isinstance(file.get("filename"), str)
                    ),
                    "checks": sorted(
                        checks,
                        key=lambda value: (str(value["name"]), str(value["url"])),
                    ),
                    "dependencies": _dependencies(body),
                    "evidence": [raw["html_url"]],
                    "disposition": _disposition(
                        repository,
                        number,
                        raw["title"],
                        taxonomy,
                        pull=True,
                        head_ref=head.get("ref", ""),
                    ),
                }
            )
        issues.sort(key=lambda item: item["number"])
        pulls.sort(key=lambda item: item["number"])
        total_issues += len(issues)
        total_pulls += len(pulls)
        repositories.append(
            {
                "name": full_name,
                "url": repo_raw["html_url"],
                "default_branch": repo_raw["default_branch"],
                "updated_at": repo_raw["updated_at"],
                "issues": issues,
                "pull_requests": pulls,
            }
        )
    digest = hashlib.sha256("\n".join(names).encode()).hexdigest()
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "catalog": {
            "source": str(catalog_path),
            "sha256": digest,
            "repository_count": len(names),
        },
        "control": {
            "program": f"{OWNER}/docs-control#1953",
            "workstreams": {
                key: f"{OWNER}/docs-control#{value}"
                for key, value in sorted(WORKSTREAMS.items())
            },
        },
        "summary": {"open_issues": total_issues, "open_pull_requests": total_pulls},
        "repositories": repositories,
    }


def validate(inventory: dict[str, Any], catalog_path: Path) -> list[str]:
    problems: list[str] = []
    if inventory.get("schema_version") != SCHEMA_VERSION:
        raise InventoryError(f"inventory schema_version must be {SCHEMA_VERSION}")
    expected_names = catalog_names(catalog_path)
    repositories = inventory.get("repositories")
    if not isinstance(repositories, list):
        raise InventoryError("inventory.repositories must be an array")
    names = [repo.get("name") for repo in repositories if isinstance(repo, dict)]
    if names != expected_names:
        problems.append(
            "catalog drift: inventory repositories do not exactly match the governed catalog"
        )
    issue_count = pull_count = 0
    seen: set[tuple[str, str, int]] = set()
    for repo in repositories:
        if not isinstance(repo, dict):
            raise InventoryError("repository entry must be an object")
        name = repo.get("name", "unknown")
        for kind, key in (("issue", "issues"), ("pull request", "pull_requests")):
            items = repo.get(key)
            if not isinstance(items, list):
                raise InventoryError(f"{name}.{key} must be an array")
            for item in items:
                if not isinstance(item, dict) or not isinstance(
                    item.get("number"), int
                ):
                    raise InventoryError(f"malformed {kind} in {name}")
                identity = (name, kind, item["number"])
                if identity in seen:
                    problems.append(f"duplicate {kind} {name}#{item['number']}")
                seen.add(identity)
                for field in (
                    "title",
                    "url",
                    "created_at",
                    "updated_at",
                    "workstream",
                    "disposition",
                ):
                    if not isinstance(item.get(field), str) or not item[field]:
                        problems.append(f"{name}#{item['number']} missing {field}")
                taxonomy = item.get("taxonomy")
                if (
                    not isinstance(taxonomy, dict)
                    or taxonomy.get("lifecycle") not in LIFECYCLES
                    or taxonomy.get("priority") not in PRIORITIES
                    or taxonomy.get("area") not in AREAS
                ):
                    problems.append(f"{name}#{item['number']} has incomplete taxonomy")
                if (
                    not isinstance(item.get("dependencies"), list)
                    or not isinstance(item.get("evidence"), list)
                    or not item.get("evidence")
                ):
                    problems.append(
                        f"{name}#{item['number']} has incomplete dependencies/evidence"
                    )
                labels = item.get("labels")
                if not isinstance(labels, list):
                    problems.append(f"{name}#{item['number']} labels are malformed")
                else:
                    expected = (
                        {
                            f"status:{taxonomy['lifecycle']}",
                            taxonomy["priority"],
                            f"area:{taxonomy['area']}",
                        }
                        if isinstance(taxonomy, dict)
                        else set()
                    )
                    actual_taxonomy = {
                        label
                        for label in labels
                        if label.startswith("status:")
                        or label.startswith("area:")
                        or label in PRIORITIES
                    }
                    if actual_taxonomy != expected:
                        problems.append(
                            f"{name}#{item['number']} taxonomy labels are {sorted(actual_taxonomy)}, expected {sorted(expected)}"
                        )
                if kind == "issue":
                    issue_count += 1
                    if not (
                        name == f"{OWNER}/docs-control"
                        and item["number"] in CONTROL_ISSUES
                    ):
                        if item.get("parent") != item.get("workstream"):
                            problems.append(
                                f"{name}#{item['number']} is not a native sub-issue of its workstream"
                            )
                else:
                    pull_count += 1
                    if not re.fullmatch(r"[0-9a-f]{40}", item.get("head_sha", "")):
                        problems.append(f"{name}#{item['number']} has invalid head SHA")
                    if not isinstance(item.get("checks"), list) or not isinstance(
                        item.get("changed_paths"), list
                    ):
                        problems.append(
                            f"{name}#{item['number']} has incomplete PR checks/paths"
                        )
    summary = inventory.get("summary", {})
    if summary != {"open_issues": issue_count, "open_pull_requests": pull_count}:
        problems.append("summary counts do not match inventoried items")
    return problems


def compare(expected: dict[str, Any], actual: dict[str, Any]) -> list[str]:
    problems: list[str] = []

    def flatten(data: dict[str, Any]) -> dict[tuple[str, str, int], dict[str, Any]]:
        result = {}
        for repo in data.get("repositories", []):
            for key in ("issues", "pull_requests"):
                for item in repo.get(key, []):
                    result[(repo["name"], key, item["number"])] = item
        return result

    wanted = flatten(expected)
    live = flatten(actual)
    if wanted.keys() != live.keys():
        missing = sorted(wanted.keys() - live.keys())
        added = sorted(live.keys() - wanted.keys())
        if missing:
            problems.append(f"items no longer open: {missing}")
        if added:
            problems.append(f"new open items: {added}")
    stable = (
        "title",
        "updated_at",
        "labels",
        "parent",
        "head_ref",
        "head_sha",
        "changed_paths",
        "checks",
    )
    for identity in sorted(wanted.keys() & live.keys()):
        for field in stable:
            if field in wanted[identity] and wanted[identity].get(field) != live[
                identity
            ].get(field):
                problems.append(f"{identity} changed {field}")
    return problems


def parse_args(argv: list[str]) -> argparse.Namespace:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("collect", "verify", "verify-live"):
        command = sub.add_parser(name)
        command.add_argument(
            "--catalog",
            type=Path,
            default=root / ".github/config/self-hosted-runner-policy.json",
        )
        if name == "collect":
            command.add_argument("--output", type=Path, required=True)
        else:
            command.add_argument("--inventory", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.command == "collect":
            inventory = collect(args.catalog)
            args.output.write_text(
                json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            print(
                f"Collected {inventory['summary']['open_issues']} issues and {inventory['summary']['open_pull_requests']} pull requests across {len(inventory['repositories'])} repositories."
            )
            return 0
        inventory = load_object(args.inventory)
        problems = validate(inventory, args.catalog)
        if args.command == "verify-live" and not problems:
            problems.extend(compare(inventory, collect(args.catalog)))
    except InventoryError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    if problems:
        for problem in problems:
            print(f"ERROR: {problem}", file=sys.stderr)
        return 1
    print(
        f"Fleet backlog inventory verified: {inventory['summary']['open_issues']} issues, {inventory['summary']['open_pull_requests']} pull requests, {len(inventory['repositories'])} repositories."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
