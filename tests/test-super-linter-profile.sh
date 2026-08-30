#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
workflow="$repo_root/.github/workflows/super-linter.yml"

python3 - "$workflow" <<'PYTEST'
import os
import subprocess
import sys
from pathlib import Path

import yaml

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
workflow = yaml.safe_load(text)
assert set(workflow["jobs"]) == {"trust-gate", "lint", "shell-unit-tests"}
assert workflow["jobs"]["lint"]["name"] == "Lint Code Base"
assert workflow["jobs"]["shell-unit-tests"]["name"] == "Shell Unit Tests"
assert workflow["jobs"]["lint"]["permissions"] == {
    "contents": "read",
    "statuses": "write",
    "pull-requests": "write",
    "packages": "read",
}
steps = workflow["jobs"]["lint"]["steps"]
by_name = {step.get("name"): step for step in steps}
required = (
    "Start Super-Linter profiler",
    "Run Super-Linter",
    "Finalize Super-Linter profile",
    "Upload Super-Linter profile",
    "Preserve Super-Linter conclusion",
)
assert set(required) <= by_name.keys()
order = [next(i for i, step in enumerate(steps) if step.get("name") == name) for name in required]
assert order == sorted(order)

start = by_name["Start Super-Linter profiler"]
assert start.get("continue-on-error") is True
assert start["env"] == {
    "SUPER_LINTER_IMAGE": "ghcr.io/super-linter/super-linter:v8.7.0",
    "SUPER_LINTER_DIGEST": "sha256:c05768164eed53bac7c82aade7a14a76955206d4962cd41be97118db96fa5996",
}
for fragment in (
    "RUNNER_TRACKING_ID=",
    "docker-action-profile",
    "--expected-digest",
    "--ready-file",
    "--pid-file",
    "--variant instrumentation",
):
    assert fragment in start["run"]

lint = by_name["Run Super-Linter"]
assert lint["id"] == "super_linter"
assert lint.get("continue-on-error") is True
assert lint["uses"] == "super-linter/super-linter@4ce20838b8ab83717e78138c5b3a1407148e0918"
assert "IGNORE_GITIGNORED_FILES" not in lint.get("env", {})

finalize = by_name["Finalize Super-Linter profile"]
assert finalize["id"] == "super_linter_profile"
assert finalize["if"] == "always()"
assert finalize.get("continue-on-error") is True
for fragment in (
    "docker-action-profile.schema.json",
    "/opt/spectral/node_modules/ajv/dist/2020",
    "/opt/spectral/node_modules/ajv-formats",
    "kill -TERM",
    "observer.result",
):
    assert fragment in finalize["run"]

upload = by_name["Upload Super-Linter profile"]
assert upload["id"] == "super_linter_profile_upload"
assert upload["if"] == "always()"
assert upload["uses"] == "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
assert upload["with"] == {
    "name": "workload-profile-super-linter",
    "path": "${{ runner.temp }}/workload-profile-super-linter/profile.json",
    "if-no-files-found": "error",
    "retention-days": 30,
}

gate = by_name["Preserve Super-Linter conclusion"]
assert gate["if"] == "always()"
assert gate["env"] == {
    "PROFILE_START_OUTCOME": "${{ steps.super_linter_profile_start.outcome }}",
    "SUPER_LINTER_OUTCOME": "${{ steps.super_linter.outcome }}",
    "PROFILE_FINALIZE_OUTCOME": "${{ steps.super_linter_profile.outcome }}",
    "PROFILE_UPLOAD_OUTCOME": "${{ steps.super_linter_profile_upload.outcome }}",
}
for name in gate["env"]:
    assert f'"${name}" != success' in gate["run"]
assert "exit 1" in gate["run"]

base_env = os.environ | {name: "success" for name in gate["env"]}
assert subprocess.run(
    ["bash", "-c", gate["run"]], env=base_env, capture_output=True, check=False
).returncode == 0
for failed_outcome in gate["env"]:
    failure_env = base_env | {failed_outcome: "failure"}
    assert subprocess.run(
        ["bash", "-c", gate["run"]],
        env=failure_env,
        capture_output=True,
        check=False,
    ).returncode != 0
cancelled_env = base_env | {"SUPER_LINTER_OUTCOME": "cancelled"}
assert subprocess.run(
    ["bash", "-c", gate["run"]], env=cancelled_env, capture_output=True, check=False
).returncode != 0

assert "SUPPRESS_OUTPUT_ON_SUCCESS" not in lint.get("env", {})
assert "stoplightio/spectral-action" in text
assert "Docker-capable lint is forbidden for fork pull requests." in text
PYTEST

echo "Super-Linter profiling workflow contract passed"
