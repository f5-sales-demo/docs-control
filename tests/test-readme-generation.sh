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
DISPATCH_WORKFLOW="$REPO_ROOT/.github/workflows/dispatch-downstream.yml"
DOCS_SITES="$REPO_ROOT/.github/config/docs-sites.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Mirrors the substitution sync-managed-files.yml performs. Kept deliberately
# close to the workflow; test 3 guards against the two drifting apart.
render() {
  local language_nav="$1" badges="$2" content="$3" out="$WORK/readme.md"

  sed -e "s|__LANGUAGE_NAV__|${language_nav}|g" \
    -e 's|__ORG_NAME__|f5-sales-demo|g' \
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

# Most sites in docs-sites.json omit readme_content, so the empty case is not
# hypothetical -- it remains what most repositories in the fleet receive.
for case_name in "no badges, no content" "badges, no content" "no badges, content"; do
  case "$case_name" in
  "no badges, no content") out=$(render "🌐 English" "" "") ;;
  "badges, no content") out=$(render "🌐 English" "[![B](https://x/b.svg)](https://x/b)" "") ;;
  "no badges, content") out=$(render "🌐 English" "" "## Extra
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
echo "=== Section 1b: generated README starts with one H1 (MD041) ==="

for case_name in "language navigation" "no language navigation"; do
  case "$case_name" in
  "language navigation") out=$(render "🌐 English" "" "") ;;
  "no language navigation") out=$(render "" "" "") ;;
  esac

  first_content=$(awk 'NF { print; exit }' "$out")
  h1_count=$(grep -c '^# ' "$out" || true)
  if [ "$first_content" = "# Example Repo" ] && [ "$h1_count" -eq 1 ]; then
    pass "1b.x rendered README starts with exactly one H1 ($case_name)"
  else
    fail "1b.x rendered README starts with exactly one H1 ($case_name)" \
      "first content is '$first_content'; H1 count is $h1_count"
  fi
done

echo ""
echo "=== Section 2: the template still renders its required content ==="

out=$(render "🌐 English" "" "")
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
echo "=== Section 4: api-specs-enriched README is governed and English-only ==="

API_SITE=$(jq -c '.[] | select(.url | contains("/api-specs-enriched/"))' "$DOCS_SITES")
if printf '%s' "$API_SITE" | jq -e \
  '(.readme_english_only | type) == "boolean" and .readme_english_only == true' >/dev/null; then
  pass "4.1 api-specs-enriched opts in with a JSON boolean language policy"
else
  fail "4.1 api-specs-enriched opts in with a JSON boolean language policy" \
    "readme_english_only must be the JSON boolean true"
fi

API_CONTENT=$(printf '%s' "$API_SITE" | jq -r '.readme_content // empty')
API_CONTENT_FLAT=$(printf '%s' "$API_CONTENT" | tr '\n' ' ')
if printf '%s' "$API_CONTENT_FLAT" | grep -q 'immutable.*api-specs.*release' &&
  printf '%s' "$API_CONTENT_FLAT" | grep -q 'specification leads provider implementation' &&
  printf '%s' "$API_CONTENT_FLAT" | grep -q 'English-only'; then
  pass "4.2 api-specs-enriched README records the supply-chain and publication boundary"
else
  fail "4.2 api-specs-enriched README records the supply-chain and publication boundary" \
    "docs-sites.json lacks one or more required boundary statements"
fi

API_README=$(render "🌐 English" "" "$API_CONTENT")
API_README_FLAT=$(tr '\n' ' ' <"$API_README")
if printf '%s' "$API_README_FLAT" | grep -qF 'canonical enriched specification bundle' &&
  grep -qF 'Documentation publication is English-only' "$API_README" &&
  ! grep -qE 'api-specs-enriched/(ar|de|es|fr|hi|it|ja|ko|pt-br|th|zh-cn|zh-tw)/' "$API_README" &&
  awk 'length > 400 { found = 1 } END { exit found }' "$API_README"; then
  pass "4.3 rendered api-specs-enriched README contains the boundary and no locale links"
else
  fail "4.3 rendered api-specs-enriched README contains the boundary and no locale links" \
    "the data-driven render lost content or advertised an unpublished locale"
fi

if grep -qF 'prerelease' "$API_README" && ! grep -qF 'pre-release' "$API_README"; then
  pass "4.4 rendered api-specs-enriched README uses governed prerelease terminology"
else
  fail "4.4 rendered api-specs-enriched README uses governed prerelease terminology" \
    "generated prose must use 'prerelease', never 'pre-release'"
fi

awk '
  /^          validate_docs_sites\(\) \{/ { found=1 }
  found {
    line=$0
    sub(/^          /, "")
    print
    if (line == "          }") exit
  }
' "$SYNC_WORKFLOW" >"$WORK/validate-docs-sites.sh"
if (
  # shellcheck source=/dev/null
  source "$WORK/validate-docs-sites.sh"
  OWNER=f5-sales-demo
  validate_docs_sites <"$DOCS_SITES" &&
    ! jq 'map(if .url | contains("/api-specs-enriched/") then
      .readme_english_only = "true" else . end)' "$DOCS_SITES" |
    validate_docs_sites
) && grep -q '__LANGUAGE_NAV__' "$SYNC_WORKFLOW"; then
  pass "4.5 sync-managed-files renders a strictly typed per-repository language policy"
else
  fail "4.5 sync-managed-files renders a strictly typed per-repository language policy" \
    "the generator must consume the policy and reject non-boolean values"
fi

if grep -q "README.md.tpl" "$DISPATCH_WORKFLOW" &&
  grep -q ".github/config/docs-sites.json" "$DISPATCH_WORKFLOW"; then
  pass "4.6 README template and metadata changes trigger downstream regeneration"
else
  fail "4.6 README template and metadata changes trigger downstream regeneration" \
    "dispatch-downstream.yml omits a dynamic README input"
fi

awk '
  /^          readme_english_only\(\) \{/ { found=1 }
  found {
    line=$0
    sub(/^          /, "")
    print
    if (line == "          }") exit
  }
' "$SYNC_WORKFLOW" >"$WORK/readme-english-only.sh"
if [ -s "$WORK/readme-english-only.sh" ] && (
  # shellcheck source=/dev/null
  source "$WORK/readme-english-only.sh"
  [ "$(printf '%s' '{}' | readme_english_only)" = false ] &&
    [ "$(printf '%s' '{"readme_english_only":false}' | readme_english_only)" = false ] &&
    [ "$(printf '%s' '{"readme_english_only":true}' | readme_english_only)" = true ] &&
    ! printf '%s' '{"readme_english_only":"false"}' | readme_english_only >/dev/null 2>&1
); then
  pass "4.7 README language policy accepts both booleans and defaults to multilingual"
else
  fail "4.7 README language policy accepts both booleans and defaults to multilingual" \
    "the production extractor must return false successfully and reject non-booleans"
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
