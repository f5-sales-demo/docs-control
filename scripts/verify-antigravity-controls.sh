#!/usr/bin/env bash
# Verify the live organization controls, repository shadows, and workflow states.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
org="f5-sales-demo"
repos_file="$repo_root/.github/config/downstream-repos.json"
review_enabled=false
translations_enabled=false
workflow_state=held

usage() {
  cat <<'EOF'
Usage: scripts/verify-antigravity-controls.sh [options]

Options:
  --org <name>                    GitHub organization (default: f5-sales-demo)
  --repos-file <path>             JSON array of governed repository names
  --review-enabled <true|false>   Expected organization review switch (default: false)
  --translations-enabled <value> Expected organization translation switch (default: false)
  --workflow-state <held|active>  Held source or fully active topology (default: held)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --org | --repos-file | --review-enabled | --translations-enabled | --workflow-state)
    [ "$#" -ge 2 ] || {
      echo "[ERROR] $1 requires a value" >&2
      exit 2
    }
    case "$1" in
    --org) org="$2" ;;
    --repos-file) repos_file="$2" ;;
    --review-enabled) review_enabled="$2" ;;
    --translations-enabled) translations_enabled="$2" ;;
    --workflow-state) workflow_state="$2" ;;
    esac
    shift 2
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    echo "[ERROR] unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

if ! printf '%s' "$org" | grep -qE '^[A-Za-z0-9_.-]+$'; then
  echo "[ERROR] invalid organization name" >&2
  exit 2
fi
for value in "$review_enabled" "$translations_enabled"; do
  if [ "$value" != true ] && [ "$value" != false ]; then
    echo "[ERROR] expected control values must be true or false" >&2
    exit 2
  fi
done
if [ "$workflow_state" != held ] && [ "$workflow_state" != active ]; then
  echo "[ERROR] --workflow-state must be held or active" >&2
  exit 2
fi
if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] gh and jq are required" >&2
  exit 1
fi
if ! jq -e '
  type == "array" and length > 0 and
  all(.[]; type == "string" and test("^[A-Za-z0-9_.-]+$")) and
  length == (unique | length)
' "$repos_file" >/dev/null 2>&1; then
  echo "[ERROR] governed repository inventory must be a non-empty unique JSON array" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

api_into() {
  local target="$1" out_file err_file rc value
  shift
  out_file=$(mktemp "$work/api-out.XXXXXX")
  err_file=$(mktemp "$work/api-err.XXXXXX")
  if gh api "$@" >"$out_file" 2>"$err_file"; then
    value=$(cat "$out_file")
    rm -f "$out_file" "$err_file"
    printf -v "$target" '%s' "$value"
    return 0
  else
    rc=$?
  fi

  if grep -qiE 'rate[[:space:]-]*limit|HTTP 429|secondary rate|abuse[ -]?detection' "$err_file"; then
    echo "[DEFER] GitHub API rate capacity was exhausted; no further reads were attempted" >&2
    rm -f "$out_file" "$err_file"
    return 84
  fi
  echo "[ERROR] GitHub API read failed: $1" >&2
  rm -f "$out_file" "$err_file"
  return "$rc"
}

read_api() {
  local target="$1" rc
  shift
  if api_into "$target" "$@"; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 84 ] && exit 84
  exit 1
}

verify_org_variable() {
  local name="$1" expected="$2" payload=""
  read_api payload "orgs/$org/actions/variables/$name"
  if ! jq -e --arg name "$name" --arg expected "$expected" '
    .name == $name and .value == $expected and .visibility == "all"
  ' <<<"$payload" >/dev/null; then
    actual=$(jq -r '[.value // "<missing>", .visibility // "<missing>"] | join(" visibility=")' \
      <<<"$payload" 2>/dev/null || echo '<malformed>')
    echo "[ERROR] $name must equal $expected with visibility=all; found $actual" >&2
    exit 1
  fi
  printf '[OK] organisation variable %s=%s visibility=all\n' "$name" "$expected"
}

workflow_count=0
repository_count=0

verify_repository() {
  local repo="$1" variables="" workflows="" shadows path state expected_workflow_state=active
  if [ "$repo" = docs-control ] && [ "$workflow_state" = held ]; then
    expected_workflow_state=disabled_manually
  fi
  read_api variables "repos/$org/$repo/actions/variables?per_page=100" --paginate --slurp
  if ! jq -e 'type == "array" and all(.[]; (.variables // []) | type == "array")' \
    <<<"$variables" >/dev/null; then
    echo "[ERROR] malformed repository-variable inventory for $repo" >&2
    exit 1
  fi
  shadows=$(jq -r '
    .[] | .variables[]? |
    select(.name == "ANTIGRAVITY_REVIEW_ENABLED" or .name == "TRANSLATIONS_ENABLED") |
    .name
  ' <<<"$variables")
  if [ -n "$shadows" ]; then
    while IFS= read -r shadow; do
      echo "[ERROR] $repo shadows the organisation control $shadow" >&2
    done <<<"$shadows"
    exit 1
  fi

  read_api workflows "repos/$org/$repo/actions/workflows?per_page=100" --paginate --slurp
  for workflow in antigravity-review.yml antigravity-translate.yml; do
    path=".github/workflows/$workflow"
    if ! state=$(jq -er --arg path "$path" '
      [.[] | .workflows[]? | select(.path == $path)] |
      if length == 1 then .[0].state else error("missing or duplicate workflow") end
    ' <<<"$workflows" 2>/dev/null); then
      echo "[ERROR] $repo has no unique live $path workflow" >&2
      exit 1
    fi
    if [ "$state" != "$expected_workflow_state" ]; then
      echo "[ERROR] $repo $workflow state=$state; expected $expected_workflow_state" >&2
      exit 1
    fi
    workflow_count=$((workflow_count + 1))
  done
  repository_count=$((repository_count + 1))
  printf '[OK] %s has no control shadows; workflows are %s\n' "$repo" "$expected_workflow_state"
}

verify_org_variable ANTIGRAVITY_REVIEW_ENABLED "$review_enabled"
verify_org_variable TRANSLATIONS_ENABLED "$translations_enabled"
verify_repository docs-control
while IFS= read -r repo; do
  [ "$repo" = docs-control ] && continue
  verify_repository "$repo"
done < <(jq -r '.[]' "$repos_file")

printf '[OK] verified 2 organisation variables, %d repositories, %d workflows\n' \
  "$repository_count" "$workflow_count"
