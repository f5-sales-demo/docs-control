#!/usr/bin/env bash
# Ensure every governed downstream repository can run the centrally dispatched
# repository-settings workflow. Values cross the GitHub CLI boundary only on
# standard input and are never written into command arguments or output.
set -euo pipefail

downstream_config="${DOWNSTREAM_CONFIG:-.github/config/downstream-repos.json}"
owner="${GITHUB_REPOSITORY_OWNER:-}"
request_delay_seconds="${PROVISION_REQUEST_DELAY_SECONDS:-2}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! printf '%s' "$owner" | grep -qE '^[A-Za-z0-9_.-]+$'; then
  echo "[ERROR] GITHUB_REPOSITORY_OWNER is invalid" >&2
  exit 1
fi
if [ -z "${REPO_SETTINGS_TOKEN:-}" ]; then
  echo "[ERROR] REPO_SETTINGS_TOKEN is required to administer repository secrets" >&2
  exit 1
fi
if [ -z "${REPO_SYNC_TOKEN:-}" ]; then
  echo "[ERROR] REPO_SYNC_TOKEN is required as a repository secret source" >&2
  exit 1
fi
if ! printf '%s' "$request_delay_seconds" | grep -qE '^[0-9]+$' ||
  [ "$request_delay_seconds" -gt 60 ]; then
  echo "[ERROR] Repository-secret request delay must be between 0 and 60 seconds" >&2
  exit 1
fi
if ! jq -e '
  type == "array" and length > 0 and
  all(.[]; type == "string" and test("^[A-Za-z0-9_.-]+$")) and
  (length == (unique | length))
' "$downstream_config" >/dev/null; then
  echo "[ERROR] Downstream inventory must be a non-empty array of unique repository names" >&2
  exit 1
fi

run_gh() {
  local err_file rc
  err_file=$(mktemp "$work/gh-err.XXXXXX")
  set +e
  GH_TOKEN="$REPO_SETTINGS_TOKEN" command gh "$@" 2>"$err_file"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    rm -f "$err_file"
    return 0
  fi
  if grep -qiE 'rate[[:space:]-]*limit|HTTP 429|abuse[ -]?detection' "$err_file"; then
    rm -f "$err_file"
    echo "[DEFER] GitHub API rate capacity was exhausted; scheduled recovery is active" >&2
    return 84
  fi
  rm -f "$err_file"
  echo "[ERROR] GitHub repository-secret operation failed closed" >&2
  return 1
}

list_secret_inventory() {
  local slug="$1" inventory rc
  set +e
  inventory=$(run_gh secret list --repo "$slug" --json name)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if ! printf '%s' "$inventory" | jq -e '
    type == "array" and
    all(.[];
      type == "object" and
      (.name | type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$"))) and
    ([.[].name] | length == (unique | length))
  ' >/dev/null; then
    echo "[ERROR] GitHub returned a malformed repository-secret inventory for ${slug}" >&2
    return 1
  fi
  printf '%s' "$inventory"
}

inventory_has() {
  local inventory="$1" name="$2"
  printf '%s' "$inventory" |
    jq -e --arg name "$name" 'any(.[]; .name == $name)' >/dev/null
}

repository_count=$(jq 'length' "$downstream_config")
repository_index=0
while IFS= read -r name; do
  slug="${owner}/${name}"
  set +e
  inventory=$(list_secret_inventory "$slug")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi

  changed=false
  for secret_name in REPO_SETTINGS_TOKEN REPO_SYNC_TOKEN; do
    if inventory_has "$inventory" "$secret_name"; then
      continue
    fi
    case "$secret_name" in
    REPO_SETTINGS_TOKEN) secret_value="$REPO_SETTINGS_TOKEN" ;;
    REPO_SYNC_TOKEN) secret_value="$REPO_SYNC_TOKEN" ;;
    esac
    set +e
    printf '%s' "$secret_value" |
      run_gh secret set "$secret_name" --repo "$slug"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      exit "$rc"
    fi
    changed=true
    printf '[SET] %s: %s\n' "$slug" "$secret_name"
  done

  if [ "$changed" = true ]; then
    set +e
    inventory=$(list_secret_inventory "$slug")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      exit "$rc"
    fi
  fi
  for secret_name in REPO_SETTINGS_TOKEN REPO_SYNC_TOKEN; do
    if ! inventory_has "$inventory" "$secret_name"; then
      echo "[ERROR] ${slug} is missing ${secret_name} after provisioning" >&2
      exit 1
    fi
  done
  printf '[OK] %s governance repository secrets are present\n' "$slug"
  repository_index=$((repository_index + 1))
  if [ "$repository_index" -lt "$repository_count" ] &&
    [ "$request_delay_seconds" -gt 0 ]; then
    sleep "$request_delay_seconds"
  fi
done < <(jq -r '.[]' "$downstream_config")
