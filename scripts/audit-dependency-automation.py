#!/usr/bin/env python3
# ruff: noqa: D101, D102, D103, EM101, EM102, PLR2004, S603, TRY003, TRY004, TRY301
"""Audit or retire mutable Dependabot state across the governed fleet."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / ".github/config/self-hosted-runner-policy.json"
ORGANIZATION = "f5-sales-demo"
EXPECTED_COUNT = 39
DEPENDABOT = "dependabot[bot]"
RETIRED_FILES = (
    ".github/dependabot.yml",
    ".github/workflows/dependabot-auto-merge.yml",
)
SUPERSESSION_COMMENT = (
    "Superseded by self-hosted Renovate. Fleet migration: "
    "https://github.com/f5-sales-demo/docs-control/issues/848; hardened runtime: "
    "https://github.com/f5-sales-demo/self-hosted-runner/issues/80."
)


class GitHubAPI(Protocol):
    def json(self, endpoint: str) -> Any: ...
    def status(self, endpoint: str) -> int: ...
    def mutate(self, method: str, endpoint: str, body: Any = None) -> None: ...


class GhClient:
    """Small fail-closed adapter around the authenticated GitHub CLI."""

    @staticmethod
    def _run(
        arguments: list[str], body: Any = None
    ) -> subprocess.CompletedProcess[str]:
        command = ["gh", "api", *arguments]
        data = None if body is None else json.dumps(body)
        if body is not None:
            command.extend(["--input", "-"])
        return subprocess.run(
            command, input=data, text=True, capture_output=True, check=False
        )

    def json(self, endpoint: str) -> Any:
        result = self._run([endpoint])
        if result.returncode != 0:
            raise RuntimeError(
                f"GitHub API GET {endpoint} failed: {result.stderr.strip()}"
            )
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError(
                f"GitHub API GET {endpoint} returned invalid JSON"
            ) from error

    def status(self, endpoint: str) -> int:
        result = self._run(["--include", endpoint])
        first_line = result.stdout.splitlines()[0] if result.stdout else ""
        fields = first_line.split()
        if len(fields) < 2 or not fields[1].isdigit():
            raise RuntimeError(
                f"GitHub API GET {endpoint} returned no HTTP status: {result.stderr.strip()}"
            )
        status = int(fields[1])
        if status not in (200, 204, 404):
            raise RuntimeError(f"GitHub API GET {endpoint} failed with HTTP {status}")
        return status

    def mutate(self, method: str, endpoint: str, body: Any = None) -> None:
        result = self._run(["--method", method, endpoint], body)
        if result.returncode != 0:
            raise RuntimeError(
                f"GitHub API {method} {endpoint} failed: {result.stderr.strip()}"
            )


def load_catalog(path: Path = POLICY) -> list[str]:
    document = json.loads(path.read_text(encoding="utf-8"))
    repositories = document.get("repositories")
    if not isinstance(repositories, dict):
        raise ValueError("policy repositories must be an object")
    return sorted(repositories)


def validate_catalog(
    repositories: list[str], expected_count: int = EXPECTED_COUNT
) -> list[str]:
    failures: list[str] = []
    if len(repositories) != expected_count:
        failures.append(
            f"catalog must contain exactly {expected_count} repositories, found {len(repositories)}"
        )
    if len(set(repositories)) != len(repositories):
        failures.append("catalog contains a duplicate repository")
    foreign = sorted(
        item for item in repositories if not item.startswith(f"{ORGANIZATION}/")
    )
    if foreign:
        failures.append(
            f"catalog contains repositories outside {ORGANIZATION}: {', '.join(foreign)}"
        )
    return failures


def _repository_state(
    repository: str, github: GitHubAPI
) -> tuple[dict[str, Any], list[Any], list[Any]]:
    metadata = github.json(f"repos/{repository}")
    pulls = github.json(f"repos/{repository}/pulls?state=open&per_page=100")
    branches = github.json(f"repos/{repository}/branches?per_page=100")
    if (
        not isinstance(metadata, dict)
        or not isinstance(pulls, list)
        or not isinstance(branches, list)
    ):
        raise RuntimeError(f"{repository}: GitHub API returned an unexpected shape")
    return metadata, pulls, branches


def audit_fleet(
    repositories: list[str], github: GitHubAPI, expected_count: int = EXPECTED_COUNT
) -> list[str]:
    failures = validate_catalog(repositories, expected_count)
    if failures:
        return failures
    defaults = github.json(f"orgs/{ORGANIZATION}/code-security/configurations/defaults")
    if defaults != []:
        failures.append("organization code-security defaults are configured")
    for repository in repositories:
        metadata, pulls, branches = _repository_state(repository, github)
        default_branch = metadata.get("default_branch")
        if metadata.get("private") is not False:
            failures.append(f"{repository}: repository must remain public")
        if not isinstance(default_branch, str) or not default_branch:
            failures.append(f"{repository}: default branch is missing")
            continue
        for path in RETIRED_FILES:
            status = github.status(
                f"repos/{repository}/contents/{path}?ref={quote(default_branch, safe='')}"
            )
            if status != 404:
                failures.append(
                    f"{repository}: retired file exists on {default_branch}: {path}"
                )
        for pull in pulls:
            if pull.get("user", {}).get("login") == DEPENDABOT:
                failures.append(
                    f"{repository}: open Dependabot PR #{pull.get('number')}"
                )
        for branch in branches:
            name = branch.get("name")
            if isinstance(name, str) and name.startswith("dependabot/"):
                failures.append(f"{repository}: Dependabot branch exists: {name}")
        alert_status = github.status(f"repos/{repository}/vulnerability-alerts")
        if alert_status == 204:
            failures.append(
                f"{repository}: Dependabot vulnerability alerts are enabled"
            )
        elif alert_status != 404:
            failures.append(
                f"{repository}: unexpected vulnerability-alert status {alert_status}"
            )
        security = github.json(f"repos/{repository}/automated-security-fixes")
        if security.get("enabled") is not False:
            failures.append(
                f"{repository}: Dependabot security updates are enabled or indeterminate"
            )
    return failures


def retire_fleet(repositories: list[str], github: GitHubAPI) -> None:
    failures = validate_catalog(repositories, len(repositories))
    if failures:
        raise ValueError("; ".join(failures))
    for repository in repositories:
        _, pulls, branches = _repository_state(repository, github)
        if github.status(f"repos/{repository}/vulnerability-alerts") == 204:
            github.mutate("DELETE", f"repos/{repository}/vulnerability-alerts")
        security = github.json(f"repos/{repository}/automated-security-fixes")
        if security.get("enabled") is True:
            github.mutate("DELETE", f"repos/{repository}/automated-security-fixes")
        for pull in pulls:
            if pull.get("user", {}).get("login") != DEPENDABOT:
                continue
            number = pull["number"]
            if pull.get("auto_merge") is not None:
                github.mutate(
                    "POST",
                    "graphql",
                    {
                        "query": "mutation($id:ID!){disablePullRequestAutoMerge(input:{pullRequestId:$id}){clientMutationId}}",
                        "variables": {"id": pull["node_id"]},
                    },
                )
            github.mutate(
                "POST",
                f"repos/{repository}/issues/{number}/comments",
                {"body": SUPERSESSION_COMMENT},
            )
            github.mutate(
                "PATCH", f"repos/{repository}/pulls/{number}", {"state": "closed"}
            )
        for branch in branches:
            name = branch.get("name")
            if isinstance(name, str) and name.startswith("dependabot/"):
                github.mutate(
                    "DELETE",
                    f"repos/{repository}/git/refs/heads/{quote(name, safe='')}",
                )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--retire",
        action="store_true",
        help="disable and remove mutable Dependabot state",
    )
    parser.add_argument("--policy", type=Path, default=POLICY)
    args = parser.parse_args()
    try:
        repositories = load_catalog(args.policy)
        catalog_failures = validate_catalog(repositories)
        if catalog_failures:
            raise RuntimeError("; ".join(catalog_failures))
        github = GhClient()
        if args.retire:
            retire_fleet(repositories, github)
        failures = audit_fleet(repositories, github)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"dependency automation audit failed closed: {error}", file=sys.stderr)
        return 1
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(
        f"Dependency automation retired across {len(repositories)}/{len(repositories)} public repositories."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
