#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/provision-governance-secrets.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[OK] %s\n' "$1"
}

mkdir -p "$WORK/bin" "$WORK/state"
cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_GH_LOG"

if [ "${1:-}" != "secret" ] || { [ "${2:-}" != "list" ] && [ "${2:-}" != "set" ]; }; then
  echo "unexpected gh invocation" >&2
  exit 2
fi

operation="$2"
shift 2
name=""
if [ "$operation" = "set" ]; then
  name="${1:-}"
  shift
fi

repo=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --json)
      [ "${2:-}" = "name" ] || exit 2
      shift 2
      ;;
    *)
      echo "unexpected gh argument" >&2
      exit 2
      ;;
  esac
done

[ -n "$repo" ] || exit 2
state_file="$FAKE_GH_STATE/${repo//\//__}"
touch "$state_file"

if [ "$operation" = "list" ]; then
  case "${FAKE_GH_MODE:-}" in
    list-error)
      echo 'gh: forbidden (HTTP 403)' >&2
      exit 1
      ;;
    list-rate)
      echo 'gh: API rate limit exceeded (HTTP 403)' >&2
      exit 1
      ;;
  esac
  jq -Rsc 'split("\n") | map(select(length > 0) | {name: .})' "$state_file"
  exit 0
fi

case "${FAKE_GH_MODE:-}" in
  set-error)
    echo 'gh: forbidden (HTTP 403)' >&2
    exit 1
    ;;
  set-rate)
    echo 'gh: secondary rate limit (HTTP 403)' >&2
    exit 1
    ;;
esac

payload=$(cat)
case "$name" in
  REPO_SETTINGS_TOKEN) expected="$EXPECTED_SETTINGS_TOKEN" ;;
  REPO_SYNC_TOKEN) expected="$EXPECTED_SYNC_TOKEN" ;;
  *) exit 2 ;;
esac
[ "$payload" = "$expected" ] || exit 3

if [ "${FAKE_GH_MODE:-}" != "drop-write" ]; then
  printf '%s\n' "$name" >>"$state_file"
  sort -u -o "$state_file" "$state_file"
fi
EOF
chmod +x "$WORK/bin/gh"

SETTINGS_TOKEN='settings-value-must-not-leak'
SYNC_TOKEN='sync-value-must-not-leak'
printf '["alpha","beta"]\n' >"$WORK/repos.json"
printf 'REPO_SETTINGS_TOKEN\nREPO_SYNC_TOKEN\n' >"$WORK/state/f5-sales-demo__alpha"
printf 'REPO_SETTINGS_TOKEN\n' >"$WORK/state/f5-sales-demo__beta"
: >"$WORK/gh.log"

run_provisioner() {
  env \
    PATH="$WORK/bin:$PATH" \
    DOWNSTREAM_CONFIG="${PROVISION_CONFIG:-$WORK/repos.json}" \
    GITHUB_REPOSITORY_OWNER=f5-sales-demo \
    REPO_SETTINGS_TOKEN="${PROVISION_SETTINGS_TOKEN-$SETTINGS_TOKEN}" \
    REPO_SYNC_TOKEN="${PROVISION_SYNC_TOKEN-$SYNC_TOKEN}" \
    EXPECTED_SETTINGS_TOKEN="$SETTINGS_TOKEN" \
    EXPECTED_SYNC_TOKEN="$SYNC_TOKEN" \
    FAKE_GH_LOG="$WORK/gh.log" \
    FAKE_GH_STATE="$WORK/state" \
    FAKE_GH_MODE="${PROVISION_FAKE_MODE:-}" \
    bash "$SCRIPT"
}

if [ -e "$SCRIPT" ]; then
  pass "provisioning script exists"
else
  fail "provisioning script exists"
fi

output=$(run_provisioner 2>&1) || fail "missing secret is provisioned"
pass "missing secret is provisioned"

set_calls=$(grep -c '^secret set ' "$WORK/gh.log" || true)
[ "$set_calls" -eq 1 ] || fail "only one missing secret is written"
grep -q '^secret set REPO_SYNC_TOKEN --repo f5-sales-demo/beta$' "$WORK/gh.log" ||
  fail "the exact missing repository secret is written"
pass "only the exact missing repository secret is written"

grep -qx 'REPO_SYNC_TOKEN' "$WORK/state/f5-sales-demo__beta" ||
  fail "secret value is accepted through standard input"
pass "secret value is accepted through standard input"

if printf '%s\n%s\n' "$output" "$(cat "$WORK/gh.log")" |
  grep -Fq -e "$SETTINGS_TOKEN" -e "$SYNC_TOKEN"; then
  fail "secret values stay out of output and command arguments"
fi
if grep -Eq -- '--(org|env|visibility|repos)( |$)' "$WORK/gh.log"; then
  fail "only GitHub Free repository secrets are used"
fi
pass "secret values stay out of logs and only repository secrets are used"

: >"$WORK/gh.log"
run_provisioner >/dev/null 2>&1 || fail "idempotent rerun succeeds"
if grep -q '^secret set ' "$WORK/gh.log"; then
  fail "existing secrets are never rewritten"
fi
pass "idempotent rerun does not rewrite existing secrets"

printf '{"not":"an array"}\n' >"$WORK/repos-invalid.json"
set +e
PROVISION_CONFIG="$WORK/repos-invalid.json" run_provisioner >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "malformed inventory fails closed"
pass "malformed inventory fails closed"

set +e
PROVISION_SETTINGS_TOKEN='' run_provisioner >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "missing administrative credential fails closed"

set +e
PROVISION_SYNC_TOKEN='' run_provisioner >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "missing sync credential fails closed"
pass "missing source credentials fail closed"

set +e
PROVISION_FAKE_MODE=list-error run_provisioner >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "inventory API failure fails closed"

set +e
PROVISION_FAKE_MODE=list-rate run_provisioner >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 84 ] || fail "inventory rate exhaustion returns 84"
pass "inventory API failures fail closed and rate exhaustion returns 84"

printf 'REPO_SETTINGS_TOKEN\n' >"$WORK/state/f5-sales-demo__beta"
set +e
PROVISION_FAKE_MODE=set-error run_provisioner >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "secret write API failure fails closed"

set +e
PROVISION_FAKE_MODE=set-rate run_provisioner >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 84 ] || fail "secret write rate exhaustion returns 84"
pass "secret write failures fail closed and rate exhaustion returns 84"

set +e
PROVISION_FAKE_MODE=drop-write run_provisioner >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "missing postcondition fails closed"
pass "post-write inventory must contain both governance secrets"
