#!/usr/bin/env bash
# Regression guard for Antigravity-only semantic review and CI triage routing.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETTINGS="$REPO_ROOT/.claude/settings.json"
REPO_SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"
GOVERNANCE="$REPO_ROOT/.claude/governance.json"
DOWNSTREAM="$REPO_ROOT/.github/config/downstream-repos.json"
PASS=0
FAIL=0

pass() {
  printf '  PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf '  FAIL: %s — %s\n' "$1" "$2"
  FAIL=$((FAIL + 1))
}

contains() {
  local file=$1 token=$2 label=$3
  if grep -qF -- "$token" "$file"; then pass "$label"; else fail "$label" "missing $token"; fi
}

rejects() {
  local file=$1 token=$2 label=$3
  if grep -qF -- "$token" "$file"; then fail "$label" "found $token"; else pass "$label"; fi
}

echo "Antigravity-only review routing"

if jq empty "$SETTINGS" "$REPO_SETTINGS" "$GOVERNANCE" "$DOWNSTREAM"; then
  pass "governance JSON parses"
else
  fail "governance JSON parses" "jq rejected a configuration file"
fi

for skill in code-review:code-review pr-review-toolkit:review-pr verified-review:verified-code-review; do
  if jq -e --arg skill "Skill($skill)" '.permissions.deny | index($skill) != null' \
    "$SETTINGS" >/dev/null; then
    pass "Claude blocks $skill"
  else
    fail "Claude blocks $skill" "deny rule is absent"
  fi
done

for document in AGENTS.md CLAUDE.md CONTRIBUTING.md; do
  contains "$REPO_ROOT/$document" 'scripts/agy-pre-push-review.sh' \
    "$document routes branch review to Antigravity"
  contains "$REPO_ROOT/$document" 'Route semantic review through Antigravity' \
    "$document states the positive semantic-review route"
  rejects "$REPO_ROOT/$document" 'not reviewers' \
    "$document avoids negative semantic-review routing"
  rejects "$REPO_ROOT/$document" 'Codex review commands' \
    "$document avoids assistant-specific stopper prose"
done
contains "$REPO_ROOT/AGENTS.md" 'scripts/agy-review.sh document' \
  "AGENTS routes specs and plans directly to agy"
contains "$REPO_ROOT/CLAUDE.md" 'scripts/agy-review.sh document' \
  "CLAUDE routes specs and plans directly to agy"
contains "$REPO_ROOT/CONTRIBUTING.md" 'scripts/agy-review.sh document' \
  "CONTRIBUTING routes specs and plans directly to agy"

for mapping in \
  'workflows/code-review.yml|.github/workflows/code-review.yml' \
  '.github/workflows/claude-review.yml|.github/workflows/claude-review.yml' \
  'scripts/antigravity-translate-staged.sh|scripts/antigravity-translate-staged.sh' \
  'scripts/parse-translation-trigger.sh|scripts/parse-translation-trigger.sh' \
  'tests/test-antigravity-translate-staged.sh|tests/test-antigravity-translate-staged.sh'; do
  asset=${mapping%%|*}
  absent=${mapping#*|}
  if [ -e "$REPO_ROOT/$asset" ]; then
    fail "$asset is retired" "asset remains in docs-control"
  elif jq -e --arg absent "$absent" '.managed_files.absent_files | index($absent) != null' \
    "$REPO_SETTINGS" >/dev/null; then
    pass "$asset is retired and removed downstream"
  else
    fail "$asset is retired and removed downstream" "absent_files does not delete it"
  fi
done

MANAGED_REVIEW_FILES=(
  scripts/agy-pre-push-review.sh
  scripts/agy-review.sh
  scripts/agy-review-output.schema.json
  scripts/validate-translations.sh
  tests/test-agy-pre-push-review.sh
  tests/test-validate-translations.sh
)
for asset in "${MANAGED_REVIEW_FILES[@]}"; do
  if jq -e --arg asset "$asset" \
    '.managed_files.files | any(.src == $asset and .dest == $asset)' \
    "$REPO_SETTINGS" >/dev/null &&
    jq -e --arg asset "$asset" '.protected_files | index($asset) != null' \
      "$GOVERNANCE" >/dev/null; then
    pass "$asset is managed and protected"
  else
    fail "$asset is managed and protected" "catalog or protection entry is missing"
  fi
done

for workflow in antigravity-review antigravity-translate; do
  caller="$REPO_ROOT/workflows/$workflow.yml"
  contains "$caller" 'workflow_dispatch:' "$workflow uses trusted default-branch dispatch"
  rejects "$caller" 'pull_request_target:' "$workflow has no privileged PR trigger"
  rejects "$caller" 'pull_request:' "$workflow does not load a PR-authored caller"
  contains "$caller" 'expected_base_sha' "$workflow binds the exact base"
  contains "$caller" 'expected_head_sha' "$workflow binds the exact head"
done

REVIEW_WORKFLOW="$REPO_ROOT/.github/workflows/antigravity-review.yml"
contains "$REVIEW_WORKFLOW" 'const pullNumber = Number(process.env.PR_NUMBER);' \
  "Antigravity review comment uses the bound pull-request input"
contains "$REVIEW_WORKFLOW" 'Number.isSafeInteger(pullNumber)' \
  "Antigravity review comment validates the pull-request number"
rejects "$REVIEW_WORKFLOW" 'context.issue.number' \
  "Antigravity reusable workflow does not depend on event issue context"
contains "$REVIEW_WORKFLOW" 'const findings = [...new Map(' \
  "Antigravity review comments deduplicate independently verified findings"

contains "$REPO_ROOT/.gitignore" '.agy-review.*' \
  "Antigravity temporary review directories are ignored"

WATCHER="$REPO_ROOT/.github/workflows/antigravity-fleet-watcher.yml"
contains "$WATCHER" 'schedule:' "fleet watcher is scheduled"
contains "$WATCHER" 'workflow_dispatch:' "fleet watcher supports manual recovery"
contains "$WATCHER" "needs.collect.outputs.has_failures == 'true'" \
  "Antigravity triage runs only for failures"
contains "$WATCHER" '<!-- agy-workflow-receipt:' "watcher publishes machine receipt markers"
for enterprise_term in 'merge_group:' 'required-reviewer' 'audit-log'; do
  rejects "$WATCHER" "$enterprise_term" "watcher avoids enterprise-only surface $enterprise_term"
done
contains "$WATCHER" 'GitHub Free-compatible' "watcher declares its GitHub Free contract"
contains "$WATCHER" 'python3 scripts/redact_automation_log.py' \
  "watcher redacts logs with the tested trusted helper"

REDACTOR="$REPO_ROOT/scripts/redact_automation_log.py"
redacted=$(printf '%s\n' \
  '"token": "synthetic-one"' \
  "'authorization': 'Bearer synthetic-two'" \
  'password=synthetic-three' \
  'gateway-url=https://synthetic.invalid/path' | python3 "$REDACTOR" 2>/dev/null || true)
if ! grep -q 'synthetic-' <<<"$redacted" &&
  [ "$(grep -o '\[REDACTED_CREDENTIAL\]' <<<"$redacted" | wc -l | tr -d ' ')" -eq 4 ]; then
  pass "watcher log redactor removes quoted and unquoted credential values"
else
  fail "watcher log redactor removes quoted and unquoted credential values" \
    "credential fixture was not completely redacted"
fi
if invalid_redacted=$(printf '\377token=synthetic-five\n' | python3 "$REDACTOR" 2>/dev/null) &&
  ! grep -q 'synthetic-five' <<<"$invalid_redacted" &&
  grep -q '\[REDACTED_CREDENTIAL\]' <<<"$invalid_redacted"; then
  pass "watcher log redactor tolerates invalid UTF-8 without leaking credentials"
else
  fail "watcher log redactor tolerates invalid UTF-8 without leaking credentials" \
    "invalid log bytes aborted or bypassed redaction"
fi
pem_redacted=$(printf '%s%s%s\n%s\n%s%s%s\n%s\n' \
  '-----BEGIN ' 'PRIVATE KEY' '-----' \
  'synthetic-pem-payload' \
  '-----END ' 'PRIVATE KEY' '-----' \
  'after block' | python3 "$REDACTOR")
if ! grep -q 'synthetic-pem-payload\|BEGIN\|END' <<<"$pem_redacted" &&
  [ "$(grep -o '\[REDACTED_PEM_BLOCK\]' <<<"$pem_redacted" | wc -l | tr -d ' ')" -eq 1 ] &&
  grep -q 'after block' <<<"$pem_redacted"; then
  pass "watcher log redactor removes complete multiline PEM blocks"
else
  fail "watcher log redactor removes complete multiline PEM blocks" \
    "PEM fixture was not completely redacted"
fi
if jq -e --arg path 'scripts/redact_automation_log.py' \
  '.protected_files | index($path) != null' "$GOVERNANCE" >/dev/null; then
  pass "watcher log redactor is governance-protected"
else
  fail "watcher log redactor is governance-protected" "protected_files entry is missing"
fi

if jq -e 'index("code-review") == null' "$DOWNSTREAM" >/dev/null &&
  jq -e '.repo_classes.repos | has("code-review") | not' "$GOVERNANCE" >/dev/null &&
  jq -e '.managed_files.skip_files | has("code-review") | not' "$REPO_SETTINGS" >/dev/null &&
  jq -e '.secrets_manifest.repo_roles | has("code-review") | not' "$REPO_SETTINGS" >/dev/null; then
  pass "retired code-review repository is absent from fleet governance"
else
  fail "retired code-review repository is absent from fleet governance" \
    "inventory, class, skip list, or secret roles still names it"
fi

if jq -e '
  ((.branch_protection[0].required_status_checks.contexts // []) +
   ([.repo_overrides[]?.additional_contexts // []] | flatten)) |
  all(.[]; test("claude|codex|code-review"; "i") | not)
' "$REPO_SETTINGS" >/dev/null; then
  pass "branch protection requires no Claude/Codex reviewer"
else
  fail "branch protection requires no Claude/Codex reviewer" "retired review context remains"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
