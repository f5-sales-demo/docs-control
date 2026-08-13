#!/usr/bin/env python3
# pylint: disable=invalid-name,too-many-branches
"""Fail closed when workflow routing or remote action pins escape fleet policy."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

SHA_RE = re.compile(r"[0-9a-f]{40}")
CANONICAL_REPOSITORY_LABEL = "${{ github.event.repository.name }}"


class AuditError(ValueError):
    """A deterministic workflow policy violation."""


def workflow_on(value):
    return value.get("on", value.get(True)) if isinstance(value, dict) else None


def load_policy(path, repository):
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise AuditError(f"cannot read runner policy: {exc}") from exc
    if raw.get("schema_version") != 2:
        raise AuditError("runner policy schema_version must be 2")
    repositories = raw.get("repositories")
    if not isinstance(repositories, dict) or repository not in repositories:
        raise AuditError(f"repository is not governed: {repository}")
    profiles = raw.get("profiles")
    if not isinstance(profiles, dict) or not profiles:
        raise AuditError("runner policy profiles must be a non-empty object")
    exceptions = raw.get("hosted_exceptions", {}).get(repository, {})
    if not isinstance(exceptions, dict):
        raise AuditError("repository hosted exceptions must be an object")
    return raw, exceptions


def remote_dependency(value):
    if not isinstance(value, str):
        raise AuditError(f"uses must be a string, got {value!r}")
    if value.startswith(("./", "docker://")):
        return None
    if "@" not in value:
        raise AuditError(f"remote action has no revision: {value}")
    _, revision = value.rsplit("@", 1)
    if not SHA_RE.fullmatch(revision):
        raise AuditError(f"remote action is not commit-pinned: {value}")
    return value


def expected_self_hosted_labels(repository_name, profile, profiles):
    labels = ["self-hosted", "Linux", "X64", CANONICAL_REPOSITORY_LABEL]
    if profile:
        if profile not in profiles:
            raise AuditError(f"unknown runner profile: {profile}")
        labels.extend(profiles[profile].get("labels", []))
    return labels


def exception_for(exceptions, relative, job_id):
    workflow = exceptions.get(relative, {})
    if not isinstance(workflow, dict):
        raise AuditError(f"hosted exception workflow must be an object: {relative}")
    return workflow.get(job_id)


def audit_job(repository, relative, job_id, job, profiles, exceptions, default_profile):
    errors = []
    if not isinstance(job, dict):
        return [f"{relative}/{job_id}: job must be an object"]
    if "uses" in job:
        try:
            remote_dependency(job["uses"])
        except AuditError as exc:
            errors.append(f"{relative}/{job_id}: {exc}")
        if "runs-on" in job:
            errors.append(
                f"{relative}/{job_id}: reusable-workflow job cannot set runs-on"
            )
        return errors
    runs_on = job.get("runs-on")
    exception = exception_for(exceptions, relative, job_id)
    if exception is not None:
        allowed = exception.get("runs_on") if isinstance(exception, dict) else None
        if allowed == "matrix":
            if not isinstance(runs_on, str) or "matrix." not in runs_on:
                errors.append(
                    f"{relative}/{job_id}: hosted exception requires matrix runs-on"
                )
        elif runs_on != allowed:
            errors.append(
                f"{relative}/{job_id}: hosted runs-on {runs_on!r} does not match {allowed!r}"
            )
        reason = exception.get("reason") if isinstance(exception, dict) else None
        if not isinstance(reason, str) or len(reason.strip()) < 12:
            errors.append(f"{relative}/{job_id}: hosted exception reason is incomplete")
    else:
        profile = default_profile
        if isinstance(runs_on, list) and len(runs_on) == 5:
            candidates = [
                name
                for name, spec in profiles.items()
                if runs_on[-1] in spec.get("labels", [])
            ]
            profile = candidates[0] if len(candidates) == 1 else None
        try:
            expected = expected_self_hosted_labels(
                repository.split("/", 1)[1], profile, profiles
            )
        except AuditError as exc:
            errors.append(f"{relative}/{job_id}: {exc}")
            expected = []
        static = list(expected)
        if len(static) >= 4:
            static[3] = repository.split("/", 1)[1]
        if runs_on not in (expected, static):
            errors.append(
                f"{relative}/{job_id}: runs-on must use the canonical repository route, got {runs_on!r}"
            )
        uses_super_linter = any(
            isinstance(step, dict)
            and isinstance(step.get("uses"), str)
            and step["uses"].startswith("super-linter/super-linter@")
            for step in job.get("steps", [])
        )
        if uses_super_linter and (
            profile not in profiles or not profiles[profile].get("container_socket")
        ):
            errors.append(
                f"{relative}/{job_id}: Super-Linter requires a container socket profile"
            )
    for index, step in enumerate(job.get("steps", [])):
        if not isinstance(step, dict) or "uses" not in step:
            continue
        try:
            remote_dependency(step["uses"])
        except AuditError as exc:
            errors.append(f"{relative}/{job_id}/steps/{index}: {exc}")
    return errors


def audit_repository(root, repository, policy_path):
    root = Path(root)
    policy, exceptions = load_policy(policy_path, repository)
    profiles = policy["profiles"]
    errors = []
    actual_exceptions = set()
    workflows = root / ".github/workflows"
    for path in sorted((*workflows.glob("*.yml"), *workflows.glob("*.yaml"))):
        relative = path.relative_to(root).as_posix()
        try:
            document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError) as exc:
            errors.append(f"{relative}: cannot parse workflow: {exc}")
            continue
        if not isinstance(document, dict) or not isinstance(document.get("jobs"), dict):
            errors.append(f"{relative}: workflow must contain a jobs object")
            continue
        if workflow_on(document) is None:
            errors.append(f"{relative}: workflow trigger is missing")
        for job_id, job in document["jobs"].items():
            if exception_for(exceptions, relative, job_id) is not None:
                actual_exceptions.add((relative, job_id))
            errors.extend(
                audit_job(
                    repository,
                    relative,
                    job_id,
                    job,
                    profiles,
                    exceptions,
                    policy["defaults"]["profile"],
                )
            )
    declared_exceptions = {
        (workflow, job_id) for workflow, jobs in exceptions.items() for job_id in jobs
    }
    for workflow, job_id in sorted(declared_exceptions - actual_exceptions):
        errors.append(f"unused hosted exception: {workflow}/{job_id}")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--repository", required=True)
    parser.add_argument(
        "--policy",
        type=Path,
        default=Path(".github/config/self-hosted-runner-policy.json"),
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        errors = audit_repository(args.root, args.repository, args.policy)
    except AuditError as exc:
        errors = [str(exc)]
    if args.json:
        print(json.dumps({"repository": args.repository, "errors": errors}, indent=2))
    else:
        for error in errors:
            print(f"::error::{error}", file=sys.stderr)
        if not errors:
            print(
                f"validated workflow routing and immutable pins for {args.repository}"
            )
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
