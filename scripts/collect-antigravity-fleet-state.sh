#!/usr/bin/env bash
# Collect exact-head fleet state and bounded recovery dispatches.
set -euo pipefail
output="$RUNNER_TEMP/fleet-watch"
mkdir -p "$output/failures"
jq -n '[]' >"$output/receipts.json"
jq -n '[]' >"$output/dispatches.json"
github_get() {
  node scripts/github-api-resilience.cjs get "$@"
}
cutoff=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
jq -r '.[]' .github/config/downstream-repos.json | {
  printf '%s\n' docs-control
  cat
} | while IFS= read -r repo; do
  full_repo="$GITHUB_REPOSITORY_OWNER/$repo"
  echo "[PROGRESS] repository $full_repo: collecting exact-head state"
  pulls=$(github_get "repos/$full_repo/pulls?state=all&sort=updated&direction=desc&per_page=30")
  recent_runs=$(github_get "repos/$full_repo/actions/runs?per_page=100")
  jq -c --arg cutoff "$cutoff" '.[] | select(.updated_at >= $cutoff)' <<<"$pulls" |
    while IFS= read -r pull; do
      number=$(jq -r .number <<<"$pull")
      state=$(jq -r .state <<<"$pull")
      base_sha=$(jq -r .base.sha <<<"$pull")
      base_ref=$(jq -r .base.ref <<<"$pull")
      head_sha=$(jq -r .head.sha <<<"$pull")
      head_repo=$(jq -r '.head.repo.full_name // ""' <<<"$pull")
      [ "$head_repo" = "$full_repo" ] || continue

      marker="<!-- agy-workflow-receipt:$head_sha -->"
      comments=$(github_get "repos/$full_repo/issues/$number/comments?per_page=100" \
        --paginate)
      if jq -e --arg marker "$marker" 'any(.[]; .body | contains($marker))' \
        <<<"$comments" >/dev/null; then
        hasReceipt=true
      else
        hasReceipt=false
      fi
      review_marker="<!-- antigravity-pr-review:$head_sha -->"
      if jq -e --arg marker "$review_marker" 'any(.[]; .body | contains($marker))' \
        <<<"$comments" >/dev/null; then
        hasReviewReceipt=true
      else
        hasReviewReceipt=false
      fi

      review_title="Antigravity review PR $number @ $head_sha"
      exact_review=$(jq -c --arg title "$review_title" \
        '[.workflow_runs[] | select(.display_title == $title)] | first // null' \
        <<<"$recent_runs")

      reviewNeedsRecovery=false
      if [ "$hasReviewReceipt" = false ]; then
        if [ "$exact_review" = null ]; then
          reviewNeedsRecovery=true
        elif [ "$(jq -r .status <<<"$exact_review")" = completed ]; then
          reviewNeedsRecovery=true
        fi
      fi



      queued=false
      if [ "$state" = open ] &&
        [ "${REVIEW_ENABLED:-false}" = true ] && [ "$reviewNeedsRecovery" = true ]; then
        prior_run_id=$(jq -r 'if . == null then 0 else .id end' <<<"$exact_review")
        jq --arg repository "$full_repo" --arg workflow antigravity-review.yml \
          --arg ref "$base_ref" --arg number "$number" --arg base "$base_sha" \
          --arg head "$head_sha" --argjson prior_run_id "$prior_run_id" \
          '. + [{repository: $repository, workflow: $workflow, ref: $ref,
            pr_number: $number, base_sha: $base, head_sha: $head,
            prior_run_id: $prior_run_id}]' \
          "$output/dispatches.json" >"$output/dispatches.next"
        mv "$output/dispatches.next" "$output/dispatches.json"
        queued=true
      fi
      [ "$queued" = false ] || continue
      [ "$hasReceipt" = false ] || continue

      head_runs=$(jq -c --arg head "$head_sha" \
        '[.workflow_runs[] | select(.head_sha == $head and
          (.event == "pull_request" or .event == "pull_request_target"))]' \
        <<<"$recent_runs")
      if [ "$exact_review" != null ]; then
        head_runs=$(jq -c --argjson run "$exact_review" '. + [$run] | unique_by(.id)' \
          <<<"$head_runs")
      elif [ "${REVIEW_ENABLED:-false}" = true ] &&
        [ "$state" = open ]; then
        continue
      fi

      check_runs=$(github_get \
        "repos/$full_repo/commits/$head_sha/check-runs?per_page=100")
      combined=$(github_get "repos/$full_repo/commits/$head_sha/status")
      signal_count=$(jq 'length' <<<"$head_runs")
      signal_count=$((signal_count + $(jq '.total_count' <<<"$check_runs")))
      signal_count=$((signal_count + $(jq '.statuses | length' <<<"$combined")))
      [ "$signal_count" -gt 0 ] || continue

      if jq -e 'any(.[]; .status != "completed")' <<<"$head_runs" >/dev/null ||
        jq -e 'any(.check_runs[]; .status != "completed")' <<<"$check_runs" >/dev/null ||
        [ "$(jq -r .state <<<"$combined")" = pending ]; then
        continue
      fi

      failed_runs=$(jq -c '[.[] | select(
        (.conclusion // "failure") as $c |
        ($c != "success" and $c != "skipped" and $c != "neutral"))]' <<<"$head_runs")
      failed_checks=$(jq -c '[.check_runs[] | select(
        (.conclusion // "failure") as $c |
        ($c != "success" and $c != "skipped" and $c != "neutral")) |
        {name, conclusion, html_url}]' <<<"$check_runs")
      failed_statuses=$(jq -c '[.statuses[] | select(.state == "error" or .state == "failure") |
        {context, state, target_url}]' <<<"$combined")
      failure_count=$(jq 'length' <<<"$failed_runs")
      failure_count=$((failure_count + $(jq 'length' <<<"$failed_checks")))
      failure_count=$((failure_count + $(jq 'length' <<<"$failed_statuses")))
      if [ "$failure_count" -gt 0 ]; then outcome=failure; else outcome=success; fi

      jq --arg repository "$full_repo" --argjson pr "$number" --arg state "$state" \
        --arg base "$base_sha" --arg head "$head_sha" --arg outcome "$outcome" \
        --argjson runs "$head_runs" --argjson checks "$failed_checks" \
        --argjson statuses "$failed_statuses" '. + [{repository: $repository,
          pull_request: $pr, pull_request_state: $state, base_sha: $base,
          head_sha: $head, outcome: $outcome,
          workflow_runs: ($runs | map({id, name, display_title, status, conclusion, html_url})),
          failed_checks: $checks, failed_statuses: $statuses}]' \
        "$output/receipts.json" >"$output/receipts.next"
      mv "$output/receipts.next" "$output/receipts.json"

      if [ "$failure_count" -gt 0 ]; then
        jq -c '.[]' <<<"$failed_runs" | while IFS= read -r run; do
          run_id=$(jq -r .id <<<"$run")
          run_name=$(jq -r .name <<<"$run" | tr -cd 'A-Za-z0-9_.-')
          log="$output/failures/${repo}-${number}-${run_id}-${run_name}.log"
          {
            jq -n --arg repository "$full_repo" --argjson pull_request "$number" \
              --arg head_sha "$head_sha" --arg workflow "$(jq -r .name <<<"$run")" \
              --argjson run_id "$run_id" \
              '{repository: $repository, pull_request: $pull_request,
                head_sha: $head_sha, workflow: $workflow, run_id: $run_id}'
            gh run view "$run_id" -R "$full_repo" --log-failed || true
          } | python3 scripts/redact_automation_log.py >"$log"
        done
      fi
    done
done
if find "$output/failures" -type f -size +0c | grep -q .; then
  echo 'has_failures=true' >>"$GITHUB_OUTPUT"
else
  echo 'has_failures=false' >>"$GITHUB_OUTPUT"
fi
