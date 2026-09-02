#!/usr/bin/env python3
# ruff: noqa: ANN001, ANN201, ANN204, D102, D103, D107, EM101, EM102, PERF401, PLC0415, PLR2004, RUF100, TC003, TRY003, TRY301
# pylint: disable=invalid-name,too-many-branches,too-many-locals,too-many-statements
"""Verify a declarative GitHub backlog-consolidation contract without mutation."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any


class AuditInputError(ValueError):
    """Raised when policy, snapshot, or GitHub input cannot be trusted."""


def load_json(path: Path) -> dict[str, Any]:
    """Load a JSON object or fail with a path-specific diagnostic."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise AuditInputError(f"cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise AuditInputError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise AuditInputError(f"{path} must contain a JSON object")
    return value


def _require_mapping(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AuditInputError(f"{path} must be an object")
    return value


def _require_list(value: Any, path: str) -> list[Any]:
    if not isinstance(value, list):
        raise AuditInputError(f"{path} must be an array")
    return value


def _require_string(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value:
        raise AuditInputError(f"{path} must be a non-empty string")
    return value


def _require_integer(value: Any, path: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise AuditInputError(f"{path} must be a positive integer")
    return value


def _parse_issue_key(value: Any, context: str) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError) as exc:
        raise AuditInputError(f"{context} {value!r} must be an issue number") from exc
    _require_integer(number, context)
    if str(number) != str(value):
        raise AuditInputError(f"{context} {value!r} must be canonical")
    return number


def _require_integer_list(value: Any, path: str) -> list[int]:
    items = _require_list(value, path)
    result = [_require_integer(item, f"{path}[]") for item in items]
    if len(result) != len(set(result)):
        raise AuditInputError(f"{path} must not contain duplicates")
    return result


def validate_policy(policy: dict[str, Any]) -> None:
    """Validate the version-one policy before comparing untrusted data."""
    if policy.get("schema_version") != 1:
        raise AuditInputError("policy schema_version must be 1")
    _require_string(policy.get("source_repository"), "source_repository")
    expected_open = _require_integer_list(
        policy.get("expected_open_issues"), "expected_open_issues"
    )
    issues = _require_mapping(policy.get("issues"), "issues")
    issue_numbers: set[int] = set()
    open_from_issues: set[int] = set()
    for key, raw_issue in issues.items():
        try:
            number = int(key)
        except (TypeError, ValueError) as exc:
            raise AuditInputError(
                f"issues key {key!r} must be an issue number"
            ) from exc
        _require_integer(number, f"issues.{key}")
        if str(number) != str(key):
            raise AuditInputError(f"issues key {key!r} must be canonical")
        issue_numbers.add(number)
        issue = _require_mapping(raw_issue, f"issues.{key}")
        state = _require_string(issue.get("state"), f"issues.{key}.state")
        if state not in {"open", "closed"}:
            raise AuditInputError(f"issues.{key}.state must be open or closed")
        if state == "open":
            open_from_issues.add(number)
        elif issue.get("state_reason") not in {"completed", "not_planned"}:
            raise AuditInputError(
                f"issues.{key}.state_reason must be completed or not_planned"
            )
        _require_string(issue.get("title"), f"issues.{key}.title")
        status = _require_string(issue.get("status"), f"issues.{key}.status")
        area = _require_string(issue.get("area"), f"issues.{key}.area")
        if not status.startswith("status:"):
            raise AuditInputError(f"issues.{key}.status must use the status: prefix")
        if not area.startswith("area:"):
            raise AuditInputError(f"issues.{key}.area must use the area: prefix")
    if set(expected_open) != open_from_issues:
        raise AuditInputError(
            "expected_open_issues must exactly match policy issues whose state is open"
        )

    relationships = _require_mapping(policy.get("relationships", {}), "relationships")
    seen_children: set[int] = set()
    for parent_key, raw_children in relationships.items():
        parent = _parse_issue_key(parent_key, "relationships key")
        if parent not in issue_numbers:
            raise AuditInputError(f"relationship parent #{parent} is not in issues")
        children = _require_integer_list(raw_children, f"relationships.{parent_key}")
        for child in children:
            if child not in issue_numbers:
                raise AuditInputError(f"relationship child #{child} is not in issues")
            if child in seen_children:
                raise AuditInputError(
                    f"relationship child #{child} has multiple parents"
                )
            seen_children.add(child)

    transfers = _require_list(policy.get("transfers", []), "transfers")
    for index, raw_transfer in enumerate(transfers):
        transfer = _require_mapping(raw_transfer, f"transfers[{index}]")
        _require_integer(
            transfer.get("source_number"), f"transfers[{index}].source_number"
        )
        _require_string(transfer.get("repository"), f"transfers[{index}].repository")
        _require_integer(transfer.get("number"), f"transfers[{index}].number")
        _require_string(transfer.get("state"), f"transfers[{index}].state")
        status = _require_string(transfer.get("status"), f"transfers[{index}].status")
        area = _require_string(transfer.get("area"), f"transfers[{index}].area")
        if not status.startswith("status:"):
            raise AuditInputError(
                f"transfers[{index}].status must use the status: prefix"
            )
        if not area.startswith("area:"):
            raise AuditInputError(f"transfers[{index}].area must use the area: prefix")
        for label in _require_list(
            transfer.get("labels", []), f"transfers[{index}].labels"
        ):
            _require_string(label, f"transfers[{index}].labels[]")

    pulls = _require_list(policy.get("pull_requests", []), "pull_requests")
    for index, raw_pull in enumerate(pulls):
        pull = _require_mapping(raw_pull, f"pull_requests[{index}]")
        _require_integer(pull.get("number"), f"pull_requests[{index}].number")
        _require_string(pull.get("state"), f"pull_requests[{index}].state")
        _require_string(pull.get("head_ref"), f"pull_requests[{index}].head_ref")
        head_sha = _require_string(
            pull.get("head_sha"), f"pull_requests[{index}].head_sha"
        )
        if re.fullmatch(r"[0-9a-f]{40}", head_sha) is None:
            raise AuditInputError(f"pull_requests[{index}].head_sha must be a full SHA")
        branch_state = _require_string(
            pull.get("head_branch"), f"pull_requests[{index}].head_branch"
        )
        if branch_state not in {"present", "absent"}:
            raise AuditInputError(
                f"pull_requests[{index}].head_branch must be present or absent"
            )
        for pattern in _require_list(
            pull.get("body_forbidden_patterns", []),
            f"pull_requests[{index}].body_forbidden_patterns",
        ):
            expression = _require_string(
                pattern, f"pull_requests[{index}].body_forbidden_patterns[]"
            )
            try:
                re.compile(expression)
            except re.error as exc:
                raise AuditInputError(
                    f"pull_requests[{index}] has invalid forbidden pattern: {exc}"
                ) from exc


def _display(value: Any) -> str:
    if value is None:
        return "null"
    return str(value)


def _taxonomy_problems(
    *, context: str, actual_labels: Any, expected_status: str, expected_area: str
) -> list[str]:
    if not isinstance(actual_labels, list) or not all(
        isinstance(label, str) for label in actual_labels
    ):
        return [f"{context} labels are unavailable or malformed"]
    problems: list[str] = []
    statuses = sorted(label for label in actual_labels if label.startswith("status:"))
    areas = sorted(label for label in actual_labels if label.startswith("area:"))
    if len(statuses) != 1:
        problems.append(f"{context} has {len(statuses)} status labels: {statuses}")
    elif statuses[0] != expected_status:
        problems.append(
            f"{context} status is {statuses[0]}, expected {expected_status}"
        )
    if len(areas) != 1:
        problems.append(f"{context} has {len(areas)} area labels: {areas}")
    elif areas[0] != expected_area:
        problems.append(f"{context} area is {areas[0]}, expected {expected_area}")
    return problems


def _repository(
    repositories: dict[str, Any], name: str, problems: list[str]
) -> dict[str, Any] | None:
    repository = repositories.get(name)
    if not isinstance(repository, dict):
        problems.append(f"repository {name} is unavailable")
        return None
    return repository


def audit_snapshot(policy: dict[str, Any], snapshot: dict[str, Any]) -> list[str]:
    """Return every policy violation found in a normalized GitHub snapshot."""
    validate_policy(policy)
    if not isinstance(snapshot, dict):
        raise AuditInputError("snapshot must be an object")
    repositories = snapshot.get("repositories")
    if not isinstance(repositories, dict):
        raise AuditInputError("snapshot.repositories must be an object")

    problems: list[str] = []
    source_name = policy["source_repository"]
    source = _repository(repositories, source_name, problems)
    if source is not None:
        actual_open = source.get("open_issues")
        if not isinstance(actual_open, list) or not all(
            isinstance(number, int) for number in actual_open
        ):
            problems.append(
                f"repository {source_name} open issue inventory is malformed"
            )
        else:
            expected_open = set(policy["expected_open_issues"])
            actual_open_set = set(actual_open)
            missing = sorted(expected_open - actual_open_set)
            unexpected = sorted(actual_open_set - expected_open)
            if missing:
                problems.append(
                    "missing open issues: "
                    + ", ".join(f"#{number}" for number in missing)
                )
            if unexpected:
                problems.append(
                    "unexpected open issues: "
                    + ", ".join(f"#{number}" for number in unexpected)
                )

        source_issues = source.get("issues")
        if not isinstance(source_issues, dict):
            problems.append(f"repository {source_name} issue details are malformed")
            source_issues = {}
        for number_text, expected in policy["issues"].items():
            number = int(number_text)
            actual = source_issues.get(number_text)
            context = f"{source_name}#{number}"
            if not isinstance(actual, dict):
                problems.append(f"{context} is unavailable")
                continue
            for field, label in (
                ("state", "state"),
                ("state_reason", "state reason"),
                ("title", "title"),
            ):
                if field not in expected:
                    continue
                actual_value = actual.get(field)
                expected_value = expected[field]
                if actual_value != expected_value:
                    if field == "title":
                        problems.append(
                            f"#{number} title is {actual_value!r}, expected {expected_value!r}"
                        )
                    else:
                        problems.append(
                            f"#{number} {label} is {_display(actual_value)}, "
                            f"expected {_display(expected_value)}"
                        )
            problems.extend(
                _taxonomy_problems(
                    context=f"#{number}",
                    actual_labels=actual.get("labels"),
                    expected_status=expected["status"],
                    expected_area=expected["area"],
                )
            )

        expected_parents: dict[int, int] = {}
        for parent_text, children in policy.get("relationships", {}).items():
            parent = int(parent_text)
            for child in children:
                expected_parents[child] = parent
        for number_text, actual in source_issues.items():
            if not isinstance(actual, dict):
                continue
            number = _parse_issue_key(number_text, "snapshot issue key")
            expected_children = policy.get("relationships", {}).get(number_text, [])
            actual_children = actual.get("children")
            if actual_children != expected_children:
                problems.append(
                    f"#{number} children are {actual_children}, expected {expected_children}"
                )
            expected_parent = expected_parents.get(number)
            actual_parent = actual.get("parent")
            if actual_parent != expected_parent:
                expected_text = (
                    "null" if expected_parent is None else f"#{expected_parent}"
                )
                problems.append(
                    f"#{number} parent is {_display(actual_parent)}, expected {expected_text}"
                )

        source_pulls = source.get("pull_requests")
        source_branches = source.get("branches")
        if not isinstance(source_pulls, dict):
            problems.append(
                f"repository {source_name} pull request details are malformed"
            )
            source_pulls = {}
        if not isinstance(source_branches, list):
            problems.append(f"repository {source_name} branch inventory is malformed")
            source_branches = []
        for expected in policy.get("pull_requests", []):
            number = expected["number"]
            actual = source_pulls.get(str(number))
            if not isinstance(actual, dict):
                problems.append(f"PR #{number} is unavailable")
                continue
            for field, label in (
                ("state", "state"),
                ("head_ref", "head ref"),
                ("head_sha", "head SHA"),
            ):
                if actual.get(field) != expected[field]:
                    problems.append(
                        f"PR #{number} {label} is {_display(actual.get(field))}, "
                        f"expected {expected[field]}"
                    )
            body = actual.get("body")
            if not isinstance(body, str):
                problems.append(f"PR #{number} body is unavailable")
            else:
                for pattern in expected.get("body_forbidden_patterns", []):
                    if re.search(pattern, body):
                        problems.append(
                            f"PR #{number} body matches forbidden pattern {pattern!r}"
                        )
            present = expected["head_ref"] in source_branches
            expected_present = expected["head_branch"] == "present"
            if present != expected_present:
                actual_text = "present" if present else "absent"
                problems.append(
                    f"branch {expected['head_ref']} is {actual_text}, "
                    f"expected {expected['head_branch']}"
                )

    for transfer in policy.get("transfers", []):
        repository_name = transfer["repository"]
        repository = _repository(repositories, repository_name, problems)
        if repository is None:
            continue
        issues = repository.get("issues")
        actual = (
            issues.get(str(transfer["number"])) if isinstance(issues, dict) else None
        )
        context = (
            f"transferred source #{transfer['source_number']} -> "
            f"{repository_name}#{transfer['number']}"
        )
        if not isinstance(actual, dict):
            problems.append(f"{context} is unavailable")
            continue
        if actual.get("state") != transfer["state"]:
            problems.append(
                f"{context} state is {_display(actual.get('state'))}, "
                f"expected {transfer['state']}"
            )
        labels = actual.get("labels")
        problems.extend(
            _taxonomy_problems(
                context=context,
                actual_labels=labels,
                expected_status=transfer["status"],
                expected_area=transfer["area"],
            )
        )
        if isinstance(labels, list):
            for label in transfer.get("labels", []):
                if label not in labels:
                    problems.append(f"{context} is missing expected label {label}")
    return problems


class GitHubClient:
    """Small fail-closed adapter around the authenticated GitHub CLI."""

    def __init__(
        self, runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run
    ):
        self.runner = runner

    def get(
        self, endpoint: str, *, paginate: bool = False, allow_not_found: bool = False
    ) -> Any:
        command = ["gh", "api"]
        if paginate:
            command.extend(["--paginate", "--slurp"])
        command.append(endpoint)
        result = self.runner(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            diagnostic = result.stderr.strip() or "unknown error"
            if allow_not_found and "404" in diagnostic:
                return None
            raise AuditInputError(f"gh api failed for {endpoint}: {diagnostic}")
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise AuditInputError(
                f"gh api returned invalid JSON for {endpoint}: {exc}"
            ) from exc
        if paginate:
            if not isinstance(value, list) or not all(
                isinstance(page, list) for page in value
            ):
                raise AuditInputError(f"gh api returned malformed pages for {endpoint}")
            return [item for page in value for item in page]
        return value


def _normalize_issue(raw: dict[str, Any]) -> dict[str, Any]:
    labels = raw.get("labels", [])
    return {
        "state": raw.get("state"),
        "state_reason": raw.get("state_reason"),
        "title": raw.get("title"),
        "labels": [
            label.get("name") if isinstance(label, dict) else label for label in labels
        ],
        "parent": None,
        "children": [],
    }


def collect_live_snapshot(
    policy: dict[str, Any], client: GitHubClient | None = None
) -> dict[str, Any]:
    """Collect only the read-only GitHub state referenced by a policy."""
    validate_policy(policy)
    api = client or GitHubClient()
    source_name = policy["source_repository"]
    repositories: dict[str, Any] = {}
    raw_open = api.get(
        f"repos/{source_name}/issues?state=open&per_page=100", paginate=True
    )
    repositories[source_name] = {
        "open_issues": sorted(
            issue["number"] for issue in raw_open if "pull_request" not in issue
        ),
        "issues": {},
        "pull_requests": {},
        "branches": [],
    }
    source = repositories[source_name]
    for number_text in policy["issues"]:
        number = int(number_text)
        raw_issue = api.get(f"repos/{source_name}/issues/{number}")
        issue = _normalize_issue(raw_issue)
        parent = api.get(
            f"repos/{source_name}/issues/{number}/parent", allow_not_found=True
        )
        issue["parent"] = parent.get("number") if isinstance(parent, dict) else None
        children = api.get(
            f"repos/{source_name}/issues/{number}/sub_issues?per_page=100",
            paginate=True,
        )
        issue["children"] = sorted(child["number"] for child in children)
        source["issues"][number_text] = issue
    for expected in policy.get("pull_requests", []):
        number = expected["number"]
        raw_pull = api.get(f"repos/{source_name}/pulls/{number}")
        source["pull_requests"][str(number)] = {
            "state": raw_pull.get("state"),
            "head_ref": raw_pull.get("head", {}).get("ref"),
            "head_sha": raw_pull.get("head", {}).get("sha"),
            "body": raw_pull.get("body") or "",
        }
    branches = api.get(f"repos/{source_name}/branches?per_page=100", paginate=True)
    source["branches"] = sorted(branch["name"] for branch in branches)

    for transfer in policy.get("transfers", []):
        repository_name = transfer["repository"]
        repository = repositories.setdefault(
            repository_name,
            {"open_issues": [], "issues": {}, "pull_requests": {}, "branches": []},
        )
        number = transfer["number"]
        raw_issue = api.get(f"repos/{repository_name}/issues/{number}")
        repository["issues"][str(number)] = _normalize_issue(raw_issue)
    return {"repositories": repositories}


def parse_args(argv: list[str]) -> argparse.Namespace:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--policy",
        type=Path,
        default=root / ".github/config/backlog-consolidation-2026-08-30.json",
        help="versioned consolidation policy JSON",
    )
    parser.add_argument(
        "--snapshot",
        type=Path,
        help="normalized offline snapshot JSON; omit to query GitHub read-only via gh",
    )
    parser.add_argument(
        "--write-snapshot",
        type=Path,
        help="write the collected live snapshot before auditing",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    raw_args = sys.argv[1:] if argv is None else argv
    if raw_args and raw_args[0] in {"collect", "verify", "verify-live"}:
        from fleet_backlog_inventory import main as fleet_main

        return fleet_main(raw_args)
    args = parse_args(raw_args)
    try:
        policy = load_json(args.policy)
        if args.snapshot:
            if args.write_snapshot:
                raise AuditInputError(
                    "--write-snapshot cannot be combined with --snapshot"
                )
            snapshot = load_json(args.snapshot)
        else:
            snapshot = collect_live_snapshot(policy)
            if args.write_snapshot:
                args.write_snapshot.write_text(
                    json.dumps(snapshot, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
        problems = audit_snapshot(policy, snapshot)
    except AuditInputError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    if problems:
        for problem in problems:
            print(f"ERROR: {problem}", file=sys.stderr)
        print(f"Backlog consolidation audit failed with {len(problems)} problem(s).")
        return 1
    print(
        "Backlog consolidation verified: "
        f"{len(policy['issues'])} source issues, "
        f"{len(policy.get('transfers', []))} transfers, and "
        f"{len(policy.get('pull_requests', []))} pull requests."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
