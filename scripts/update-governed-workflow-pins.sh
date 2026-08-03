#!/usr/bin/env bash
# Publish one exact governed-workflow pin through a unique, current-base PR.
set -euo pipefail

repository="${GITHUB_REPOSITORY:-}"
target_revision="${REQUESTED_REVISION:-${GITHUB_SHA:-}}"
run_id="${GITHUB_RUN_ID:-}"
run_attempt="${GITHUB_RUN_ATTEMPT:-}"
branch=""
base_oid=""
head_oid=""
workflow_list=""
work=""

is_sha() {
  printf '%s' "$1" | grep -qE '^[0-9a-f]{40}$'
}

fetch_main() {
  if ! git fetch --no-tags origin main; then
    echo "::error::could not refresh protected main" >&2
    return 1
  fi
  if ! current_main_oid=$(git rev-parse refs/remotes/origin/main); then
    echo "::error::could not resolve refreshed protected main" >&2
    return 1
  fi
  if ! is_sha "$current_main_oid"; then
    echo "::error::protected main returned an invalid commit" >&2
    return 1
  fi
}

assert_target_current() {
  local expected_base="$1" current_revision workflow target_blob current_blob
  if ! fetch_main; then
    return 1
  fi
  if [ "$current_main_oid" != "$expected_base" ]; then
    echo "[DEFER] protected main advanced beyond the updater base"
    return 75
  fi
  if ! git cat-file -e "${target_revision}^{commit}" 2>/dev/null ||
    ! git merge-base --is-ancestor "$target_revision" "$current_main_oid"; then
    echo "::error::revision is not an ancestor of protected main: $target_revision" >&2
    return 1
  fi
  if ! current_revision=$(git show \
    "${current_main_oid}:.github/config/governed-workflow-pin.json" |
    jq -er '.revision | select(type == "string" and test("^[0-9a-f]{40}$"))'); then
    echo "::error::protected main contains an invalid governed-workflow receipt" >&2
    return 1
  fi
  if ! git cat-file -e "${current_revision}^{commit}" 2>/dev/null ||
    ! git merge-base --is-ancestor "$current_revision" "$target_revision"; then
    echo "::error::refusing to roll governed workflows backward from $current_revision to $target_revision" >&2
    return 1
  fi
  if [ ! -s "$workflow_list" ]; then
    echo "::error::governed workflow inventory is empty" >&2
    return 1
  fi
  if [ -n "$(sort "$workflow_list" | uniq -d)" ]; then
    echo "::error::governed workflow inventory contains duplicates" >&2
    return 1
  fi
  while IFS= read -r workflow; do
    if ! printf '%s' "$workflow" | grep -qE '^[A-Za-z0-9_.-]+\.ya?ml$'; then
      echo "::error::invalid reusable workflow path: $workflow" >&2
      return 1
    fi
    if ! git cat-file -e "$target_revision:.github/workflows/$workflow" 2>/dev/null ||
      ! git cat-file -e "$current_main_oid:.github/workflows/$workflow" 2>/dev/null; then
      echo "::error::missing reusable workflow $workflow" >&2
      return 1
    fi
    if ! target_blob=$(git rev-parse "$target_revision:.github/workflows/$workflow") ||
      ! current_blob=$(git rev-parse "$current_main_oid:.github/workflows/$workflow"); then
      echo "::error::could not resolve reusable workflow $workflow" >&2
      return 1
    fi
    if ! is_sha "$target_blob" || ! is_sha "$current_blob"; then
      echo "::error::invalid reusable workflow blob receipt for $workflow" >&2
      return 1
    fi
    if [ "$target_blob" != "$current_blob" ]; then
      echo "[DEFER] a newer reusable implementation supersedes $target_revision"
      return 75
    fi
  done <"$workflow_list"
}

read_paginated_array() {
  local endpoint="$1" destination="$2" response
  if ! response=$(mktemp "$work/api-pages.XXXXXX"); then
    echo "::error::could not allocate governed pin inventory response" >&2
    return 1
  fi
  if ! gh api "$endpoint" --paginate --slurp >"$response"; then
    echo "::error::could not inventory governed pin automation state" >&2
    rm -f "$response"
    return 1
  fi
  if ! jq -e 'type == "array" and all(.[]; type == "array")' "$response" >/dev/null ||
    ! jq -c 'add // []' "$response" >"$destination"; then
    echo "::error::governed pin automation inventory is malformed" >&2
    rm -f "$response"
    return 1
  fi
  rm -f "$response"
}

read_open_pin_prs() {
  read_paginated_array \
    "repos/${repository}/pulls?state=open&per_page=100" "$1"
}

read_pin_refs() {
  read_paginated_array \
    "repos/${repository}/git/matching-refs/heads/sync/governed-workflow-pins-?per_page=100" \
    "$1"
}

delete_remote_branch() {
  local ref="$1" expected_oid="$2" err_file actual_oid rc
  # This exact sync/governed-workflow-pins-* namespace is reserved for this
  # monotonic automation. Once a newer run owns the transition, the entire
  # older ref is disposable even if its tip moves after this defensive read;
  # no human or other automation may publish into the reserved namespace.
  if ! err_file=$(mktemp "$work/ref-error.XXXXXX"); then
    echo "::error::could not allocate governed pin ref error capture" >&2
    return 1
  fi
  if actual_oid=$(gh api "repos/${repository}/git/ref/heads/${ref}" --jq '.object.sha' \
    2>"$err_file"); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if grep -qE '\(HTTP 404\)$' "$err_file"; then
      rm -f "$err_file"
      return 0
    fi
    echo "::error::could not verify automation branch before deletion" >&2
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  if ! is_sha "$actual_oid" || [ "$actual_oid" != "$expected_oid" ]; then
    echo "::error::automation branch changed before deletion: $ref" >&2
    return 1
  fi
  if ! gh api "repos/${repository}/git/refs/heads/${ref}" --method DELETE >/dev/null; then
    echo "::error::could not delete superseded automation branch" >&2
    return 1
  fi
}

decimal_greater_than() {
  local left="$1" right="$2"
  if [ "${#left}" -gt "${#right}" ]; then return 0; fi
  if [ "${#left}" -lt "${#right}" ]; then return 1; fi
  [[ "$left" > "$right" ]]
}

classify_owner() {
  local ref="$1" other_run other_attempt
  if [[ ! "$ref" =~ ^sync/governed-workflow-pins-[0-9a-f]{12}-([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
    echo "::error::unrecognized governed pin automation branch" >&2
    return 1
  fi
  other_run="${BASH_REMATCH[1]}"
  other_attempt="${BASH_REMATCH[2]}"
  if decimal_greater_than "$other_run" "$run_id" ||
    { [ "$other_run" = "$run_id" ] &&
      decimal_greater_than "$other_attempt" "$run_attempt"; }; then
    echo "[DEFER] a newer governed pin run owns the transition"
    return 75
  fi
}

reconcile_pin_prs() {
  local prs refs rows number ref head_repo base_ref expected_oid rc current_count
  local retired_prs retired_refs retired_row full_ref
  local settle_attempt settle_delay clear_sweeps retired_visible settle_required
  reconciled_pin_pr_number=""
  reconciled_pin_pr_head_oid=""
  prs=""
  refs=""
  retired_prs=""
  retired_refs=""
  if ! prs=$(mktemp "$work/open-prs.XXXXXX"); then
    echo "::error::could not allocate governed pin PR inventory" >&2
    return 1
  fi
  if ! refs=$(mktemp "$work/open-refs.XXXXXX"); then
    echo "::error::could not allocate governed pin ref inventory" >&2
    rm -f "$prs"
    return 1
  fi
  if ! retired_prs=$(mktemp "$work/retired-prs.XXXXXX"); then
    echo "::error::could not allocate retired governed pin PR inventory" >&2
    rm -f "$prs" "$refs"
    return 1
  fi
  if ! retired_refs=$(mktemp "$work/retired-refs.XXXXXX"); then
    echo "::error::could not allocate retired governed pin ref inventory" >&2
    rm -f "$prs" "$refs" "$retired_prs"
    return 1
  fi
  if ! read_open_pin_prs "$prs" || ! read_pin_refs "$refs"; then
    rm -f "$prs" "$refs"
    return 1
  fi
  if ! jq -e --arg prefix 'sync/governed-workflow-pins-' '
    all(.[] | select(.head.ref | startswith($prefix));
      (.number | type == "number" and . >= 1 and . == floor) and
      (.head.ref | type == "string") and
      (.head.sha | type == "string" and test("^[0-9a-f]{40}$")) and
      (.head.repo.full_name | type == "string") and
      (.base.ref | type == "string"))
  ' "$prs" >/dev/null || ! jq -e '
    all(.[]; (.ref | type == "string") and
      (.object.sha | type == "string" and test("^[0-9a-f]{40}$")))
  ' "$refs" >/dev/null; then
    echo "::error::governed pin ownership inventory is malformed" >&2
    rm -f "$prs" "$refs"
    return 1
  fi

  if ! rows=$(jq -r --arg prefix 'sync/governed-workflow-pins-' '
    .[] | select(.head.ref | startswith($prefix)) |
    [.number, .head.ref, .head.sha, .head.repo.full_name, .base.ref] | @tsv
  ' "$prs"); then
    echo "::error::could not extract governed pin PR ownership" >&2
    rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
    return 1
  fi
  current_count=0
  while IFS=$'\t' read -r number ref expected_oid head_repo base_ref; do
    [ -n "$number" ] || continue
    if [ "$head_repo" != "$repository" ] || [ "$base_ref" != main ]; then
      echo "::error::governed pin PR does not belong to protected main" >&2
      rm -f "$prs" "$refs"
      return 1
    fi
    if classify_owner "$ref"; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      rm -f "$prs" "$refs"
      return "$rc"
    fi
    if [ "$ref" = "$branch" ]; then
      current_count=$((current_count + 1))
      reconciled_pin_pr_number="$number"
      reconciled_pin_pr_head_oid="$expected_oid"
    fi
  done <<<"$rows"
  if [ "$current_count" -gt 1 ]; then
    echo "::error::multiple governed pin PRs claim the current owner" >&2
    rm -f "$prs" "$refs"
    return 1
  fi

  if ! rows=$(jq -r --arg branch "refs/heads/${branch}" \
    '.[] | select(.ref != $branch) | [.ref, .object.sha] | @tsv' "$refs"); then
    echo "::error::could not extract governed pin ref ownership" >&2
    rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
    return 1
  fi
  while IFS=$'\t' read -r ref expected_oid; do
    [ -n "$ref" ] || continue
    ref="${ref#refs/heads/}"
    if classify_owner "$ref"; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      rm -f "$prs" "$refs"
      return "$rc"
    fi
  done <<<"$rows"

  if ! rows=$(jq -r --arg branch "$branch" --arg prefix 'sync/governed-workflow-pins-' '
    .[] | select(.head.ref | startswith($prefix)) |
    select(.head.ref != $branch) | [.number, .head.ref, .head.sha] | @tsv
  ' "$prs"); then
    echo "::error::could not extract superseded governed pin PRs" >&2
    rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
    return 1
  fi
  while IFS=$'\t' read -r number ref expected_oid; do
    [ -n "$number" ] || continue
    if ! gh pr close "$number" --repo "$repository" \
      --comment "Superseded by a newer exact governed-workflow pin."; then
      echo "::error::could not close superseded governed pin PR" >&2
      rm -f "$prs" "$refs"
      return 1
    fi
    if ! printf '%s\t%s\t%s\n' "$number" "$ref" "$expected_oid" >>"$retired_prs"; then
      echo "::error::could not record retired governed pin PR identity" >&2
      rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
      return 1
    fi
  done <<<"$rows"

  if ! rows=$(jq -r --arg branch "refs/heads/${branch}" \
    '.[] | select(.ref != $branch) | [.ref, .object.sha] | @tsv' "$refs"); then
    echo "::error::could not extract superseded governed pin refs" >&2
    rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
    return 1
  fi
  while IFS=$'\t' read -r ref expected_oid; do
    [ -n "$ref" ] || continue
    full_ref="$ref"
    ref="${ref#refs/heads/}"
    if ! delete_remote_branch "$ref" "$expected_oid"; then
      rm -f "$prs" "$refs"
      return 1
    fi
    if ! printf '%s\t%s\n' "$full_ref" "$expected_oid" >>"$retired_refs"; then
      echo "::error::could not record retired governed pin ref identity" >&2
      rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
      return 1
    fi
  done <<<"$rows"

  settle_required=false
  if [ -s "$retired_prs" ] || [ -s "$retired_refs" ]; then
    settle_required=true
  fi
  settle_attempt=1
  settle_delay=1
  clear_sweeps=0
  while true; do
    if ! read_open_pin_prs "$prs" || ! read_pin_refs "$refs"; then
      rm -f "$prs" "$refs"
      return 1
    fi
    if ! jq -e --arg prefix 'sync/governed-workflow-pins-' '
      all(.[] | select(.head.ref | startswith($prefix));
        (.number | type == "number" and . >= 1 and . == floor) and
        (.head.ref | type == "string") and
        (.head.sha | type == "string" and test("^[0-9a-f]{40}$")) and
        (.head.repo.full_name | type == "string") and
        (.base.ref | type == "string"))
    ' "$prs" >/dev/null || ! jq -e '
      all(.[]; (.ref | type == "string") and
        (.object.sha | type == "string" and test("^[0-9a-f]{40}$")))
    ' "$refs" >/dev/null; then
      echo "::error::governed pin ownership changed during reconciliation" >&2
      rm -f "$prs" "$refs"
      return 1
    fi

    retired_visible=false
    current_count=0
    if ! rows=$(jq -r --arg prefix 'sync/governed-workflow-pins-' '
      .[] | select(.head.ref | startswith($prefix)) |
      [.number, .head.ref, .head.sha, .head.repo.full_name, .base.ref] | @tsv
    ' "$prs"); then
      echo "::error::could not extract settling governed pin PR ownership" >&2
      rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
      return 1
    fi
    while IFS=$'\t' read -r number ref expected_oid head_repo base_ref; do
      [ -n "$number" ] || continue
      if [ "$head_repo" != "$repository" ] || [ "$base_ref" != main ]; then
        echo "::error::governed pin PR does not belong to protected main" >&2
        rm -f "$prs" "$refs"
        return 1
      fi
      if [ "$ref" = "$branch" ]; then
        current_count=$((current_count + 1))
        if [ "$current_count" -gt 1 ]; then
          echo "::error::multiple governed pin PRs claim the current owner" >&2
          rm -f "$prs" "$refs"
          return 1
        fi
        continue
      fi
      printf -v retired_row '%s\t%s\t%s' "$number" "$ref" "$expected_oid"
      if grep -Fqx -- "$retired_row" "$retired_prs"; then
        retired_visible=true
        continue
      fi
      if classify_owner "$ref"; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -ne 0 ]; then
        rm -f "$prs" "$refs"
        return "$rc"
      fi
      echo "::error::an unseen governed pin PR appeared during reconciliation" >&2
      rm -f "$prs" "$refs"
      return 1
    done <<<"$rows"

    if ! rows=$(jq -r --arg branch "refs/heads/${branch}" \
      '.[] | select(.ref != $branch) | [.ref, .object.sha] | @tsv' "$refs"); then
      echo "::error::could not extract settling governed pin ref ownership" >&2
      rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
      return 1
    fi
    while IFS=$'\t' read -r ref expected_oid; do
      [ -n "$ref" ] || continue
      printf -v retired_row '%s\t%s' "$ref" "$expected_oid"
      if grep -Fqx -- "$retired_row" "$retired_refs"; then
        retired_visible=true
        continue
      fi
      full_ref="$ref"
      ref="${ref#refs/heads/}"
      if classify_owner "$ref"; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -ne 0 ]; then
        rm -f "$prs" "$refs"
        return "$rc"
      fi
      echo "::error::an unseen governed pin ref appeared during reconciliation: $full_ref" >&2
      rm -f "$prs" "$refs"
      return 1
    done <<<"$rows"

    if [ "$settle_required" = false ]; then
      break
    fi
    if [ "$retired_visible" = true ]; then
      clear_sweeps=0
    else
      clear_sweeps=$((clear_sweeps + 1))
    fi
    if [ "$clear_sweeps" -ge 2 ]; then
      break
    fi
    if [ "$settle_attempt" -ge 6 ]; then
      echo "::error::retired governed pin ownership did not settle after six inventories" >&2
      rm -f "$prs" "$refs"
      return 1
    fi
    echo "[WAIT] governed pin ownership visibility is not confirmed (${settle_attempt}/6)"
    if ! sleep "$settle_delay"; then
      echo "::error::governed pin ownership settling delay was interrupted" >&2
      rm -f "$prs" "$refs"
      return 1
    fi
    settle_attempt=$((settle_attempt + 1))
    settle_delay=$((settle_delay * 2))
    if [ "$settle_delay" -gt 4 ]; then settle_delay=4; fi
  done
  reconciled_pin_pr_number=""
  reconciled_pin_pr_head_oid=""
  current_count=0
  if ! rows=$(jq -r --arg prefix 'sync/governed-workflow-pins-' '
    .[] | select(.head.ref | startswith($prefix)) |
    [.number, .head.ref, .head.sha, .head.repo.full_name, .base.ref] | @tsv
  ' "$prs"); then
    echo "::error::could not extract reconciled governed pin PR ownership" >&2
    rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
    return 1
  fi
  while IFS=$'\t' read -r number ref expected_oid head_repo base_ref; do
    [ -n "$number" ] || continue
    if [ "$head_repo" != "$repository" ] || [ "$base_ref" != main ]; then
      echo "::error::governed pin PR does not belong to protected main" >&2
      rm -f "$prs" "$refs"
      return 1
    fi
    if [[ ! "$ref" =~ ^sync/governed-workflow-pins-[0-9a-f]{12}-([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
      echo "::error::unrecognized governed pin automation branch" >&2
      rm -f "$prs" "$refs"
      return 1
    fi
    if [ "$ref" != "$branch" ]; then
      echo "::error::another governed pin owner remains mergeable" >&2
      rm -f "$prs" "$refs"
      return 1
    fi
    current_count=$((current_count + 1))
    reconciled_pin_pr_number="$number"
    reconciled_pin_pr_head_oid="$expected_oid"
  done <<<"$rows"
  if [ "$current_count" -gt 1 ]; then
    echo "::error::multiple governed pin PRs claim the current owner" >&2
    rm -f "$prs" "$refs"
    return 1
  fi
  if ! rows=$(jq -r '.[] | [.ref, .object.sha] | @tsv' "$refs"); then
    echo "::error::could not extract reconciled governed pin ref ownership" >&2
    rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
    return 1
  fi
  while IFS=$'\t' read -r ref expected_oid; do
    [ -n "$ref" ] || continue
    if [ "$ref" != "refs/heads/${branch}" ]; then
      echo "::error::another governed pin owner remains published" >&2
      rm -f "$prs" "$refs"
      return 1
    fi
  done <<<"$rows"
  rm -f "$prs" "$refs" "$retired_prs" "$retired_refs"
}

assert_local_commit() {
  local parent count paths path
  if ! head_oid=$(git rev-parse HEAD) || ! parent=$(git rev-parse HEAD^) ||
    ! count=$(git rev-list --count "${base_oid}..HEAD") ||
    ! paths=$(git diff --name-only "${base_oid}..HEAD"); then
    echo "::error::could not inspect governed pin commit" >&2
    return 1
  fi
  if ! is_sha "$head_oid" || [ "$parent" != "$base_oid" ] || [ "$count" -ne 1 ] ||
    [ -z "$paths" ]; then
    echo "::error::governed pin branch is not one exact current-base commit" >&2
    return 1
  fi
  while IFS= read -r path; do
    if [[ ! "$path" =~ ^workflows/[^/]+\.ya?ml$ ]] &&
      [ "$path" != .github/config/governed-workflow-pin.json ]; then
      echo "::error::governed pin commit contains an unexpected path" >&2
      return 1
    fi
  done <<<"$paths"
}

assert_strict_protection() {
  local strict
  if ! strict=$(gh api \
    "repos/${repository}/branches/main/protection/required_status_checks" \
    --jq '.strict'); then
    echo "::error::could not verify protected-main status-check strictness" >&2
    return 1
  fi
  if [ "$strict" != true ]; then
    echo "::error::protected main must require up-to-date checks before auto-merge" >&2
    return 1
  fi
}

cleanup_current_owner() {
  local pr_number="${1:-}"
  if [ -n "$pr_number" ] && ! gh pr close "$pr_number" --repo "$repository" \
    --comment "Closed because protected main advanced before exact merge."; then
    return 1
  fi
  delete_remote_branch "$branch" "$head_oid"
}

main() {
  local target_rc pr_url pr_number created_pr_number pr_json update_output update_summary
  if ! is_sha "$target_revision"; then
    echo "::error::revision must be a full lowercase 40-character commit SHA" >&2
    return 1
  fi
  if ! printf '%s' "$repository" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ||
    ! printf '%s' "$run_id" | grep -qE '^[1-9][0-9]*$' ||
    ! printf '%s' "$run_attempt" | grep -qE '^[1-9][0-9]*$'; then
    echo "::error::invalid repository or workflow-run identity" >&2
    return 1
  fi
  if ! work=$(mktemp -d); then
    echo "::error::could not allocate governed pin updater workspace" >&2
    return 1
  fi
  trap 'rm -rf "$work"' EXIT
  workflow_list="$work/workflows"
  update_output="$work/update-output"

  if ! fetch_main; then return 1; fi
  base_oid="$current_main_oid"
  branch="sync/governed-workflow-pins-${target_revision:0:12}-${run_id}-${run_attempt}"
  if ! git switch -c "$branch" "$base_oid"; then
    echo "::error::could not create exact governed pin branch" >&2
    return 1
  fi
  if ! python3 scripts/update_governed_workflow_pins.py \
    --revision "$target_revision" >"$update_output"; then
    echo "::error::could not render governed workflow pins" >&2
    return 1
  fi
  cat "$update_output"
  if ! update_summary=$(head -n 1 "$update_output") ||
    ! printf '%s' "$update_summary" |
    grep -qE "^updated [0-9]+ file\(s\) to docs-control@${target_revision}$"; then
    echo "::error::governed pin renderer returned an invalid receipt" >&2
    return 1
  fi
  tail -n +2 "$update_output" >"$workflow_list"

  set +e
  assert_target_current "$base_oid"
  target_rc=$?
  set -e
  if [ "$target_rc" -eq 75 ]; then return 0; fi
  [ "$target_rc" -eq 0 ] || return "$target_rc"

  set +e
  reconcile_pin_prs
  target_rc=$?
  set -e
  if [ "$target_rc" -eq 75 ]; then return 0; fi
  [ "$target_rc" -eq 0 ] || return "$target_rc"

  git config user.email "github-actions[bot]@users.noreply.github.com"
  git config user.name "github-actions[bot]"
  git add workflows/ .github/config/governed-workflow-pin.json
  if git diff --cached --quiet; then
    echo "Governed callers already use docs-control@$target_revision"
    return 0
  fi
  if ! git commit -m "chore(governance): roll reusable workflow pins"; then
    return 1
  fi
  if ! assert_local_commit; then return 1; fi

  set +e
  assert_target_current "$base_oid"
  target_rc=$?
  set -e
  if [ "$target_rc" -eq 75 ]; then return 0; fi
  [ "$target_rc" -eq 0 ] || return "$target_rc"
  set +e
  reconcile_pin_prs
  target_rc=$?
  set -e
  if [ "$target_rc" -eq 75 ]; then return 0; fi
  [ "$target_rc" -eq 0 ] || return "$target_rc"

  if ! git push -u origin "$branch"; then
    echo "::error::could not publish unique governed pin branch" >&2
    return 1
  fi

  set +e
  assert_target_current "$base_oid"
  target_rc=$?
  set -e
  if [ "$target_rc" -eq 75 ]; then
    cleanup_current_owner
    return 0
  fi
  [ "$target_rc" -eq 0 ] || return "$target_rc"

  set +e
  reconcile_pin_prs
  target_rc=$?
  set -e
  if [ "$target_rc" -eq 75 ]; then
    cleanup_current_owner
    return 0
  fi
  [ "$target_rc" -eq 0 ] || return "$target_rc"

  pr_number="$reconciled_pin_pr_number"
  created_pr_number=""
  if [ -z "$pr_number" ]; then
    if ! pr_url=$(gh pr create \
      --repo "$repository" \
      --base main \
      --head "$branch" \
      --title "chore(governance): roll reusable workflow pins" \
      --body "Automated immutable pin update to docs-control@$target_revision."); then
      echo "::error::could not create governed pin PR" >&2
      return 1
    fi
    pr_number="${pr_url##*/}"
    created_pr_number="$pr_number"
    if ! printf '%s' "$created_pr_number" | grep -qE '^[1-9][0-9]*$'; then
      echo "::error::could not resolve governed pin PR number" >&2
      return 1
    fi
  fi

  set +e
  assert_target_current "$base_oid"
  target_rc=$?
  set -e
  if [ "$target_rc" -eq 75 ]; then
    cleanup_current_owner "$pr_number"
    return 0
  fi
  [ "$target_rc" -eq 0 ] || return "$target_rc"
  set +e
  reconcile_pin_prs
  target_rc=$?
  set -e
  if [ "$target_rc" -eq 75 ]; then
    cleanup_current_owner "$pr_number"
    return 0
  fi
  [ "$target_rc" -eq 0 ] || return "$target_rc"
  if [ -z "$reconciled_pin_pr_number" ] ||
    [ "$reconciled_pin_pr_number" != "$pr_number" ] ||
    [ "$reconciled_pin_pr_head_oid" != "$head_oid" ] ||
    { [ -n "$created_pr_number" ] &&
      [ "$reconciled_pin_pr_number" != "$created_pr_number" ]; }; then
    echo "::error::governed pin PR identity changed after selection" >&2
    return 1
  fi

  if ! pr_json=$(gh pr view "$pr_number" --repo "$repository" \
    --json baseRefName,baseRefOid,headRefName,headRefOid,files,commits); then
    echo "::error::could not verify governed pin PR" >&2
    return 1
  fi
  if ! printf '%s' "$pr_json" | jq -e \
    --arg branch "$branch" --arg head "$head_oid" --arg base "$base_oid" '
      .baseRefName == "main" and .baseRefOid == $base and
      .headRefName == $branch and .headRefOid == $head and
      (.commits | length) == 1 and (.files | length) > 0 and
      all(.files[]; (.path | test("^workflows/[^/]+\\.ya?ml$")) or
        .path == ".github/config/governed-workflow-pin.json")
    ' >/dev/null; then
    echo "::error::governed pin PR contains unexpected base, history, or files" >&2
    return 1
  fi
  if ! assert_strict_protection; then return 1; fi

  set +e
  assert_target_current "$base_oid"
  target_rc=$?
  set -e
  if [ "$target_rc" -eq 75 ]; then
    cleanup_current_owner "$pr_number"
    return 0
  fi
  [ "$target_rc" -eq 0 ] || return "$target_rc"
  if ! gh pr merge "$pr_number" --repo "$repository" \
    --squash --auto --delete-branch; then
    echo "::error::could not enable exact governed pin auto-merge" >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
