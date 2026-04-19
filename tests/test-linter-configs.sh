#!/usr/bin/env bash
# Phase 2 TDD harness: assertions on every managed linter config.
# Every Phase 2 config change MUST land paired with one of these assertions
# (test-first: assertion written and confirmed red, then config fixed).
# Run from repo root: bash tests/test-linter-configs.sh
set -euo pipefail

# ── Test framework (shared pattern with test-protect-managed-files.sh) ──
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
REPO_SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"

# ════════════════════════════════════════════════════════════════════
# SECTION 1: JSON Parse Validity (all managed JSON lint configs)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 1: JSON parse validity ==="

for f in .markdownlint.json .jscpd.json .editorconfig-checker.json; do
  if jq empty "$REPO_ROOT/$f" 2>/dev/null; then
    pass "1.x $f is valid JSON"
  else
    fail "1.x $f is valid JSON" "jq parse failed"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 2: YAML Parse Validity (all managed YAML lint configs)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 2: YAML parse validity ==="

for f in .yamllint.yaml zizmor.yaml .checkov.yaml .textlintrc; do
  if python3 -c "import sys, yaml; yaml.safe_load(open('$REPO_ROOT/$f'))" 2>/dev/null; then
    pass "2.x $f is valid YAML"
  else
    fail "2.x $f is valid YAML" "yaml.safe_load failed"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 3: TOML Parse Validity (Python lint configs)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 3: TOML parse validity ==="

for f in ruff.toml .ruff.toml; do
  if python3 -c "import sys, tomllib; tomllib.load(open('$REPO_ROOT/$f', 'rb'))" 2>/dev/null; then
    pass "3.x $f is valid TOML"
  else
    fail "3.x $f is valid TOML" "tomllib.load failed"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 4: ruff.toml is self-contained (no dead extend references)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 4: ruff.toml self-contained ==="

# Test 4.1 / 4.2: ruff.toml and .ruff.toml must not reference a non-existent
# file via `extend`. Both configs get synced downstream verbatim, so a missing
# target would break lint in every governed repo.
for cfg in ruff.toml .ruff.toml; do
  EXTEND_TARGET=$(python3 -c "import tomllib; d=tomllib.load(open('$REPO_ROOT/$cfg','rb')); print(d.get('extend',''))")
  if [ -z "$EXTEND_TARGET" ]; then
    pass "4.x $cfg has no extend directive"
  elif [ -f "$REPO_ROOT/$EXTEND_TARGET" ]; then
    pass "4.x $cfg extend target '$EXTEND_TARGET' exists"
  else
    fail "4.x $cfg extend target '$EXTEND_TARGET' exists" "file not found in repo root"
  fi
done

# Test 4.3: ruff can actually run against ruff.toml end-to-end on an empty
# directory. Exercises config load, including all extend chains and lint rule
# tables. A missing extend target surfaces here as a runtime error (unlike
# --help which short-circuits before config resolution).
if command -v ruff >/dev/null 2>&1; then
  EMPTY=$(mktemp -d)
  # shellcheck disable=SC2064  # $EMPTY is set locally above and intentional
  trap "rm -rf '$EMPTY'" EXIT
  if (cd "$REPO_ROOT" && ruff check --config "$REPO_ROOT/ruff.toml" "$EMPTY" >/dev/null 2>&1); then
    pass "4.3 ruff check --config ruff.toml runs cleanly end-to-end"
  else
    fail "4.3 ruff check --config ruff.toml runs cleanly end-to-end" "ruff exited non-zero on an empty dir"
  fi
else
  echo "  SKIP: ruff CLI not installed in this environment"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 5: .codespellrc skip patterns cover expected noise sources
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 5: .codespellrc skip coverage ==="

CODESPELL_SKIP=$(awk -F= '/^skip[[:space:]]*=/{sub(/^[^=]*=/,""); print}' "$REPO_ROOT/.codespellrc" | tr -d ' ')

# Each pattern below is a real noise source we observed when auditing xcsh:
# vendored/ holds forks like brush-core-vendored (bash parser fork)
# *-vendored* catches hyphenated vendored crates (brush-core-vendored, etc.)
# */gen/* catches protobuf/codegen output (packages/*/gen/*.ts)
# fixtures/ holds test snapshots with intentional misspellings
# *.min.js is minified vendor JS copied into the tree
# *.jsonl is session-fixture prose
# *.b64.js is base64-encoded vendored content
for pat in 'vendored' '*-vendored*' '*/gen/*' 'fixtures' '*.min.js' '*.jsonl' '*.b64.js'; do
  if echo "$CODESPELL_SKIP" | grep -qF "$pat"; then
    pass "5.x .codespellrc skip contains '$pat'"
  else
    fail "5.x .codespellrc skip contains '$pat'" "not in skip list"
  fi
done

# Domain-specific words that would otherwise noise-out the audit:
# Rust identifier fragments from xcsh's pi-natives (ForIn, ser, anc, abd, fo, te, RUNN, Statics)
# JS camelCase variable names codespell splits (crossReferences, prevEnd, aLine)
# Legitimate English (invokable) and common test-fixture strings (doesnt, takin, hel, deine)
# SQL/HTTP abbreviations (doub for DOUBLE, cros for CORS)
for word in doesnt forin invokable takin deine doub cros defaul ser anc runn; do
  if grep -qE "(^|[=,])${word}([,]|$)" "$REPO_ROOT/.codespellrc"; then
    pass "5.x .codespellrc ignore-words-list contains '$word'"
  else
    fail "5.x .codespellrc ignore-words-list contains '$word'" "not whitelisted"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 5e: super-linter disables validators not applicable to the
#             ecosystem's language mix (TS/Rust/Python/Markdown/Astro)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 5e: super-linter VALIDATE_* disables ==="

SL_YML="$REPO_ROOT/.github/workflows/super-linter.yml"
# Each entry below is an explicit "not relevant" decision captured with
# its rationale in the workflow comment. Removing a disable re-introduces
# a full audit surface for that validator on every governed repo.
for v in POWERSHELL HTML CPP RUST_2015 DOCKERFILE_HADOLINT BASH_EXEC EDITORCONFIG PROTOBUF; do
  if grep -qE "^[[:space:]]*VALIDATE_${v}:[[:space:]]+false" "$SL_YML"; then
    pass "5e.x super-linter disables VALIDATE_${v}"
  else
    fail "5e.x super-linter disables VALIDATE_${v}" "not set to false"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 6: zizmor.yaml suppressions are complete enough for caller
#            workflows + typical downstream CI patterns to scan clean
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 6: zizmor suppression coverage ==="

# Rationale: without these suppressions, zizmor reports 100+ findings on a
# typical downstream repo (e.g., xcsh reports 185 before config, 27 with
# config). Each rule below represents a deliberate docs-control decision
# — removing one here would re-introduce noise across every governed repo.
for rule in \
  unpinned-uses \
  artipacked \
  excessive-permissions \
  template-injection \
  cache-poisoning \
  secrets-inherit \
  secrets-outside-env \
  pull-request-target \
  dangerous-triggers \
  bot-conditions \
  dependabot-cooldown; do
  if python3 -c "
import sys, yaml
with open('$REPO_ROOT/zizmor.yaml') as f:
  cfg = yaml.safe_load(f)
sys.exit(0 if cfg.get('rules', {}).get('$rule', {}).get('disable') else 1)
" 2>/dev/null; then
    pass "6.x zizmor.yaml disables '$rule' (governed-repo noise suppression)"
  else
    fail "6.x zizmor.yaml disables '$rule'" "rule not disabled"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 5a: .jscpd.json guardrails — threshold + ignore patterns
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 5a: .jscpd.json guardrails ==="

# Threshold is the duplication-percentage above which jscpd exits non-zero.
# 10% is the negotiated ecosystem default — fork repos (xcsh at 5.25%) and
# greenfield repos both fit under. Dropping below 5% would fail xcsh; going
# above 20% makes the rule toothless.
THRESHOLD=$(jq -r '.threshold // 0' "$REPO_ROOT/.jscpd.json")
if [ "$THRESHOLD" = "10" ]; then
  pass "5a.1 .jscpd.json threshold is 10%"
else
  fail "5a.1 .jscpd.json threshold is 10%" "got $THRESHOLD"
fi

# The ignore list must exclude generated / vendored / built output so
# clones in those directories do not inflate the rate.
for pat in '**/node_modules/**' '**/dist/**' '**/build/**' '**/vendor/**' '**/.github/workflows/**'; do
  if jq -e --arg p "$pat" '.ignore | index($p) != null' "$REPO_ROOT/.jscpd.json" >/dev/null; then
    pass "5a.x .jscpd.json ignore contains '$pat'"
  else
    fail "5a.x .jscpd.json ignore contains '$pat'" "not in ignore list"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 5b: .markdownlint.json rule disables match opinionated-rule
#             audit decisions (tech-docs convention)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 5b: .markdownlint.json opinionated-rule disables ==="

# Each entry below is a rule docs-control disables based on real audit
# findings against governed repos. Removing the disable would re-introduce
# hundreds of noise violations on fork/reference-style docs.
# MD013  line-length           — long code examples / tables
# MD029  ordered-list-style    — allow mixed 1. + 1) styles
# MD033  no-inline-html        — MDX components and HTML embed
# MD040  code-fence-language   — plain fenced code for pseudo-output is valid
# MD041  first-line-h1         — Starlight frontmatter supplies the H1 implicitly
# MD060  table-column-style    — tables are content-first, not pipe-aligned
# MD025  single-title          — multi-H1 is used in reference docs
# MD024  no-duplicate-heading  — repeated section names in reference docs
# MD007  ul-indent             — indent preference varies by fork style
for rule in MD013 MD029 MD033 MD040 MD041 MD060 MD025 MD024 MD007; do
  if jq -e --arg r "$rule" '.[$r] == false' "$REPO_ROOT/.markdownlint.json" >/dev/null; then
    pass "5b.x .markdownlint.json disables $rule"
  else
    fail "5b.x .markdownlint.json disables $rule" "not set to false"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 6b: .textlintrc terminology excludes cover terms flagged
#             during the xcsh audit (defaultTerms is too opinionated
#             for tech prose; without these, xcsh reports 150 errors)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 6b: .textlintrc terminology excludes ==="

# textlint-rule-terminology v5 matches the exclude list string against
# term[0] from terms.jsonc (exact, not regex). The strings below are the
# canonical term-source patterns; changing them here without coordinating
# with the rule's dictionary would silently break exclusion.
for term in 'regexp?(s)?' 'Bash' 'Markdown' 'Git' 'API' 'HTML' 'JSON' 'SQLite' \
  'Unicode' 'ID' 'check[- ]box(es)?' 'key[/ ]?value' 'CLI tool(s)?' \
  'Visual ?Studio ?Code' 'built ?in(s)?' 'trade ?off(s)?' \
  'anti[- ]pattern(s)?' 're[- ]export(s|ing|ed)?'; do
  if jq -e --arg t "$term" '.rules.terminology.exclude | index($t) != null' "$REPO_ROOT/.textlintrc" >/dev/null; then
    pass "6b.x .textlintrc exclude contains '$term'"
  else
    fail "6b.x .textlintrc exclude contains '$term'" "not in exclude list"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 7: per-repo Python config opt-outs (xcsh fork fidelity)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 7: Python config opt-outs for xcsh ==="

# Rationale: docs-control's ruff.toml / .python-lint / .mypy.ini are
# deliberately strict (pydocstyle D, pytest PT, tryceratops TRY, errmsg EM,
# type-checking TC, full select list). Applied to xcsh — an active fork of
# badlogic/pi-mono — they surface 743+ ruff errors and 73 mypy errors that
# are not bugs, just stylistic drift from upstream. xcsh therefore ships
# its own permissive Python configs and must be opted out of sync.
for cfg in ruff.toml .ruff.toml .python-lint .mypy.ini; do
  xcsh_skip=$(jq -r --arg c "$cfg" '.managed_files.skip_files.xcsh // [] | .[] | select(. == $c)' "$REPO_SETTINGS")
  if [ -n "$xcsh_skip" ]; then
    pass "7.x $cfg is in xcsh skip_files (fork Python linter fidelity)"
  else
    fail "7.x $cfg is in xcsh skip_files" "not in skip list"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 5c: .checkov.yaml skips the install-test harness dockerfiles
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 5c: .checkov.yaml skip-path covers install-test dockerfiles ==="

CHECKOV_SKIP=$(python3 -c "import yaml; print(' '.join(yaml.safe_load(open('$REPO_ROOT/.checkov.yaml')).get('skip-path',[])))")
for p in 'scripts/install-tests' 'node_modules' 'vendor'; do
  if echo "$CHECKOV_SKIP" | grep -qFw "$p"; then
    pass "5c.x .checkov.yaml skip-path contains '$p'"
  else
    fail "5c.x .checkov.yaml skip-path contains '$p'" "not in skip-path"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 5d: super-linter.yml FILTER_REGEX_EXCLUDE covers tree-sitter
#             generated / companion C sources (machine-generated or
#             upstream-style; reformatting creates fork drift)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 5d: super-linter FILTER_REGEX_EXCLUDE tree-sitter coverage ==="

FILTER_REGEX=$(grep -E '^[[:space:]]*FILTER_REGEX_EXCLUDE:' "$REPO_ROOT/.github/workflows/super-linter.yml" | head -1)
for pattern in 'tree-sitter-' 'parser|scanner' 'dist/' 'vendor/'; do
  if echo "$FILTER_REGEX" | grep -qF "$pattern"; then
    pass "5d.x super-linter FILTER_REGEX_EXCLUDE contains '$pattern'"
  else
    fail "5d.x super-linter FILTER_REGEX_EXCLUDE contains '$pattern'" "not in regex"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 7b: Onboarding doc regression net — the key Phase 1+2
#             concepts must stay documented for future onboarders
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 7b: onboarding.mdx regression net ==="

ONBOARDING="$REPO_ROOT/docs/onboarding.mdx"
for phrase in 'skip_files' 'excluded_required_contexts' 'Fork-fidelity' 'Linter-compatibility audit cadence' 'frontmatter titles containing colons'; do
  if grep -qF "$phrase" "$ONBOARDING"; then
    pass "7b.x onboarding.mdx references '$phrase'"
  else
    fail "7b.x onboarding.mdx references '$phrase'" "phrase missing"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 8: Idempotence (running this script twice yields identical output)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 8: Idempotence ==="
# We assert this by making sure no test mutates repo state.
# If a future assertion generates a temp file, it must clean up.
TMPS_BEFORE=$(find /tmp -maxdepth 1 -name 'test-linter-configs-*' 2>/dev/null | wc -l)
if [ "$TMPS_BEFORE" = "0" ]; then
  pass "6.1 no stray /tmp/test-linter-configs-* files (idempotent)"
else
  fail "6.1 no stray /tmp/test-linter-configs-* files (idempotent)" "$TMPS_BEFORE stray files"
fi

# ════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($TESTS_RUN total)"
echo "════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
