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

if python3 -c "import sys, tomllib; tomllib.load(open('$REPO_ROOT/.ruff.toml', 'rb'))" 2>/dev/null; then
  pass "3.x .ruff.toml is valid TOML"
else
  fail "3.x .ruff.toml is valid TOML" "tomllib.load failed"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 4: .ruff.toml is self-contained (no dead extend references)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 4: .ruff.toml self-contained ==="

# Test 4.1: .ruff.toml must not reference a non-existent file via `extend`.
# It is synced downstream verbatim, so a missing target would break lint in
# every governed repo.
EXTEND_TARGET=$(python3 -c "import tomllib; d=tomllib.load(open('$REPO_ROOT/.ruff.toml','rb')); print(d.get('extend',''))")
if [ -z "$EXTEND_TARGET" ]; then
  pass "4.x .ruff.toml has no extend directive"
elif [ -f "$REPO_ROOT/$EXTEND_TARGET" ]; then
  pass "4.x .ruff.toml extend target '$EXTEND_TARGET' exists"
else
  fail "4.x .ruff.toml extend target '$EXTEND_TARGET' exists" "file not found in repo root"
fi

# Test 4.3: ruff can actually run against .ruff.toml end-to-end on an empty
# directory. Exercises config load, including all extend chains and lint rule
# tables. A missing extend target surfaces here as a runtime error (unlike
# --help which short-circuits before config resolution).
if command -v ruff >/dev/null 2>&1; then
  EMPTY=$(mktemp -d)
  # shellcheck disable=SC2064  # $EMPTY is set locally above and intentional
  trap "rm -rf '$EMPTY'" EXIT
  if (cd "$REPO_ROOT" && ruff check --config "$REPO_ROOT/.ruff.toml" "$EMPTY" >/dev/null 2>&1); then
    pass "4.3 ruff check --config .ruff.toml runs cleanly end-to-end"
  else
    fail "4.3 ruff check --config .ruff.toml runs cleanly end-to-end" "ruff exited non-zero on an empty dir"
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
# Rust identifier fragments from xcsh (ForIn, ser, anc, Statics)
# Legitimate English (invokable) and common test-fixture strings (doesnt, takin)
for word in doesnt forin invokable takin defaul ser anc; do
  if grep -qE "(^|[=,])${word}([,]|$)" "$REPO_ROOT/.codespellrc"; then
    pass "5.x .codespellrc ignore-words-list contains '$word'"
  else
    fail "5.x .codespellrc ignore-words-list contains '$word'" "not whitelisted"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 7c: excluded_required_contexts entries must use the fully-
#             qualified "workflow / job" form that matches the actual
#             `contexts` list in branch protection
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 7c: excluded_required_contexts uses qualified names ==="

# GitHub reports required status checks as "<workflow>/<job>", e.g.
# "lint / Lint Code Base" (not "Lint Code Base"). Set subtraction in
# enforce-repo-settings.yml is exact-match, so bare job names never match
# the `contexts` array and the exclusion silently no-ops.
# Every entry in excluded_required_contexts MUST therefore appear in the
# base `required_status_checks.contexts` list verbatim, OR in
# `additional_contexts` (the only other source of contexts).
BASE_CTX=$(jq -c '.branch_protection[0].required_status_checks.contexts // []' "$REPO_SETTINGS")
MISSING=""
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  if ! echo "$BASE_CTX" | jq -e --arg e "$entry" 'index($e) != null' >/dev/null; then
    REPO=$(jq -r --arg e "$entry" '.repo_overrides | to_entries[] | select(.value.excluded_required_contexts // [] | index($e)) | .key' "$REPO_SETTINGS" | head -1)
    ADDITIONAL=$(jq -c --arg r "$REPO" '.repo_overrides[$r].additional_contexts // []' "$REPO_SETTINGS")
    if ! echo "$ADDITIONAL" | jq -e --arg e "$entry" 'index($e) != null' >/dev/null; then
      MISSING="${MISSING}  - ${entry} (in repo_overrides.${REPO})\n"
    fi
  fi
done < <(jq -r '.repo_overrides | to_entries[] | .value.excluded_required_contexts // [] | .[]' "$REPO_SETTINGS")

if [ -z "$MISSING" ]; then
  pass "7c.1 every excluded_required_contexts entry matches a real context"
else
  fail "7c.1 every excluded_required_contexts entry matches a real context" \
    "unmatched:\n$MISSING"
fi

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
  cache-poisoning \
  secrets-inherit \
  secrets-outside-env \
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

# Security-relevant audits stay ENABLED fleet-wide (never globally disabled).
# Intentional instances are handled with justified inline `# zizmor: ignore`
# comments or root-cause fixes, so new occurrences elsewhere are still caught.
for rule in \
  dangerous-triggers \
  excessive-permissions \
  template-injection; do
  if python3 -c "
import sys, yaml
with open('$REPO_ROOT/zizmor.yaml') as f:
  cfg = yaml.safe_load(f)
sys.exit(1 if cfg.get('rules', {}).get('$rule', {}).get('disable') else 0)
" 2>/dev/null; then
    pass "6.x zizmor.yaml keeps '$rule' enabled (security audit active)"
  else
    fail "6.x zizmor.yaml keeps '$rule' enabled" "rule is globally disabled"
  fi
done

# template-injection is scoped-ignored ONLY for the trusted, push:main-only
# github-pages-deploy.yml (no untrusted-data path); it stays active elsewhere.
if python3 -c "
import sys, yaml
with open('$REPO_ROOT/zizmor.yaml') as f:
  cfg = yaml.safe_load(f)
ig = cfg.get('rules', {}).get('template-injection', {}).get('ignore', [])
sys.exit(0 if 'github-pages-deploy.yml' in ig else 1)
" 2>/dev/null; then
  pass "6.x template-injection scoped-ignores github-pages-deploy.yml only"
else
  fail "6.x template-injection scoped-ignores github-pages-deploy.yml" "scoped ignore missing"
fi

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
# MD029  ordered-list-style    — allow mixed 1. + 1) styles
# MD033  no-inline-html        — MDX components and HTML embed
# MD040  code-fence-language   — plain fenced code for pseudo-output is valid
# MD041  first-line-h1         — Starlight frontmatter supplies the H1 implicitly
# MD060  table-column-style    — tables are content-first, not pipe-aligned
# MD025  single-title          — multi-H1 is used in reference docs
# MD024  no-duplicate-heading  — repeated section names in reference docs
# MD007  ul-indent             — indent preference varies by fork style
for rule in MD029 MD033 MD040 MD041 MD060 MD025 MD024 MD007; do
  if jq -e --arg r "$rule" '.[$r] == false' "$REPO_ROOT/.markdownlint.json" >/dev/null; then
    pass "5b.x .markdownlint.json disables $rule"
  else
    fail "5b.x .markdownlint.json disables $rule" "not set to false"
  fi
done

# MD013 (line-length) is ENFORCED with a generous 400-char cap, not disabled
# (#682: "enforce MD013 (400) to match CI"). Long code examples and tables fit
# under 400 while genuinely runaway lines are still flagged — so assert the cap
# rather than a blanket disable.
if jq -e '.MD013.line_length == 400' "$REPO_ROOT/.markdownlint.json" >/dev/null; then
  pass "5b.x .markdownlint.json enforces MD013 line_length 400"
else
  fail "5b.x .markdownlint.json enforces MD013 line_length 400" "MD013.line_length != 400"
fi

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

# Rationale: docs-control's .ruff.toml / .python-lint / .mypy.ini are
# deliberately strict (pydocstyle D, pytest PT, tryceratops TRY, errmsg EM,
# type-checking TC, full select list). Applied to xcsh — an active fork of
# badlogic/pi-mono — they surface 743+ ruff errors and 73 mypy errors that
# are not bugs, just stylistic drift from upstream. xcsh therefore ships
# its own permissive Python configs and must be opted out of sync.
for cfg in .ruff.toml .python-lint .mypy.ini; do
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
for phrase in 'skip_files' 'excluded_required_contexts' 'Fork-fidelity' 'Linter-compatibility audit cadence' 'frontmatter titles containing colons' 'release PR pattern'; do
  if grep -qF "$phrase" "$ONBOARDING"; then
    pass "7b.x onboarding.mdx references '$phrase'"
  else
    fail "7b.x onboarding.mdx references '$phrase'" "phrase missing"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 9: .pre-commit-config.yaml — editorconfig-checker must honor
#            --files so pre-existing unrelated violations do not block
#            developer commits
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 9: pre-commit editorconfig-checker scope ==="

# When editorconfig-checker was ported out of super-linter into
# .pre-commit-config.yaml it was written with pass_filenames: false,
# causing the hook to receive no file args and scan the entire repo.
# Any governed repo carrying even one pre-existing violation then
# blocks every developer commit regardless of what the commit actually
# touches. pass_filenames must be true (or absent, since pre-commit's
# default is true) so the hook scrubs only the changed files.
ECC_PASS=$(python3 -c "
import sys, yaml
cfg = yaml.safe_load(open('$REPO_ROOT/.pre-commit-config.yaml'))
for repo in cfg.get('repos', []):
    for hook in repo.get('hooks', []):
        if hook.get('id') == 'editorconfig-checker':
            print(hook.get('pass_filenames', True))
            sys.exit(0)
print('HOOK_MISSING')
")

if [ "$ECC_PASS" = "True" ]; then
  pass "9.1 editorconfig-checker hook honors --files (pass_filenames: true)"
else
  fail "9.1 editorconfig-checker hook honors --files (pass_filenames: true)" \
    "expected pass_filenames=True (or absent), got '$ECC_PASS'"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 10: secrets_manifest schema validity
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 10: secrets_manifest schema validity ==="

MANIFEST=$(jq -c '.secrets_manifest // empty' "$REPO_SETTINGS")

if [ -z "$MANIFEST" ] || [ "$MANIFEST" = "null" ]; then
  fail "10.1 secrets_manifest exists in repo-settings.json" "key not found"
else
  pass "10.1 secrets_manifest exists in repo-settings.json"

  # 10.2: every role referenced in repo_roles must exist in roles
  ROLE_CHECK=$(echo "$MANIFEST" | jq -r '
    . as $m |
    [.repo_roles | to_entries[] | .value[]] | unique | .[] |
    select(. as $r | $m.roles | has($r) | not)
  ')
  if [ -z "$ROLE_CHECK" ]; then
    pass "10.2 all repo_roles reference valid roles"
  else
    fail "10.2 all repo_roles reference valid roles" "undefined roles: $ROLE_CHECK"
  fi

fi

# ════════════════════════════════════════════════════════════════════
# SECTION 11: fork-PR workflow approval policy
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 11: actions_fork_pr_approval schema validity ==="

FORK_POLICY=$(jq -r '.actions_fork_pr_approval.approval_policy // empty' "$REPO_SETTINGS")

if [ -z "$FORK_POLICY" ]; then
  fail "11.1 actions_fork_pr_approval.approval_policy exists" "key not found"
else
  pass "11.1 actions_fork_pr_approval.approval_policy exists"

  # 11.2: must be one of GitHub's accepted enum values for the
  # fork-pr-contributor-approval endpoint. Anything else is silently
  # rejected by the API and would leave the fleet on GitHub's default.
  case "$FORK_POLICY" in
  first_time_contributors_new_to_github | first_time_contributors | all_external_contributors)
    pass "11.2 approval_policy is a valid enum ($FORK_POLICY)"
    ;;
  *)
    fail "11.2 approval_policy is a valid enum" "got '$FORK_POLICY'"
    ;;
  esac
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 8: Idempotence (running this script twice yields identical output)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 8: Idempotence ==="
# We assert this by making sure no test mutates repo state.
# If a future assertion generates a temp file, it must clean up.
TMPS_BEFORE=$(find /tmp -maxdepth 1 -name 'test-linter-configs-*' 2>/dev/null | wc -l | tr -d ' ')
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
