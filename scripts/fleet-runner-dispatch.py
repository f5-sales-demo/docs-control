#!/usr/bin/env python3
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
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "provision", ROOT / "provision-ephemeral-runners.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load runner provisioner")
PROVISION = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROVISION
SPEC.loader.exec_module(PROVISION)

DISPATCH_ROOT = PROVISION.STATE_ROOT / "fleet-dispatch"
STATE_PATH = DISPATCH_ROOT / "state.json"
LOCK_PATH = DISPATCH_ROOT / "dispatch.lock"


def state(repositories):
    try:
        value = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"cursor": 0, "cooldowns": {"primary": 0, "secondary": 0}}
    except (OSError, ValueError) as exc:
        raise PROVISION.ProvisionError(
            f"cannot read fleet dispatcher state: {exc}"
        ) from exc
    if not isinstance(value, dict) or set(value) != {"cursor", "cooldowns"}:
        raise PROVISION.ProvisionError("fleet dispatcher state is malformed")
    cooldowns = value["cooldowns"]
    if (
        not isinstance(value["cursor"], int)
        or not isinstance(cooldowns, dict)
        or set(cooldowns) != {"primary", "secondary"}
        or not all(isinstance(item, int) and item >= 0 for item in cooldowns.values())
    ):
        raise PROVISION.ProvisionError("fleet dispatcher state is malformed")
    value["cursor"] %= len(repositories)
    return value


def save(value):
    DISPATCH_ROOT.mkdir(parents=True, exist_ok=True)
    PROVISION.safe_write(STATE_PATH, json.dumps(value, sort_keys=True), 0o600)


@contextmanager
def locked():
    DISPATCH_ROOT.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def cache_path(path):
    return DISPATCH_ROOT / (
        "etag-" + hashlib.sha256(path.encode()).hexdigest() + ".json"
    )


def get(github, path):
    cache = None
    destination = cache_path(path)
    try:
        cache = json.loads(destination.read_text(encoding="utf-8"))
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as exc:
        raise PROVISION.ProvisionError(f"cannot read fleet ETag cache: {exc}") from exc
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
            raise PROVISION.ProvisionError(
                "GitHub returned 304 without a valid fleet cache"
            )
        return cache["body"]
    if not isinstance(body, dict):
        raise PROVISION.ProvisionError("GitHub fleet response is malformed")
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


def valid_runs(response):
    runs = response.get("workflow_runs")
    if not isinstance(runs, list) or any(
        not isinstance(run, dict) or not isinstance(run.get("id"), int) for run in runs
    ):
        raise PROVISION.ProvisionError("GitHub fleet workflow inventory is malformed")
    return [run for run in runs if run.get("status") in {"queued", "in_progress"}]


def candidate_for(policy, repository, profile):
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


def active(item):
    result = PROVISION.command(
        ["systemctl", "is-active", item.unit], check=False, capture=True
    )
    return result.returncode == 0 and result.stdout.strip() == "active"


def primary_busy(github, repository, spec, profile, primary):
    response = get(github, f"/repos/{repository}/actions/runners?per_page=100")
    runners = response.get("runners")
    if not isinstance(runners, list) or any(
        not isinstance(runner, dict) for runner in runners
    ):
        raise PROVISION.ProvisionError("GitHub fleet runner inventory is malformed")
    prefix = f"gha-{spec.name}-{profile.name}-{primary.slot}-"
    return any(
        isinstance(runner.get("name"), str)
        and runner["name"].startswith(prefix)
        and runner.get("status") == "online"
        and runner.get("busy") is True
        for runner in runners
    )


def runner_is_idle(response, spec, profile, item):
    runners = response.get("runners")
    if not isinstance(runners, list) or any(
        not isinstance(runner, dict) for runner in runners
    ):
        raise PROVISION.ProvisionError("GitHub fleet runner inventory is malformed")
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


def reap_idle(github, policy, request_budget):
    """Asynchronously stop only verified-idle active runner services."""
    inventories = {}
    requests = 0
    for item in PROVISION.active_fleet_instances(policy):
        if requests >= request_budget:
            break
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
            PROVISION.command(["systemctl", "stop", "--no-block", item.unit])
            print(
                f"[REAP] repository={item.repository} profile={profile.name} "
                f"unit={item.unit} runner=verified-idle"
            )
    return requests


def dispatch():
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
            requests = reap_idle(github, policy, policy.dispatcher.request_budget)
            for offset, repository in enumerate(ordered):
                if requests >= policy.dispatcher.request_budget:
                    break
                runs = []
                for status in ("queued", "in_progress"):
                    if requests >= policy.dispatcher.request_budget:
                        break
                    response = get(
                        github,
                        f"/repos/{repository}/actions/runs?status={status}&per_page=100",
                    )
                    requests += 1
                    runs.extend(valid_runs(response))
                spec = policy.repository(repository)
                for run in runs:
                    if requests >= policy.dispatcher.request_budget:
                        break
                    response = get(
                        github,
                        f"/repos/{repository}/actions/runs/{run['id']}/jobs?per_page=100",
                    )
                    requests += 1
                    jobs = response.get("jobs")
                    if not isinstance(jobs, list) or any(
                        not isinstance(job, dict) for job in jobs
                    ):
                        raise PROVISION.ProvisionError(
                            "GitHub fleet job inventory is malformed"
                        )
                    trusted = any(
                        PROVISION.successful_docker_trust_gate(job) for job in jobs
                    )
                    for job in jobs:
                        labels = job.get("labels")
                        if (
                            job.get("status") != "queued"
                            or not isinstance(labels, list)
                            or not all(isinstance(label, str) for label in labels)
                            or len(labels) != len(set(labels))
                        ):
                            continue
                        for profile in spec.profiles:
                            if set(labels) != controller.expected_labels(
                                spec, profile
                            ) or (profile.docker_socket and not trusted):
                                continue
                            primary, standby = candidate_for(
                                policy, repository, profile
                            )
                            if primary is None:
                                break
                            candidate = primary
                            if active(primary):
                                if (
                                    standby is None
                                    or active(standby)
                                    or requests >= policy.dispatcher.request_budget
                                ):
                                    break
                                if not primary_busy(
                                    github, repository, spec, profile, primary
                                ):
                                    break
                                requests += 1
                                candidate = standby
                            if not PROVISION.admission_allows(policy, candidate):
                                print(
                                    f"[REFUSE] repository={repository} profile={profile.name} admission=exceeded"
                                )
                                break
                            PROVISION.authorize_runner_start(candidate)
                            try:
                                PROVISION.command(
                                    ["systemctl", "start", candidate.unit]
                                )
                            except (OSError, subprocess.SubprocessError):
                                PROVISION.revoke_runner_start(candidate)
                                raise
                            print(
                                f"[DISPATCH] repository={repository} profile={profile.name} unit={candidate.unit}"
                            )
                            break
                current["cursor"] = (cursor + offset + 1) % len(repositories)
                save(current)
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
