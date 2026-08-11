#!/usr/bin/env bash
# Contract tests for the fail-closed consumer shell-test selector.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="${REPO_ROOT}/scripts/run-consumer-shell-tests.sh"
SETTINGS="${REPO_ROOT}/.github/config/repo-settings.json"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
LAST_RC=0
LAST_OUTPUT=""

pass() {
  echo "  [PASS] $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  [FAIL] $1${2:+ — $2}"
  FAIL=$((FAIL + 1))
}

assert_rc() {
  local want="$1" label="$2"
  if [ "$LAST_RC" -eq "$want" ]; then
    pass "$label"
  else
    fail "$label" "expected rc=$want, got rc=$LAST_RC; output: $LAST_OUTPUT"
  fi
}

assert_contains() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" <<<"$LAST_OUTPUT"; then
    pass "$label"
  else
    fail "$label" "missing '$needle'; output: $LAST_OUTPUT"
  fi
}

run_selector() {
  local root="$1" config="$2" repository="$3"
  LAST_RC=0
  LAST_OUTPUT=$(GITHUB_EVENT_NAME="${SELECTOR_EVENT_NAME:-}" \
    GITHUB_HEAD_REF="${SELECTOR_HEAD_REF:-}" \
    TEST_LOG="${root}/executed.log" bash "$RUNNER" \
    --root "$root" --config "$config" --repository "$repository" 2>&1) || LAST_RC=$?
}

new_root() {
  local name="$1"
  mkdir -p "${WORK}/${name}/tests"
  printf '%s\n' "${WORK}/${name}"
}

write_probe() {
  local root="$1" name="$2"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s:%s\n" "$(basename "$0")" "$*" >> "$TEST_LOG"' \
    >"${root}/tests/${name}"
}

write_config() {
  local name="$1" body="$2"
  printf '%s\n' "$body" >"${WORK}/${name}.json"
  printf '%s\n' "${WORK}/${name}.json"
}

echo "=== Consumer shell-test selector ==="

# Default behavior stays deliberately broad: every root-level test-*.sh runs.
root=$(new_root default)
write_probe "$root" test-b.sh
write_probe "$root" test-a.sh
config=$(write_config default '{"consumer_shell_tests":{"profiles":{}}}')
run_selector "$root" "$config" f5-sales-demo/example
assert_rc 0 "default profile succeeds"
expected=$'test-a.sh:\ntest-b.sh:'
actual=$(cat "${root}/executed.log" 2>/dev/null || true)
if [ "$actual" = "$expected" ]; then
  pass "default profile runs every test in stable order"
else
  fail "default profile runs every test in stable order" "got: $actual"
fi

# No tests is a valid, explicit success for an unprofiled repository.
root=$(new_root empty)
run_selector "$root" "$config" f5-sales-demo/empty
assert_rc 0 "unprofiled repository with no tests succeeds"
assert_contains "No tests/test-*.sh present" "no-tests result is visible"

# A profile is an argv contract, not a shell command string.
root=$(new_root profiled)
write_probe "$root" test-unit.sh
write_probe "$root" test-environment.sh
config=$(write_config profiled '{
  "consumer_shell_tests": {
    "profiles": {
      "profiled": {
        "unit": [{"path":"tests/test-unit.sh","args":["--unit-only"]}],
        "environment": [{"path":"tests/test-environment.sh","reason":"requires a running service"}]
      }
    }
  }
}')
run_selector "$root" "$config" f5-sales-demo/profiled
assert_rc 0 "profiled selection succeeds"
actual=$(cat "${root}/executed.log" 2>/dev/null || true)
if [ "$actual" = "test-unit.sh:--unit-only" ]; then
  pass "profile invokes unit test with literal argv and not the environment test"
else
  fail "profile invokes unit test with literal argv and not the environment test" "got: $actual"
fi
assert_contains "requires a running service" "environment classification is reported"

# Inventory comparison is fail-closed in both directions and happens before execution.
root=$(new_root extra)
write_probe "$root" test-unit.sh
write_probe "$root" test-new.sh
run_selector "$root" "$config" f5-sales-demo/profiled
assert_rc 1 "unclassified test fails the profile"
assert_contains "inventory does not match" "unclassified-test failure explains the drift"
if [ ! -e "${root}/executed.log" ]; then
  pass "inventory drift fails before any test executes"
else
  fail "inventory drift fails before any test executes"
fi

root=$(new_root missing)
write_probe "$root" test-unit.sh
run_selector "$root" "$config" f5-sales-demo/profiled
assert_rc 1 "missing classified test fails the profile"
assert_contains "inventory does not match" "missing-test failure explains the drift"

# Exact-caller bootstrap can precede managed-file delivery. Only a missing test
# declared by the canonical managed-file inventory may be deferred, and only on
# the strictly formed generated receipt branch.
bootstrap_branch="sync/exact-caller-$(printf 'a%.0s' {1..160})"
config=$(write_config bootstrap-managed '{
  "managed_files": {
    "files": [
      {"src":"tests/test-managed.sh","dest":"tests/test-managed.sh"}
    ],
    "skip_files": {}
  },
  "consumer_shell_tests": {
    "profiles": {
      "bootstrap-managed": {
        "unit": [
          {"path":"tests/test-present.sh","args":[]},
          {"path":"tests/test-managed.sh","args":[]}
        ],
        "environment": []
      }
    }
  }
}')

root=$(new_root bootstrap-managed)
write_probe "$root" test-present.sh
SELECTOR_EVENT_NAME=pull_request SELECTOR_HEAD_REF="$bootstrap_branch" \
  run_selector "$root" "$config" f5-sales-demo/bootstrap-managed
assert_rc 0 "exact-caller bootstrap defers a missing canonically managed test"
assert_contains "Deferring managed test until synchronization: tests/test-managed.sh" \
  "managed-test deferral is visible"
actual=$(cat "${root}/executed.log" 2>/dev/null || true)
if [ "$actual" = "test-present.sh:" ]; then
  pass "bootstrap transition still runs every present unit test"
else
  fail "bootstrap transition still runs every present unit test" "got: $actual"
fi

SELECTOR_EVENT_NAME=pull_request SELECTOR_HEAD_REF=feature/not-generated \
  run_selector "$root" "$config" f5-sales-demo/bootstrap-managed
assert_rc 1 "ordinary pull requests cannot defer a managed test"
assert_contains "inventory does not match" "ordinary pull request stays fail-closed"

config=$(write_config bootstrap-unmanaged '{
  "managed_files": {"files": [], "skip_files": {}},
  "consumer_shell_tests": {
    "profiles": {
      "bootstrap-unmanaged": {
        "unit": [
          {"path":"tests/test-present.sh","args":[]},
          {"path":"tests/test-unmanaged.sh","args":[]}
        ],
        "environment": []
      }
    }
  }
}')
root=$(new_root bootstrap-unmanaged)
write_probe "$root" test-present.sh
SELECTOR_EVENT_NAME=pull_request SELECTOR_HEAD_REF="$bootstrap_branch" \
  run_selector "$root" "$config" f5-sales-demo/bootstrap-unmanaged
assert_rc 1 "exact-caller bootstrap cannot defer an unmanaged test"
assert_contains "inventory does not match" "unmanaged missing test stays fail-closed"

root=$(new_root bootstrap-extra)
write_probe "$root" test-present.sh
write_probe "$root" test-unclassified.sh
SELECTOR_EVENT_NAME=pull_request SELECTOR_HEAD_REF="$bootstrap_branch" \
  run_selector "$root" "$config" f5-sales-demo/bootstrap-unmanaged
assert_rc 1 "exact-caller bootstrap cannot hide an unclassified test"
assert_contains "inventory does not match" "extra test stays fail-closed during bootstrap"
unset SELECTOR_EVENT_NAME SELECTOR_HEAD_REF

# Duplicate and unsafe paths are rejected even if the inventory could otherwise match.
root=$(new_root duplicate)
write_probe "$root" test-unit.sh
config=$(write_config duplicate '{
  "consumer_shell_tests": {
    "profiles": {
      "duplicate": {
        "unit": [{"path":"tests/test-unit.sh","args":[]}],
        "environment": [{"path":"tests/test-unit.sh","reason":"duplicate"}]
      }
    }
  }
}')
run_selector "$root" "$config" f5-sales-demo/duplicate
assert_rc 1 "duplicate classified path fails"
assert_contains "duplicate" "duplicate-path failure is explicit"

config=$(write_config unsafe '{
  "consumer_shell_tests": {
    "profiles": {
      "unsafe": {
        "unit": [{"path":"tests/../test-unit.sh","args":[]}],
        "environment": []
      }
    }
  }
}')
run_selector "$root" "$config" f5-sales-demo/unsafe
assert_rc 1 "unsafe test path fails"
assert_contains "unsafe" "unsafe-path failure is explicit"

# Canonical configuration is required and must have the expected schema.
config=$(write_config malformed '{"consumer_shell_tests":{"profiles":[]}}')
run_selector "$root" "$config" f5-sales-demo/example
assert_rc 1 "malformed canonical profile map fails"
assert_contains "malformed" "malformed configuration failure is explicit"

run_selector "$root" "${WORK}/absent.json" f5-sales-demo/example
assert_rc 1 "missing canonical configuration fails"
assert_contains "cannot read" "missing configuration failure is explicit"

run_selector "$root" "$config" f5-sales-demo/example/extra
assert_rc 1 "malformed repository name fails"
assert_contains "malformed repository" "repository-name failure is explicit"

# The production profile accounts for the complete devcontainer inventory.
if jq -e '
  .consumer_shell_tests.profiles.devcontainer as $p |
  ($p.unit | map(.path)) == [
    "tests/test-agy-pre-push-review.sh",
    "tests/test-check-pii.sh",
    "tests/test-check-repo-hygiene.sh",
    "tests/test-fetch-governed.sh",
    "tests/test-github-api-resilience.sh",
    "tests/test-hook-neutralization.sh",
    "tests/test-inlined-helpers-match.sh",
    "tests/test-lint-mdx-prose.sh",
    "tests/test-review-plugin-removal.sh",
    "tests/test-translation-release-policy.sh",
    "tests/test-validate-translations.sh"
  ] and
  ($p.unit[] | select(.path == "tests/test-hook-neutralization.sh") | .args) == ["--unit-only"] and
  ($p.environment | map(.path)) == [
    "tests/test-firecrawl.sh",
    "tests/test-lsp-coverage.sh",
    "tests/test-npx-resolution.sh"
  ] and
  all($p.environment[]; (.reason | type == "string" and length > 0))
' "$SETTINGS" >/dev/null 2>&1; then
  pass "canonical devcontainer profile classifies the complete inventory"
else
  fail "canonical devcontainer profile classifies the complete inventory"
fi

DOWNSTREAM="${REPO_ROOT}/.github/config/downstream-repos.json"
if jq -e --slurpfile repos "$DOWNSTREAM" '
  (.consumer_shell_tests.profiles | keys) as $profiles |
  all($profiles[]; . as $profile | $repos[0] | index($profile) != null)
' "$SETTINGS" >/dev/null 2>&1; then
  pass "every canonical profile names a governed repository"
else
  fail "every canonical profile names a governed repository"
fi

WORKFLOW="${REPO_ROOT}/.github/workflows/super-linter.yml"
if grep -qF 'scripts/run-consumer-shell-tests.sh' "$WORKFLOW" &&
  grep -qF '.github/config/repo-settings.json' "$WORKFLOW" &&
  grep -qF 'canonical_sha' "$WORKFLOW"; then
  pass "reusable workflow executes runner and config from logged canonical revision"
else
  fail "reusable workflow executes runner and config from logged canonical revision"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
exit "$FAIL"
