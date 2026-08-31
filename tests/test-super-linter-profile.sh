#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
workflow="$repo_root/.github/workflows/super-linter.yml"

python3 - "$workflow" <<'PYTEST'
import os
import subprocess
import sys
import tempfile
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
    "Run native Spectral OpenAPI lint",
    "Validate Spectral profile",
    "Upload Spectral profile",
    "Preserve Spectral conclusion",
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

assert lint["env"]["SUPPRESS_OUTPUT_ON_SUCCESS"] is True
assert "stoplightio/spectral-action" not in text

spectral = by_name["Run native Spectral OpenAPI lint"]
assert spectral["id"] == "spectral"
assert spectral["if"] == "hashFiles('.spectral.yaml', '.spectral.yml') != ''"
assert spectral.get("continue-on-error") is True
assert spectral["env"] == {
    "BASE_SHA": "${{ github.event.pull_request.base.sha || '' }}",
    "EVENT_NAME": "${{ github.event_name }}",
    "HEAD_SHA": "${{ github.event.pull_request.head.sha || github.sha }}",
    "NODE_OPTIONS": "--max-old-space-size=4096",
}
for fragment in (
    "spectral --version",
    '!= "6.16.3"',
    "runner-profile",
    "--name spectral",
    "--cache-state warm",
    "--variant native-spectral-suppressed",
    '--ruleset "$ruleset"',
    "--format github-actions",
    "--fail-severity error",
    "git ls-files -z -- '*.json' '*.yaml' '*.yml'",
    "git diff --name-only --diff-filter=ACMR -z",
    'case "$EVENT_NAME" in',
    "BEGIN OPENAPI DISCOVERY",
    "END OPENAPI DISCOVERY",
    'mapfile -d \'\' -t spectral_files',
    '"${spectral_files[@]}"',
):
    assert fragment in spectral["run"]

discovery = spectral["run"].split("# BEGIN OPENAPI DISCOVERY\n", 1)[1].split(
    "\n# END OPENAPI DISCOVERY", 1
)[0]
discovery = discovery.split("<<'PYDISCOVERY'\n", 1)[1].split("\nPYDISCOVERY", 1)[0]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    fixtures = {
        "api.json": '{"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{}}',
        "api.yaml": "openapi: 3.0.3\ninfo: {title: x, version: '1'}\npaths: {}\n",
        "legacy.yml": "swagger: '2.0'\ninfo: {title: x, version: '1'}\npaths: {}\n",
        "config.yaml": "service:\n  openapi: disabled\n",
        "-api.json": '{"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{}}',
        "odd\nname.json": '{"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{}}',
    }
    for name, content in fixtures.items():
        (root / name).write_text(content, encoding="utf-8")
    candidates = root / "candidates"
    targets = root / "targets"
    candidates.write_bytes(b"\0".join(os.fsencode(name) for name in fixtures) + b"\0")
    result = subprocess.run(
        [sys.executable, "-", str(candidates), str(targets)],
        input=discovery,
        text=True,
        cwd=root,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert targets.read_bytes().split(b"\0")[:-1] == [
        b"./api.json",
        b"./api.yaml",
        b"./legacy.yml",
        b"./-api.json",
        b"./odd\nname.json",
    ]

    (root / "broken.json").write_text('{"openapi":"3.1.0",', encoding="utf-8")
    candidates.write_bytes(b"broken.json\0")
    result = subprocess.run(
        [sys.executable, "-", str(candidates), str(targets)],
        input=discovery,
        text=True,
        cwd=root,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    assert "broken.json" in result.stderr

    candidates.write_bytes(b"config.yaml\0")
    result = subprocess.run(
        [sys.executable, "-", str(candidates), str(targets)],
        input=discovery,
        text=True,
        cwd=root,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert targets.read_bytes() == b""

    (root / "linked.yaml").symlink_to(root / "api.yaml")
    candidates.write_bytes(b"linked.yaml\0")
    result = subprocess.run(
        [sys.executable, "-", str(candidates), str(targets)],
        input=discovery,
        text=True,
        cwd=root,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    assert "not a regular file" in result.stderr

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / ".spectral.yaml").write_text("extends: spectral:oas\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(
        ["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True
    )
    subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
    (root / "unchanged.json").write_text('{"openapi":"3.1.0"}', encoding="utf-8")
    (root / "deleted.json").write_text('{"openapi":"3.1.0"}', encoding="utf-8")
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(["git", "commit", "-qm", "base"], cwd=root, check=True)
    base_sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    (root / "api.json").write_text('{"openapi":"3.1.0"}', encoding="utf-8")
    (root / "-api.yaml").write_text("swagger: '2.0'\n", encoding="utf-8")
    (root / "deleted.json").unlink()
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "commit", "-qm", "candidate"], cwd=root, check=True)
    head_sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    bin_dir = root / "bin"
    bin_dir.mkdir()
    args_file = root / "spectral-args"
    (bin_dir / "spectral").write_text(
        "#!/usr/bin/env bash\n"
        "if [[ ${1:-} == --version ]]; then echo 6.16.3; exit 0; fi\n"
        "printf '%s\\0' \"$@\" >\"$SPECTRAL_ARGS_FILE\"\n",
        encoding="utf-8",
    )
    (bin_dir / "runner-profile").write_text(
        "#!/usr/bin/env bash\n"
        "while (($#)) && [[ $1 != -- ]]; do shift; shift; done\n"
        "shift\n"
        'exec "$@"\n',
        encoding="utf-8",
    )
    for executable in ("spectral", "runner-profile"):
        (bin_dir / executable).chmod(0o755)
    env = os.environ | {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "RUNNER_TEMP": str(root / "runner-temp"),
        "GITHUB_RUN_ID": "1",
        "GITHUB_RUN_ATTEMPT": "1",
        "GITHUB_JOB": "lint",
        "SPECTRAL_ARGS_FILE": str(args_file),
        "BASE_SHA": base_sha,
        "EVENT_NAME": "pull_request",
        "HEAD_SHA": head_sha,
    }
    (root / "runner-temp").mkdir()
    result = subprocess.run(
        ["bash", "-c", spectral["run"]], cwd=root, env=env, capture_output=True, check=False
    )
    assert result.returncode == 0, result.stderr
    assert args_file.read_bytes().split(b"\0")[:-1] == [
        b"lint", b"--ruleset", b".spectral.yaml", b"--format", b"github-actions",
        b"--fail-severity", b"error", b"./-api.yaml", b"./api.json",
    ]

    env["EVENT_NAME"] = "workflow_dispatch"
    args_file.unlink()
    result = subprocess.run(
        ["bash", "-c", spectral["run"]],
        cwd=root,
        env=env,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert args_file.read_bytes().split(b"\0")[:-1] == [
        b"lint", b"--ruleset", b".spectral.yaml", b"--format", b"github-actions",
        b"--fail-severity", b"error", b"./-api.yaml", b"./api.json",
        b"./unchanged.json",
    ]

    env.update(EVENT_NAME="pull_request", BASE_SHA="not-a-sha")
    args_file.unlink()
    result = subprocess.run(
        ["bash", "-c", spectral["run"]],
        cwd=root,
        env=env,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    assert not args_file.exists()

spectral_profile = by_name["Validate Spectral profile"]
assert spectral_profile["id"] == "spectral_profile"
assert spectral_profile["if"] == "always() && hashFiles('.spectral.yaml', '.spectral.yml') != ''"
assert spectral_profile.get("continue-on-error") is True
for fragment in (
    "workload-profile.schema.json",
    "/opt/spectral/node_modules/ajv/dist/2020",
    "profile.phase !== 'spectral'",
    "profile.exit.code",
):
    assert fragment in spectral_profile["run"]

spectral_upload = by_name["Upload Spectral profile"]
assert spectral_upload["id"] == "spectral_profile_upload"
assert spectral_upload["if"] == "always() && hashFiles('.spectral.yaml', '.spectral.yml') != ''"
assert spectral_upload.get("continue-on-error") is True
assert spectral_upload["uses"] == "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
assert spectral_upload["with"] == {
    "name": "workload-profile-spectral",
    "path": "${{ runner.temp }}/workload-profile-spectral/profile.json",
    "if-no-files-found": "error",
    "retention-days": 30,
}

spectral_gate = by_name["Preserve Spectral conclusion"]
assert spectral_gate["if"] == "always() && hashFiles('.spectral.yaml', '.spectral.yml') != ''"
assert spectral_gate["env"] == {
    "SPECTRAL_OUTCOME": "${{ steps.spectral.outcome }}",
    "PROFILE_OUTCOME": "${{ steps.spectral_profile.outcome }}",
    "PROFILE_UPLOAD_OUTCOME": "${{ steps.spectral_profile_upload.outcome }}",
}
for name in spectral_gate["env"]:
    assert f'"${name}" != success' in spectral_gate["run"]
spectral_base_env = os.environ | {name: "success" for name in spectral_gate["env"]}
assert subprocess.run(
    ["bash", "-c", spectral_gate["run"]],
    env=spectral_base_env,
    capture_output=True,
    check=False,
).returncode == 0
for failed_outcome in spectral_gate["env"]:
    failure_env = spectral_base_env | {failed_outcome: "failure"}
    assert subprocess.run(
        ["bash", "-c", spectral_gate["run"]],
        env=failure_env,
        capture_output=True,
        check=False,
    ).returncode != 0

assert "Docker-capable lint is forbidden for fork pull requests." in text
PYTEST

echo "Super-Linter profiling workflow contract passed"
