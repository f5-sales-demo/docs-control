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
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
CONTRIBUTING_MD="$REPO_ROOT/CONTRIBUTING.md"
PR_TEMPLATE="$REPO_ROOT/.github/PULL_REQUEST_TEMPLATE.md"

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
  "scripts/agy-review.sh" \
  "pr-review-toolkit" "/security-review" "Opus" "Sonnet" "Haiku"; do
  assert_not_contains "$AGENTS_MD" "$token" "AGENTS.md excludes assistant-specific token: $token"
done
assert_not_contains "$AGENTS_MD" "demo-components" "AGENTS.md keeps skills out of project instructions"

echo ""
echo "=== Section 2: agent guidance carries work through the protected-branch lifecycle ==="

for file in "$AGENTS_MD" "$CLAUDE_MD" "$CONTRIBUTING_MD" "$PR_TEMPLATE"; do
  relative=${file#"$REPO_ROOT"/}
  for token in "detailed issue" "feature branch" "MERGED" "fleet convergence"; do
    assert_contains "$file" "$token" "$relative carries lifecycle state: $token"
  done
done

for file in "$AGENTS_MD" "$CLAUDE_MD" "$CONTRIBUTING_MD"; do
  relative=${file#"$REPO_ROOT"/}
  for token in "gh pr checks --watch" "BEHIND" "gh pr update-branch" "DIRTY" \
    "gh pr merge --auto --squash"; do
    assert_contains "$file" "$token" "$relative defines active PR handling: $token"
  done
done

for token in \
  "Never commit or push directly to the protected default branch" \
  "After opening a PR, return control" \
  "do not spend a coding-agent session polling GitHub Actions" \
  "Do not poll or wait on GitHub Actions" \
  "CI watched to green (not just queued)"; do
  for file in "$AGENTS_MD" "$CLAUDE_MD" "$CONTRIBUTING_MD" "$PR_TEMPLATE"; do
    relative=${file#"$REPO_ROOT"/}
    assert_not_contains "$file" "$token" "$relative excludes legacy stopper: $token"
  done
done

echo ""
echo "=== Section 3: managed-file governance covers Codex surfaces ==="

MANAGED_PATHS="AGENTS.md
.agents/skills/demo-components/SKILL.md
.agents/skills/demo-components/agents/openai.yaml
scripts/agy-pre-push-review.sh
scripts/agy-review.sh
scripts/agy-review-output.schema.json
scripts/translation-release-policy.sh
scripts/validate-translations.sh
tests/test-agy-pre-push-review.sh
tests/test-translation-release-policy.sh
tests/test-validate-translations.sh"

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

echo "=== Section 3a: every managed source triggers a manifest rebuild ==="

manifest_trigger_for_source() {
  local source="$1"
  case "$source" in
  .agents/*) printf '%s\n' '.agents/**' ;;
  .claude/hooks/*) printf '%s\n' '.claude/hooks/**' ;;
  .github/ISSUE_TEMPLATE/*) printf '%s\n' '.github/ISSUE_TEMPLATE/**' ;;
  workflows/*) printf '%s\n' 'workflows/**' ;;
  scripts/*) printf '%s\n' 'scripts/**' ;;
  tests/*) printf '%s\n' 'tests/**' ;;
  *) printf '%s\n' "$source" ;;
  esac
}

while IFS= read -r source; do
  [ -n "$source" ] || continue
  trigger=$(manifest_trigger_for_source "$source")
  if grep -qF -- "- '$trigger'" "$MANIFEST_WORKFLOW"; then
    pass "manifest rebuild watches managed source: $source"
  else
    fail "manifest rebuild watches managed source: $source" "missing trigger: $trigger"
  fi
done < <(jq -r '.managed_files.files[].src' "$REPO_SETTINGS")

echo ""
echo "=== Section 4: demo-components uses current progressive-discovery endpoints ==="

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
