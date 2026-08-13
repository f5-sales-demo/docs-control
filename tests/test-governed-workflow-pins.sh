#!/usr/bin/env bash
# Contracts for immutable remote workflow dependencies and their roll-forward path.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PIN_CONFIG="$REPO_ROOT/.github/config/governed-workflow-pin.json"
UPDATER="$REPO_ROOT/scripts/update_governed_workflow_pins.py"
UPDATER_WORKFLOW="$REPO_ROOT/.github/workflows/update-governed-workflow-pins.yml"
ROLLOUT_SCRIPT="$REPO_ROOT/scripts/update-governed-workflow-pins.sh"
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

check "governed Super-Linter pin references Docker-routed trusted implementation" \
  bash -c '
    revision=$(jq -er '\''.revision | select(type == "string" and test("^[0-9a-f]{40}$"))'\'' "$2") &&
      if git -C "$1" cat-file -e "${revision}^{commit}" 2>/dev/null; then
        implementation=$(git -C "$1" show "${revision}:.github/workflows/super-linter.yml")
      else
        remote=$(git -C "$1" remote get-url origin) &&
          git init --quiet "$3" &&
          git -C "$3" fetch --no-tags --quiet --depth=1 "$remote" "$revision" &&
          test "$(git -C "$3" rev-parse FETCH_HEAD)" = "$revision" &&
          implementation=$(git -C "$3" show "FETCH_HEAD:.github/workflows/super-linter.yml")
      fi &&
      grep -Fq '\''runs-on: [self-hosted, Linux, X64, "${{ github.event.repository.name }}", container-build]'\'' <<<"$implementation" &&
      grep -Fq '\''github.event.pull_request.head.repo.full_name == github.repository'\'' <<<"$implementation" &&
      grep -Fq '\''Docker-capable lint is forbidden for fork pull requests.'\'' <<<"$implementation"
  ' _ "$REPO_ROOT" "$PIN_CONFIG" "$WORK/pinned-revision"

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

check "protected main requires up-to-date status checks before delayed auto-merge" \
  jq -e '.branch_protection[] | select(.branch == "main") | .required_status_checks.strict == true' \
  "$REPO_ROOT/.github/config/repo-settings.json"

check "protected main requires pull requests without a review bypass" \
  jq -e '
    .branch_protection[] | select(.branch == "main") |
    .required_pull_request_reviews == {
      dismiss_stale_reviews: false,
      require_code_owner_reviews: false,
      required_approving_review_count: 0,
      require_last_push_approval: false,
      dismissal_restrictions: {users: [], teams: []},
      bypass_pull_request_allowances: {users: [], teams: [], apps: []}
    }
  ' "$REPO_ROOT/.github/config/repo-settings.json"

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
    "scripts/update-governed-workflow-pins.sh",
    "REPO_SETTINGS_TOKEN",
)
missing.extend(token for token in required if token not in workflow)
if "push --force" in workflow or "push -f" in workflow:
    missing.append("workflow must not force-push")
if missing:
    raise SystemExit("missing/invalid updater contract: " + ", ".join(missing))
PY

check "roll-forward script exists and is executable" test -x "$ROLLOUT_SCRIPT"

BEHAVIOR="$WORK/behavior"
mkdir -p "$BEHAVIOR/bin" "$BEHAVIOR/state"
REAL_JQ_COMMAND=$(command -v jq)
REAL_MKTEMP_COMMAND=$(command -v mktemp)
export REAL_JQ_COMMAND REAL_MKTEMP_COMMAND
cat >"$BEHAVIOR/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COMMAND_LOG"
if [ "${FAKE_FETCH_FAIL:-}" = 1 ] && [ "$1" = fetch ]; then exit 1; fi
if [ "$1" = rev-parse ] && [[ "$*" == *'refs/remotes/origin/main'* ]]; then
  printf '%s\n' "${FAKE_MAIN_OID:-1111111111111111111111111111111111111111}"
  exit 0
fi
exit 0
EOF
cat >"$BEHAVIOR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COMMAND_LOG"
if [[ "$*" == api\ repos/*/pulls\?state=open* ]]; then
  count_file="$FAKE_STATE/inventory-count"
  count=0
  [ ! -f "$count_file" ] || count=$(cat "$count_file")
  count=$((count + 1))
  printf '%s\n' "$count" >"$count_file"
  if [ "${FAKE_INVENTORY_FAIL_AT:-0}" -eq "$count" ]; then exit 1; fi
  if [ "${FAKE_INVENTORY_MALFORMED_AT:-0}" -eq "$count" ]; then
    printf '[[{}]]\n'
    exit 0
  fi
  if [ "${FAKE_DUPLICATE_CURRENT:-}" = 1 ]; then
    jq -cn --arg branch "$FAKE_CURRENT_BRANCH" --arg repo "f5-sales-demo/docs-control" \
      '[[{number: 10, head: {ref: $branch, sha: "9999999999999999999999999999999999999999", repo: {full_name: $repo}}, base: {ref: "main"}},
         {number: 11, head: {ref: $branch, sha: "9999999999999999999999999999999999999999", repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    exit 0
  elif [ "${FAKE_FORK_CURRENT:-}" = 1 ]; then
    jq -cn --arg branch "$FAKE_CURRENT_BRANCH" --arg repo "f5-sales-demo-fork/docs-control" \
      '[[{number: 9, head: {ref: $branch, sha: "9999999999999999999999999999999999999999", repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    exit 0
  elif [ "${FAKE_FORK_CURRENT_AFTER_DELETE:-}" = 1 ] &&
    [ -f "$FAKE_STATE/old-ref-deleted" ]; then
    jq -cn --arg branch "$FAKE_CURRENT_BRANCH" --arg repo "f5-sales-demo-fork/docs-control" \
      '[[{number: 9, head: {ref: $branch, sha: "9999999999999999999999999999999999999999", repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    exit 0
  elif [ "${FAKE_OLD_PR:-}" = 1 ] && [ ! -f "$FAKE_STATE/old-pr-closed" ]; then
    jq -cn --arg repo "f5-sales-demo/docs-control" \
      '[[{number: 10, head: {ref: "sync/governed-workflow-pins-aaaaaaaaaaaa-1-1", sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    exit 0
  elif [ "${FAKE_OLD_PR:-}" = 1 ] && [ -f "$FAKE_STATE/old-pr-closed" ]; then
    count_file="$FAKE_STATE/post-close-pr-reads"
    count=0
    [ ! -f "$count_file" ] || count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "${FAKE_PERSIST_OLD_PR:-}" = 1 ] ||
      [ "$count" -le "${FAKE_PR_VISIBILITY_LAG_READS:-0}" ]; then
      jq -cn --arg repo "f5-sales-demo/docs-control" \
        '[[{number: 10, head: {ref: "sync/governed-workflow-pins-aaaaaaaaaaaa-1-1", sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", repo: {full_name: $repo}}, base: {ref: "main"}}]]'
    else
      printf '[[]]\n'
    fi
    exit 0
  fi
  printf '[[]]\n'
  exit 0
fi
if [[ "$*" == api\ repos/*/git/matching-refs/heads/sync/governed-workflow-pins-* ]]; then
  if [ "${FAKE_OLD_REF:-}" = 1 ] && [ ! -f "$FAKE_STATE/old-ref-deleted" ]; then
    printf '[[{"ref":"refs/heads/sync/governed-workflow-pins-aaaaaaaaaaaa-1-1","object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]]\n'
  elif [ "${FAKE_OLD_REF:-}" = 1 ] && [ -f "$FAKE_STATE/old-ref-deleted" ]; then
    count_file="$FAKE_STATE/post-delete-ref-reads"
    count=0
    [ ! -f "$count_file" ] || count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "${FAKE_NEWER_REF_AFTER_DELETE:-}" = 1 ]; then
      printf '[[{"ref":"refs/heads/sync/governed-workflow-pins-cccccccccccc-3-1","object":{"sha":"cccccccccccccccccccccccccccccccccccccccc"}}]]\n'
    elif [ "${FAKE_UNSEEN_OLDER_REF_AFTER_DELETE:-}" = 1 ]; then
      printf '[[{"ref":"refs/heads/sync/governed-workflow-pins-cccccccccccc-1-1","object":{"sha":"cccccccccccccccccccccccccccccccccccccccc"}}]]\n'
    elif [ "${FAKE_EMPTY_THEN_STALE_REF:-}" = 1 ] && [ "$count" -eq 1 ]; then
      printf '[[]]\n'
    elif [ "${FAKE_EMPTY_THEN_STALE_REF:-}" = 1 ] && [ "$count" -eq 2 ]; then
      printf '[[{"ref":"refs/heads/sync/governed-workflow-pins-aaaaaaaaaaaa-1-1","object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]]\n'
    elif [ "${FAKE_PERSIST_OLD_REF:-}" = 1 ] ||
      [ "$count" -le "${FAKE_REF_VISIBILITY_LAG_READS:-0}" ]; then
      printf '[[{"ref":"refs/heads/sync/governed-workflow-pins-aaaaaaaaaaaa-1-1","object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]]\n'
    else
      printf '[[]]\n'
    fi
  else
    printf '[[]]\n'
  fi
  exit 0
fi
if [[ "$*" == pr\ close\ 10* ]]; then
  touch "$FAKE_STATE/old-pr-closed"
  exit 0
fi
if [[ "$*" == *'/git/ref/heads/sync/governed-workflow-pins-aaaaaaaaaaaa-1-1'* ]]; then
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
  exit 0
fi
if [[ "$*" == *'/git/refs/heads/sync/governed-workflow-pins-aaaaaaaaaaaa-1-1 --method DELETE'* ]]; then
  touch "$FAKE_STATE/old-ref-deleted"
  exit 0
fi
if [[ "$*" == *'/branches/main/protection/required_status_checks'* ]]; then
  printf '%s\n' "${FAKE_STRICT_VALUE:-true}"
  exit 0
fi
exit 64
EOF
cat >"$BEHAVIOR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$FAKE_COMMAND_LOG"
count_file="$FAKE_STATE/sleep-count"
count=0
[ ! -f "$count_file" ] || count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [ "${FAKE_SLEEP_FAIL_AT:-0}" -eq "$count" ]; then exit 1; fi
EOF
cat >"$BEHAVIOR/bin/jq" <<'EOF'
#!/usr/bin/env bash
if [ "${FAKE_JQ_TSV_FAIL:-}" = 1 ] && [[ "$*" == *'@tsv'* ]]; then exit 42; fi
exec "$REAL_JQ_COMMAND" "$@"
EOF
cat >"$BEHAVIOR/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
count_file="$FAKE_STATE/mktemp-count"
count=0
[ ! -f "$count_file" ] || count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [ "${FAKE_MKTEMP_FAIL:-}" = 1 ]; then exit 1; fi
exec "$REAL_MKTEMP_COMMAND" "$@"
EOF
chmod +x "$BEHAVIOR/bin/git" "$BEHAVIOR/bin/gh" "$BEHAVIOR/bin/sleep" \
  "$BEHAVIOR/bin/jq" "$BEHAVIOR/bin/mktemp"

check "failed main fetch cannot pass against a stale local tracking ref" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_FETCH_FAIL=1
    source "$1"
    target_revision=2222222222222222222222222222222222222222
    workflow_list="$2/workflows"
    : >"$workflow_list"
    ! assert_target_current 1111111111111111111111111111111111111111
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "failed first PR inventory read blocks every reconciliation mutation" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state" FAKE_INVENTORY_FAIL_AT=1
    : >"$FAKE_COMMAND_LOG"; rm -f "$FAKE_STATE/inventory-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-test-2-1
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs && ! grep -Eq "pr close|method DELETE" "$FAKE_COMMAND_LOG"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "failed second PR inventory read blocks auto-merge ownership proof" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state" FAKE_INVENTORY_FAIL_AT=2
    : >"$FAKE_COMMAND_LOG"; rm -f "$FAKE_STATE/inventory-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-test-2-1
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs && ! grep -Eq "pr close|method DELETE" "$FAKE_COMMAND_LOG"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "ownership row extraction failure cannot erase a hostile owner" \
  bash -c '
    expected_branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_FORK_CURRENT=1 FAKE_CURRENT_BRANCH="$expected_branch" FAKE_JQ_TSV_FAIL=1
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/mktemp-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch="$expected_branch"
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs &&
      ! grep -Eq "pr (close|create|merge)|method (POST|PUT|PATCH|DELETE)" "$FAKE_COMMAND_LOG"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "ownership reconciliation stops after its first allocation failure" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_MKTEMP_FAIL=1
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/mktemp-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs && test "$(cat "$FAKE_STATE/mktemp-count")" -eq 1 &&
      ! grep -Eq "api |pr " "$FAKE_COMMAND_LOG"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "hostile same-ref fork PR blocks governed-pin mutation" \
  bash -c '
    expected_branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_FORK_CURRENT=1 FAKE_CURRENT_BRANCH="$expected_branch"
    : >"$FAKE_COMMAND_LOG"; rm -f "$FAKE_STATE/inventory-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch="$expected_branch"
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs &&
      ! grep -Eq "pr (close|create|merge)|method (POST|PUT|PATCH|DELETE)" "$FAKE_COMMAND_LOG"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "duplicate current governed-pin PRs block mutation" \
  bash -c '
    expected_branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_DUPLICATE_CURRENT=1 FAKE_CURRENT_BRANCH="$expected_branch"
    : >"$FAKE_COMMAND_LOG"; rm -f "$FAKE_STATE/inventory-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch="$expected_branch"
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs &&
      ! grep -Eq "pr (close|create|merge)|method (POST|PUT|PATCH|DELETE)" "$FAKE_COMMAND_LOG"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "oversized automation run identifiers defer without integer overflow" \
  bash -c '
    source "$1"; run_id=2; run_attempt=1
    set +e
    classify_owner sync/governed-workflow-pins-aaaaaaaaaaaa-999999999999999999999999999999-1
    rc=$?
    set -e
    [ "$rc" -eq 75 ]
  ' _ "$ROLLOUT_SCRIPT"

check "orphaned older updater refs are deleted after complete paginated inventory" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state" FAKE_OLD_REF=1
    : >"$FAKE_COMMAND_LOG"; rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    reconcile_pin_prs && test -f "$FAKE_STATE/old-ref-deleted" &&
      grep -q -- "--paginate --slurp" "$FAKE_COMMAND_LOG"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "deleted updater refs may settle after bounded visibility lag" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_REF=1 FAKE_REF_VISIBILITY_LAG_READS=2
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    reconcile_pin_prs && test -f "$FAKE_STATE/old-ref-deleted" &&
      test "$(cat "$FAKE_STATE/post-delete-ref-reads")" -eq 4 &&
      test "$(grep "^sleep " "$FAKE_COMMAND_LOG" | cut -d " " -f 2 | paste -sd, -)" = "1,2,4"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "persistently published deleted updater refs still fail closed" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_REF=1 FAKE_PERSIST_OLD_REF=1
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs && test -f "$FAKE_STATE/old-ref-deleted" &&
      test "$(cat "$FAKE_STATE/post-delete-ref-reads")" -eq 6 &&
      test "$(grep "^sleep " "$FAKE_COMMAND_LOG" | cut -d " " -f 2 | paste -sd, -)" = "1,2,4,4,4"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "closed PR and deleted ref visibility settle only after two clear inventories" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_PR=1 FAKE_PR_VISIBILITY_LAG_READS=1
    export FAKE_OLD_REF=1 FAKE_REF_VISIBILITY_LAG_READS=2
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-pr-closed" \
      "$FAKE_STATE/post-close-pr-reads" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    reconcile_pin_prs && test -f "$FAKE_STATE/old-pr-closed" &&
      test -f "$FAKE_STATE/old-ref-deleted" &&
      test "$(cat "$FAKE_STATE/post-close-pr-reads")" -eq 4 &&
      test "$(cat "$FAKE_STATE/post-delete-ref-reads")" -eq 4 &&
      test "$(grep "^sleep " "$FAKE_COMMAND_LOG" | cut -d " " -f 2 | paste -sd, -)" = "1,2,4"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "an empty inventory followed by a stale deleted ref cannot pass early" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_REF=1 FAKE_EMPTY_THEN_STALE_REF=1
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    reconcile_pin_prs && test "$(cat "$FAKE_STATE/post-delete-ref-reads")" -eq 4 &&
      test "$(grep "^sleep " "$FAKE_COMMAND_LOG" | cut -d " " -f 2 | paste -sd, -)" = "1,2,4"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "a newer owner appearing while visibility settles defers immediately" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_REF=1 FAKE_NEWER_REF_AFTER_DELETE=1
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    set +e; reconcile_pin_prs; rc=$?; set -e
    test "$rc" -eq 75 && test ! -f "$FAKE_STATE/sleep-count"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "a hostile current-branch PR appearing while visibility settles fails immediately" \
  bash -c '
    expected_branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_REF=1 FAKE_FORK_CURRENT_AFTER_DELETE=1
    export FAKE_CURRENT_BRANCH="$expected_branch"
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch="$expected_branch"
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs && test ! -f "$FAKE_STATE/sleep-count" &&
      ! grep -Eq "pr (close|create|merge) 9|method (POST|PUT|PATCH)" "$FAKE_COMMAND_LOG"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "an unseen older owner appearing while visibility settles fails immediately" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_REF=1 FAKE_UNSEEN_OLDER_REF_AFTER_DELETE=1
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs && test ! -f "$FAKE_STATE/sleep-count"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "an API failure during visibility settling fails after no further sleeps" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_REF=1 FAKE_REF_VISIBILITY_LAG_READS=5 FAKE_INVENTORY_FAIL_AT=3
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs && test "$(grep "^sleep " "$FAKE_COMMAND_LOG")" = "sleep 1"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "malformed inventory during visibility settling fails after no further sleeps" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_REF=1 FAKE_REF_VISIBILITY_LAG_READS=5 FAKE_INVENTORY_MALFORMED_AT=3
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs && test "$(grep "^sleep " "$FAKE_COMMAND_LOG")" = "sleep 1"
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "an interrupted settling delay fails closed immediately" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STATE="$2/state"
    export FAKE_OLD_REF=1 FAKE_REF_VISIBILITY_LAG_READS=5 FAKE_SLEEP_FAIL_AT=1
    : >"$FAKE_COMMAND_LOG"
    rm -f "$FAKE_STATE/inventory-count" "$FAKE_STATE/old-ref-deleted" \
      "$FAKE_STATE/post-delete-ref-reads" "$FAKE_STATE/sleep-count"
    source "$1"
    repository=f5-sales-demo/docs-control; branch=sync/governed-workflow-pins-bbbbbbbbbbbb-2-1
    run_id=2; run_attempt=1; work="$2/state"
    ! reconcile_pin_prs && test "$(grep "^sleep " "$FAKE_COMMAND_LOG")" = "sleep 1" &&
      test "$(cat "$FAKE_STATE/post-delete-ref-reads")" -eq 1
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

NOOP_ORIGIN="$WORK/noop-origin.git"
NOOP_REPO="$WORK/noop-repo"
NOOP_BIN="$WORK/noop-bin"
git init -q --bare "$NOOP_ORIGIN"
git clone -q "$NOOP_ORIGIN" "$NOOP_REPO"
git -C "$NOOP_REPO" config user.email test@example.com
git -C "$NOOP_REPO" config user.name Test
mkdir -p "$NOOP_REPO/.github/workflows" "$NOOP_REPO/.github/config" \
  "$NOOP_REPO/workflows" "$NOOP_REPO/scripts" "$NOOP_BIN"
printf '%s\n' reusable >"$NOOP_REPO/.github/workflows/enforce-repo-settings.yml"
git -C "$NOOP_REPO" add .github/workflows/enforce-repo-settings.yml
git -C "$NOOP_REPO" commit -qm reusable
NOOP_TARGET=$(git -C "$NOOP_REPO" rev-parse HEAD)
printf 'uses: f5-sales-demo/docs-control/.github/workflows/enforce-repo-settings.yml@%s\n' \
  "$NOOP_TARGET" >"$NOOP_REPO/workflows/enforce-repo-settings.yml"
printf '{\n  "revision": "%s"\n}\n' "$NOOP_TARGET" \
  >"$NOOP_REPO/.github/config/governed-workflow-pin.json"
cp "$UPDATER" "$NOOP_REPO/scripts/update_governed_workflow_pins.py"
git -C "$NOOP_REPO" add workflows .github/config scripts
git -C "$NOOP_REPO" commit -qm configured
git -C "$NOOP_REPO" branch -M main
git -C "$NOOP_REPO" push -q -u origin main
ln -s "$BEHAVIOR/bin/gh" "$NOOP_BIN/gh"
rm -f "$BEHAVIOR/state/inventory-count" "$BEHAVIOR/state/old-ref-deleted"
: >"$BEHAVIOR/commands"
check "no-op updater still reconciles canceled-run orphan refs" \
  bash -c '
    cd "$2"
    export PATH="$3:$PATH" FAKE_COMMAND_LOG="$4/commands" FAKE_STATE="$4/state" FAKE_OLD_REF=1
    export GITHUB_REPOSITORY=f5-sales-demo/docs-control GITHUB_RUN_ID=2 GITHUB_RUN_ATTEMPT=1
    export REQUESTED_REVISION="$5"
    "$1" && test -f "$FAKE_STATE/old-ref-deleted" && ! grep -q "pr create" "$FAKE_COMMAND_LOG"
  ' _ "$ROLLOUT_SCRIPT" "$NOOP_REPO" "$NOOP_BIN" "$BEHAVIOR" "$NOOP_TARGET"

check "base movement defers before a stale updater branch can proceed" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_MAIN_OID=9999999999999999999999999999999999999999
    source "$1"
    target_revision=2222222222222222222222222222222222222222
    workflow_list="$2/workflows"; : >"$workflow_list"
    set +e; assert_target_current 1111111111111111111111111111111111111111; rc=$?; set -e
    [ "$rc" -eq 75 ]
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

check "non-strict live branch protection blocks delayed auto-merge" \
  bash -c '
    export PATH="$2/bin:$PATH" FAKE_COMMAND_LOG="$2/commands" FAKE_STRICT_VALUE=false
    source "$1"; repository=f5-sales-demo/docs-control
    ! assert_strict_protection
  ' _ "$ROLLOUT_SCRIPT" "$BEHAVIOR"

BASE_REPO="$WORK/base-proof"
git init -q "$BASE_REPO"
git -C "$BASE_REPO" config user.email test@example.com
git -C "$BASE_REPO" config user.name Test
mkdir -p "$BASE_REPO/workflows"
printf 'base\n' >"$BASE_REPO/base"
git -C "$BASE_REPO" add base
git -C "$BASE_REPO" commit -qm base
git -C "$BASE_REPO" branch -M main
git -C "$BASE_REPO" switch -qc updater
printf 'pin\n' >"$BASE_REPO/workflows/enforce-repo-settings.yml"
git -C "$BASE_REPO" add workflows/enforce-repo-settings.yml
git -C "$BASE_REPO" commit -qm pin
git -C "$BASE_REPO" switch -q main
printf 'advance\n' >"$BASE_REPO/advance"
git -C "$BASE_REPO" add advance
git -C "$BASE_REPO" commit -qm advance
ADVANCED_BASE=$(git -C "$BASE_REPO" rev-parse HEAD)
git -C "$BASE_REPO" switch -q updater
check "one-commit proof rejects a commit whose parent is not the current base" \
  bash -c '
    cd "$2"
    source "$1"; base_oid="$3"
    ! assert_local_commit
  ' _ "$ROLLOUT_SCRIPT" "$BASE_REPO" "$ADVANCED_BASE"

check "zizmor enforces unpinned-use findings" \
  python3 - "$REPO_ROOT/zizmor.yaml" <<'PY'
import sys
import yaml

config = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(1 if config.get("rules", {}).get("unpinned-uses", {}).get("disable") else 0)
PY

exit "$FAIL"
