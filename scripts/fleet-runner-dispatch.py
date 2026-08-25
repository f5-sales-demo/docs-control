#!/usr/bin/env python3
# pylint: disable=invalid-name
"""Bounded, fair dispatcher for queued governed-repository runner jobs."""

from __future__ import annotations

import fcntl
import hashlib
import importlib.util
import json
import subprocess
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from collections.abc import Iterator

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "provision", ROOT / "provision-ephemeral-runners.py"
)
if SPEC is None or SPEC.loader is None:
    message = "cannot load runner provisioner"
    raise RuntimeError(message)
PROVISION = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROVISION
SPEC.loader.exec_module(PROVISION)

DISPATCH_ROOT = PROVISION.STATE_ROOT / "fleet-dispatch"
STATE_PATH = DISPATCH_ROOT / "state.json"
LOCK_PATH = DISPATCH_ROOT / "dispatch.lock"


@dataclass(frozen=True)
class RepositoryContext:
    """Runtime dependencies for dispatching one governed repository."""

    github: Any
    controller: Any
    policy: Any
    repository: str
    spec: Any


def state(repositories: tuple[str, ...]) -> dict[str, Any]:
    """Read and validate the durable dispatcher cursor and cooldowns."""
    try:
        value = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"cursor": 0, "cooldowns": {"primary": 0, "secondary": 0}}
    except (OSError, ValueError) as exc:
        message = f"cannot read fleet dispatcher state: {exc}"
        raise PROVISION.ProvisionError(message) from exc
    if not isinstance(value, dict) or set(value) != {"cursor", "cooldowns"}:
        message = "fleet dispatcher state is malformed"
        raise PROVISION.ProvisionError(message)
    cooldowns = value["cooldowns"]
    if (
        not isinstance(value["cursor"], int)
        or not isinstance(cooldowns, dict)
        or set(cooldowns) != {"primary", "secondary"}
        or not all(isinstance(item, int) and item >= 0 for item in cooldowns.values())
    ):
        message = "fleet dispatcher state is malformed"
        raise PROVISION.ProvisionError(message)
    value["cursor"] %= len(repositories)
    return value


def save(value: dict[str, Any]) -> None:
    """Persist dispatcher state atomically with private permissions."""
    DISPATCH_ROOT.mkdir(parents=True, exist_ok=True)
    PROVISION.safe_write(STATE_PATH, json.dumps(value, sort_keys=True), 0o600)


@contextmanager
def locked() -> Iterator[None]:
    """Hold the non-blocking singleton lock for one dispatcher cycle."""
    DISPATCH_ROOT.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def cache_path(path: str) -> Path:
    """Map one GitHub API path to its exact ETag cache path."""
    return DISPATCH_ROOT / (
        "etag-" + hashlib.sha256(path.encode()).hexdigest() + ".json"
    )


def get(github: Any, path: str) -> dict[str, Any]:
    """Fetch one GitHub object with a validated durable ETag cache."""
    cache: Any = None
    destination = cache_path(path)
    try:
        cache = json.loads(destination.read_text(encoding="utf-8"))
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as exc:
        message = f"cannot read fleet ETag cache: {exc}"
        raise PROVISION.ProvisionError(message) from exc
    valid = (
        isinstance(cache, dict)
        and set(cache) == {"path", "etag", "body"}
        and cache["path"] == path
        and isinstance(cache["etag"], str)
        and cache["etag"]
    )
    body, headers = github.request(
        "GET",
        path,
        headers={"If-None-Match": cache["etag"]} if valid else {},
        include_headers=True,
    )
    if body is None:
        if not valid:
            message = "GitHub returned 304 without a valid fleet cache"
            raise PROVISION.ProvisionError(message)
        return cache["body"]
    if not isinstance(body, dict):
        message = "GitHub fleet response is malformed"
        raise PROVISION.ProvisionError(message)
    etag = next(
        (
            value
            for key, value in headers.items()
            if key.lower() == "etag" and isinstance(value, str) and value
        ),
        None,
    )
    if etag:
        DISPATCH_ROOT.mkdir(parents=True, exist_ok=True)
        PROVISION.safe_write(
            destination,
            json.dumps({"path": path, "etag": etag, "body": body}, sort_keys=True),
            0o600,
        )
    return body


def valid_runs(response: dict[str, Any]) -> list[dict[str, Any]]:
    """Return only structurally valid queued or active workflow runs."""
    runs = response.get("workflow_runs")
    if not isinstance(runs, list) or any(
        not isinstance(run, dict) or not isinstance(run.get("id"), int) for run in runs
    ):
        message = "GitHub fleet workflow inventory is malformed"
        raise PROVISION.ProvisionError(message)
    return [run for run in runs if run.get("status") in {"queued", "in_progress"}]


def candidate_for(
    policy: Any, repository: str, profile: Any
) -> tuple[Any | None, Any | None]:
    """Resolve the primary and optional standby slot for one profile."""
    primary = next(
        (
            item
            for item in PROVISION.instances(policy)
            if item.repository == repository
            and item.profile == profile.name
            and item.slot == 0
        ),
        None,
    )
    standby = next(
        (
            item
            for item in PROVISION.standby_instances(policy)
            if item.repository == repository and item.profile == profile.name
        ),
        None,
    )
    return primary, standby


def active(item: Any) -> bool:
    """Return whether one exact runner unit is active."""
    result = PROVISION.command(
        ["systemctl", "is-active", item.unit], check=False, capture=True
    )
    return result.returncode == 0 and result.stdout.strip() == "active"


def primary_busy(
    github: Any, repository: str, spec: Any, profile: Any, primary: Any
) -> bool:
    """Confirm that the exact primary runner has accepted a job."""
    response = get(github, f"/repos/{repository}/actions/runners?per_page=100")
    runners = response.get("runners")
    if not isinstance(runners, list) or any(
        not isinstance(runner, dict) for runner in runners
    ):
        message = "GitHub fleet runner inventory is malformed"
        raise PROVISION.ProvisionError(message)
    prefix = f"gha-{spec.name}-{profile.name}-{primary.slot}-"
    return any(
        isinstance(runner.get("name"), str)
        and runner["name"].startswith(prefix)
        and runner.get("status") == "online"
        and runner.get("busy") is True
        for runner in runners
    )


def runner_is_idle(
    response: dict[str, Any], spec: Any, profile: Any, item: Any
) -> bool:
    """Confirm that an exact runner generation is online and idle."""
    runners = response.get("runners")
    if not isinstance(runners, list) or any(
        not isinstance(runner, dict) for runner in runners
    ):
        message = "GitHub fleet runner inventory is malformed"
        raise PROVISION.ProvisionError(message)
    prefix = f"gha-{spec.name}-{profile.name}-{item.slot}-"
    matching = [
        runner
        for runner in runners
        if isinstance(runner.get("name"), str) and runner["name"].startswith(prefix)
    ]
    return any(
        runner.get("status") == "online" and runner.get("busy") is False
        for runner in matching
    ) and not any(
        runner.get("status") == "online" and runner.get("busy") is True
        for runner in matching
    )


def reap_idle(
    github: Any,
    policy: Any,
    request_budget: int,
    protected_repositories: set[str],
) -> int:
    """Synchronously stop only verified-idle active runner services."""
    inventories: dict[str, dict[str, Any]] = {}
    requests = 0
    for item in PROVISION.active_fleet_instances(policy):
        if requests >= request_budget:
            break
        if item.repository in protected_repositories:
            continue
        response = inventories.get(item.repository)
        if response is None:
            response = get(
                github, f"/repos/{item.repository}/actions/runners?per_page=100"
            )
            inventories[item.repository] = response
            requests += 1
        spec = policy.repository(item.repository)
        profile = PROVISION.instance_profile(policy, item)
        if runner_is_idle(response, spec, profile, item):
            PROVISION.command(["systemctl", "stop", item.unit])
            print(
                f"[REAP] repository={item.repository} profile={profile.name} "
                f"unit={item.unit} runner=verified-idle"
            )
    return requests


def dispatch_job(
    context: RepositoryContext,
    job: dict[str, Any],
    trusted: bool,
    request_budget: int,
) -> int:
    """Start the exact eligible slot for one queued job."""
    labels = job.get("labels")
    if (
        job.get("status") != "queued"
        or not isinstance(labels, list)
        or not all(isinstance(label, str) for label in labels)
        or len(labels) != len(set(labels))
    ):
        return 0
    requests = 0
    for profile in context.spec.profiles:
        if set(labels) != context.controller.expected_labels(context.spec, profile) or (
            profile.docker_socket and not trusted
        ):
            continue
        primary, standby = candidate_for(context.policy, context.repository, profile)
        if primary is None:
            break
        candidate = primary
        if active(primary):
            if standby is None or active(standby) or request_budget <= 0:
                break
            busy = primary_busy(
                context.github,
                context.repository,
                context.spec,
                profile,
                primary,
            )
            requests = 1
            if not busy:
                break
            candidate = standby
        if not PROVISION.admission_allows(context.policy, candidate):
            print(
                f"[REFUSE] repository={context.repository} "
                f"profile={profile.name} admission=exceeded"
            )
            break
        PROVISION.authorize_runner_start(candidate)
        try:
            PROVISION.command(["systemctl", "start", candidate.unit])
        except (OSError, subprocess.SubprocessError):
            PROVISION.revoke_runner_start(candidate)
            raise
        print(
            f"[DISPATCH] repository={context.repository} "
            f"profile={profile.name} unit={candidate.unit}"
        )
        return requests
    return requests


def dispatch_repository(
    context: RepositoryContext, request_budget: int
) -> tuple[int, bool]:
    """Inspect and dispatch queued jobs for one repository within a budget."""
    requests = 0
    runs: list[dict[str, Any]] = []
    for status in ("queued", "in_progress"):
        if requests >= request_budget:
            break
        response = get(
            context.github,
            f"/repos/{context.repository}/actions/runs?status={status}&per_page=100",
        )
        requests += 1
        runs.extend(valid_runs(response))
    for run in runs:
        if requests >= request_budget:
            break
        response = get(
            context.github,
            f"/repos/{context.repository}/actions/runs/{run['id']}/jobs?per_page=100",
        )
        requests += 1
        jobs = response.get("jobs")
        if not isinstance(jobs, list) or any(not isinstance(job, dict) for job in jobs):
            message = "GitHub fleet job inventory is malformed"
            raise PROVISION.ProvisionError(message)
        trusted = any(PROVISION.successful_docker_trust_gate(job) for job in jobs)
        for job in jobs:
            requests += dispatch_job(
                context,
                job,
                trusted,
                request_budget - requests,
            )
    return requests, bool(runs)


def dispatch() -> int:
    """Make at most 80 inventory requests, resuming fairly from a durable cursor."""
    PROVISION.require_root()
    policy = PROVISION.active_policy()
    repositories = policy.dispatcher.repositories
    controller_module = PROVISION.load_controller()
    now = int(time.time())
    with locked():
        current = state(repositories)
        retry_at = max(current["cooldowns"].values())
        if retry_at > now:
            print(f"[COOLDOWN] fleet dispatcher retry_at={retry_at}")
            return 0
        github = controller_module.GitHubClient(
            controller_module.token_from_environment()
        )
        controller = controller_module.EphemeralController(policy, None)
        cursor = current["cursor"]
        ordered = repositories[cursor:] + repositories[:cursor]
        try:
            requests = 0
            protected_repositories = set()
            for offset, repository in enumerate(ordered):
                if requests >= policy.dispatcher.request_budget:
                    break
                context = RepositoryContext(
                    github,
                    controller,
                    policy,
                    repository,
                    policy.repository(repository),
                )
                consumed, has_work = dispatch_repository(
                    context, policy.dispatcher.request_budget - requests
                )
                requests += consumed
                if has_work:
                    protected_repositories.add(repository)
                current["cursor"] = (cursor + offset + 1) % len(repositories)
                save(current)
            requests += reap_idle(
                github,
                policy,
                policy.dispatcher.request_budget - requests,
                protected_repositories,
            )
        except controller_module.GitHubRateLimitError as exc:
            current["cooldowns"][exc.kind] = max(
                current["cooldowns"][exc.kind], exc.retry_at
            )
            save(current)
            print(f"[COOLDOWN] fleet dispatcher {exc.kind} retry_at={exc.retry_at}")
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(dispatch())
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"fleet dispatcher failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
