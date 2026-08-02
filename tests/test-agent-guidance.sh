#!/usr/bin/env bash
# Regression tests for managed agent guidance and shared skills (issue #985).
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

assert_contains() {
  local file="$1" token="$2" label="$3"
  if grep -qF -- "$token" "$file"; then
    pass "$label"
  else
    fail "$label" "missing: $token"
  fi
}

assert_not_contains() {
  local file="$1" token="$2" label="$3"
  if grep -qF -- "$token" "$file"; then
    fail "$label" "unexpected: $token"
  else
    pass "$label"
  fi
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_MD="$REPO_ROOT/AGENTS.md"
SKILL_MD="$REPO_ROOT/.agents/skills/demo-components/SKILL.md"
OPENAI_YAML="$REPO_ROOT/.agents/skills/demo-components/agents/openai.yaml"
REPO_SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"
GOVERNANCE="$REPO_ROOT/.claude/governance.json"
MANIFEST_WORKFLOW="$REPO_ROOT/.github/workflows/build-managed-files-manifest.yml"

echo ""
echo "=== Section 1: AGENTS.md is slim and agent-neutral ==="

for file in "$AGENTS_MD" "$SKILL_MD" "$OPENAI_YAML"; do
  if [ -f "$file" ]; then
    pass "managed source exists: ${file#"$REPO_ROOT"/}"
  else
    fail "managed source exists: ${file#"$REPO_ROOT"/}" "file not found"
  fi
done

AGENTS_MAX_BYTES=4096
AGENTS_BYTES=$(wc -c <"$AGENTS_MD" | tr -d ' ')
if [ "$AGENTS_BYTES" -le "$AGENTS_MAX_BYTES" ]; then
  pass "AGENTS.md is ${AGENTS_BYTES}B, within the ${AGENTS_MAX_BYTES}B budget"
else
  fail "AGENTS.md stays within ${AGENTS_MAX_BYTES}B" "it is ${AGENTS_BYTES}B"
fi

for token in "CONTRIBUTING.md" "DEVELOPING.md" ".claude/governance.json" \
  "origin/<default-branch>" "normal defaults"; do
  assert_contains "$AGENTS_MD" "$token" "AGENTS.md retains ecosystem routing: $token"
done

for token in "EnterWorktree" ".claude/settings.json" "codex:verified-code-review" \
  "code-review-f5" "pr-review-toolkit" "/security-review" "Opus" "Sonnet" "Haiku"; do
  assert_not_contains "$AGENTS_MD" "$token" "AGENTS.md excludes assistant-specific token: $token"
done
assert_not_contains "$AGENTS_MD" "demo-components" "AGENTS.md keeps skills out of project instructions"

echo ""
echo "=== Section 2: managed-file governance covers Codex surfaces ==="

MANAGED_PATHS="AGENTS.md
.agents/skills/demo-components/SKILL.md
.agents/skills/demo-components/agents/openai.yaml"

while IFS= read -r path; do
  [ -z "$path" ] && continue
  if jq -e --arg path "$path" '.managed_files.files | any(.dest == $path and .src == $path)' \
    "$REPO_SETTINGS" >/dev/null; then
    pass "repo-settings manages $path"
  else
    fail "repo-settings manages $path" "missing identical src/dest entry"
  fi

  if jq -e --arg path "$path" '.protected_files | index($path) != null' \
    "$GOVERNANCE" >/dev/null; then
    pass "governance protects $path"
  else
    fail "governance protects $path" "missing protected_files entry"
  fi

  if jq -e --arg path "$path" \
    '[.managed_files.skip_files // {} | .[][] | select(. == $path)] | length == 0' \
    "$REPO_SETTINGS" >/dev/null &&
    jq -e --arg path "$path" '[.skip_files // {} | .[][] | select(. == $path)] | length == 0' \
      "$GOVERNANCE" >/dev/null; then
    pass "$path is distributed fleet-wide"
  else
    fail "$path is distributed fleet-wide" "found in a repository skip list"
  fi
done <<<"$MANAGED_PATHS"

assert_contains "$MANIFEST_WORKFLOW" "- 'AGENTS.md'" "manifest rebuild watches AGENTS.md"
assert_contains "$MANIFEST_WORKFLOW" "- '.agents/**'" "manifest rebuild watches shared skills"

echo ""
echo "=== Section 3: demo-components uses current progressive-discovery endpoints ==="

FRONTMATTER_KEYS=$(awk 'NR == 1 { next } /^---$/ { exit } /^[a-zA-Z0-9_-]+:/ { print $1 }' \
  "$SKILL_MD" | tr '\n' ' ')
if [ "$FRONTMATTER_KEYS" = "name: description: " ]; then
  pass "skill frontmatter contains only name and description"
else
  fail "skill frontmatter contains only name and description" "got: $FRONTMATTER_KEYS"
fi

for endpoint in \
  "https://f5-sales-demo.github.io/demo-resources/llms.txt" \
  "https://f5-sales-demo.github.io/demo-resources/_llms-txt/en/{component}.txt" \
  "https://f5-sales-demo.github.io/{component}/_llms-txt/en/03-deploy.txt"; do
  assert_contains "$SKILL_MD" "$endpoint" "skill includes current endpoint: $endpoint"
done

for obsolete in \
  "demo-resources/_llms-txt/component-catalog.txt" \
  "/_llms-txt/deployment.txt"; do
  assert_not_contains "$SKILL_MD" "$obsolete" "skill rejects obsolete endpoint: $obsolete"
done

assert_contains "$SKILL_MD" "explicit user confirmation" "skill gates terraform apply on confirmation"
assert_contains "$SKILL_MD" "do not fabricate" "skill prohibits fabricated catalog data"
assert_contains "$OPENAI_YAML" 'display_name: "Demo Components"' "OpenAI metadata has display name"
assert_contains "$OPENAI_YAML" 'short_description: "Discover and deploy F5 demo infrastructure"' \
  "OpenAI metadata has concise description"
assert_contains "$OPENAI_YAML" 'default_prompt: "Use $demo-components' \
  "OpenAI metadata default prompt invokes the skill"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Tests run: $TESTS_RUN | Passed: $PASS | Failed: $FAIL"
echo "════════════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
