#!/usr/bin/env bash
# Deliver the exact enforcement, Super-Linter, and linked-issue workflows
# through bounded, monotonic PRs before reusable governance is invoked.
set -euo pipefail

repository="${GITHUB_REPOSITORY:-}"
owner="${repository%%/*}"
source_sha="${SOURCE_SHA:-}"
run_id="${GITHUB_RUN_ID:-}"
run_attempt="${GITHUB_RUN_ATTEMPT:-}"
downstream_config="${DOWNSTREAM_CONFIG:-.github/config/downstream-repos.json}"
rollout_config="${ROLLOUT_CONFIG:-.github/config/governance-rollout.json}"
repo_settings_config="${REPO_SETTINGS_CONFIG:-.github/config/repo-settings.json}"
caller_path=".github/workflows/enforce-repo-settings.yml"
lint_caller_path=".github/workflows/super-linter.yml"
linked_caller_path=".github/workflows/require-linked-issue.yml"
linked_context="Check linked issues"
legacy_linked_context="check / Check linked issues"
wait_seconds="${BOOTSTRAP_WAIT_SECONDS:-1800}"
poll_seconds="${BOOTSTRAP_POLL_SECONDS:-30}"
linked_wait_seconds="${BOOTSTRAP_LINKED_WAIT_SECONDS:-300}"

if ! printf '%s' "$source_sha" | grep -qE '^[0-9a-f]{40}$'; then
  echo "[ERROR] Source receipt must be a full lowercase commit SHA" >&2
  exit 1
fi
if ! printf '%s' "$repository" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  echo "[ERROR] GITHUB_REPOSITORY is invalid" >&2
  exit 1
fi
if ! printf '%s' "$run_id" | grep -qE '^[1-9][0-9]*$' ||
  ! printf '%s' "$run_attempt" | grep -qE '^[1-9][0-9]*$'; then
  echo "[ERROR] GitHub run identity is invalid" >&2
  exit 1
fi
if ! printf '%s' "$wait_seconds" | grep -qE '^[0-9]+$' ||
  ! printf '%s' "$poll_seconds" | grep -qE '^[1-9][0-9]*$' ||
  ! printf '%s' "$linked_wait_seconds" | grep -qE '^[0-9]+$'; then
  echo "[ERROR] Bootstrap wait configuration is invalid" >&2
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
if ! jq -e '
  (.branch_protection | type == "array") and
  ([.branch_protection[] | select(.branch == "main")] | length == 1) and
  ([.branch_protection[] | select(.branch == "main")][0].required_status_checks |
    type == "object" and
    (.strict | type == "boolean") and
    (.contexts |
      type == "array" and length > 0 and
      all(.[]; type == "string" and length > 0) and
      length == (unique | length))) and
  (.repo_overrides | type == "object") and
  all(.repo_overrides[];
    ((.additional_contexts // []) |
      type == "array" and
      all(.[]; type == "string" and length > 0) and
      length == (unique | length)) and
    ((.excluded_required_contexts // []) |
      type == "array" and
      all(.[]; type == "string" and length > 0) and
      length == (unique | length)))
' "$repo_settings_config" >/dev/null; then
  echo "[ERROR] Repository settings contain an invalid required-check contract" >&2
  exit 1
fi
if ! rollout_state=$(jq -er '.state | select(. == "quiesced" or . == "active")' \
  "$rollout_config"); then
  echo "[ERROR] Governance rollout state is missing or invalid" >&2
  exit 1
fi
if [ -z "${REPO_SETTINGS_TOKEN:-}" ]; then
  echo "[ERROR] REPO_SETTINGS_TOKEN is required for workflow state control" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

gh() {
  local err_file rc
  err_file=$(mktemp "$work/gh-err.XXXXXX")
  if command gh "$@" 2>"$err_file"; then
    rm -f "$err_file"
    return 0
  else
    rc=$?
  fi
  if grep -qiE 'rate limit|\(HTTP 429\)$' "$err_file"; then
    cat "$err_file" >&2
    rm -f "$err_file"
    return 84
  fi
  if grep -qE '\(HTTP 422\)$' "$err_file"; then
    rm -f "$err_file"
    return 85
  fi
  cat "$err_file" >&2
  rm -f "$err_file"
  return "$rc"
}

api_value_or_404() {
  local endpoint="$1" jq_filter="$2" token="${3:-${GH_TOKEN:-}}"
  local out_file err_file rc value
  out_file=$(mktemp "$work/api-out.XXXXXX")
  err_file=$(mktemp "$work/api-err.XXXXXX")
  set +e
  GH_TOKEN="$token" gh api "$endpoint" --jq "$jq_filter" >"$out_file" 2>"$err_file"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    value=$(cat "$out_file")
    rm -f "$out_file" "$err_file"
    printf '%s' "$value"
    return 0
  fi
  if grep -qE '\(HTTP 404\)$' "$err_file"; then
    rm -f "$out_file" "$err_file"
    return 44
  fi
  if [ "$rc" -eq 84 ]; then
    cat "$err_file" >&2
    rm -f "$out_file" "$err_file"
    return 84
  fi
  echo "[ERROR] GitHub API read failed closed" >&2
  sed -E 's/(Request-Id:).*/\1 [redacted]/I' "$err_file" >&2
  rm -f "$out_file" "$err_file"
  return 1
}

retry() {
  local max="$1"
  shift
  local attempt=1 delay=2
  local rc
  while true; do
    (
      set -e
      "$@"
    )
    rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 74 ] || [ "$rc" -eq 75 ] ||
      [ "$rc" -eq 76 ] || [ "$rc" -eq 84 ] || [ "$rc" -eq 85 ]; then
      return "$rc"
    fi
    if [ "$attempt" -ge "$max" ]; then
      return 1
    fi
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

active_run_ids() {
  local slug="$1" state_filter rc
  # Filter server-side so quiescence is proportional to active work, not the
  # repository's unbounded workflow history. Inventory repository-wide runs
  # and select the exact workflow path locally: the workflow-scoped endpoint
  # returns 404 after the file is deleted even while a legacy run remains active.
  # Query non-terminal states in forward lifecycle order so a run that advances
  # during one sweep is observed by a later query in that same sweep.
  for state_filter in \
    status=requested \
    status=waiting \
    status=pending \
    status=queued \
    status=in_progress; do
    set +e
    GH_TOKEN="$REPO_SETTINGS_TOKEN" gh api \
      "repos/${slug}/actions/runs?${state_filter}&per_page=100" \
      --paginate --jq \
      '.workflow_runs[] | select(.path == ".github/workflows/enforce-repo-settings.yml") | .id'
    rc=$?
    set -e
    if [ "$rc" -eq 84 ]; then
      return 84
    fi
    if [ "$rc" -ne 0 ]; then
      echo "[ERROR] Could not inventory ${state_filter#status=} enforcement runs for ${slug}" >&2
      return 1
    fi
  done
}

assert_source_current() {
  local current_main
  current_main=$(gh api "repos/${repository}/commits/main" --jq '.sha')
  if ! printf '%s' "$current_main" | grep -qE '^[0-9a-f]{40}$'; then
    echo "[ERROR] Protected docs-control main returned an invalid commit" >&2
    return 1
  fi
  if [ "$current_main" != "$source_sha" ]; then
    echo "[DEFER] A newer docs-control run supersedes this bootstrap"
    return 74
  fi
}

required_checks_for_repo() {
  local name="$1"
  jq -c --arg name "$name" '
    ([.branch_protection[] | select(.branch == "main")][0].required_status_checks) as $base |
    (.repo_overrides[$name] // {}) as $override |
    {
      strict: $base.strict,
      contexts: (
        (($base.contexts + ($override.additional_contexts // [])) | unique) -
        ($override.excluded_required_contexts // []) |
        sort
      )
    }
  ' "$repo_settings_config"
}

normalize_required_checks() {
  jq -c '{strict: .strict, contexts: (.contexts | unique | sort)}'
}

transition_required_checks_for_repo() {
  local name="$1" desired
  desired=$(required_checks_for_repo "$name")
  printf '%s' "$desired" | jq -ce \
    --arg current "$linked_context" --arg legacy "$legacy_linked_context" '
    if ([.contexts[] | select(. == $current)] | length) != 1 then
      error("authoritative linked-issue context is not unique")
    else
      .contexts = ([.contexts[] | select(. != $current)] + [$legacy] | unique | sort)
    end
  '
}

reconcile_required_checks_to() {
  local name="$1" desired="$2" slug endpoint current current_state verified rc payload
  slug="${owner}/${name}"
  endpoint="repos/${slug}/branches/main/protection/required_status_checks"
  if ! printf '%s' "$desired" | jq -e '
    .strict | type == "boolean"
  ' >/dev/null || ! printf '%s' "$desired" | jq -e '
    .contexts |
    type == "array" and length > 0 and
    all(.[]; type == "string" and length > 0) and
    length == (unique | length)
  ' >/dev/null; then
    echo "[ERROR] Could not derive exact required checks for ${slug}" >&2
    return 1
  fi

  set +e
  current=$(api_value_or_404 "$endpoint" '.' "$REPO_SETTINGS_TOKEN")
  rc=$?
  set -e
  case "$rc" in
  0) ;;
  44)
    echo "[ERROR] Protected main has no required-status-checks resource for ${slug}" >&2
    return 1
    ;;
  84) return 84 ;;
  *) return 1 ;;
  esac
  if ! printf '%s' "$current" | jq -e '
    type == "object" and
    (.strict | type == "boolean") and
    (.contexts | type == "array" and all(.[]; type == "string" and length > 0))
  ' >/dev/null; then
    echo "[ERROR] Required-status-checks response is malformed for ${slug}" >&2
    return 1
  fi
  current_state=$(printf '%s' "$current" | normalize_required_checks)
  if [ "$current_state" = "$desired" ]; then
    return 0
  fi

  assert_source_current
  payload="$work/required-checks-${name}.json"
  printf '%s\n' "$desired" >"$payload"
  set +e
  GH_TOKEN="$REPO_SETTINGS_TOKEN" retry 3 gh api "$endpoint" \
    --method PATCH --input "$payload" >/dev/null
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -ne 84 ] || return 84
    echo "[ERROR] Could not reconcile required checks for ${slug}" >&2
    return 1
  fi
  assert_source_current
  set +e
  verified=$(api_value_or_404 "$endpoint" '.' "$REPO_SETTINGS_TOKEN")
  rc=$?
  set -e
  if [ "$rc" -eq 84 ]; then
    return 84
  fi
  if [ "$rc" -ne 0 ] || ! printf '%s' "$verified" | jq -e '
    type == "object" and
    (.strict | type == "boolean") and
    (.contexts | type == "array" and all(.[]; type == "string" and length > 0))
  ' >/dev/null || [ "$(printf '%s' "$verified" | normalize_required_checks)" != "$desired" ]; then
    echo "[ERROR] Required checks did not settle exactly for ${slug}" >&2
    return 1
  fi
  echo "[OK] Required checks reconciled for ${slug}"
}

reconcile_required_checks() {
  local name="$1" desired
  desired=$(required_checks_for_repo "$name")
  reconcile_required_checks_to "$name" "$desired"
}

required_checks_are_desired() {
  local name="$1" slug endpoint desired current rc
  slug="${owner}/${name}"
  endpoint="repos/${slug}/branches/main/protection/required_status_checks"
  desired=$(required_checks_for_repo "$name")
  set +e
  current=$(api_value_or_404 "$endpoint" '.' "$REPO_SETTINGS_TOKEN")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return "$rc"
  if ! printf '%s' "$current" | jq -e '
    type == "object" and
    (.strict | type == "boolean") and
    (.contexts | type == "array" and all(.[]; type == "string" and length > 0))
  ' >/dev/null; then
    echo "[ERROR] Required-status-checks response is malformed for ${slug}" >&2
    return 1
  fi
  if [ "$(printf '%s' "$current" | normalize_required_checks)" = "$desired" ]; then
    return 0
  fi
  return 77
}

legacy_linked_check_is_successful() {
  local slug="$1" head="$2" response run_response run_ids run_id rc
  response=$(mktemp "$work/legacy-linked-check.XXXXXX")
  set +e
  gh api "repos/${slug}/commits/${head}/check-runs" >"$response"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    rm -f "$response"
    return "$rc"
  fi
  if ! jq -e '
    type == "object" and (.check_runs | type == "array") and
    all(.check_runs[];
      (.name | type == "string") and (.head_sha | type == "string") and
      (.status | type == "string") and
      (.conclusion == null or (.conclusion | type == "string")) and
      (.details_url | type == "string") and
      (.app.id | type == "number" and . >= 1 and . == floor) and
      (.app.slug | type == "string"))
  ' "$response" >/dev/null; then
    echo "[ERROR] Legacy linked-issue check response is malformed for ${slug}" >&2
    rm -f "$response"
    return 1
  fi
  run_ids=$(jq -r --arg head "$head" --arg context "$legacy_linked_context" \
    --arg prefix "https://github.com/${slug}/actions/runs/" '
    .check_runs[] |
    select(.name == $context and .head_sha == $head and .status == "completed" and
      .conclusion == "success" and .app.id == 15368 and .app.slug == "github-actions" and
      (.details_url | startswith($prefix))) |
    .details_url | capture("/actions/runs/(?<run>[1-9][0-9]*)/job/[1-9][0-9]*$").run
  ' "$response")
  rm -f "$response"
  while IFS= read -r run_id; do
    [ -n "$run_id" ] || continue
    run_response=$(mktemp "$work/legacy-linked-run.XXXXXX")
    set +e
    gh api "repos/${slug}/actions/runs/${run_id}" >"$run_response"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      rm -f "$run_response"
      return "$rc"
    fi
    if jq -e --arg head "$head" '
      type == "object" and .path == ".github/workflows/require-linked-issue.yml" and
      .event == "pull_request_target" and .head_sha == $head and
      .status == "completed" and .conclusion == "success"
    ' "$run_response" >/dev/null; then
      rm -f "$run_response"
      return 0
    fi
    rm -f "$run_response"
  done <<<"$run_ids"
  return 76
}

canonical_linked_status_ids() {
  local slug="$1" head="$2" destination="$3" response rc
  response=$(mktemp "$work/canonical-linked-status.XXXXXX")
  set +e
  gh api "repos/${slug}/commits/${head}/statuses" >"$response"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    rm -f "$response"
    return "$rc"
  fi
  if ! jq -e '
    type == "array" and
    all(.[];
      (.id | type == "number" and . >= 1 and . == floor) and
      (.context | type == "string") and (.state | type == "string") and
      (.creator.id | type == "number" and . >= 1 and . == floor) and
      (.creator.login | type == "string") and (.creator.type | type == "string"))
  ' "$response" >/dev/null || ! jq -c --arg context "$linked_context" '
    [.[] |
      select(.context == $context and .creator.id == 41898282 and
        .creator.login == "github-actions[bot]" and .creator.type == "Bot") |
      .id] | unique | sort
  ' "$response" >"$destination"; then
    echo "[ERROR] Commit-status response is malformed for ${slug}" >&2
    rm -f "$response"
    return 1
  fi
  rm -f "$response"
}

dispatch_and_verify_linked_status() {
  local slug="$1" pr_number="$2" head="$3" targeted="${4:-true}"
  local before_ids after_file payload rc deadline
  before_ids=$(mktemp "$work/linked-before.XXXXXX")
  after_file=$(mktemp "$work/linked-after.XXXXXX")
  canonical_linked_status_ids "$slug" "$head" "$before_ids" || {
    rc=$?
    rm -f "$before_ids" "$after_file"
    return "$rc"
  }
  payload=$(mktemp "$work/linked-dispatch.XXXXXX")
  if [ "$targeted" = true ]; then
    jq -n --arg ref main --arg pr "$pr_number" --arg head "$head" \
      '{ref: $ref, inputs: {pull_request_number: $pr, expected_head_sha: $head}}' >"$payload"
  elif [ "$targeted" = false ]; then
    jq -n --arg ref main '{ref: $ref}' >"$payload"
  else
    echo "[ERROR] Linked-issue dispatch mode is invalid for ${slug}" >&2
    rm -f "$before_ids" "$after_file" "$payload"
    return 1
  fi
  set +e
  GH_TOKEN="$REPO_SETTINGS_TOKEN" gh api \
    "repos/${slug}/actions/workflows/require-linked-issue.yml/dispatches" \
    --method POST --input "$payload" >/dev/null
  rc=$?
  set -e
  rm -f "$payload"
  if [ "$rc" -ne 0 ]; then
    rm -f "$before_ids" "$after_file"
    return "$rc"
  fi

  deadline=$((SECONDS + linked_wait_seconds))
  while true; do
    set +e
    gh api "repos/${slug}/commits/${head}/statuses" >"$after_file"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      rm -f "$before_ids" "$after_file"
      return "$rc"
    fi
    if ! jq -e --slurpfile before "$before_ids" --arg context "$linked_context" '
      type == "array" and
      any(.[];
        (.id | type == "number" and . >= 1 and . == floor) and
        .context == $context and .state == "success" and .creator.id == 41898282 and
        .creator.login == "github-actions[bot]" and .creator.type == "Bot" and
        (.id as $id | ($before[0] | index($id)) == null))
    ' "$after_file" >/dev/null; then
      if [ "$SECONDS" -ge "$deadline" ]; then
        rm -f "$before_ids" "$after_file"
        return 76
      fi
      sleep "$poll_seconds"
      continue
    fi
    rm -f "$before_ids" "$after_file"
    return 0
  done
}

recover_linked_transition_receipt() {
  local name="$1" slug prefix response candidate pr_number head actual
  slug="${owner}/${name}"
  prefix="sync/exact-caller-${expected_blob:0:6}${expected_lint_blob:0:6}${expected_linked_blob:0:6}-"
  response=$(mktemp "$work/merged-bootstrap-prs.XXXXXX")
  gh api "repos/${slug}/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
    >"$response"
  if ! jq -e '
    type == "array" and all(.[];
      (.number | type == "number" and . >= 1 and . == floor) and
      (.head.ref | type == "string") and
      (.head.sha | type == "string") and
      (.head.repo.full_name | type == "string") and
      (.base.ref | type == "string") and
      (.merged_at == null or (.merged_at | type == "string")))
  ' "$response" >/dev/null; then
    echo "[ERROR] Closed bootstrap PR inventory is malformed for ${slug}" >&2
    rm -f "$response"
    return 1
  fi
  candidate=$(jq -c --arg prefix "$prefix" --arg slug "$slug" '
    [.[] | select(
      .merged_at != null and .base.ref == "main" and .head.repo.full_name == $slug and
      (.head.ref | startswith($prefix)))] |
    sort_by(.merged_at) | reverse | first // empty
  ' "$response")
  rm -f "$response"
  if [ -z "$candidate" ]; then
    echo "[ERROR] No exact merged bootstrap receipt can restore protection for ${slug}" >&2
    return 1
  fi
  pr_number=$(printf '%s' "$candidate" | jq -r '.number')
  head=$(printf '%s' "$candidate" | jq -r '.head.sha')
  if ! [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then
    echo "[ERROR] Merged bootstrap receipt has an invalid head for ${slug}" >&2
    return 1
  fi
  actual=$(gh api "repos/${slug}/contents/${caller_path}?ref=${head}" --jq '.sha')
  [ "$actual" = "$expected_blob" ] || return 1
  actual=$(gh api "repos/${slug}/contents/${lint_caller_path}?ref=${head}" --jq '.sha')
  [ "$actual" = "$expected_lint_blob" ] || return 1
  actual=$(gh api "repos/${slug}/contents/${linked_caller_path}?ref=${head}" --jq '.sha')
  [ "$actual" = "$expected_linked_blob" ] || return 1
  jq -n --argjson pr "$pr_number" --arg head "$head" \
    '{pull_request: $pr, head: $head}' >"$work/linked-transition-${name}.json"
}

finalize_linked_transition() {
  local name="$1" slug receipt pr_number head rc
  slug="${owner}/${name}"
  if required_checks_are_desired "$name"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  [ "$rc" -eq 77 ] || return "$rc"
  receipt="$work/linked-transition-${name}.json"
  if [ ! -f "$receipt" ]; then
    recover_linked_transition_receipt "$name"
  fi
  if ! pr_number=$(jq -er '.pull_request | select(type == "number" and . >= 1 and . == floor)' \
    "$receipt") || ! head=$(jq -er \
      '.head | select(type == "string" and test("^[0-9a-f]{40}$"))' "$receipt"); then
    echo "[ERROR] Linked-issue transition receipt is malformed for ${name}" >&2
    return 1
  fi
  if dispatch_and_verify_linked_status "$slug" "$pr_number" "$head"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 76 ]; then
    echo "[DEFER] Canonical linked-issue status remains pending for ${name} PR #${pr_number}"
    return 76
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  reconcile_required_checks "$name"
}

decimal_greater_than() {
  local left="$1" right="$2"
  if [ "${#left}" -gt "${#right}" ]; then return 0; fi
  if [ "${#left}" -lt "${#right}" ]; then return 1; fi
  [[ "$left" > "$right" ]]
}

read_bootstrap_prs() {
  local slug="$1" destination="$2" response rc
  response=$(mktemp "$work/bootstrap-pr-pages.XXXXXX")
  set +e
  gh api "repos/${slug}/pulls?state=open&per_page=100" \
    --paginate >"$response"
  rc=$?
  set -e
  if [ "$rc" -eq 84 ]; then
    rm -f "$response"
    return 84
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] Could not inventory exact-caller PRs for ${slug}" >&2
    rm -f "$response"
    return 1
  fi
  if ! jq -se 'length > 0 and all(.[]; type == "array")' \
    "$response" >/dev/null || ! jq -sc 'add // []' "$response" >"$destination"; then
    echo "[ERROR] Exact-caller PR inventory is malformed for ${slug}" >&2
    rm -f "$response"
    return 1
  fi
  rm -f "$response"
}

reconcile_bootstrap_prs() {
  local slug="$1" current_branch="$2" open_prs rows number head_ref
  local head_oid head_repo base_ref other_run other_attempt rc current_count
  bootstrap_pr_number=""
  bootstrap_pr_head_oid=""
  open_prs=$(mktemp "$work/bootstrap-prs.XXXXXX")
  set +e
  read_bootstrap_prs "$slug" "$open_prs"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    rm -f "$open_prs"
    return "$rc"
  fi
  if ! jq -e --arg prefix 'sync/exact-caller-' '
    all(.[] | select(.head.ref | startswith($prefix));
      (.number | type == "number" and . >= 1 and . == floor) and
      (.head.ref | type == "string") and
      (.head.sha | type == "string" and test("^[0-9a-f]{40}$")) and
      (.head.repo.full_name | type == "string") and
      (.base.ref | type == "string"))
  ' "$open_prs" >/dev/null; then
    echo "[ERROR] Exact-caller PR ownership is malformed for ${slug}" >&2
    rm -f "$open_prs"
    return 1
  fi
  rows=$(jq -r --arg prefix 'sync/exact-caller-' '
    .[] | select(.head.ref | startswith($prefix)) |
    [.number, .head.ref, .head.sha, .head.repo.full_name, .base.ref] | @tsv
  ' "$open_prs")
  current_count=0
  while IFS=$'\t' read -r number head_ref head_oid head_repo base_ref; do
    [ -n "$number" ] || continue
    if [ "$head_repo" != "$slug" ] || [ "$base_ref" != main ]; then
      echo "[ERROR] Exact-caller PR does not belong to ${slug} protected main" >&2
      rm -f "$open_prs"
      return 1
    fi
    if [[ ! "$head_ref" =~ ^sync/exact-caller-[0-9a-f]{18}-([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
      echo "[ERROR] Unrecognized exact-caller automation branch for ${slug}" >&2
      rm -f "$open_prs"
      return 1
    fi
    if [ "$head_ref" = "$current_branch" ]; then
      current_count=$((current_count + 1))
      bootstrap_pr_number="$number"
      bootstrap_pr_head_oid="$head_oid"
      continue
    fi
    other_run="${BASH_REMATCH[1]}"
    other_attempt="${BASH_REMATCH[2]}"
    if decimal_greater_than "$other_run" "$run_id" ||
      { [ "$other_run" = "$run_id" ] &&
        decimal_greater_than "$other_attempt" "$run_attempt"; }; then
      echo "[DEFER] A newer exact-caller run owns ${slug}"
      rm -f "$open_prs"
      return 75
    fi
  done <<<"$rows"
  if [ "$current_count" -gt 1 ]; then
    echo "[ERROR] Multiple exact-caller PRs claim the current owner for ${slug}" >&2
    rm -f "$open_prs"
    return 1
  fi

  while IFS=$'\t' read -r number head_ref head_oid head_repo base_ref; do
    [ -n "$number" ] || continue
    [ "$head_ref" != "$current_branch" ] || continue
    set +e
    gh pr close "$number" --repo "$slug" --delete-branch \
      --comment "Superseded by a newer exact managed-caller receipt."
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -ne 84 ] || return 84
      echo "[ERROR] Could not close superseded exact-caller PR for ${slug}" >&2
      rm -f "$open_prs"
      return 1
    fi
  done <<<"$rows"

  set +e
  read_bootstrap_prs "$slug" "$open_prs"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    rm -f "$open_prs"
    return "$rc"
  fi
  if ! jq -e --arg prefix 'sync/exact-caller-' '
    all(.[] | select(.head.ref | startswith($prefix));
      (.number | type == "number" and . >= 1 and . == floor) and
      (.head.ref | type == "string") and
      (.head.sha | type == "string" and test("^[0-9a-f]{40}$")) and
      (.head.repo.full_name | type == "string") and
      (.base.ref | type == "string"))
  ' "$open_prs" >/dev/null; then
    echo "[ERROR] Exact-caller PR ownership changed during reconciliation for ${slug}" >&2
    rm -f "$open_prs"
    return 1
  fi
  bootstrap_pr_number=""
  bootstrap_pr_head_oid=""
  current_count=0
  rows=$(jq -r --arg prefix 'sync/exact-caller-' '
    .[] | select(.head.ref | startswith($prefix)) |
    [.number, .head.ref, .head.sha, .head.repo.full_name, .base.ref] | @tsv
  ' "$open_prs")
  while IFS=$'\t' read -r number head_ref head_oid head_repo base_ref; do
    [ -n "$number" ] || continue
    if [ "$head_repo" != "$slug" ] || [ "$base_ref" != main ]; then
      echo "[ERROR] Exact-caller PR does not belong to ${slug} protected main" >&2
      rm -f "$open_prs"
      return 1
    fi
    if [[ ! "$head_ref" =~ ^sync/exact-caller-[0-9a-f]{18}-([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
      echo "[ERROR] Unrecognized exact-caller automation branch for ${slug}" >&2
      rm -f "$open_prs"
      return 1
    fi
    if [ "$head_ref" != "$current_branch" ]; then
      echo "[ERROR] Another exact-caller PR remains mergeable for ${slug}" >&2
      rm -f "$open_prs"
      return 1
    fi
    current_count=$((current_count + 1))
    bootstrap_pr_number="$number"
    bootstrap_pr_head_oid="$head_oid"
  done <<<"$rows"
  if [ "$current_count" -gt 1 ]; then
    echo "[ERROR] Multiple exact-caller PRs claim the current owner for ${slug}" >&2
    rm -f "$open_prs"
    return 1
  fi
  rm -f "$open_prs"
}

quiesce_one() {
  local name="$1" slug state runs run_id status attempt rc workflow_present=true empty_sweeps=0
  local required_empty_sweeps=1
  slug="${owner}/${name}"
  set +e
  state=$(api_value_or_404 \
    "repos/${slug}/actions/workflows/enforce-repo-settings.yml" '.state' \
    "$REPO_SETTINGS_TOKEN")
  rc=$?
  set -e
  case "$rc" in
  0) ;;
  44) workflow_present=false ;;
  84) return 84 ;;
  *) return 1 ;;
  esac
  if [ "$workflow_present" = true ] && [ "$state" != "disabled_manually" ]; then
    set +e
    GH_TOKEN="$REPO_SETTINGS_TOKEN" gh api \
      "repos/${slug}/actions/workflows/enforce-repo-settings.yml/disable" \
      --method PUT >/dev/null
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || return "$rc"
    required_empty_sweeps=2
  fi

  # A run may change status between filtered API queries and escape one sweep.
  # Require two consecutive empty inventories when this invocation disabled an
  # active workflow. A workflow already disabled before this invocation cannot
  # start new runs, so one bounded inventory is sufficient. Cancel every run
  # found in each required sweep before certifying quiescence.
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    set +e
    runs=$(active_run_ids "$slug")
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || return "$rc"
    while IFS= read -r run_id; do
      [ -n "$run_id" ] || continue
      if [[ ! "$run_id" =~ ^[1-9][0-9]*$ ]]; then
        echo "[ERROR] Active-run inventory returned an invalid run ID for ${slug}" >&2
        return 1
      fi
      set +e
      GH_TOKEN="$REPO_SETTINGS_TOKEN" gh api \
        "repos/${slug}/actions/runs/${run_id}/cancel" --method POST >/dev/null
      rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        [ "$rc" -ne 84 ] || return 84
        set +e
        status=$(GH_TOKEN="$REPO_SETTINGS_TOKEN" gh api \
          "repos/${slug}/actions/runs/${run_id}" --jq '.status')
        rc=$?
        set -e
        [ "$rc" -eq 0 ] || return "$rc"
        [ "$status" = "completed" ] || return 1
      fi
    done <<<"$runs"
    if [ -z "$runs" ]; then
      empty_sweeps=$((empty_sweeps + 1))
      [ "$empty_sweeps" -ge "$required_empty_sweeps" ] && break
    else
      empty_sweeps=0
    fi
    sleep "$((attempt < 5 ? attempt : 5))"
  done
  [ "$empty_sweeps" -ge "$required_empty_sweeps" ] || return 1
  set +e
  state=$(api_value_or_404 \
    "repos/${slug}/actions/workflows/enforce-repo-settings.yml" '.state' \
    "$REPO_SETTINGS_TOKEN")
  rc=$?
  set -e
  case "$rc" in
  0) [ "$state" = "disabled_manually" ] ;;
  44) return 0 ;;
  84) return 84 ;;
  *) return 1 ;;
  esac
}

quiesce_fleet() {
  local failures=0 name rc
  while IFS= read -r name; do
    set +e
    retry 3 quiesce_one "$name"
    rc=$?
    set -e
    if [ "$rc" -eq 84 ]; then
      echo "[DEFER] GitHub API rate capacity was exhausted while quiescing ${name}" >&2
      return 84
    fi
    if [ "$rc" -ne 0 ]; then
      echo "[FAIL] Could not quiesce ${name} after 3 attempts" >&2
      failures=$((failures + 1))
    fi
  done < <(jq -r '.[]' "$downstream_config")
  [ "$failures" -eq 0 ]
}

enable_one() {
  local name="$1" slug state
  slug="${owner}/${name}"
  assert_source_current
  state=$(GH_TOKEN="$REPO_SETTINGS_TOKEN" gh api \
    "repos/${slug}/actions/workflows/enforce-repo-settings.yml" --jq '.state')
  if [ "$state" != "active" ]; then
    GH_TOKEN="$REPO_SETTINGS_TOKEN" gh api \
      "repos/${slug}/actions/workflows/enforce-repo-settings.yml/enable" \
      --method PUT >/dev/null
  fi
  state=$(GH_TOKEN="$REPO_SETTINGS_TOKEN" gh api \
    "repos/${slug}/actions/workflows/enforce-repo-settings.yml" --jq '.state')
  [ "$state" = "active" ]
}

# The mutating path independently repeats the dispatch safety proof.
callers_exact=false
set +e
GH_TOKEN="$REPO_SETTINGS_TOKEN" scripts/preflight-downstream-dispatch.sh
preflight_rc=$?
set -e
case "$preflight_rc" in
0)
  callers_exact=true
  ;;
80) ;;
81 | 82) callers_exact=true ;;
78) exit 78 ;;
*)
  echo "[ERROR] Mutating bootstrap preflight rejected this run" >&2
  exit 1
  ;;
esac

set +e
gh api \
  "repos/${repository}/contents/workflows/enforce-repo-settings.yml?ref=${source_sha}" \
  >"$work/caller.json"
rc=$?
set -e
if [ "$rc" -eq 84 ]; then
  exit 84
fi
if [ "$rc" -ne 0 ]; then
  echo "[ERROR] Could not fetch the exact managed caller" >&2
  exit 1
fi
if ! jq -e '
  .type == "file" and .encoding == "base64" and
  (.sha | type == "string" and test("^[0-9a-f]{40}$")) and
  (.content | type == "string" and length > 0)
' "$work/caller.json" >/dev/null; then
  echo "[ERROR] Managed caller response is malformed" >&2
  exit 1
fi
expected_blob=$(jq -r '.sha' "$work/caller.json")
jq -r '.content' "$work/caller.json" | tr -d '\n' >"$work/caller.b64"
if ! base64 -d <"$work/caller.b64" >"$work/caller.yml"; then
  echo "[ERROR] Managed caller response contains invalid base64" >&2
  exit 1
fi
if [ "$(git hash-object "$work/caller.yml")" != "$expected_blob" ]; then
  echo "[ERROR] Managed caller bytes do not match the GitHub blob receipt" >&2
  exit 1
fi
set +e
gh api \
  "repos/${repository}/contents/workflows/super-linter.yml?ref=${source_sha}" \
  >"$work/lint-caller.json"
rc=$?
set -e
if [ "$rc" -eq 84 ]; then
  exit 84
fi
if [ "$rc" -ne 0 ]; then
  echo "[ERROR] Could not fetch the exact Super-Linter caller" >&2
  exit 1
fi
if ! jq -e '
  .type == "file" and .encoding == "base64" and
  (.sha | type == "string" and test("^[0-9a-f]{40}$")) and
  (.content | type == "string" and length > 0)
' "$work/lint-caller.json" >/dev/null; then
  echo "[ERROR] Super-Linter caller response is malformed" >&2
  exit 1
fi
expected_lint_blob=$(jq -r '.sha' "$work/lint-caller.json")
jq -r '.content' "$work/lint-caller.json" | tr -d '\n' >"$work/lint-caller.b64"
if ! base64 -d <"$work/lint-caller.b64" >"$work/lint-caller.yml"; then
  echo "[ERROR] Super-Linter caller response contains invalid base64" >&2
  exit 1
fi
if [ "$(git hash-object "$work/lint-caller.yml")" != "$expected_lint_blob" ]; then
  echo "[ERROR] Super-Linter caller bytes do not match the GitHub blob receipt" >&2
  exit 1
fi
set +e
gh api \
  "repos/${repository}/contents/workflows/require-linked-issue.yml?ref=${source_sha}" \
  >"$work/linked-caller.json"
rc=$?
set -e
if [ "$rc" -eq 84 ]; then
  exit 84
fi
if [ "$rc" -ne 0 ]; then
  echo "[ERROR] Could not fetch the exact linked-issue evaluator" >&2
  exit 1
fi
if ! jq -e '
  .type == "file" and .encoding == "base64" and
  (.sha | type == "string" and test("^[0-9a-f]{40}$")) and
  (.content | type == "string" and length > 0)
' "$work/linked-caller.json" >/dev/null; then
  echo "[ERROR] Linked-issue evaluator response is malformed" >&2
  exit 1
fi
expected_linked_blob=$(jq -r '.sha' "$work/linked-caller.json")
jq -r '.content' "$work/linked-caller.json" | tr -d '\n' >"$work/linked-caller.b64"
if ! base64 -d <"$work/linked-caller.b64" >"$work/linked-caller.yml"; then
  echo "[ERROR] Linked-issue evaluator response contains invalid base64" >&2
  exit 1
fi
if [ "$(git hash-object "$work/linked-caller.yml")" != "$expected_linked_blob" ]; then
  echo "[ERROR] Linked-issue evaluator bytes do not match the GitHub blob receipt" >&2
  exit 1
fi
branch="sync/exact-caller-${expected_blob:0:6}${expected_lint_blob:0:6}${expected_linked_blob:0:6}-${run_id}-${run_attempt}"

if [ "$callers_exact" = true ]; then
  finalization_pending=false
  while IFS= read -r name; do
    set +e
    finalize_linked_transition "$name"
    rc=$?
    set -e
    if [ "$rc" -eq 76 ]; then
      finalization_pending=true
      continue
    fi
    if [ "$rc" -eq 84 ]; then
      exit 84
    fi
    if [ "$rc" -ne 0 ]; then
      echo "[ERROR] Could not finalize linked-issue protection for ${name}" >&2
      exit 1
    fi
  done < <(jq -r '.[]' "$downstream_config")
  if [ "$finalization_pending" = true ]; then
    exit 83
  fi
  if [ "$preflight_rc" -eq 0 ]; then
    echo "[OK] Every downstream managed workflow and required context is exact"
    exit 0
  fi
fi

set +e
assert_source_current
source_rc=$?
set -e
if [ "$source_rc" -eq 74 ]; then exit 78; fi
[ "$source_rc" -eq 0 ] || exit "$source_rc"

set +e
quiesce_fleet
rc=$?
set -e
if [ "$rc" -eq 84 ]; then
  exit 84
fi
if [ "$rc" -ne 0 ]; then
  echo "[ERROR] Fleet quiescence failed; no caller mutation was attempted" >&2
  exit 1
fi
echo "[OK] Downstream enforcement workflows are disabled with no active runs"

bootstrap_one() {
  local name="$1" slug default_branch base_sha main_sha actual_blob actual_lint_blob
  local actual_linked_blob rc branch_head branch_blob branch_lint_blob branch_linked_blob
  local expected_change_count
  local pr_number pr_url created_pr_number compare_file pr_file verified_head verified_blob
  local verified_lint_blob verified_linked_blob transition_checks
  slug="${owner}/${name}"

  assert_source_current
  main_sha=$(gh api "repos/${slug}/commits/main" --jq '.sha')
  if ! printf '%s' "$main_sha" | grep -qE '^[0-9a-f]{40}$'; then
    echo "[ERROR] Invalid protected-main receipt for ${name}" >&2
    return 1
  fi
  set +e
  actual_blob=$(api_value_or_404 \
    "repos/${slug}/contents/${caller_path}?ref=${main_sha}" '.sha')
  rc=$?
  set -e
  case "$rc" in
  0)
    if ! printf '%s' "$actual_blob" | grep -qE '^[0-9a-f]{40}$'; then
      echo "[ERROR] Invalid live caller blob for ${name}" >&2
      return 1
    fi
    ;;
  44) ;;
  84) return 84 ;;
  *) return 1 ;;
  esac
  set +e
  actual_lint_blob=$(api_value_or_404 \
    "repos/${slug}/contents/${lint_caller_path}?ref=${main_sha}" '.sha')
  rc=$?
  set -e
  case "$rc" in
  0)
    if ! printf '%s' "$actual_lint_blob" | grep -qE '^[0-9a-f]{40}$'; then
      echo "[ERROR] Invalid live Super-Linter caller blob for ${name}" >&2
      return 1
    fi
    ;;
  44) actual_lint_blob="" ;;
  84) return 84 ;;
  *) return 1 ;;
  esac
  set +e
  actual_linked_blob=$(api_value_or_404 \
    "repos/${slug}/contents/${linked_caller_path}?ref=${main_sha}" '.sha')
  rc=$?
  set -e
  case "$rc" in
  0)
    if ! printf '%s' "$actual_linked_blob" | grep -qE '^[0-9a-f]{40}$'; then
      echo "[ERROR] Invalid live linked-issue evaluator blob for ${name}" >&2
      return 1
    fi
    ;;
  44) actual_linked_blob="" ;;
  84) return 84 ;;
  *) return 1 ;;
  esac
  if [ "$actual_blob" = "$expected_blob" ] &&
    [ "$actual_lint_blob" = "$expected_lint_blob" ] &&
    [ "$actual_linked_blob" = "$expected_linked_blob" ]; then
    return 0
  fi
  expected_change_count=0
  [ "$actual_blob" = "$expected_blob" ] || expected_change_count=$((expected_change_count + 1))
  [ "$actual_lint_blob" = "$expected_lint_blob" ] || expected_change_count=$((expected_change_count + 1))
  [ "$actual_linked_blob" = "$expected_linked_blob" ] || expected_change_count=$((expected_change_count + 1))

  default_branch=$(gh api "repos/${slug}" --jq '.default_branch')
  if [ "$default_branch" != "main" ]; then
    echo "[ERROR] Governed repository ${name} does not use protected main" >&2
    return 1
  fi
  base_sha=$(gh api "repos/${slug}/git/ref/heads/${default_branch}" --jq '.object.sha')
  if ! printf '%s' "$base_sha" | grep -qE '^[0-9a-f]{40}$'; then
    echo "[ERROR] Invalid default-branch receipt for ${name}" >&2
    return 1
  fi

  reconcile_bootstrap_prs "$slug" "$branch"

  set +e
  branch_head=$(api_value_or_404 "repos/${slug}/git/ref/heads/${branch}" '.object.sha')
  rc=$?
  set -e
  case "$rc" in
  0)
    if ! printf '%s' "$branch_head" | grep -qE '^[0-9a-f]{40}$'; then
      echo "[ERROR] Invalid bootstrap branch receipt for ${name}" >&2
      return 1
    fi
    ;;
  44)
    jq -n --arg ref "refs/heads/${branch}" --arg sha "$base_sha" \
      '{ref: $ref, sha: $sha}' >"$work/ref-${name}.json"
    gh api "repos/${slug}/git/refs" --method POST \
      --input "$work/ref-${name}.json" >/dev/null
    branch_head="$base_sha"
    ;;
  84) return 84 ;;
  *) return 1 ;;
  esac

  set +e
  branch_blob=$(api_value_or_404 \
    "repos/${slug}/contents/${caller_path}?ref=${branch_head}" '.sha')
  rc=$?
  set -e
  case "$rc" in
  0)
    if ! printf '%s' "$branch_blob" | grep -qE '^[0-9a-f]{40}$'; then
      echo "[ERROR] Invalid bootstrap caller blob for ${name}" >&2
      return 1
    fi
    ;;
  44) branch_blob="" ;;
  84) return 84 ;;
  *) return 1 ;;
  esac

  set +e
  branch_lint_blob=$(api_value_or_404 \
    "repos/${slug}/contents/${lint_caller_path}?ref=${branch_head}" '.sha')
  rc=$?
  set -e
  case "$rc" in
  0)
    if ! printf '%s' "$branch_lint_blob" | grep -qE '^[0-9a-f]{40}$'; then
      echo "[ERROR] Invalid bootstrap Super-Linter caller blob for ${name}" >&2
      return 1
    fi
    ;;
  44) branch_lint_blob="" ;;
  84) return 84 ;;
  *) return 1 ;;
  esac

  set +e
  branch_linked_blob=$(api_value_or_404 \
    "repos/${slug}/contents/${linked_caller_path}?ref=${branch_head}" '.sha')
  rc=$?
  set -e
  case "$rc" in
  0)
    if ! printf '%s' "$branch_linked_blob" | grep -qE '^[0-9a-f]{40}$'; then
      echo "[ERROR] Invalid bootstrap linked-issue evaluator blob for ${name}" >&2
      return 1
    fi
    ;;
  44) branch_linked_blob="" ;;
  84) return 84 ;;
  *) return 1 ;;
  esac

  if { [ "$branch_blob" != "$expected_blob" ] ||
    [ "$branch_lint_blob" != "$expected_lint_blob" ] ||
    [ "$branch_linked_blob" != "$expected_linked_blob" ]; } &&
    [ "$branch_head" != "$base_sha" ]; then
    echo "[ERROR] Refusing to append to a non-exact bootstrap branch for ${name}" >&2
    return 1
  fi
  if [ "$branch_blob" != "$expected_blob" ]; then
    jq -n \
      --arg message "chore(governance): bootstrap exact managed caller" \
      --arg branch "$branch" \
      --arg sha "$branch_blob" \
      --rawfile content "$work/caller.b64" \
      '{message: $message, content: $content, branch: $branch, sha: $sha} |
       if .sha == "" then del(.sha) else . end' >"$work/update-${name}.json"
    gh api "repos/${slug}/contents/${caller_path}" \
      --method PUT --input "$work/update-${name}.json" >/dev/null
    branch_head=$(gh api "repos/${slug}/git/ref/heads/${branch}" --jq '.object.sha')
  fi
  if [ "$branch_lint_blob" != "$expected_lint_blob" ]; then
    jq -n \
      --arg message "chore(governance): bootstrap exact Super-Linter caller" \
      --arg branch "$branch" \
      --arg sha "$branch_lint_blob" \
      --rawfile content "$work/lint-caller.b64" \
      '{message: $message, content: $content, branch: $branch, sha: $sha} |
       if .sha == "" then del(.sha) else . end' >"$work/update-lint-${name}.json"
    gh api "repos/${slug}/contents/${lint_caller_path}" \
      --method PUT --input "$work/update-lint-${name}.json" >/dev/null
    branch_head=$(gh api "repos/${slug}/git/ref/heads/${branch}" --jq '.object.sha')
  fi
  if [ "$branch_linked_blob" != "$expected_linked_blob" ]; then
    jq -n \
      --arg message "chore(governance): bootstrap exact linked-issue evaluator" \
      --arg branch "$branch" \
      --arg sha "$branch_linked_blob" \
      --rawfile content "$work/linked-caller.b64" \
      '{message: $message, content: $content, branch: $branch, sha: $sha} |
       if .sha == "" then del(.sha) else . end' >"$work/update-linked-${name}.json"
    gh api "repos/${slug}/contents/${linked_caller_path}" \
      --method PUT --input "$work/update-linked-${name}.json" >/dev/null
    branch_head=$(gh api "repos/${slug}/git/ref/heads/${branch}" --jq '.object.sha')
  fi
  if ! printf '%s' "$branch_head" | grep -qE '^[0-9a-f]{40}$'; then
    echo "[ERROR] Invalid exact bootstrap head for ${name}" >&2
    return 1
  fi

  compare_file="$work/compare-${name}.json"
  gh api "repos/${slug}/compare/${base_sha}...${branch_head}" >"$compare_file"
  if ! jq -e --arg path "$caller_path" --arg blob "$expected_blob" \
    --arg lint_path "$lint_caller_path" --arg lint_blob "$expected_lint_blob" \
    --arg linked_path "$linked_caller_path" --arg linked_blob "$expected_linked_blob" \
    --argjson change_count "$expected_change_count" '
    .status == "ahead" and .ahead_by == $change_count and
    .total_commits == $change_count and (.commits | length) == $change_count and
    (.files | length) == $change_count and
    all(.files[];
      ((.filename == $path and .sha == $blob) or
       (.filename == $lint_path and .sha == $lint_blob) or
       (.filename == $linked_path and .sha == $linked_blob)) and
      (.status == "added" or .status == "modified"))
  ' "$compare_file" >/dev/null; then
    echo "[ERROR] Bootstrap branch for ${name} is not an exact caller update" >&2
    return 1
  fi

  pr_number="$bootstrap_pr_number"
  created_pr_number=""
  if [ -z "$pr_number" ]; then
    pr_url=$(gh pr create \
      --repo "$slug" \
      --base "$default_branch" \
      --head "$branch" \
      --title "chore(governance): bootstrap exact managed callers" \
      --body "Installs the exact enforcement, Super-Linter, and linked-issue workflows before fleet enforcement resumes. The sync/ branch uses the governed automation exemption from linked-issue enforcement.")
    pr_number=${pr_url##*/}
    created_pr_number="$pr_number"
    if ! printf '%s' "$created_pr_number" | grep -qE '^[1-9][0-9]*$'; then
      echo "[ERROR] Could not resolve created exact-caller PR for ${name}" >&2
      return 1
    fi
  fi
  reconcile_bootstrap_prs "$slug" "$branch"
  if [ -z "$bootstrap_pr_number" ] || [ "$bootstrap_pr_number" != "$pr_number" ] ||
    [ "$bootstrap_pr_head_oid" != "$branch_head" ] ||
    { [ -n "$created_pr_number" ] && [ "$bootstrap_pr_number" != "$created_pr_number" ]; }; then
    echo "[ERROR] Exact-caller PR identity changed after selection for ${name}" >&2
    return 1
  fi
  pr_file="$work/pr-${name}.json"
  gh pr view "$pr_number" --repo "$slug" \
    --json baseRefName,headRefName,headRefOid,files,commits >"$pr_file"
  if ! jq -e --arg path "$caller_path" --arg lint_path "$lint_caller_path" \
    --arg linked_path "$linked_caller_path" \
    --arg base "$default_branch" --arg head "$branch" --arg oid "$branch_head" \
    --argjson change_count "$expected_change_count" '
    .baseRefName == $base and .headRefName == $head and .headRefOid == $oid and
    (.commits | length) == $change_count and (.files | length) == $change_count and
    all(.files[]; .path == $path or .path == $lint_path or .path == $linked_path)
  ' "$pr_file" >/dev/null; then
    echo "[ERROR] Bootstrap PR for ${name} contains an unexpected diff" >&2
    return 1
  fi

  assert_source_current
  reconcile_bootstrap_prs "$slug" "$branch"
  if [ "$bootstrap_pr_number" != "$pr_number" ] ||
    [ "$bootstrap_pr_head_oid" != "$branch_head" ]; then
    echo "[ERROR] Exact-caller PR owner changed before merge for ${name}" >&2
    return 1
  fi
  verified_head=$(gh api "repos/${slug}/git/ref/heads/${branch}" --jq '.object.sha')
  if [ "$verified_head" != "$branch_head" ]; then
    echo "[ERROR] Bootstrap head changed after exact PR verification for ${name}" >&2
    return 1
  fi
  verified_blob=$(gh api \
    "repos/${slug}/contents/${caller_path}?ref=${verified_head}" --jq '.sha')
  if [ "$verified_blob" != "$expected_blob" ]; then
    echo "[ERROR] Bootstrap caller changed after exact PR verification for ${name}" >&2
    return 1
  fi
  verified_lint_blob=$(gh api \
    "repos/${slug}/contents/${lint_caller_path}?ref=${verified_head}" --jq '.sha')
  if [ "$verified_lint_blob" != "$expected_lint_blob" ]; then
    echo "[ERROR] Super-Linter caller changed after exact PR verification for ${name}" >&2
    return 1
  fi
  verified_linked_blob=$(gh api \
    "repos/${slug}/contents/${linked_caller_path}?ref=${verified_head}" --jq '.sha')
  if [ "$verified_linked_blob" != "$expected_linked_blob" ]; then
    echo "[ERROR] Linked-issue evaluator changed after exact PR verification for ${name}" >&2
    return 1
  fi
  if [ "$actual_linked_blob" != "$expected_linked_blob" ]; then
    if dispatch_and_verify_linked_status "$slug" "$pr_number" "$verified_head" false; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      reconcile_required_checks "$name"
    elif [ "$rc" -eq 85 ]; then
      if legacy_linked_check_is_successful "$slug" "$verified_head"; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 76 ]; then
          echo "[DEFER] Waiting for the legacy linked-issue gate on ${name} PR #${pr_number}"
        fi
        return "$rc"
      fi
      transition_checks=$(transition_required_checks_for_repo "$name") || {
        echo "[ERROR] Could not derive transitional required checks for ${slug}" >&2
        return 1
      }
      reconcile_required_checks_to "$name" "$transition_checks"
      jq -n --argjson pr "$pr_number" --arg head "$verified_head" \
        '{pull_request: $pr, head: $head}' >"$work/linked-transition-${name}.json"
    else
      if [ "$rc" -eq 76 ]; then
        echo "[DEFER] Waiting for the canonical linked-issue gate on ${name} PR #${pr_number}"
      fi
      return "$rc"
    fi
  else
    dispatch_and_verify_linked_status "$slug" "$pr_number" "$verified_head" || return $?
    reconcile_required_checks "$name"
  fi
  gh pr merge "$pr_number" --repo "$slug" --auto --squash --delete-branch \
    --match-head-commit "$verified_head"
  echo "[BOOTSTRAP] ${name} caller PR #${pr_number} is queued for exact merge"
}

failures=0
source_superseded=false
newer_owner=false
transition_pending=false
while IFS= read -r name; do
  set +e
  retry 3 bootstrap_one "$name"
  rc=$?
  set -e
  if [ "$rc" -eq 74 ]; then
    source_superseded=true
    break
  fi
  if [ "$rc" -eq 75 ]; then
    newer_owner=true
    break
  fi
  if [ "$rc" -eq 76 ]; then
    transition_pending=true
    continue
  fi
  if [ "$rc" -eq 84 ]; then
    exit 84
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[FAIL] Could not bootstrap ${name} after 3 attempts" >&2
    failures=$((failures + 1))
  fi
done < <(jq -r '.[]' "$downstream_config")
if [ "$source_superseded" = true ]; then
  echo "[DEFER] A newer bootstrap run owns the transition"
  exit 78
fi
if [ "$newer_owner" = true ]; then
  echo "[DEFER] A newer bootstrap run owns the transition"
  exit 83
fi
if [ "$transition_pending" = true ]; then
  echo "[DEFER] Linked-issue transition checks remain pending"
  exit 83
fi
if [ "$failures" -gt 0 ]; then
  echo "[ERROR] ${failures} downstream caller bootstrap(s) failed" >&2
  exit 1
fi

deadline=$((SECONDS + wait_seconds))
while true; do
  pending=0
  while IFS= read -r name; do
    slug="${owner}/${name}"
    main_sha=$(gh api "repos/${slug}/commits/main" --jq '.sha')
    if ! printf '%s' "$main_sha" | grep -qE '^[0-9a-f]{40}$'; then
      echo "[ERROR] Invalid protected-main receipt while verifying ${name}" >&2
      exit 1
    fi
    set +e
    live_blob=$(api_value_or_404 \
      "repos/${slug}/contents/${caller_path}?ref=${main_sha}" '.sha')
    rc=$?
    set -e
    case "$rc" in
    0)
      if ! printf '%s' "$live_blob" | grep -qE '^[0-9a-f]{40}$'; then
        echo "[ERROR] Invalid live caller receipt while verifying ${name}" >&2
        exit 1
      fi
      [ "$live_blob" = "$expected_blob" ] || pending=$((pending + 1))
      ;;
    44) pending=$((pending + 1)) ;;
    84) exit 84 ;;
    *) exit 1 ;;
    esac

    set +e
    live_lint_blob=$(api_value_or_404 \
      "repos/${slug}/contents/${lint_caller_path}?ref=${main_sha}" '.sha')
    rc=$?
    set -e
    case "$rc" in
    0)
      if ! printf '%s' "$live_lint_blob" | grep -qE '^[0-9a-f]{40}$'; then
        echo "[ERROR] Invalid live Super-Linter caller receipt while verifying ${name}" >&2
        exit 1
      fi
      [ "$live_lint_blob" = "$expected_lint_blob" ] || pending=$((pending + 1))
      ;;
    44) pending=$((pending + 1)) ;;
    84) exit 84 ;;
    *) exit 1 ;;
    esac

    set +e
    live_linked_blob=$(api_value_or_404 \
      "repos/${slug}/contents/${linked_caller_path}?ref=${main_sha}" '.sha')
    rc=$?
    set -e
    case "$rc" in
    0)
      if ! printf '%s' "$live_linked_blob" | grep -qE '^[0-9a-f]{40}$'; then
        echo "[ERROR] Invalid live linked-issue evaluator receipt while verifying ${name}" >&2
        exit 1
      fi
      [ "$live_linked_blob" = "$expected_linked_blob" ] || pending=$((pending + 1))
      ;;
    44) pending=$((pending + 1)) ;;
    84) exit 84 ;;
    *) exit 1 ;;
    esac
  done < <(jq -r '.[]' "$downstream_config")

  if [ "$pending" -eq 0 ]; then
    echo "[OK] Every downstream protected main contains all exact managed workflows"
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "[DEFER] ${pending} exact-caller blob(s) remain pending; scheduled dispatch will resume verification"
    exit 83
  fi
  sleep "$poll_seconds"
done

while IFS= read -r name; do
  set +e
  finalize_linked_transition "$name"
  rc=$?
  set -e
  if [ "$rc" -eq 76 ]; then
    exit 83
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
done < <(jq -r '.[]' "$downstream_config")

set +e
assert_source_current
source_rc=$?
set -e
if [ "$source_rc" -eq 74 ]; then exit 78; fi
[ "$source_rc" -eq 0 ] || exit "$source_rc"

if [ "$rollout_state" = "quiesced" ]; then
  set +e
  quiesce_fleet
  rc=$?
  set -e
  if [ "$rc" -eq 84 ]; then
    exit 84
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] Exact callers landed but fleet quiescence could not be verified" >&2
    exit 1
  fi
  echo "[DEFER] Exact callers are installed; enforcement remains deliberately quiesced"
  exit 81
fi

enable_failures=0
source_superseded=false
while IFS= read -r name; do
  set +e
  retry 3 enable_one "$name"
  rc=$?
  set -e
  if [ "$rc" -eq 74 ]; then
    source_superseded=true
    break
  fi
  if [ "$rc" -eq 84 ]; then
    exit 84
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[FAIL] Could not enable exact enforcement for ${name}" >&2
    enable_failures=$((enable_failures + 1))
  fi
done < <(jq -r '.[]' "$downstream_config")
if [ "$source_superseded" = true ]; then
  set +e
  quiesce_fleet
  rc=$?
  set -e
  if [ "$rc" -eq 84 ]; then
    exit 84
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] Source advanced during enable and fleet rollback failed" >&2
    exit 1
  fi
  echo "[DEFER] Source advanced during enable; the fleet was returned to quiescence"
  exit 78
fi
if [ "$enable_failures" -gt 0 ]; then
  set +e
  quiesce_fleet
  rc=$?
  set -e
  if [ "$rc" -eq 84 ]; then
    exit 84
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] Enable failed and fleet rollback could not be verified" >&2
    exit 1
  fi
  echo "[ERROR] ${enable_failures} exact enforcement workflow(s) remain disabled" >&2
  exit 1
fi

set +e
assert_source_current
source_rc=$?
set -e
if [ "$source_rc" -eq 74 ]; then
  set +e
  quiesce_fleet
  rc=$?
  set -e
  if [ "$rc" -eq 84 ]; then
    exit 84
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] Source advanced after enable and fleet rollback failed" >&2
    exit 1
  fi
  echo "[DEFER] Source advanced after enable; the fleet was returned to quiescence"
  exit 78
fi
[ "$source_rc" -eq 0 ] || exit "$source_rc"
echo "[OK] Exact downstream enforcement workflows are active"
