#!/usr/bin/env bash
# Run consumer shell unit tests from a trusted, fail-closed fleet profile.
set -euo pipefail

ROOT=""
CONFIG=""
REPOSITORY=""

usage() {
  echo "Usage: $0 --root PATH --config PATH --repository OWNER/REPO" >&2
}

die() {
  echo "::error::$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --root)
    [ "$#" -ge 2 ] || {
      usage
      exit 2
    }
    ROOT="$2"
    shift 2
    ;;
  --config)
    [ "$#" -ge 2 ] || {
      usage
      exit 2
    }
    CONFIG="$2"
    shift 2
    ;;
  --repository)
    [ "$#" -ge 2 ] || {
      usage
      exit 2
    }
    REPOSITORY="$2"
    shift 2
    ;;
  *)
    usage
    exit 2
    ;;
  esac
done

[ -d "$ROOT" ] || die "cannot read consumer repository root: $ROOT"
[ -r "$CONFIG" ] || die "cannot read canonical shell-test configuration: $CONFIG"
case "$REPOSITORY" in
*[!A-Za-z0-9_./-]* | */*/* | /* | */) die "malformed repository name: $REPOSITORY" ;;
*/*) ;;
*) die "malformed repository name: $REPOSITORY" ;;
esac

if ! jq -e \
  '.consumer_shell_tests | type == "object" and (.profiles | type == "object")' \
  "$CONFIG" >/dev/null 2>&1; then
  die "malformed canonical shell-test configuration: expected consumer_shell_tests.profiles object"
fi

repo_name=${REPOSITORY##*/}
profile=$(jq -c --arg repo "$repo_name" \
  '.consumer_shell_tests.profiles[$repo] // null' "$CONFIG") ||
  die "malformed canonical shell-test configuration"

shopt -s nullglob
discovered=""
for test_path in "$ROOT"/tests/test-*.sh; do
  # Match the old glob contract, including symlinks, but not directories.
  if [ -f "$test_path" ] || [ -L "$test_path" ]; then
    relative=${test_path#"$ROOT"/}
    discovered="${discovered}${relative}"$'\n'
  fi
done
discovered=$(printf '%s' "$discovered" | sed '/^$/d' | LC_ALL=C sort)

run_one() {
  local path="$1"
  shift
  echo "::group::$path"
  if (cd "$ROOT" && bash "$path" "$@"); then
    echo "PASS: $path"
    echo "::endgroup::"
    return 0
  fi
  echo "::error::FAIL: $path"
  echo "::endgroup::"
  return 1
}

if [ "$profile" = "null" ]; then
  if [ -z "$discovered" ]; then
    echo "No tests/test-*.sh present in ${REPOSITORY}; nothing to run."
    exit 0
  fi

  rc=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    run_one "$path" || rc=1
  done <<<"$discovered"
  exit "$rc"
fi

if ! jq -e '
  type == "object" and
  (.unit | type == "array") and
  (.environment | type == "array") and
  all(.unit[];
    type == "object" and
    (.path | type == "string") and
    (.args | type == "array") and
    all(.args[]; type == "string")) and
  all(.environment[];
    type == "object" and
    (.path | type == "string") and
    (.reason | type == "string" and test("[^[:space:]]")))
' <<<"$profile" >/dev/null 2>&1; then
  die "malformed shell-test profile for ${repo_name}"
fi

unsafe_path=$(jq -r '
  [.unit[].path, .environment[].path][] |
  select(test("^tests/test-[A-Za-z0-9._-]+[.]sh$") | not)
' <<<"$profile" | sed -n '1p')
[ -z "$unsafe_path" ] || die "unsafe test path in ${repo_name} profile: $unsafe_path"

unsafe_arg=$(jq -r '
  .unit[].args[] |
  select(test("^--?[A-Za-z0-9][A-Za-z0-9._=-]*$") | not)
' <<<"$profile" | sed -n '1p')
[ -z "$unsafe_arg" ] || die "unsafe test argument in ${repo_name} profile: $unsafe_arg"

duplicates=$(jq -r '[.unit[].path, .environment[].path][]' <<<"$profile" |
  LC_ALL=C sort | uniq -d)
[ -z "$duplicates" ] || die "duplicate test path in ${repo_name} profile: $duplicates"

expected=$(jq -r '[.unit[].path, .environment[].path][]' <<<"$profile" | LC_ALL=C sort)
deferred_managed_tests=""
if [ "$discovered" != "$expected" ]; then
  unexpected=$(comm -23 \
    <(printf '%s\n' "$discovered" | sed '/^$/d') \
    <(printf '%s\n' "$expected" | sed '/^$/d'))
  missing=$(comm -13 \
    <(printf '%s\n' "$discovered" | sed '/^$/d') \
    <(printf '%s\n' "$expected" | sed '/^$/d'))

  bootstrap_transition=false
  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] &&
    [[ "${GITHUB_HEAD_REF:-}" =~ ^sync/exact-caller-[0-9a-f]{40}(skipped|[0-9a-f]{40})(skipped|[0-9a-f]{40})[0-9a-f]{40}$ ]] &&
    [ -z "$unexpected" ] && [ -n "$missing" ]; then
    bootstrap_transition=true
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if ! jq -e --arg path "$path" --arg repo "$repo_name" '
        (.managed_files | type == "object") and
        (.managed_files.files | type == "array") and
        any(.managed_files.files[];
          type == "object" and .dest == $path) and
        (((.managed_files.skip_files // {})[$repo] // []) | index($path) == null)
      ' "$CONFIG" >/dev/null 2>&1; then
        bootstrap_transition=false
        break
      fi
      deferred_managed_tests="${deferred_managed_tests}${path}"$'\n'
    done <<<"$missing"
  fi

  if [ "$bootstrap_transition" = true ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      echo "::notice::Deferring managed test until synchronization: ${path}"
    done <<<"$deferred_managed_tests"
  else
    {
      echo "::error::${repo_name} test inventory does not match its canonical profile"
      echo "--- discovered tests"
      printf '%s\n' "$discovered"
      echo "--- configured tests"
      printf '%s\n' "$expected"
    } >&2
    exit 1
  fi
fi

rc=0
unit_count=$(jq '.unit | length' <<<"$profile")
index=0
while [ "$index" -lt "$unit_count" ]; do
  path=$(jq -r --argjson index "$index" '.unit[$index].path' <<<"$profile")
  args_json=$(jq -c --argjson index "$index" '.unit[$index].args' <<<"$profile")
  if grep -Fqx -- "$path" <<<"$deferred_managed_tests"; then
    index=$((index + 1))
    continue
  fi
  if [ "$args_json" = "[]" ]; then
    run_one "$path" || rc=1
  else
    args=()
    while IFS= read -r arg; do
      args+=("$arg")
    done < <(jq -r '.[]' <<<"$args_json")
    run_one "$path" "${args[@]}" || rc=1
  fi
  index=$((index + 1))
done

while IFS=$'\t' read -r path reason; do
  [ -n "$path" ] || continue
  echo "::notice::Not run by the bare-runner unit profile: ${path} — ${reason}"
done < <(jq -r '.environment[] | [.path, .reason] | @tsv' <<<"$profile")

exit "$rc"
