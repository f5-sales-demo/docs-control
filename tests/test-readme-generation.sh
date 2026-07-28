#!/usr/bin/env bash
# Assertions on the dynamically generated README.md.
#
# sync-managed-files.yml renders README.md.tpl into every downstream repo,
# substituting placeholders and deleting the optional ones when they have no
# value. Deleting a placeholder that sits on its own line between two blank
# lines leaves those blanks adjacent, which is markdownlint MD012
# (no-multiple-blanks) -- so the generator emits a file that the fleet's own
# managed linter rejects, in every repo, and no consumer can fix it because
# README.md is a protected file.
#
# Run from repo root: bash tests/test-readme-generation.sh
set -euo pipefail

PASS=0
FAIL=0
TESTS_RUN=0

pass() {
  PASS=$((PASS + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "  PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "  FAIL: $1 — $2"
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$REPO_ROOT/README.md.tpl"
SYNC_WORKFLOW="$REPO_ROOT/.github/workflows/sync-managed-files.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Mirrors the substitution sync-managed-files.yml performs. Kept deliberately
# close to the workflow; test 3 guards against the two drifting apart.
render() {
  local badges="$1" content="$2" out="$WORK/readme.md"

  sed -e 's|__ORG_NAME__|f5-sales-demo|g' \
    -e 's|__TITLE__|Example Repo|g' \
    -e 's|__DESCRIPTION__|An example description|g' \
    -e 's|__REPO_NAME__|example-repo|g' \
    -e 's|__DOCS_URL__|https://f5-sales-demo.github.io/example-repo/|g' \
    "$TPL" >"$out"

  if [ -n "$badges" ]; then
    printf '%s\n' "$badges" >"$WORK/badges.tmp"
    sed -i.bak '/__EXTRA_BADGES__/{
      r '"$WORK"'/badges.tmp
      d
    }' "$out"
  else
    sed -i.bak '/__EXTRA_BADGES__/d' "$out"
  fi

  if [ -n "$content" ]; then
    printf '%s\n' "$content" >"$WORK/content.tmp"
    sed -i.bak '/__EXTRA_CONTENT__/{
      r '"$WORK"'/content.tmp
      d
    }' "$out"
  else
    sed -i.bak '/__EXTRA_CONTENT__/d' "$out"
  fi

  # The fix under test: collapse runs of blank lines left behind by deleting an
  # optional placeholder. `cat -s` squeezes repeated empty lines to one.
  cat -s "$out" >"$out.squeezed" && mv "$out.squeezed" "$out"

  rm -f "$out.bak"
  printf '%s' "$out"
}

consecutive_blanks() {
  awk 'prev == "" && $0 == "" { print NR } { prev = $0 }' "$1"
}

echo ""
echo "=== Section 1: generated README has no consecutive blank lines (MD012) ==="

# Every site in docs-sites.json currently omits readme_content, so the empty
# case is not hypothetical -- it is what every repo in the fleet receives.
for case_name in "no badges, no content" "badges, no content" "no badges, content"; do
  case "$case_name" in
  "no badges, no content") out=$(render "" "") ;;
  "badges, no content") out=$(render "[![B](https://x/b.svg)](https://x/b)" "") ;;
  "no badges, content") out=$(render "" "## Extra
Some per-repo prose.") ;;
  esac

  hits=$(consecutive_blanks "$out")
  if [ -z "$hits" ]; then
    pass "1.x rendered README has no MD012 violation ($case_name)"
  else
    fail "1.x rendered README has no MD012 violation ($case_name)" \
      "consecutive blank lines at: $(echo "$hits" | tr '\n' ' ')"
  fi
done

echo ""
echo "=== Section 2: the template still renders its required content ==="

out=$(render "" "")
for needle in "# Example Repo" "An example description" "## Documentation" "## Contributing"; do
  if grep -qF "$needle" "$out"; then
    pass "2.x rendered README contains '$needle'"
  else
    fail "2.x rendered README contains '$needle'" "not found"
  fi
done

if [ -z "$(grep -n '__[A-Z_]*__' "$out" || true)" ]; then
  pass "2.x no unsubstituted placeholders remain"
else
  fail "2.x no unsubstituted placeholders remain" "$(grep -n '__[A-Z_]*__' "$out" | head -3)"
fi

echo ""
echo "=== Section 3: the workflow performs the same normalisation ==="

# Guards against this test and the workflow drifting: the fix has to be in the
# generator, not only in this file's reimplementation of it.
if grep -q 'cat -s' "$SYNC_WORKFLOW"; then
  pass "3.1 sync-managed-files.yml squeezes blank lines in generated README"
else
  fail "3.1 sync-managed-files.yml squeezes blank lines in generated README" \
    "no 'cat -s' normalisation found; the workflow will still emit MD012"
fi

echo ""
echo "════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($TESTS_RUN total)"
echo "════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
