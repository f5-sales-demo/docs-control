#!/usr/bin/env bash
# Behavioural tests for where the lint job sources governed scripts from (issue #815).
#
# The lint job executes governed scripts against the PR head working tree. Which
# COPY of the script it executes is a trust decision with two failure modes:
#
#   - Running the head's copy would hand statuses:write / pull-requests:write to
#     PR-authored code, and would let a PR delete the file to skip the gate
#     (REVIEWER-SPEC.md invariant 3).
#   - Running the downstream default branch's copy deadlocks: when that copy lags
#     docs-control, the pull request that would deliver the fix is blocked by the
#     stale copy it is trying to replace. This is what stranded i18n-core.
#
# Canonical bytes satisfy both. These tests drive the real step, extracted from the
# workflow, against local git repositories via the GOVERNANCE_REMOTE seam — no
# network, no GitHub.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
WORKFLOW="${REPO_ROOT}/.github/workflows/super-linter.yml"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1 — $2"
}

TMPDIR_BASE=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Extract a step's `run:` body from the workflow so the test exercises shipped bytes.
# Keyed on the step name, then the run block, de-indented to column 0.
extract_step() {
  local name="$1"
  awk -v want="$name" '
    $0 ~ ("^[[:space:]]*- name: " want "[[:space:]]*$") { found = 1; next }
    found && /^[[:space:]]*run: \|/ { inrun = 1; next }
    inrun && /^[[:space:]]*- name: / { exit }
    inrun { print }
  ' "$WORKFLOW" | sed -e 's/^[[:space:]]\{10\}//' -e '/^[[:space:]]*$/d'
}

GUARDED_SCRIPT='#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ] && grep -q "@f5-sales-demo/i18n-core" package.json; then
  echo "canonical: this is i18n-core itself — definitions are canonical"
  exit 0
fi
if grep -rqE "export const LOCALE_DISPLAY_NAMES" --include="*.ts" .; then
  echo "FAIL: hardcoded locale data"
  exit 1
fi
'

GUARDLESS_SCRIPT='#!/usr/bin/env bash
set -euo pipefail
if grep -rqE "export const LOCALE_DISPLAY_NAMES" --include="*.ts" .; then
  echo "FAIL: hardcoded locale data"
  exit 1
fi
'

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }

# A canonical governance repo. `with_script` empty means canonical retired the script.
# $3 = "listed" (default) to keep scripts/locale-lint.sh in managed_files, or
# "retired" to drop it. The sync never deletes downstream blobs, so the manifest --
# not the presence of the file downstream -- is what marks a script retired.
make_canonical() {
  local dir="$1" body="${2:-}" manifest="${3:-listed}"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git_quiet init
    if [ -n "$body" ]; then
      mkdir -p scripts
      printf '%s' "$body" >scripts/locale-lint.sh
      chmod +x scripts/locale-lint.sh
    fi
    mkdir -p .github/config
    if [ "$manifest" = "nomanifest" ]; then
      : # deliberately no repo-settings.json
    elif [ "$manifest" = "retired" ]; then
      echo '{"managed_files":{"files":[{"src":"other.sh","dest":"other.sh"}]}}' \
        >.github/config/repo-settings.json
    else
      echo '{"managed_files":{"files":[{"src":"scripts/locale-lint.sh","dest":"scripts/locale-lint.sh"}]}}' \
        >.github/config/repo-settings.json
    fi
    echo "canonical" >MARKER
    git_quiet add -A
    git_quiet commit -m canonical
  )
}

# A downstream repo: `main` carries $main_body (empty = opts out via skip_files), and
# the checked-out head is i18n-core-shaped, with $head_body as its own copy.
make_downstream() {
  local dir="$1" main_body="${2:-}" head_body="${3:-}"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git_quiet init
    mkdir -p src
    echo '{ "name": "@f5-sales-demo/i18n-core", "version": "1.0.0" }' >package.json
    cat >src/display-names.ts <<'TS'
import { LOCALE_REGISTRY } from './registry.js';

export const LOCALE_DISPLAY_NAMES: Readonly<Record<string, string>> = Object.fromEntries(
  LOCALE_REGISTRY.map((entry) => [entry.slug, entry.labelEn]),
);
TS
    if [ -n "$main_body" ]; then
      mkdir -p scripts
      printf '%s' "$main_body" >scripts/locale-lint.sh
      chmod +x scripts/locale-lint.sh
    fi
    git_quiet add -A
    git_quiet commit -m downstream
    # The step reads origin/<default>, so give the repo an origin pointing at itself.
    git_quiet remote add origin "$dir"
    git_quiet fetch origin
    if [ -n "$head_body" ]; then
      mkdir -p scripts
      printf '%s' "$head_body" >scripts/locale-lint.sh
      chmod +x scripts/locale-lint.sh
    fi
  )
}

# Run the extracted step inside a downstream repo with a given canonical remote.
run_step() {
  local downstream="$1" remote="$2" body="$3"
  (
    cd "$downstream" || exit 1
    DEFAULT_BRANCH=main GOVERNANCE_REMOTE="$remote" bash -c "$body" 2>&1
  )
}

STEP=$(extract_step "Check for hardcoded locale lists")

echo ""
echo "=== governed-script source: 'Check for hardcoded locale lists' ==="

if [ -z "$STEP" ]; then
  fail "step body is extractable" "no run: block found for the step"
else
  pass "step body is extractable"

  CANON="${TMPDIR_BASE}/canonical"
  make_canonical "$CANON" "$GUARDED_SCRIPT"

  # Retired properly: gone from canonical AND dropped from managed_files.
  CANON_RETIRED="${TMPDIR_BASE}/canonical-retired"
  make_canonical "$CANON_RETIRED" "" "retired"

  # Gone from canonical but STILL listed in managed_files -- an accidental deletion
  # or rename, not a retirement.
  CANON_ACCIDENT="${TMPDIR_BASE}/canonical-accident"
  make_canonical "$CANON_ACCIDENT" "" "listed"

  # Script gone AND no manifest to consult: an anomaly, not a retirement.
  CANON_NOMANIFEST="${TMPDIR_BASE}/canonical-nomanifest"
  make_canonical "$CANON_NOMANIFEST" "" "nomanifest"

  # 1. THE DEADLOCK. Canonical carries the guard; the downstream default branch does
  #    not. The old behaviour ran the stale guardless copy and failed, blocking the
  #    very PR that would deliver the guard.
  d1="${TMPDIR_BASE}/d1"
  make_downstream "$d1" "$GUARDLESS_SCRIPT" "$GUARDLESS_SCRIPT"
  rc=0
  out=$(run_step "$d1" "$CANON" "$STEP") || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "stale downstream copy does not block: canonical bytes run"
  else
    fail "stale downstream copy does not block: canonical bytes run" \
      "exit $rc — the deadlock is still present: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi

  # 2. The skip_files opt-out is expressed by file absence and must survive.
  d2="${TMPDIR_BASE}/d2"
  make_downstream "$d2" "" ""
  rc=0
  out=$(run_step "$d2" "$CANON" "$STEP") || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "nothing to enforce"; then
    pass "opt-out preserved: absent on the default branch means nothing to enforce"
  else
    fail "opt-out preserved: absent on the default branch means nothing to enforce" \
      "exit $rc out=$(printf '%s' "$out" | tr '\n' ' ')"
  fi

  # 3. The head must not be able to weaken the gate. Head's copy exits 0
  #    unconditionally; canonical still flags, so the step must still fail.
  d3="${TMPDIR_BASE}/d3"
  make_downstream "$d3" "$GUARDLESS_SCRIPT" '#!/usr/bin/env bash
exit 0
'
  # Remove the i18n-core marker so canonical's guard does not legitimately exempt it.
  echo '{ "name": "some-consumer", "version": "1.0.0" }' >"${d3}/package.json"
  rc=0
  out=$(run_step "$d3" "$CANON" "$STEP") || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "head cannot weaken the gate: its own copy is never executed"
  else
    fail "head cannot weaken the gate: its own copy is never executed" \
      "exit 0 — the head's exit-0 copy appears to have run"
  fi

  # 4. Unreachable canonical must fail closed, not pass or skip.
  d4="${TMPDIR_BASE}/d4"
  make_downstream "$d4" "$GUARDLESS_SCRIPT" "$GUARDLESS_SCRIPT"
  rc=0
  out=$(run_step "$d4" "${TMPDIR_BASE}/does-not-exist" "$STEP") || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "cannot reach canonical governance"; then
    pass "unreachable canonical fails closed"
  else
    fail "unreachable canonical fails closed" \
      "exit $rc out=$(printf '%s' "$out" | tr '\n' ' ')"
  fi

  # 5. A genuine retirement: gone from canonical and dropped from managed_files. The
  #    orphaned downstream copy stays forever (the sync never deletes), so the
  #    manifest is the only reliable signal.
  d5="${TMPDIR_BASE}/d5"
  make_downstream "$d5" "$GUARDLESS_SCRIPT" "$GUARDLESS_SCRIPT"
  rc=0
  out=$(run_step "$d5" "$CANON_RETIRED" "$STEP") || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "has been retired"; then
    pass "a real retirement (dropped from managed_files) exits 0"
  else
    fail "a real retirement (dropped from managed_files) exits 0" \
      "exit $rc out=$(printf '%s' "$out" | tr '\n' ' ')"
  fi

  # 6. Missing from canonical but still listed in managed_files must fail closed:
  #    passing would silently disable the gate in every still-opted-in repository.
  d6="${TMPDIR_BASE}/d6"
  make_downstream "$d6" "$GUARDLESS_SCRIPT" "$GUARDLESS_SCRIPT"
  rc=0
  out=$(run_step "$d6" "$CANON_ACCIDENT" "$STEP") || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "still listed in canonical managed_files"; then
    pass "accidental removal from canonical fails closed, not open"
  else
    fail "accidental removal from canonical fails closed, not open" \
      "exit $rc out=$(printf '%s' "$out" | tr '\n' ' ')"
  fi

  # 6b. An unreadable or malformed manifest must not read as an empty file list, or a
  #     schema migration would silently stand the gate down fleet-wide.
  d6b="${TMPDIR_BASE}/d6b"
  make_downstream "$d6b" "$GUARDLESS_SCRIPT" "$GUARDLESS_SCRIPT"
  rc=0
  out=$(run_step "$d6b" "$CANON_NOMANIFEST" "$STEP") || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "cannot read managed_files"; then
    pass "unreadable canonical manifest fails closed, not open"
  else
    fail "unreadable canonical manifest fails closed, not open" \
      "exit $rc out=$(printf '%s' "$out" | tr '\n' ' ')"
  fi

  # 7. The workspace must be left pristine. A --depth=1 fetch into the checkout writes
  #    .git/shallow, which breaks Super-Linter's GIT_MERGE_BASE calculation and fails
  #    the whole job — caught in CI on PR #817, not locally.
  d7="${TMPDIR_BASE}/d7"
  make_downstream "$d7" "$GUARDLESS_SCRIPT" "$GUARDLESS_SCRIPT"
  run_step "$d7" "$CANON" "$STEP" >/dev/null 2>&1 || true
  if [ ! -f "${d7}/.git/shallow" ]; then
    pass "workspace is not made shallow by the canonical fetch"
  else
    fail "workspace is not made shallow by the canonical fetch" \
      ".git/shallow was created — this breaks Super-Linter's merge-base calculation"
  fi
  # The fixture's own `git fetch origin` legitimately leaves a FETCH_HEAD, so the
  # meaningful assertion is that the canonical fetch did not overwrite it.
  fetch_head_after=$(git -C "$d7" rev-parse --quiet --verify FETCH_HEAD 2>/dev/null || echo "")
  canonical_head=$(git -C "$CANON" rev-parse HEAD)
  if [ "$fetch_head_after" != "$canonical_head" ]; then
    pass "workspace FETCH_HEAD is not clobbered by the canonical fetch"
  else
    fail "workspace FETCH_HEAD is not clobbered by the canonical fetch" \
      "FETCH_HEAD now points at the canonical commit — the fetch landed in the workspace"
  fi
fi

# The sibling hygiene step shares the pattern and must get the same treatment, or the
# deadlock simply moves to the next governed script.
echo ""
echo "=== the sibling hygiene step uses the same source ==="
HYGIENE=$(extract_step "Check repository hygiene")
if [ -z "$HYGIENE" ]; then
  fail "hygiene step body is extractable" "no run: block found"
else
  pass "hygiene step body is extractable"
  if printf '%s' "$HYGIENE" | grep -q 'canonical_sha}:\${script}'; then
    pass "hygiene step also executes canonical bytes"
  else
    fail "hygiene step also executes canonical bytes" "still sources the local default branch"
  fi
fi

echo ""
echo "════════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed ($((PASS + FAIL)) total)"
echo "════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
