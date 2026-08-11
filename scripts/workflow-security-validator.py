#!/usr/bin/env python3
"""Fail-closed authorization for Zizmor self-hosted-runner findings."""

import argparse
from collections import Counter
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys

import yaml

TOP_FIELDS = {"schema_version", "repositories"}
JOB_FIELDS = {"runs_on", "environment", "permissions", "allowed_secrets", "triggers", "if"}
SECRET_RE = re.compile(r"\bsecrets\.([A-Za-z_][A-Za-z0-9_]*)\b")
FORBIDDEN_TRIGGERS = {"pull_request_target", "workflow_run", "repository_dispatch"}


class PolicyError(ValueError):
    pass


def validate_zizmor_result(exit_code, findings):
    """Validate Zizmor's documented findings exit contract before authorization."""
    if not isinstance(findings, list):
        raise PolicyError("Zizmor output must be a JSON array")
    if exit_code == 0 and findings:
        raise PolicyError("Zizmor exit 0 requires an empty finding array")
    if exit_code == 13 and not findings:
        raise PolicyError("Zizmor exit 13 requires a non-empty finding array")
    if exit_code not in {0, 13}:
        raise PolicyError(f"unsupported Zizmor exit code: {exit_code}")


def strict_object(value, allowed, context):
    if not isinstance(value, dict):
        raise PolicyError(f"{context} must be an object")
    unknown = set(value) - set(allowed)
    if unknown:
        raise PolicyError(f"{context} has unknown fields: {sorted(unknown)}")
    return value


def load_policy(path, repository):
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise PolicyError(f"cannot read policy {path}: {exc}") from exc
    strict_object(raw, TOP_FIELDS, "policy")
    if raw.get("schema_version") != 1:
        raise PolicyError(f"unsupported schema_version: {raw.get('schema_version')!r}")
    repositories = raw.get("repositories")
    if not isinstance(repositories, dict) or repository not in repositories:
        raise PolicyError(f"repository {repository!r} is not present in policy")
    result = {}
    workflows = repositories[repository]
    if not isinstance(workflows, dict):
        raise PolicyError("repository policy must be a workflow object")
    for workflow, jobs in workflows.items():
        if not isinstance(workflow, str) or not workflow.startswith(".github/workflows/"):
            raise PolicyError(f"invalid workflow key: {workflow!r}")
        if not isinstance(jobs, dict) or not jobs:
            raise PolicyError(f"{workflow} must contain jobs")
        for job_id, spec in jobs.items():
            strict_object(spec, JOB_FIELDS, f"{workflow}/{job_id}")
            if set(spec) != JOB_FIELDS:
                raise PolicyError(f"{workflow}/{job_id} must define exactly {sorted(JOB_FIELDS)}")
            labels = spec["runs_on"]
            if not isinstance(labels, list) or not all(isinstance(x, str) for x in labels):
                raise PolicyError(f"{workflow}/{job_id}.runs_on must be a string array")
            if not isinstance(spec["permissions"], dict):
                raise PolicyError(f"{workflow}/{job_id}.permissions must be an object")
            if not isinstance(spec["allowed_secrets"], list) or len(set(spec["allowed_secrets"])) != len(spec["allowed_secrets"]):
                raise PolicyError(f"{workflow}/{job_id}.allowed_secrets must be a unique array")
            if not isinstance(spec["triggers"], dict) or not all(isinstance(x, str) for x in spec["triggers"]):
                raise PolicyError(f"{workflow}/{job_id}.triggers must be an exact trigger mapping")
            result[(workflow, job_id)] = spec
    return result


def route_component(item):
    if isinstance(item, str):
        return item
    if isinstance(item, dict) and set(item) == {"Key"} and isinstance(item["Key"], str):
        return item["Key"]
    raise PolicyError(f"malformed route component: {item!r}")


def normalize_location(location):
    if not isinstance(location, dict):
        raise PolicyError("location must be an object")
    symbolic = location.get("symbolic")
    if not isinstance(symbolic, dict):
        raise PolicyError("location.symbolic is missing")
    key = symbolic.get("key")
    local = key.get("Local") if isinstance(key, dict) else None
    path = local.get("verbatim_path") if isinstance(local, dict) else None
    if not isinstance(path, str):
        raise PolicyError("location.symbolic.key.Local.verbatim_path is missing")
    route_container = symbolic.get("route")
    route = route_container.get("route") if isinstance(route_container, dict) else None
    if not isinstance(route, list):
        raise PolicyError("location.symbolic.route.route must be an array")
    parts = [route_component(item) for item in route]
    if parts.count("jobs") != 1:
        raise PolicyError(f"route must contain exactly one jobs component: {parts}")
    index = parts.index("jobs")
    if index + 2 >= len(parts) or parts[index + 2:] != ["runs-on"]:
        raise PolicyError(f"route must identify exactly one job runs-on: {parts}")
    normalized = PurePosixPath(path).as_posix()
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized, parts[index + 1], parts


def workflow_on(workflow):
    return workflow.get("on", workflow.get(True))


def trigger_names(workflow):
    value = workflow_on(workflow)
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(x, str) for x in value):
        return sorted(value)
    if isinstance(value, dict) and all(isinstance(x, str) for x in value):
        return sorted(value)
    raise PolicyError("workflow on must be a string, string array, or mapping")


def effective_permissions(workflow, job):
    value = job.get("permissions", workflow.get("permissions"))
    if value is None:
        raise PolicyError("effective permissions are implicit")
    if value == "read-all" or value == "write-all":
        raise PolicyError("permissions shortcuts are forbidden")
    if not isinstance(value, dict) or not all(isinstance(k, str) and v in {"read", "write", "none"} for k, v in value.items()):
        raise PolicyError("effective permissions must be an explicit scope mapping")
    return value


def walk(value, path=()):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, path + (str(index),))
    elif isinstance(value, str):
        yield path, value


def validate_job(repository, workflow_path, job_id, workflow, job, spec):
    errors = []
    basename = repository.split("/", 1)[1]
    runs_on = job.get("runs-on")
    expected_labels = ["self-hosted", "Linux", "X64", basename]
    if runs_on != spec["runs_on"] or runs_on != expected_labels:
        errors.append(f"runs-on must equal {expected_labels!r}, got {runs_on!r}")
    if job.get("environment") != spec["environment"]:
        errors.append(f"environment mismatch: {job.get('environment')!r}")
    try:
        permissions = effective_permissions(workflow, job)
        if permissions != spec["permissions"]:
            errors.append(f"permissions mismatch: {permissions!r}")
    except PolicyError as exc:
        errors.append(str(exc))
    try:
        triggers = trigger_names(workflow)
        if triggers != sorted(spec["triggers"]):
            errors.append(f"trigger mismatch: {triggers!r}")
        if workflow_on(workflow) != spec["triggers"]:
            errors.append("complete trigger structure does not exactly match policy")
        if set(triggers) & FORBIDDEN_TRIGGERS:
            errors.append(f"forbidden trigger(s): {sorted(set(triggers) & FORBIDDEN_TRIGGERS)}")
        on = workflow_on(workflow)
        if "push" in triggers:
            push = on.get("push") if isinstance(on, dict) else None
            if not isinstance(push, dict) or push.get("branches") != ["main"]:
                errors.append("push must be bounded exactly to main")
    except PolicyError as exc:
        errors.append(str(exc))
    if job.get("if") != spec["if"]:
        errors.append("job if expression does not exactly match policy")
    references = set()
    for path, text in walk(job):
        names = set(SECRET_RE.findall(text))
        references.update(names)
        if names and ("run" in path or not ({"env", "with"} & set(path))):
            errors.append(f"secret reference in unsupported location {'.'.join(path)}")
    if references != set(spec["allowed_secrets"]):
        errors.append(f"secret set mismatch: {sorted(references)!r}")
    for step in job.get("steps", []):
        if isinstance(step, dict) and isinstance(step.get("uses"), str) and step["uses"].split("@", 1)[0] == "actions/checkout":
            if step.get("with", {}).get("persist-credentials") is not False:
                errors.append("checkout must use literal persist-credentials: false")
    return errors


def inventory(root, repository, policy):
    actual = {}
    for path in sorted((root / ".github/workflows").glob("*.y*ml")):
        relative = path.relative_to(root).as_posix()
        try:
            workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except Exception as exc:
            raise PolicyError(f"cannot parse {relative}: {exc}") from exc
        if not isinstance(workflow, dict) or not isinstance(workflow.get("jobs", {}), dict):
            raise PolicyError(f"malformed workflow {relative}")
        for job_id, job in workflow.get("jobs", {}).items():
            if not isinstance(job, dict):
                raise PolicyError(f"malformed job {relative}/{job_id}")
            runs_on = job.get("runs-on")
            self_hosted = isinstance(runs_on, list) and "self-hosted" in runs_on
            suspicious = isinstance(runs_on, str) and "self-hosted" in runs_on
            if suspicious:
                raise PolicyError(f"expression or scalar self-hosted runs-on at {relative}/{job_id}")
            if self_hosted:
                key = (relative, job_id)
                if key not in policy:
                    raise PolicyError(f"unlisted self-hosted job {relative}/{job_id}")
                errors = validate_job(repository, relative, job_id, workflow, job, policy[key])
                if errors:
                    raise PolicyError(f"{relative}/{job_id}: " + "; ".join(errors))
                actual[key] = workflow
    if set(actual) != set(policy):
        unused = sorted(set(policy) - set(actual))
        raise PolicyError(f"unused policy entries: {unused}")
    return set(actual)


def finding_ident(finding):
    ident = finding.get("ident") if isinstance(finding, dict) else None
    if isinstance(ident, str):
        return ident
    if isinstance(ident, dict):
        for key in ("slug", "id", "name"):
            if isinstance(ident.get(key), str):
                return ident[key]
    return finding.get("rule") if isinstance(finding, dict) else None


def validate(findings, root, repository, policy_path):
    if not isinstance(findings, list):
        raise PolicyError("Zizmor output must be a JSON array")
    policy = load_policy(policy_path, repository)
    actual = inventory(root, repository, policy)
    found = []
    routes = []
    for finding in findings:
        ident = finding_ident(finding)
        if ident != "self-hosted-runner":
            raise PolicyError(f"unapproved finding: {ident!r}")
        locations = finding.get("locations") if isinstance(finding, dict) else None
        if not isinstance(locations, list) or len(locations) != 1:
            raise PolicyError("each finding must have exactly one location")
        workflow, job_id, route = normalize_location(locations[0])
        key = (workflow, job_id)
        if key not in actual:
            raise PolicyError(f"finding route is not approved: {workflow}/{job_id}")
        found.append(key)
        routes.append((workflow, job_id, route))
    counts = Counter(found)
    duplicates = sorted(key for key, count in counts.items() if count != 1)
    if duplicates:
        raise PolicyError(f"duplicate findings: {duplicates}")
    if set(found) != actual:
        raise PolicyError(f"finding/job mismatch: missing={sorted(actual-set(found))}, extra={sorted(set(found)-actual)}")
    return routes


def parse_args(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("findings", type=Path)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        if not args.repository or args.repository.count("/") != 1:
            raise PolicyError("an exact --repository owner/name is required")
        findings = json.loads(args.findings.read_text(encoding="utf-8"))
        routes = validate(findings, Path.cwd(), args.repository, args.policy)
    except Exception as exc:
        print(f"workflow security validation failed: {exc}", file=sys.stderr)
        return 1
    for workflow, job_id, route in routes:
        print(f"approved {args.repository}:{workflow}:{job_id} route={json.dumps(route)}")
    print(f"validated {len(routes)} governed self-hosted-runner finding(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
