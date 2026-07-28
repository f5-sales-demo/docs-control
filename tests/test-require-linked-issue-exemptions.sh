#!/usr/bin/env bash
# Hermetic test for the branch-exemption set of the required linked-issue gate in
# .github/workflows/require-linked-issue.yml.
#
# The gate is a required status check, so a branch that is wrongly gated cannot
# merge at all — which is what happened to Changesets release PRs, whose bot-
# authored body is a generated changelog with no issue to reference.
#
# The constant and the glob matcher are extracted from the workflow itself and
# evaluated as-is, so this exercises the shipped logic rather than a copy of it
# that could agree with the test while disagreeing with production.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW="${REPO_ROOT}/.github/workflows/require-linked-issue.yml"

FAIL=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Lift `const EXCLUDE_BRANCHES = "..."` and the `globToRegex` arrow function out
# of the inline github-script body, then rebuild the decision the workflow makes.
exclude_line=$(grep -m1 'const EXCLUDE_BRANCHES' "$WORKFLOW" | sed 's/^[[:space:]]*//')
if [ -z "$exclude_line" ]; then
  echo "[FAIL] could not find EXCLUDE_BRANCHES in $(basename "$WORKFLOW")"
  exit 1
fi
glob_fn=$(awk '
  /const globToRegex = \(glob\) => \{/ { inside = 1 }
  inside { sub(/^[[:space:]]*/, ""); print }
  inside && /^[[:space:]]*\};[[:space:]]*$/ { exit }
' "$WORKFLOW")
if [ -z "$glob_fn" ]; then
  echo "[FAIL] could not find globToRegex in $(basename "$WORKFLOW")"
  exit 1
fi

cat >"$WORK/is-exempt.mjs" <<EOF
${exclude_line}
${glob_fn}
const patterns = EXCLUDE_BRANCHES.split(",").map((p) => globToRegex(p.trim()));
const headRef = process.argv[2];
process.exit(patterns.some((re) => re.test(headRef)) ? 0 : 1);
EOF

is_exempt() { node "$WORK/is-exempt.mjs" "$1"; }

assert_exempt() { # assert_exempt <branch> <why>
  if is_exempt "$1"; then
    echo "[OK] '$1' is exempt — $2"
  else
    echo "[FAIL] '$1' should be exempt — $2"
    FAIL=1
  fi
}

assert_gated() { # assert_gated <branch> <why>
  if is_exempt "$1"; then
    echo "[FAIL] '$1' should still require a linked issue — $2"
    FAIL=1
  else
    echo "[OK] '$1' still requires a linked issue — $2"
  fi
}

# The regression this test exists for: a Changesets release PR carries only a
# version bump and a changelog generated from already-gated PRs.
assert_exempt "changeset-release/main" "Changesets release PR against main"
assert_exempt "changeset-release/next" "Changesets release PR against another base"

# Exemptions that were already relied upon, locked so a future edit cannot drop
# one while adding another.
assert_exempt "dependabot/npm_and_yarn/astro-6.1.5" "dependency bump"
assert_exempt "release/3.9.14" "release branch"
assert_exempt "openapi-sync/2026-07-28" "spec sync"
assert_exempt "plugin-sync/marketplace" "plugin sync"
assert_exempt "deps/bump-node" "dependency branch"
assert_exempt "sync/managed-files" "managed-file sync"
assert_exempt "docs/update-terminology" "docs update branch"

# Authored work must stay gated, and the patterns must stay anchored so a
# prefix cannot be smuggled in mid-path.
assert_gated "feat/locale-complete-llms-surface" "ordinary feature branch"
assert_gated "fix/exempt-changeset-release-branches" "ordinary fix branch"
assert_gated "feature/changeset-release/main" "exemption must be anchored at the start"
assert_gated "changeset-release" "directory prefix without a base is not a release branch"
assert_gated "docs/update" "docs/update-* needs the suffix"
assert_gated "main" "the default branch is not exempt"

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: linked-issue gate exemptions behave as specified"
else
  echo "FAIL: linked-issue gate exemptions are wrong"
fi
exit "$FAIL"
