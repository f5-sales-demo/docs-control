#!/usr/bin/env bash
# Structural check on dispatch-downstream.yml: a single runner must
# fan out to every downstream repo, cap parallelism at 5, keep bounded
# receipt-aware retry-with-backoff, and aggregate per-repo terminal states.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="${REPO_ROOT}/.github/workflows/dispatch-downstream.yml"
CONFIG="${REPO_ROOT}/.github/config/downstream-repos.json"
ROLLOUT="${REPO_ROOT}/.github/config/governance-rollout.json"

FAIL=0
check() {
  local label="$1"
  local cond="$2"
  if eval "$cond"; then
    echo "[OK] $label"
  else
    echo "[FAIL] $label"
    FAIL=1
  fi
}

# Architecture: one job named `dispatch`, no per-repo matrix fan-out.
check "has dispatch job" "grep -q '^  dispatch:$' '$WF'"
check "no matrix fan-out (single runner)" "! grep -q '^[[:space:]]*matrix:$' '$WF'"
check "no read-config job (consolidated)" "! grep -q '^  read-config:$' '$WF'"

# Parallelism cap stays at 5 via batched dispatch loop.
check "BATCH_SIZE=5 for parallelism cap" "grep -q 'BATCH_SIZE=5' '$WF'"

# Leave room for one complete secondary-limit cooldown plus preflight and the
# deterministic fleet pacing inside the explicit GitHub Free-compatible job timeout.
BATCH_SIZE_VALUE=$(sed -nE 's/^[[:space:]]*BATCH_SIZE=([0-9]+)$/\1/p' "$WF")
BATCH_DELAY_VALUE=$(sed -nE 's/^[[:space:]]*BATCH_DELAY=([0-9]+)$/\1/p' "$WF")
PROVISION_DELAY_VALUE=$(sed -nE \
  's/^[[:space:]]*PROVISION_REQUEST_DELAY_SECONDS: ([0-9]+)$/\1/p' "$WF")
PROVISION_DELAY_VALUE=${PROVISION_DELAY_VALUE:-0}
FLEET_SIZE=$(jq 'length' "$CONFIG")
BATCH_COUNT=$(((FLEET_SIZE + BATCH_SIZE_VALUE - 1) / BATCH_SIZE_VALUE))
SCHEDULED_SLEEP_SECONDS=$(((\
  BATCH_COUNT - 1) * BATCH_DELAY_VALUE + (\
  FLEET_SIZE - 1) * PROVISION_DELAY_VALUE))
JOB_TIMEOUT_MINUTES=$(sed -nE 's/^[[:space:]]*timeout-minutes: ([0-9]+)$/\1/p' "$WF")
DISPATCH_WAIT_BUDGET_SECONDS=$(sed -nE \
  's/^[[:space:]]*DISPATCH_WAIT_BUDGET_SECONDS: ([0-9]+)$/\1/p' "$WF")
RUNNER_RESERVE_SECONDS=300
check "job has a bounded 30-minute timeout" \
  "[ '$JOB_TIMEOUT_MINUTES' -eq 30 ]"
check "one full secondary cooldown and deterministic pacing fit with five minutes reserved" \
  "[ '$((SCHEDULED_SLEEP_SECONDS + DISPATCH_WAIT_BUDGET_SECONDS))' -le '$((JOB_TIMEOUT_MINUTES * 60 - RUNNER_RESERVE_SECONDS))' ]"
check "repository-secret inventory stays below 30 requests per minute" \
  "[ '$PROVISION_DELAY_VALUE' -eq 2 ]"

# The shared helper reads response headers, honors Retry-After, and applies the
# tested 60/120/240-second missing-header contract.
check "dispatch uses the receipt-aware resilience helper" \
  "grep -qF 'github-api-resilience.cjs dispatch' '$WF'"
check "dispatch preserves GitHub response diagnostics" \
  "! grep -qF '>/dev/null 2>&1' '$WF'"
check "dispatch has an explicit 15-minute wait budget" \
  "[ '$DISPATCH_WAIT_BUDGET_SECONDS' -eq 900 ]"

# Failure aggregation — step fails iff at least one dispatch failed.
check "emits [FAIL] markers" "grep -q '\[FAIL\]' '$WF'"
check "aggregates FAIL_COUNT" "grep -q 'FAIL_COUNT' '$WF'"
check "emits durable [DEFER] markers" "grep -q '\[DEFER\]' '$WF'"
check "aggregates DEFER_COUNT" "grep -q 'DEFER_COUNT' '$WF'"

# Config still drives the fan-out.
check "consumes downstream-repos.json" "grep -q 'downstream-repos.json' '$WF'"
check "config is JSON array" "jq -e 'type == \"array\" and length > 0' '$CONFIG' > /dev/null"
check "production governance rollout is active" \
  "jq -e '.state == \"active\"' '$ROLLOUT' > /dev/null"

# Trigger: dispatch must run when the regenerated manifest LANDS on main (the
# auto-merging sync/manifest PR merges), not when the manifest build completes.
# Triggering on build completion races the PR merge and fans out a stale
# manifest — see issue #634.
check "triggers on manifest landing on main" \
  "grep -q 'managed-files-manifest.json' '$WF'"
check "triggers on repo-settings.json (settings-only changes)" \
  "grep -q 'repo-settings.json' '$WF'"
check "triggers on README.md.tpl (dynamic README template changes)" \
  "grep -q 'README.md.tpl' '$WF'"
check "triggers on docs-sites.json (dynamic README metadata changes)" \
  "grep -q 'docs-sites.json' '$WF'"
check "triggers when fleet membership changes" \
  "grep -q 'downstream-repos.json' '$WF'"
check "triggers when the dispatcher contract changes" \
  "grep -q 'dispatch-downstream.yml' '$WF'"
check "triggers when governance-secret provisioning changes" \
  "grep -q 'scripts/provision-governance-secrets.sh' '$WF'"
check "triggers when the exact managed caller changes" \
  "grep -q 'workflows/enforce-repo-settings.yml' '$WF'"
check "triggers after the immutable governed workflow pin rolls forward" \
  "grep -q 'governed-workflow-pin.json' '$WF'"
check "triggers when the explicit governance rollout state changes" \
  "grep -q 'governance-rollout.json' '$WF'"
check "does NOT trigger on build workflow_run (stale-manifest race)" \
  "! grep -q 'workflow_run:' '$WF'"
check "keeps manual workflow_dispatch fallback" \
  "grep -q 'workflow_dispatch:' '$WF'"
check "queues transitions instead of cancelling a mutating bootstrap" \
  "grep -A5 '^concurrency:' '$WF' | grep -q 'cancel-in-progress: false'"

# Receipt: every downstream workflow must receive the exact docs-control commit
# that caused this dispatch. Without this field, callers resolve mutable main at
# different times while the fleet fan-out is still running.
check "captures the exact triggering commit" \
  "grep -Fq 'SOURCE_SHA: \${{ github.sha }}' '$WF'"
check "forwards the exact source receipt to every downstream run" \
  "grep -Fq -- 'dispatch \"\$repo\" \"\$SOURCE_SHA\"' '$WF'"
check "runs exact-source and immutable-pin preflight before fan-out" \
  "grep -q 'scripts/preflight-downstream-dispatch.sh' '$WF'"
PROVISION_LINE=$(grep -n '^[[:space:]]*scripts/provision-governance-secrets.sh$' "$WF" |
  head -n1 | cut -d: -f1 || true)
PREFLIGHT_LINE=$(grep -n '^[[:space:]]*scripts/preflight-downstream-dispatch.sh$' "$WF" |
  head -n1 | cut -d: -f1 || true)
check "provisions governance secrets before downstream preflight" \
  "[ -n '$PROVISION_LINE' ] && [ -n '$PREFLIGHT_LINE' ] && [ '$PROVISION_LINE' -lt '$PREFLIGHT_LINE' ]"
check "defers fan-out until the governed caller pin is exact" \
  "grep -q '\[DEFER\].*governed workflow pin' '$WF'"
check "bootstraps stale downstream callers without legacy reusable code" \
  "grep -q 'scripts/bootstrap-downstream-callers.sh' '$WF'"
check "historical dispatches enqueue the current protected-main receipt" \
  "grep -q 'gh workflow run dispatch-downstream.yml' '$WF'"

if command -v actionlint >/dev/null 2>&1; then
  check "actionlint clean" "actionlint '$WF' >/dev/null 2>&1"
fi

# Exercise the recovery branch: main can advance while bootstrap is running.
# A post-bootstrap historical receipt must enqueue current main and end cleanly,
# not leak shell exit 78 as a failed workflow.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/scripts" "$WORK/bin"
python3 - "$WF" "$WORK/dispatch.sh" <<'PY'
import sys
import yaml

workflow = yaml.load(open(sys.argv[1], encoding="utf-8"), Loader=yaml.BaseLoader)
steps = workflow["jobs"]["dispatch"]["steps"]
run = next(step["run"] for step in steps if step.get("name", "").startswith("Dispatch enforce"))
open(sys.argv[2], "w", encoding="utf-8").write(run)
PY
cat >"$WORK/scripts/preflight-downstream-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_PREFLIGHT_RC:-}" ]; then
  exit "$FAKE_PREFLIGHT_RC"
fi
count_file=.preflight-count
count=0
[ ! -f "$count_file" ] || count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
[ "$count" -eq 1 ] && exit 80
exit 78
EOF
cat >"$WORK/scripts/provision-governance-secrets.sh" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_PROVISION_RC:-0}"
EOF
cat >"$WORK/scripts/bootstrap-downstream-callers.sh" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_BOOTSTRAP_RC:-0}"
EOF
cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
exit 0
EOF
chmod +x "$WORK/scripts/"*.sh "$WORK/bin/gh"
: >"$WORK/gh.log"
set +e
(
  cd "$WORK"
  env \
    PATH="$WORK/bin:$PATH" \
    FAKE_GH_LOG="$WORK/gh.log" \
    GITHUB_REPOSITORY=f5-sales-demo/docs-control \
    GITHUB_REPOSITORY_OWNER=f5-sales-demo \
    SOURCE_SHA=1111111111111111111111111111111111111111 \
    REPO_SETTINGS_TOKEN=settings-token \
    REPO_SYNC_TOKEN=sync-token \
    bash "$WORK/dispatch.sh"
)
recovery_rc=$?
set -e
check "post-bootstrap historical receipt enqueues current main and succeeds" \
  "[ '$recovery_rc' -eq 0 ] && grep -q 'workflow run dispatch-downstream.yml.*--ref main' '$WORK/gh.log'"

rm -f "$WORK/.preflight-count"
: >"$WORK/gh.log"
set +e
(
  cd "$WORK"
  env \
    PATH="$WORK/bin:$PATH" \
    FAKE_GH_LOG="$WORK/gh.log" \
    FAKE_BOOTSTRAP_RC=78 \
    GITHUB_REPOSITORY=f5-sales-demo/docs-control \
    GITHUB_REPOSITORY_OWNER=f5-sales-demo \
    SOURCE_SHA=1111111111111111111111111111111111111111 \
    REPO_SETTINGS_TOKEN=settings-token \
    REPO_SYNC_TOKEN=sync-token \
    bash "$WORK/dispatch.sh"
)
recovery_rc=$?
set -e
check "bootstrap source supersession enqueues current main and succeeds" \
  "[ '$recovery_rc' -eq 0 ] && grep -q 'workflow run dispatch-downstream.yml.*--ref main' '$WORK/gh.log'"

rm -f "$WORK/.preflight-count"
: >"$WORK/gh.log"
set +e
(
  cd "$WORK"
  env \
    PATH="$WORK/bin:$PATH" \
    FAKE_GH_LOG="$WORK/gh.log" \
    FAKE_BOOTSTRAP_RC=84 \
    GITHUB_REPOSITORY=f5-sales-demo/docs-control \
    GITHUB_REPOSITORY_OWNER=f5-sales-demo \
    SOURCE_SHA=1111111111111111111111111111111111111111 \
    REPO_SETTINGS_TOKEN=settings-token \
    REPO_SYNC_TOKEN=sync-token \
    bash "$WORK/dispatch.sh"
)
recovery_rc=$?
set -e
check "bootstrap API rate exhaustion defers to scheduled recovery" \
  "[ '$recovery_rc' -eq 0 ] && ! grep -q 'workflow run dispatch-downstream.yml' '$WORK/gh.log'"

rm -f "$WORK/.preflight-count"
: >"$WORK/gh.log"
set +e
(
  cd "$WORK"
  env \
    PATH="$WORK/bin:$PATH" \
    FAKE_GH_LOG="$WORK/gh.log" \
    FAKE_PREFLIGHT_RC=84 \
    GITHUB_REPOSITORY=f5-sales-demo/docs-control \
    GITHUB_REPOSITORY_OWNER=f5-sales-demo \
    SOURCE_SHA=1111111111111111111111111111111111111111 \
    REPO_SETTINGS_TOKEN=settings-token \
    REPO_SYNC_TOKEN=sync-token \
    bash "$WORK/dispatch.sh"
)
recovery_rc=$?
set -e
check "preflight API rate exhaustion defers to scheduled recovery" \
  "[ '$recovery_rc' -eq 0 ] && ! grep -q 'workflow run dispatch-downstream.yml' '$WORK/gh.log'"

rm -f "$WORK/.preflight-count"
: >"$WORK/gh.log"
set +e
(
  cd "$WORK"
  env \
    PATH="$WORK/bin:$PATH" \
    FAKE_GH_LOG="$WORK/gh.log" \
    FAKE_PROVISION_RC=84 \
    GITHUB_REPOSITORY=f5-sales-demo/docs-control \
    GITHUB_REPOSITORY_OWNER=f5-sales-demo \
    SOURCE_SHA=1111111111111111111111111111111111111111 \
    REPO_SETTINGS_TOKEN=settings-token \
    REPO_SYNC_TOKEN=sync-token \
    bash "$WORK/dispatch.sh"
)
recovery_rc=$?
set -e
check "secret-provisioning rate exhaustion defers before preflight" \
  "[ '$recovery_rc' -eq 0 ] && [ ! -e '$WORK/.preflight-count' ] && ! grep -q 'workflow run dispatch-downstream.yml' '$WORK/gh.log'"

exit "$FAIL"
