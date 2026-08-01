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
# Upstream-misspelled F5 Distributed Cloud API identifiers that must reach the
# wire verbatim (checkin, blocked_sevice) — codespell offers two candidates for
# "sevice" so --write-changes cannot resolve it and the gate hard-fails
for word in doesnt forin invokable takin defaul ser anc checkin sevice; do
  if grep -qE "(^|[=,])${word}([,]|$)" "$REPO_ROOT/.codespellrc"; then
    pass "5.x .codespellrc ignore-words-list contains '$word'"
  else
    fail "5.x .codespellrc ignore-words-list contains '$word'" "not whitelisted"
  fi
done

# pre-commit passes explicit paths, bypassing .codespellrc's skip list. Its
# hook-level regex must filter both translated docs and translated source
# catalogs while leaving English docs and i18n implementation code checked.
CODESPELL_EXCLUDE=$(awk '
  /- id: codespell$/ { in_codespell = 1; next }
  in_codespell && /exclude:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
' "$REPO_ROOT/.pre-commit-config.yaml")

for path in docs/fr/guide.md src/i18n/mega-menu-translations.ts; do
  if [[ "$path" =~ $CODESPELL_EXCLUDE ]]; then
    pass "5.x codespell pre-commit excludes '$path'"
  else
    fail "5.x codespell pre-commit excludes '$path'" "not matched by hook exclude regex"
  fi
done

for path in docs/en/guide.md src/i18n/translator.ts; do
  if [[ "$path" =~ $CODESPELL_EXCLUDE ]]; then
    fail "5.x codespell pre-commit checks '$path'" "unexpectedly matched by hook exclude regex"
  else
    pass "5.x codespell pre-commit checks '$path'"
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

XCSH_CONTEXTS=$(jq -c '.repo_overrides.xcsh.additional_contexts // []' "$REPO_SETTINGS")
if echo "$XCSH_CONTEXTS" | jq -e 'index("pii-guard") != null' >/dev/null; then
  pass "7c.2 xcsh requires the pii-guard check"
else
  fail "7c.2 xcsh requires the pii-guard check" "pii-guard is not in xcsh additional_contexts"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 7d: additional_contexts must name checks that ALWAYS run
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 7d: additional_contexts name unconditional checks ==="

# What actually deadlocks a required check is a *workflow* that never starts, not a
# *job* that skips. GitHub's documented behaviour, which decides this list:
#
#   "Successful check statuses are success, skipped, and neutral."
#   "If a job within a workflow is skipped due to a conditional, it will report its
#    status as 'Success'."
#   "If a workflow is skipped due to path filtering, branch filtering or a commit
#    message, then checks associated with that workflow will remain in a 'Pending'
#    state. A pull request that requires those checks to be successful will be
#    blocked from merging."
#   — docs.github.com, "Troubleshooting required status checks"
#
# So a job-level `if:` is safe to require: when it skips, it reports success and the
# pull request merges. Only a workflow-level filter leaves the context pending.
#
# What this section cannot do, stated plainly so a green result is not mistaken for
# coverage: it rejects names it was told about. The workflows live in independently
# changing repositories, so a rename, a typo, or a newly added workflow-level filter
# passes here and then enforce-repo-settings installs a context that never reports.
# `scripts/verify-required-contexts.sh` closes that gap by asking GitHub which checks
# real pull requests actually reported, and is the check docs-control#862 asks for:
# "verified by opening a throwaway PR per repo and confirming the check actually
# blocks, not by reading the config back." Run it when changing this config.
#
# This list is therefore workflow-filtered contexts only. Both live in
# terraform-provider-xcsh's acc-tests.yml:
#
#   on:
#     pull_request:
#       branches: [main]
#       paths:
#         - 'internal/provider/**'
#         - 'internal/client/**'
#         ...
#
#   Mock Tests (Parallel), Test Summary
#     Neither reports on a pull request touching nothing under those paths — a
#     docs-only or CI-only change, for instance. Test Summary even carries
#     `if: always()`, which looks maximally safe and is irrelevant: the workflow
#     never starts, so the job never exists. Requiring either blocks every PR
#     outside those paths, permanently.
#
# Constitution Check and Contract-diff gate were previously listed here and have
# been removed. Both are ordinary jobs with a job-level `if:` in workflows that
# trigger on every pull request to main (ci.yml and tests.yml respectively, neither
# paths-filtered — verified against those repositories). They report success when
# they skip, so requiring them is safe, and both are now required: each had already
# caught a real defect that merged anyway (#1400, #1153). Keeping them out of the
# required set was the very gap #862 exists to close.
SKIPPABLE="Mock Tests (Parallel)
Test Summary"
WRONGLY_REQUIRED=""
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if jq -e --arg n "$name" \
    '[.repo_overrides[] | .additional_contexts // [] | .[]] | index($n) != null' \
    "$REPO_SETTINGS" >/dev/null; then
    WRONGLY_REQUIRED="${WRONGLY_REQUIRED}  - ${name}\n"
  fi
done < <(printf '%s\n' "$SKIPPABLE")

if [ -z "$WRONGLY_REQUIRED" ]; then
  pass "7d.1 no additional_contexts entry names a job that can skip"
else
  fail "7d.1 no additional_contexts entry names a job that can skip" \
    "these jobs carry a branch condition and would block forever:\n$WRONGLY_REQUIRED"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 7e: the uniform shell-test job gates every governed PR
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 7e: uniform shell-test required context ==="

if echo "$BASE_CTX" | jq -e 'index("lint / Shell Unit Tests") != null' >/dev/null; then
  pass "7e.1 downstream branch protection requires Shell Unit Tests"
else
  fail "7e.1 downstream branch protection requires Shell Unit Tests" \
    "lint / Shell Unit Tests is absent from the base contexts"
fi

SELF_CTX=$(jq -c \
  '.branch_protection[0].required_status_checks.self_contexts // []' \
  "$REPO_SETTINGS")
if echo "$SELF_CTX" | jq -e 'index("Shell Unit Tests") != null' >/dev/null; then
  pass "7e.2 docs-control branch protection requires Shell Unit Tests"
else
  fail "7e.2 docs-control branch protection requires Shell Unit Tests" \
    "Shell Unit Tests is absent from self_contexts"
fi

MCN_CONTEXTS=$(jq -c '.repo_overrides.mcn.additional_contexts // []' "$REPO_SETTINGS")
if echo "$MCN_CONTEXTS" | jq -e 'index("lint / Shell Unit Tests") == null' >/dev/null; then
  pass "7e.3 mcn does not duplicate the uniform base context"
else
  fail "7e.3 mcn does not duplicate the uniform base context" \
    "remove the obsolete mcn-only Shell Unit Tests override"
fi

REQUIRED_CONTEXT_VERIFIER="$REPO_ROOT/scripts/verify-required-contexts.sh"
if grep -qF 'downstream-repos.json' "$REQUIRED_CONTEXT_VERIFIER"; then
  pass "7e.4 live verification covers the complete governed fleet"
else
  fail "7e.4 live verification covers the complete governed fleet" \
    "verify-required-contexts.sh still checks only repository overrides"
fi

if grep -qF 'required_status_checks.contexts' "$REQUIRED_CONTEXT_VERIFIER"; then
  pass "7e.5 live verification includes uniform base contexts"
else
  fail "7e.5 live verification includes uniform base contexts" \
    "verify-required-contexts.sh ignores the base required contexts"
fi

XCSH_EXCLUDED=$(jq -c '.repo_overrides.xcsh.excluded_required_contexts // []' \
  "$REPO_SETTINGS")
if echo "$XCSH_EXCLUDED" | jq -e \
  'index("lint / Shell Unit Tests") != null' >/dev/null; then
  pass "7e.6 xcsh opts out of the Super-Linter shell context it does not emit"
else
  fail "7e.6 xcsh opts out of the Super-Linter shell context it does not emit" \
    "fleet verification proves xcsh never reports lint / Shell Unit Tests"
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
# SECTION 5f: the repo-hygiene gate never executes PR-head code
#             (REVIEWER-SPEC.md invariant 3). The Lint Code Base job holds
#             statuses:write and pull-requests:write, so running a PR's own
#             copy of the script would hand those scopes to PR-authored code,
#             and gating on the head's copy would let a PR delete the file to
#             skip the gate.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 5f: repo-hygiene gate trust boundary ==="

HYG_STEP=$(awk '/- name: Check repository hygiene/,/- name: Check for hardcoded locale lists/' "$SL_YML")
LOCALE_STEP=$(awk '/- name: Check for hardcoded locale lists/,/^      - name: Setup Biome/' "$SL_YML")

if [ -n "$HYG_STEP" ]; then
  pass "5f.1 repo-hygiene step is present in the lint job"
else
  fail "5f.1 repo-hygiene step is present in the lint job" "step not found"
fi

if printf '%s' "$HYG_STEP" | grep -qE 'git -C "\$gov_dir" show "\$\{canonical_sha\}:\$\{script\}"' &&
  ! printf '%s' "$HYG_STEP" | grep -qE 'git show "origin/\$\{branch\}:\$\{script\}"'; then
  pass "5f.2 repo-hygiene runs the canonical copy, not this repo's"
else
  fail "5f.2 repo-hygiene runs the canonical copy, not this repo's" \
    "a sync target's copy can lag docs-control and deadlock the PR that would fix it (#815)"
fi

if printf '%s' "$HYG_STEP" | grep -qE '^[[:space:]]*run: bash scripts/check-repo-hygiene\.sh[[:space:]]*$'; then
  fail "5f.3 does not execute the PR head's copy" "step runs the head working-copy script directly"
else
  pass "5f.3 does not execute the PR head's copy"
fi

if printf '%s' "$HYG_STEP" | grep -q "hashFiles('scripts/check-repo-hygiene.sh')"; then
  fail "5f.4 enforcement cannot be skipped by deleting the file" "step is gated on the head's copy"
else
  pass "5f.4 enforcement cannot be skipped by deleting the file"
fi

# Every governed script the lint job executes must come from CANONICAL governance,
# never from the pull request head and never from this repo's possibly-stale copy,
# and must not be skippable by deleting the file. Whether a script applies here is
# still decided by the default branch carrying it, so skip_files keeps working.
if [ -n "$LOCALE_STEP" ]; then
  pass "5f.5 locale-lint step is present in the lint job"
else
  fail "5f.5 locale-lint step is present in the lint job" "step not found"
fi

if printf '%s' "$LOCALE_STEP" | grep -qE 'git -C "\$gov_dir" show "\$\{canonical_sha\}:\$\{script\}"' &&
  ! printf '%s' "$LOCALE_STEP" | grep -qE 'git show "origin/\$\{branch\}:\$\{script\}"'; then
  pass "5f.6 locale-lint runs the canonical copy, not this repo's"
else
  fail "5f.6 locale-lint runs the canonical copy, not this repo's" \
    "a sync target's copy can lag docs-control and deadlock the PR that would fix it (#815)"
fi

if printf '%s' "$LOCALE_STEP" | grep -qE '^[[:space:]]*run: bash scripts/locale-lint\.sh[[:space:]]*$'; then
  fail "5f.7 locale-lint does not execute the head's copy" "step runs the head working-copy script"
else
  pass "5f.7 locale-lint does not execute the head's copy"
fi

if printf '%s' "$LOCALE_STEP" | grep -q "hashFiles('scripts/locale-lint.sh')"; then
  fail "5f.8 locale-lint enforcement cannot be skipped by deleting the file" "gated on the head's copy"
else
  pass "5f.8 locale-lint enforcement cannot be skipped by deleting the file"
fi

# The skip_files opt-out is expressed by the repo not carrying the script at all, so
# the presence check against the default branch must remain. Sourcing canonical
# unconditionally would start enforcing locale-lint in terraform-provider-xcsh, which
# deliberately opted out.
for pair in "5f.9:HYG:check-repo-hygiene.sh" "5f.10:LOC:locale-lint.sh"; do
  num=${pair%%:*}
  rest=${pair#*:}
  which=${rest%%:*}
  name=${rest##*:}
  if [ "$which" = "HYG" ]; then step="$HYG_STEP"; else step="$LOCALE_STEP"; fi
  if printf '%s' "$step" | grep -qE 'git cat-file -e "origin/\$\{branch\}:\$\{script\}"'; then
    pass "${num} ${name} keeps the default-branch presence gate (skip_files opt-out)"
  else
    fail "${num} ${name} keeps the default-branch presence gate (skip_files opt-out)" \
      "without it, repos that opted out would start being enforced"
  fi
done

# The canonical fetch must not touch this workspace: a --depth=1 fetch into the
# checkout writes .git/shallow and breaks Super-Linter's GIT_MERGE_BASE calculation,
# failing the whole job (observed on PR #817).
for pair in "5f.13:HYG:check-repo-hygiene.sh" "5f.14:LOC:locale-lint.sh"; do
  num=${pair%%:*}
  rest=${pair#*:}
  which=${rest%%:*}
  name=${rest##*:}
  if [ "$which" = "HYG" ]; then step="$HYG_STEP"; else step="$LOCALE_STEP"; fi
  if printf '%s' "$step" | grep -qE 'git -C "\$gov_dir" fetch' &&
    ! printf '%s' "$step" | grep -qE '^[[:space:]]*git fetch --no-tags --quiet --depth=1'; then
    pass "${num} ${name} fetches canonical into a throwaway repo, not the workspace"
  else
    fail "${num} ${name} fetches canonical into a throwaway repo, not the workspace" \
      "a --depth=1 fetch into the checkout writes .git/shallow and breaks merge-base"
  fi
done

# A governed gate that silently stops enforcing when it cannot reach canonical is
# worse than a red check.
for pair in "5f.11:HYG:check-repo-hygiene.sh" "5f.12:LOC:locale-lint.sh"; do
  num=${pair%%:*}
  rest=${pair#*:}
  which=${rest%%:*}
  name=${rest##*:}
  if [ "$which" = "HYG" ]; then step="$HYG_STEP"; else step="$LOCALE_STEP"; fi
  if printf '%s' "$step" | grep -q "cannot reach canonical governance" &&
    printf '%s' "$step" | grep -qE '^[[:space:]]*exit 1$'; then
    pass "${num} ${name} fails closed when canonical is unreachable"
  else
    fail "${num} ${name} fails closed when canonical is unreachable" \
      "an unreachable remote must not pass or skip the gate"
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
for phrase in 'skip_files' 'excluded_required_contexts' 'Fork-fidelity' 'Linter-compatibility audit cadence' 'frontmatter titles containing colons' 'release PR pattern' 'Repository classes: repo_classes'; do
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

# Shell formatting must fail locally before Super-Linter's SHELL_SHFMT gate.
# Install the prebuilt mirror as a local Python hook so contributors and
# pre-commit.ci get the same formatter version without a local prerequisite,
# while pre-commit.ci's weekly autoupdater cannot rewrite its pinned revision.
SHFMT_CONFIG=$(python3 -c "
import json, yaml
cfg = yaml.safe_load(open('$REPO_ROOT/.pre-commit-config.yaml'))
result = {
    'repo': None,
    'rev': None,
    'hook_found': False,
    'entry': None,
    'language': None,
    'additional_dependencies': None,
    'args': None,
    'types': None,
    'exclude_types': None,
    'ci_skipped': 'shfmt' in cfg.get('ci', {}).get('skip', []),
}
for repo in cfg.get('repos', []):
    for hook in repo.get('hooks', []):
        if hook.get('id') == 'shfmt':
            result['repo'] = repo.get('repo')
            result['rev'] = repo.get('rev')
            result['hook_found'] = True
            result['entry'] = hook.get('entry')
            result['language'] = hook.get('language')
            result['additional_dependencies'] = hook.get('additional_dependencies')
            result['args'] = hook.get('args')
            result['types'] = hook.get('types')
            result['exclude_types'] = hook.get('exclude_types')
print(json.dumps(result))
")

if echo "$SHFMT_CONFIG" | jq -e \
  '.hook_found and .repo == "local" and .rev == null and
   .entry == "shfmt" and .language == "python" and
   .additional_dependencies == ["git+https://github.com/scop/pre-commit-shfmt@05c1426671b9237fb5e1444dd63aa5731bec0dfb"]' >/dev/null; then
  pass "9.2 shfmt uses an immutable auto-installed dependency outside autoupdate"
else
  fail "9.2 shfmt uses an immutable auto-installed dependency outside autoupdate" \
    "expected a local Python hook pinned to scop/pre-commit-shfmt@05c1426671b9237fb5e1444dd63aa5731bec0dfb, got $SHFMT_CONFIG"
fi

if echo "$SHFMT_CONFIG" | jq -e \
  '.args == ["--write", "--indent", "2"]' >/dev/null; then
  pass "9.3 shfmt auto-formats with the CI-equivalent two-space style"
else
  fail "9.3 shfmt auto-formats with the CI-equivalent two-space style" \
    "expected --write --indent 2, got $SHFMT_CONFIG"
fi

if echo "$SHFMT_CONFIG" | jq -e \
  '.types == ["shell"] and .exclude_types == ["csh", "tcsh"] and
   (.ci_skipped | not)' >/dev/null; then
  pass "9.4 shfmt covers Bourne shell files locally and in pre-commit.ci"
else
  fail "9.4 shfmt covers Bourne shell files locally and in pre-commit.ci" \
    "expected types=[shell], exclude_types=[csh,tcsh], and no ci.skip entry, got $SHFMT_CONFIG"
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
# ════════════════════════════════════════════════════════════════════
# SECTION 8: .gitignore's Go vendor rule is root-anchored (#794)
# ════════════════════════════════════════════════════════════════════
# The rule exists for Go module vendoring, which always sits at the module
# root. Unanchored, `vendor/` matches at ANY depth, so it silently swallowed
# deliberately-committed vendored trees — xcsh-chrome-extension's
# src/vendor/chat-ui (45 files) and xcsh's
# packages/coding-agent/src/export/html/vendor. Every re-vendor needed
# `git add -f`, and a forgotten force flag failed CI somewhere unrelated.
# Asserted behaviourally via `git check-ignore` rather than by grepping the
# file, because the pattern's semantics are the thing under test.
echo ""
echo "SECTION 8: .gitignore Go vendor rule is root-anchored"

GI_TMP=$(mktemp -d /tmp/test-linter-configs-gitignore-XXXXXX)
git -C "$GI_TMP" init -q
cp "$REPO_ROOT/.gitignore" "$GI_TMP/.gitignore"
mkdir -p "$GI_TMP/vendor" "$GI_TMP/src/vendor/chat-ui"
: >"$GI_TMP/vendor/modules.txt"
: >"$GI_TMP/src/vendor/chat-ui/index.ts"

# A top-level vendor/ tree must still be ignored — that is the rule's purpose.
if git -C "$GI_TMP" check-ignore -q vendor/modules.txt; then
  pass "8.1 top-level vendor/ is still ignored (Go module vendoring)"
else
  fail "8.1 top-level vendor/ is still ignored (Go module vendoring)" "vendor/modules.txt is no longer ignored"
fi

# A nested vendored tree must NOT be ignored — it is committed deliberately.
if git -C "$GI_TMP" check-ignore -q src/vendor/chat-ui/index.ts; then
  fail "8.2 nested src/vendor/ is NOT ignored" "src/vendor/chat-ui/index.ts is ignored; the vendor rule needs a leading slash"
else
  pass "8.2 nested src/vendor/ is NOT ignored"
fi

rm -rf "$GI_TMP"

# ════════════════════════════════════════════════════════════════════
# SECTION 12: managed PII scanner is formatter-portable
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 12: managed PII scanner Ruff portability ==="

# The scanner is synced verbatim, so its formatter portability is enforced where
# it is authored. Rechecking a caller's stale managed copy deadlocks unrelated
# downstream PRs: they are forbidden to fix it, while the sync PR cannot land.
for width in 88 100 120; do
  if python3 - "$REPO_ROOT/.github/workflows/super-linter.yml" "$width" <<'PY'; then
import sys

import yaml

workflow_path, width = sys.argv[1:]
with open(workflow_path, encoding="utf-8") as workflow_file:
    workflow = yaml.safe_load(workflow_file)

expected_name = f"Check managed PII scanner format at {width} columns"
steps = workflow["jobs"]["lint"]["steps"]
matching = [step for step in steps if step.get("name") == expected_name]
if len(matching) != 1:
    raise SystemExit(1)

step = matching[0]
expected = {
    "uses": "astral-sh/ruff-action@278981a28ce3188b1e39527901f38254bf3aac89",
    "if": (
        "github.repository == 'f5-sales-demo/docs-control' && "
        "hashFiles('scripts/check_pii.py') != ''"
    ),
}
if any(step.get(key) != value for key, value in expected.items()):
    raise SystemExit(1)

inputs = step.get("with", {})
if inputs.get("version") != "0.16.0":
    raise SystemExit(1)
if inputs.get("src") != "scripts/check_pii.py":
    raise SystemExit(1)
if inputs.get("args") != f"format --check --config=line-length={width}":
    raise SystemExit(1)
PY
    pass "12.x docs-control checks canonical PII scanner at ${width} columns"
  else
    fail "12.x docs-control checks canonical PII scanner at ${width} columns" \
      "missing, incorrectly pinned, or not source-repository scoped"
  fi
done

# ════════════════════════════════════════════════════════════════════
# SECTION 13: managed security fixtures satisfy repository hygiene
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 13: managed security fixture hygiene ==="

if (cd "$REPO_ROOT" && bash scripts/check-repo-hygiene.sh --include-paths >/dev/null); then
  pass "13.1 managed security fixtures contain no literal machine-specific paths"
else
  fail "13.1 managed security fixtures contain no literal machine-specific paths" \
    "the opt-in repository hygiene scan rejected governed source"
fi

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
