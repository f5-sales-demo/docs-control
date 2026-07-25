#!/usr/bin/env bash
# Hermetic test for scripts/preflight-fleet.sh — the tool that answers "would this
# check break any governed repository?" before a check is enforced fleet-wide.
# Builds throwaway repositories and never touches the network (--no-fetch).
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/preflight-fleet.sh"

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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A fake governed repo whose default branch (origin/HEAD) content is what matters.
# The working tree is deliberately left DIRTY and divergent, so a tool that reads
# the working tree instead of origin/HEAD gets the wrong answer and the test fails.
make_repo() {
  local name="$1" committed="$2" worktree_override="${3:-}"
  local dir="${WORK}/clones/${name}"
  local origin="${WORK}/origins/${name}.git"
  mkdir -p "$(dirname "$origin")"
  git init -q --bare -b main "$origin"
  mkdir -p "$dir"
  git init -q -b main "$dir"
  git -C "$dir" config user.email pf@test
  git -C "$dir" config user.name "Preflight Test"
  printf '%s\n' "$committed" >"${dir}/content.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -qm baseline
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" push -q origin main
  git -C "$dir" remote set-head origin main
  if [ -n "$worktree_override" ]; then
    printf '%s\n' "$worktree_override" >"${dir}/content.txt"
  fi
}

# The check under test: fails when content.txt contains BAD.
CHECK="${WORK}/bad-check.sh"
cat >"$CHECK" <<'CHK'
#!/usr/bin/env bash
set -euo pipefail
if grep -q BAD content.txt 2>/dev/null; then
  echo "::error::found BAD"
  exit 1
fi
echo "clean"
CHK
chmod +x "$CHECK"

run_preflight() {
  local rc=0
  # shellcheck disable=SC2086
  bash "$SCRIPT" --check "$CHECK" --repos-file "$WORK/repos.json" \
    --search-path "$WORK/clones" --no-fetch "$@" >"$WORK/out.txt" 2>&1 || rc=$?
  echo "$rc"
}

echo ""
echo "=== Fleet Pre-flight Tests ==="

# --- all clean -----------------------------------------------------------------
mkdir -p "$WORK/clones" "$WORK/origins"
make_repo alpha GOOD
make_repo beta GOOD
printf '["alpha","beta"]\n' >"$WORK/repos.json"
RC=$(run_preflight)
if [ "$RC" -eq 0 ]; then pass "clean fleet exits 0"; else fail "clean fleet exits 0" "rc=$RC: $(cat "$WORK/out.txt")"; fi
if grep -q "clean=2" "$WORK/out.txt"; then pass "counts both repositories as clean"; else fail "counts both clean" "$(cat "$WORK/out.txt")"; fi

# --- one would break ------------------------------------------------------------
rm -rf "$WORK/clones" "$WORK/origins"
mkdir -p "$WORK/clones" "$WORK/origins"
make_repo alpha GOOD
make_repo beta BAD
printf '["alpha","beta"]\n' >"$WORK/repos.json"
RC=$(run_preflight)
if [ "$RC" -ne 0 ]; then pass "a repository that would break exits non-zero"; else fail "would-break exits non-zero" "rc=0"; fi
if grep -q "beta" "$WORK/out.txt"; then pass "names the repository that would break"; else fail "names the repository" "$(cat "$WORK/out.txt")"; fi

# --- THE STALE-CLONE TRAP: origin/HEAD is clean, working tree is dirty ----------
# A tool that inspects the working tree reports a false break here.
rm -rf "$WORK/clones" "$WORK/origins"
mkdir -p "$WORK/clones" "$WORK/origins"
make_repo alpha GOOD BAD
printf '["alpha"]\n' >"$WORK/repos.json"
RC=$(run_preflight)
if [ "$RC" -eq 0 ]; then pass "judges origin/HEAD, not the dirty working tree"; else fail "judges origin/HEAD" "rc=$RC: $(cat "$WORK/out.txt")"; fi

# --- the inverse: origin/HEAD is bad, working tree looks clean ------------------
rm -rf "$WORK/clones" "$WORK/origins"
mkdir -p "$WORK/clones" "$WORK/origins"
make_repo alpha BAD GOOD
printf '["alpha"]\n' >"$WORK/repos.json"
RC=$(run_preflight)
if [ "$RC" -ne 0 ]; then pass "a stale clean working tree does not hide a broken origin/HEAD"; else fail "stale tree hides breakage" "rc=0"; fi

# --- repositories not cloned locally are reported, never silently ignored -------
rm -rf "$WORK/clones" "$WORK/origins"
mkdir -p "$WORK/clones" "$WORK/origins"
make_repo alpha GOOD
printf '["alpha","never-cloned"]\n' >"$WORK/repos.json"
RC=$(run_preflight)
if grep -qE "uncloned=1|never-cloned" "$WORK/out.txt"; then pass "reports coverage gaps explicitly"; else fail "reports coverage gaps" "$(cat "$WORK/out.txt")"; fi

# --- a repository that opts out of the check is skipped, not counted as broken --
rm -rf "$WORK/clones" "$WORK/origins"
mkdir -p "$WORK/clones" "$WORK/origins"
make_repo alpha BAD
printf '["alpha"]\n' >"$WORK/repos.json"
cat >"$WORK/governance.json" <<JSON
{ "skip_files": { "alpha": ["$(basename "$CHECK")"] } }
JSON
RC=$(run_preflight --governance-file "$WORK/governance.json")
if [ "$RC" -eq 0 ]; then pass "a repository opting out of the check is skipped"; else fail "opt-out is skipped" "rc=$RC: $(cat "$WORK/out.txt")"; fi
if grep -q "skipped=1" "$WORK/out.txt"; then pass "counts the opt-out as skipped"; else fail "counts opt-out" "$(cat "$WORK/out.txt")"; fi

# --- arguments reach the check ---------------------------------------------------
rm -rf "$WORK/clones" "$WORK/origins"
mkdir -p "$WORK/clones" "$WORK/origins"
make_repo alpha GOOD
printf '["alpha"]\n' >"$WORK/repos.json"
ARGCHECK="${WORK}/argcheck.sh"
cat >"$ARGCHECK" <<'CHK'
#!/usr/bin/env bash
[ "${1:-}" = "--include-paths" ] || exit 1
echo "got flag"
CHK
chmod +x "$ARGCHECK"
RC=0
bash "$SCRIPT" --check "$ARGCHECK" --repos-file "$WORK/repos.json" --search-path "$WORK/clones" \
  --no-fetch --args "--include-paths" >"$WORK/out.txt" 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "passes --args through to the check"; else fail "passes --args through" "rc=$RC: $(cat "$WORK/out.txt")"; fi

# --- it must not leave worktrees behind in the operator's clones ----------------
if [ -z "$(git -C "$WORK/clones/alpha" worktree list | tail -n +2)" ]; then
  pass "leaves no worktrees behind"
else
  fail "leaves no worktrees behind" "$(git -C "$WORK/clones/alpha" worktree list)"
fi

# --- a missing check script is an error, not a silent pass ----------------------
RC=0
bash "$SCRIPT" --check "$WORK/does-not-exist.sh" --repos-file "$WORK/repos.json" \
  --search-path "$WORK/clones" --no-fetch >"$WORK/out.txt" 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then pass "a missing check script fails loudly"; else fail "missing check fails loudly" "rc=0"; fi

echo ""
echo "════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($((PASS + FAIL)) total)"
echo "════════════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
