#!/usr/bin/env bash
# Permit fleet fan-out only from current protected main and only after governed
# callers pin the exact reusable workflow implementation at this source.
set -euo pipefail

pin_config="${PIN_CONFIG:-.github/config/governed-workflow-pin.json}"
downstream_config="${DOWNSTREAM_CONFIG:-.github/config/downstream-repos.json}"
rollout_config="${ROLLOUT_CONFIG:-.github/config/governance-rollout.json}"
repository="${GITHUB_REPOSITORY:-}"
owner="${repository%%/*}"
source_sha="${SOURCE_SHA:-}"
api_not_found=false
current_main=""
source_status=""
pinned_blob=""
source_blob=""
expected_caller_blob=""
expected_lint_caller_blob=""
downstream_main=""
actual_caller_blob=""
actual_lint_caller_blob=""
workflow_state=""

github_api_into() {
  local target="$1"
  local err_file api_output api_rc
  shift
  err_file=$(mktemp)
  set +e
  api_output=$(gh api "$@" 2>"$err_file")
  api_rc=$?
  set -e
  api_not_found=false
  if [ "$api_rc" -ne 0 ]; then
    if grep -qiE 'rate[[:space:]-]*limit|HTTP 429|abuse[ -]?detection' "$err_file"; then
      rm -f "$err_file"
      echo "[DEFER] GitHub API rate capacity was exhausted; scheduled recovery is active"
      exit 84
    fi
    grep -qE '\(HTTP 404\)$' "$err_file" && api_not_found=true
    cat "$err_file" >&2
    rm -f "$err_file"
    return "$api_rc"
  fi
  rm -f "$err_file"
  printf -v "$target" '%s' "$api_output"
}

if ! printf '%s' "$source_sha" | grep -qE '^[0-9a-f]{40}$'; then
  echo "[ERROR] Source receipt must be a full lowercase commit SHA" >&2
  exit 1
fi
if ! printf '%s' "$repository" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  echo "[ERROR] GITHUB_REPOSITORY is invalid" >&2
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
if ! rollout_state=$(jq -er '.state | select(. == "quiesced" or . == "active")' \
  "$rollout_config"); then
  echo "[ERROR] Governance rollout state is missing or invalid" >&2
  exit 1
fi
if ! pin_revision=$(jq -er \
  '.revision | select(type == "string" and test("^[0-9a-f]{40}$"))' \
  "$pin_config"); then
  echo "[ERROR] Governed workflow pin is missing or invalid" >&2
  exit 1
fi
if ! github_api_into current_main "repos/${repository}/commits/main" --jq '.sha'; then
  echo "[ERROR] Could not resolve protected docs-control main" >&2
  exit 1
fi
if ! printf '%s' "$current_main" | grep -qE '^[0-9a-f]{40}$'; then
  echo "[ERROR] Protected docs-control main returned an invalid commit" >&2
  exit 1
fi

if [ "$source_sha" != "$current_main" ]; then
  if ! github_api_into source_status \
    "repos/${repository}/compare/${source_sha}...${current_main}" --jq '.status'; then
    echo "[ERROR] Could not prove the dispatch receipt is on protected main" >&2
    exit 1
  fi
  if [ "$source_status" = "ahead" ]; then
    echo "[DEFER] historical dispatch receipt ${source_sha:0:8}; protected main is ${current_main:0:8}"
    exit 78
  fi
  echo "[ERROR] Dispatch receipt is not an approved protected-main commit" >&2
  exit 1
fi

for workflow in enforce-repo-settings.yml sync-managed-files.yml; do
  path=".github/workflows/${workflow}"
  if ! github_api_into pinned_blob \
    "repos/${repository}/contents/${path}?ref=${pin_revision}" --jq '.sha'; then
    echo "[ERROR] Could not resolve pinned reusable workflow ${workflow}" >&2
    exit 1
  fi
  if ! github_api_into source_blob \
    "repos/${repository}/contents/${path}?ref=${source_sha}" --jq '.sha'; then
    echo "[ERROR] Could not resolve source reusable workflow ${workflow}" >&2
    exit 1
  fi
  if ! printf '%s' "$pinned_blob" | grep -qE '^[0-9a-f]{40}$' ||
    ! printf '%s' "$source_blob" | grep -qE '^[0-9a-f]{40}$'; then
    echo "[ERROR] GitHub returned an invalid workflow blob receipt for ${workflow}" >&2
    exit 1
  fi
  if [ "$pinned_blob" != "$source_blob" ]; then
    echo "[DEFER] governed workflow pin does not contain exact ${workflow} implementation"
    exit 79
  fi
done

if ! github_api_into expected_caller_blob \
  "repos/${repository}/contents/workflows/enforce-repo-settings.yml?ref=${source_sha}" \
  --jq '.sha'; then
  echo "[ERROR] Could not resolve the exact managed caller" >&2
  exit 1
fi
if ! printf '%s' "$expected_caller_blob" | grep -qE '^[0-9a-f]{40}$'; then
  echo "[ERROR] GitHub returned an invalid managed caller blob receipt" >&2
  exit 1
fi
if ! github_api_into expected_lint_caller_blob \
  "repos/${repository}/contents/workflows/super-linter.yml?ref=${source_sha}" \
  --jq '.sha'; then
  echo "[ERROR] Could not resolve the exact Super-Linter caller" >&2
  exit 1
fi
if ! printf '%s' "$expected_lint_caller_blob" | grep -qE '^[0-9a-f]{40}$'; then
  echo "[ERROR] GitHub returned an invalid Super-Linter caller blob receipt" >&2
  exit 1
fi

stale_callers=0
state_mismatches=0
while IFS= read -r name; do
  if ! printf '%s' "$name" | grep -qE '^[A-Za-z0-9_.-]+$'; then
    echo "[ERROR] Invalid downstream repository name" >&2
    exit 1
  fi
  if ! github_api_into downstream_main "repos/${owner}/${name}/commits/main" \
    --jq '.sha'; then
    echo "[ERROR] Could not resolve protected main for ${name}" >&2
    exit 1
  fi
  if ! printf '%s' "$downstream_main" | grep -qE '^[0-9a-f]{40}$'; then
    echo "[ERROR] Invalid protected-main receipt for ${name}" >&2
    exit 1
  fi
  if ! github_api_into actual_caller_blob \
    "repos/${owner}/${name}/contents/.github/workflows/enforce-repo-settings.yml?ref=${downstream_main}" \
    --jq '.sha'; then
    if [ "$api_not_found" = true ]; then
      actual_caller_blob=""
    else
      echo "[ERROR] Could not read the live managed caller for ${name}" >&2
      exit 1
    fi
  elif ! printf '%s' "$actual_caller_blob" | grep -qE '^[0-9a-f]{40}$'; then
    echo "[ERROR] Invalid live caller blob receipt for ${name}" >&2
    exit 1
  fi
  if [ "$actual_caller_blob" != "$expected_caller_blob" ]; then
    echo "[BOOTSTRAP] ${name} does not contain the exact managed caller"
    stale_callers=$((stale_callers + 1))
    # Legacy or malformed caller bytes need replacement regardless of their
    # Actions state. They may not parse as a workflow, so no state endpoint is
    # required until the exact caller has landed.
    continue
  fi
  if ! github_api_into actual_lint_caller_blob \
    "repos/${owner}/${name}/contents/.github/workflows/super-linter.yml?ref=${downstream_main}" \
    --jq '.sha'; then
    if [ "$api_not_found" = true ]; then
      actual_lint_caller_blob=""
    else
      echo "[ERROR] Could not read the live Super-Linter caller for ${name}" >&2
      exit 1
    fi
  elif ! printf '%s' "$actual_lint_caller_blob" | grep -qE '^[0-9a-f]{40}$'; then
    echo "[ERROR] Invalid live Super-Linter caller blob receipt for ${name}" >&2
    exit 1
  fi
  if [ "$actual_lint_caller_blob" != "$expected_lint_caller_blob" ]; then
    echo "[BOOTSTRAP] ${name} does not contain the exact Super-Linter caller"
    stale_callers=$((stale_callers + 1))
    continue
  fi
  if ! github_api_into workflow_state \
    "repos/${owner}/${name}/actions/workflows/enforce-repo-settings.yml" \
    --jq '.state'; then
    echo "[ERROR] Could not resolve enforcement workflow state for ${name}" >&2
    exit 1
  fi
  desired_state="active"
  [ "$rollout_state" = "active" ] || desired_state="disabled_manually"
  if [ "$workflow_state" != "$desired_state" ]; then
    echo "[STATE] ${name} enforcement is ${workflow_state}; expected ${desired_state}"
    state_mismatches=$((state_mismatches + 1))
  fi
done < <(jq -er '.[] | select(type == "string")' "$downstream_config")

if [ "$stale_callers" -gt 0 ]; then
  echo "[BOOTSTRAP] ${stale_callers} downstream caller(s) require exact-byte propagation"
  exit 80
fi
if [ "$state_mismatches" -gt 0 ]; then
  echo "[STATE] ${state_mismatches} downstream workflow state(s) require reconciliation"
  exit 82
fi
if [ "$rollout_state" = "quiesced" ]; then
  echo "[DEFER] Governance rollout is deliberately quiesced"
  exit 81
fi

echo "[OK] protected-main receipt and governed workflow pin are exact"
