#!/usr/bin/env bash
# Contracts for immutable remote workflow dependencies and their roll-forward path.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PIN_CONFIG="$REPO_ROOT/.github/config/governed-workflow-pin.json"
UPDATER="$REPO_ROOT/scripts/update_governed_workflow_pins.py"
UPDATER_WORKFLOW="$REPO_ROOT/.github/workflows/update-governed-workflow-pins.yml"
FAIL=0

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "[OK] $label"
  else
    echo "[FAIL] $label"
    FAIL=1
  fi
}

check "every remote action and reusable workflow is commit-pinned" \
  python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
mutable = []
for directory in (root / ".github/workflows", root / "workflows"):
    for workflow in sorted((*directory.glob("*.yml"), *directory.glob("*.yaml"))):
        for line_number, line in enumerate(workflow.read_text(encoding="utf-8").splitlines(), 1):
            match = re.match(r"\s*uses:\s*([^\s#]+)", line)
            if not match:
                continue
            dependency = match.group(1)
            if dependency.startswith(("./", "docker://")):
                continue
            if not re.fullmatch(r"[^@]+@[0-9a-f]{40}", dependency):
                mutable.append(f"{workflow.relative_to(root)}:{line_number}: {dependency}")
if mutable:
    print("\n".join(mutable), file=sys.stderr)
    raise SystemExit(1)
PY

check "governed callers share the configured docs-control revision" \
  python3 - "$REPO_ROOT" "$PIN_CONFIG" <<'PY'
from pathlib import Path
import json
import re
import sys

root = Path(sys.argv[1])
config = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
expected = config["revision"]
if not re.fullmatch(r"[0-9a-f]{40}", expected):
    raise SystemExit(f"invalid configured revision: {expected!r}")
refs = []
for workflow in sorted((root / "workflows").glob("*.yml")):
    refs.extend(
        re.findall(
            r"f5-sales-demo/docs-control/\.github/workflows/[^@\s]+@([0-9a-f]{40})",
            workflow.read_text(encoding="utf-8"),
        )
    )
if not refs or set(refs) != {expected}:
    raise SystemExit(f"configured={expected}; callers={sorted(set(refs))}")
PY

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/workflows" "$WORK/.github/config"
cp "$REPO_ROOT"/workflows/*.yml "$WORK/workflows/"
cp "$PIN_CONFIG" "$WORK/.github/config/governed-workflow-pin.json"
TARGET=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

check "pin updater deterministically rewrites callers and its revision receipt" \
  python3 "$UPDATER" --root "$WORK" --revision "$TARGET"

check "updated fixture records the requested revision" \
  test "$(jq -r .revision "$WORK/.github/config/governed-workflow-pin.json")" = "$TARGET"

check "updated fixture contains no previous docs-control workflow revision" \
  bash -c '! grep -R -E "docs-control/.github/workflows/[^@]+@(main|[0-9a-f]{40})" "$1/workflows" | grep -v "@$2"' _ "$WORK" "$TARGET"

SECOND_RUN=$(python3 "$UPDATER" --root "$WORK" --revision "$TARGET")
check "pin updater is idempotent" grep -q '^updated 0 file(s)' <<<"$SECOND_RUN"

check "pin updater rejects a mutable revision" \
  bash -c '! python3 "$1" --root "$2" --revision main >/dev/null 2>&1' _ "$UPDATER" "$WORK"

check "roll-forward workflow invokes the updater for reusable implementation changes" \
  python3 - "$REPO_ROOT" "$UPDATER_WORKFLOW" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
workflow = Path(sys.argv[2]).read_text(encoding="utf-8")
called = set()
for caller in (root / "workflows").glob("*.yml"):
    called.update(
        re.findall(
            r"f5-sales-demo/docs-control/\.github/workflows/([^@\s]+)@[0-9a-f]{40}",
            caller.read_text(encoding="utf-8"),
        )
    )
missing = [name for name in sorted(called) if f".github/workflows/{name}" not in workflow]
required = (
    "scripts/update_governed_workflow_pins.py",
    "--revision \"$TARGET_REVISION\"",
    "git merge-base --is-ancestor",
    "refusing to roll governed workflows backward",
    "git cat-file -e",
    "REPO_SETTINGS_TOKEN",
)
missing.extend(token for token in required if token not in workflow)
if "push --force" in workflow or "push -f" in workflow:
    missing.append("workflow must not force-push")
if missing:
    raise SystemExit("missing/invalid updater contract: " + ", ".join(missing))
PY

check "zizmor enforces unpinned-use findings" \
  python3 - "$REPO_ROOT/zizmor.yaml" <<'PY'
import sys
import yaml

config = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(1 if config.get("rules", {}).get("unpinned-uses", {}).get("disable") else 0)
PY

exit "$FAIL"
