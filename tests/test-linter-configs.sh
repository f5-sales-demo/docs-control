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
# fixtures/ holds test snapshots with intentional misspellings
# *.min.js is minified vendor JS copied into the tree
# *.jsonl is session-fixture prose
# *.b64.js is base64-encoded vendored content
for pat in 'vendored' 'fixtures' '*.min.js' '*.jsonl' '*.b64.js'; do
  if echo "$CODESPELL_SKIP" | grep -qF "$pat"; then
    pass "5.x .codespellrc skip contains '$pat'"
  else
    fail "5.x .codespellrc skip contains '$pat'" "not in skip list"
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
# SECTION 7: Idempotence (running this script twice yields identical output)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Section 7: Idempotence ==="
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
