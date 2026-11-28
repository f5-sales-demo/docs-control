#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$repo_root" <<'PYTEST'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

root = Path(sys.argv[1])
workflow = yaml.safe_load((root / ".github/workflows/super-linter.yml").read_text())
steps = workflow["jobs"]["lint"]["steps"]
by_name = {step.get("name"): step for step in steps}
verify = by_name["Verify current shell formatter"]
image = "ghcr.io/super-linter/super-linter@sha256:7620fb6f07a1908b0642d9ddc4f49da7d9f2b9497bcafee4d3d151d1e5567c0b"
assert verify["env"] == {
    "SUPER_LINTER_IMAGE": image,
    "SHFMT_VERSION": "v3.14.1",
}
assert "continue-on-error" not in verify
assert steps.index(verify) < steps.index(by_name["Start Super-Linter profiler"])
assert by_name["Run Super-Linter"]["uses"] == (
    "super-linter/super-linter@2da136927bd4a73596db63044b504547c62cb854"
)
hook_config = yaml.safe_load((root / ".pre-commit-config.yaml").read_text())
hooks = [hook for repo in hook_config["repos"] for hook in repo["hooks"]]
shfmt = next(hook for hook in hooks if hook["id"] == "shfmt")
assert shfmt["additional_dependencies"] == [
    "git+https://github.com/scop/pre-commit-shfmt@479be5958357ba5ab65ce47172117348516860e9"
]
assert shfmt["args"] == ["--write", "--indent", "2"]
assert shfmt["types"] == ["shell"]
assert shfmt["exclude_types"] == ["csh", "tcsh"]
assert 'TEXTLINT_PKG="textlint@15.8.0"' in (
    root / "scripts/lint-mdx-prose.sh"
).read_text()

with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    docker = temp / "docker"
    docker.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        "from pathlib import Path\n"
        "Path(os.environ['ARGV_FILE']).write_text(json.dumps(sys.argv[1:]))\n"
        "sys.stdout.write(os.environ['FORMATTER_OUTPUT'])\n"
        "sys.exit(int(os.environ['DOCKER_EXIT']))\n"
    )
    docker.chmod(0o700)
    for output, exit_code, expected_success in (
        ("v3.14.1\n", 0, True),
        ("v3.13.1\n", 0, False),
        ("", 0, False),
        ("v3.14.1-unverified\n", 0, False),
        ("v3.14.1\nambiguous evidence\n", 0, False),
        ("v3.14.1\n", 17, False),
    ):
        args_file = temp / "args.json"
        env = os.environ | verify["env"] | {
            "PATH": str(temp) + os.pathsep + os.environ["PATH"],
            "ARGV_FILE": str(args_file),
            "FORMATTER_OUTPUT": output,
            "DOCKER_EXIT": str(exit_code),
        }
        result = subprocess.run(
            ["bash", "-c", verify["run"]],
            cwd=temp,
            env=env,
            capture_output=True,
            check=False,
        )
        assert (result.returncode == 0) == expected_success, (
            output, exit_code, result.stdout, result.stderr
        )
        assert json.loads(args_file.read_text()) == [
            "run", "--rm", "--entrypoint", "/usr/bin/shfmt", image, "--version"
        ]

print("Current formatter provenance, rejection and prose parity checks passed")
PYTEST
