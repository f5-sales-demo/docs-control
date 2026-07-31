#!/usr/bin/env bash
# Verify every required status context is one that real pull requests actually report.
#
# Why this is a live check and not a unit test:
#
# tests/test-linter-configs.sh section 7d can only reject names it was told about.
# The workflows those names refer to live in independently changing repositories, so
# a rename, a typo, or a newly added workflow-level `paths:` filter passes that test,
# and then enforce-repo-settings installs a required context that never reports. With
# `enforce_admins: true`, ordinary merging in that repository stops until somebody
# repairs branch protection by hand.
#
# docs-control#862 says the same of its own acceptance criteria: "A context name that
# does not match any job silently requires nothing — the same failure mode as the gap
# itself. Whatever lands should be verified by opening a throwaway PR per repo and
# confirming the check actually blocks, not by reading the config back."
#
# Why it reads check runs rather than workflow YAML:
#
# A check's name can come from a job's `name:`, from the job id when `name:` is
# absent, from a matrix expansion ("Test (ubuntu-latest)"), or from a reusable
# workflow's nested job ("lint / Shell Unit Tests"). Parsing YAML to predict all four
# produces false positives — an earlier version of this script reported `xcsh`'s
# `check` and `test` as missing when both demonstrably run. Asking GitHub what it
# actually reported on a recent pull request has no such ambiguity.
#
# What deadlocks a required check, per GitHub's "Troubleshooting required status
# checks": a *job* skipped by a conditional reports "Success" and is safe to require;
# a *workflow* skipped by path, branch or commit-message filtering leaves the context
# "Pending" forever and is never safe to require. A context that appears on some pull
# requests but not others is the second case, which is why this samples more than one.
#
# Usage: bash scripts/verify-required-contexts.sh [repo ...]
# Requires: gh (authenticated), jq. Read-only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$REPO_ROOT/.github/config/repo-settings.json"
OWNER="f5-sales-demo"
SAMPLE=5        # recent PRs to inspect per repo
MIN_SAMPLES=3   # below this the evidence is inconclusive, not clean
MAX_AGE_DAYS=30 # newest sample older than this predates current workflows

PROBLEMS=0
CHECKED=0

if [ "$#" -gt 0 ]; then
  REPOS="$*"
  # An explicitly named repository with nothing to check is almost always a typo, and
  # silently reporting "0 problems" for it is the same failure this script exists to
  # remove. Reject it before any work starts.
  for arg in "$@"; do
    if ! jq -e --arg r "$arg" '.repo_overrides[$r].additional_contexts // empty' "$SETTINGS" >/dev/null 2>&1; then
      echo "ERROR: '$arg' has no additional_contexts in $SETTINGS — nothing to verify." >&2
      echo "       Known: $(jq -r '.repo_overrides | to_entries[] | select(.value.additional_contexts) | .key' "$SETTINGS" | tr '\n' ' ')" >&2
      exit 2
    fi
  done
else
  REPOS=$(jq -r '.repo_overrides | to_entries[] | select(.value.additional_contexts) | .key' "$SETTINGS")
  if [ -z "$REPOS" ]; then
    echo "ERROR: no repository declares additional_contexts — refusing to report success." >&2
    exit 2
  fi
fi

for repo in $REPOS; do
  contexts=$(jq -r --arg r "$repo" '.repo_overrides[$r].additional_contexts // [] | .[]' "$SETTINGS")
  [ -z "$contexts" ] && continue

  echo "=== $repo ==="

  # Collect the union of check-run names GitHub reported across the sampled pull
  # requests, and count how many PRs each name appeared on.
  # Exclude pull requests with merge conflicts. A `pull_request` workflow runs
  # against refs/pull/N/merge, which GitHub cannot create when the merge is
  # impossible, so none of those workflows start and none of their contexts report.
  # `pull_request_target` workflows use the base ref and run anyway, which is why a
  # conflicting PR still shows "Check linked issues" and nothing else. Sampling one
  # of those makes every ordinary context look intermittent — it cost an
  # investigation here before the cause was clear. It is also harmless in practice:
  # a conflicting PR cannot merge until the conflict is resolved, and resolving it
  # makes the workflows run.
  # `mergeable` from the list endpoint is computed lazily and frequently returns
  # UNKNOWN, so filtering on it alone lets a conflicting PR through — which then looks
  # like a genuinely intermittent context, because none of its `pull_request`
  # workflows ever ran. Ask per pull request, where GitHub resolves the value, and
  # reject on either field.
  candidates=$(gh pr list -R "$OWNER/$repo" --state all --limit $((SAMPLE * 4)) \
    --json number -q '.[].number' 2>/dev/null)
  shas=""
  kept=0
  while IFS= read -r num; do
    [ -z "$num" ] && continue
    [ "$kept" -ge "$SAMPLE" ] && break
    info=$(gh pr view "$num" -R "$OWNER/$repo" --json mergeable,mergeStateStatus,headRefOid \
      -q '"\(.mergeable)|\(.mergeStateStatus)|\(.headRefOid)"' 2>/dev/null)
    [ -z "$info" ] && continue
    case "$info" in
    CONFLICTING\|* | *\|DIRTY\|*) continue ;;
    esac
    shas="${shas}${info##*|}
"
    kept=$((kept + 1))
  done <<<"$candidates"
  shas=$(printf '%s' "$shas" | sed '/^$/d')
  if [ -z "$shas" ]; then
    echo "  UNREADABLE: no pull requests found to sample"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi

  pr_count=0
  names_file=$(mktemp)
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    pr_count=$((pr_count + 1))
    {
      gh api "repos/$OWNER/$repo/commits/$sha/check-runs" --paginate \
        -q '.check_runs[].name' 2>/dev/null
      gh api "repos/$OWNER/$repo/commits/$sha/status" \
        -q '.statuses[].context' 2>/dev/null
    } | sort -u
  done <<<"$shas" >"$names_file"

  # Evidence has to be both sufficient and current, and "insufficient" must not read
  # as "verified". Old pull requests keep reporting whatever their contemporary
  # workflows produced, so a job renamed, deleted, or moved off main last month still
  # looks healthy in commits from before the change — and pass 2 only detects path
  # filters, not disappearance. A single ancient sample would certify an impossible
  # required check, which branch protection then installs.
  newest=$(printf '%s\n' "$shas" | head -1)
  newest_date=$(gh api "repos/$OWNER/$repo/commits/$newest" -q '.commit.committer.date' 2>/dev/null)
  age_days=""
  if [ -n "$newest_date" ]; then
    now=$(date -u +%s)
    then_ts=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$newest_date" +%s 2>/dev/null ||
      date -u -d "$newest_date" +%s 2>/dev/null || echo "")
    [ -n "$then_ts" ] && age_days=$(((now - then_ts) / 86400))
  fi

  if [ "$pr_count" -lt "$MIN_SAMPLES" ]; then
    echo "  INCONCLUSIVE: only $pr_count non-conflicting PR(s) available, need $MIN_SAMPLES — cannot certify this repo"
    PROBLEMS=$((PROBLEMS + 1))
    rm -f "$names_file"
    continue
  fi
  if [ -n "$age_days" ] && [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
    echo "  INCONCLUSIVE: newest sampled PR is ${age_days}d old (limit ${MAX_AGE_DAYS}d) — evidence predates current workflows"
    PROBLEMS=$((PROBLEMS + 1))
    rm -f "$names_file"
    continue
  fi

  # An absolute age limit is not enough. What matters is whether the evidence
  # postdates the workflow definitions it is meant to certify: if a job was renamed
  # or deleted after the sampled runs, every sample still carries the old name, pass 2
  # cannot see a disappearance, and the script would exit clean while branch
  # protection installs a permanently pending context. Compare the newest sample
  # against the last change to .github/workflows/ and refuse to certify evidence that
  # is older.
  wf_changed=$(gh api "repos/$OWNER/$repo/commits?path=.github/workflows&per_page=1" \
    -q '.[0].commit.committer.date' 2>/dev/null)
  if [ -z "$wf_changed" ]; then
    echo "  INCONCLUSIVE: cannot read the last change to .github/workflows/ — cannot prove evidence is current"
    PROBLEMS=$((PROBLEMS + 1))
    rm -f "$names_file"
    continue
  fi
  wf_ts=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$wf_changed" +%s 2>/dev/null ||
    date -u -d "$wf_changed" +%s 2>/dev/null || echo "")
  if [ -n "$wf_ts" ] && [ -n "${then_ts:-}" ] && [ "$then_ts" -lt "$wf_ts" ]; then
    echo "  INCONCLUSIVE: newest sample ($newest_date) predates the last workflow change ($wf_changed)"
    echo "      a job renamed or removed in that change would still appear in these runs; open a fresh PR and re-run"
    PROBLEMS=$((PROBLEMS + 1))
    rm -f "$names_file"
    continue
  fi

  while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    CHECKED=$((CHECKED + 1))
    seen=$(grep -cxF "$ctx" "$names_file" || true)

    if [ "$seen" -eq 0 ]; then
      echo "  NEVER REPORTED   $ctx — absent from all $pr_count sampled PRs; requiring it blocks every merge"
      PROBLEMS=$((PROBLEMS + 1))
    elif [ "$seen" -lt "$pr_count" ]; then
      echo "  INTERMITTENT     $ctx — reported on $seen of $pr_count PRs; a workflow filter can leave it Pending"
      PROBLEMS=$((PROBLEMS + 1))
    else
      echo "  ok               $ctx (reported on all $pr_count sampled PRs)"
    fi
  done <<<"$contexts"

  rm -f "$names_file"
done

echo ""
echo "── Pass 2: workflow-level filters ─────────────────────────────────────"
echo ""
# Sampling recent pull requests answers "does this name resolve to something that
# reports", but it cannot prove "always". If every sampled PR happened to satisfy a
# workflow's path filter, the context looks healthy and the next PR outside those
# paths is blocked permanently. Samples can also predate the current workflow.
#
# That specific class is statically decidable, and unlike job existence it carries no
# naming ambiguity: a `paths:`/`paths-ignore:` filter under a workflow's
# `pull_request:` trigger means the workflow can fail to start for reasons unrelated
# to the code. So scan the other direction — find the filtered workflows first, then
# flag any required context that maps onto a job they declare.
#
# The two passes are complementary. Pass 1 catches names that resolve to nothing;
# pass 2 catches names that resolve to something which can decline to run at all.
for repo in $REPOS; do
  contexts=$(jq -r --arg r "$repo" '.repo_overrides[$r].additional_contexts // [] | .[]' "$SETTINGS")
  [ -z "$contexts" ] && continue

  # Fail loudly on API trouble. Skipping quietly would let pass 2 examine nothing
  # while pass 1 still succeeds from historical samples, reporting a clean scan for a
  # repository nobody actually looked at — the failure mode this script exists to
  # remove, reintroduced one level up.
  wf_list=$(gh api "repos/$OWNER/$repo/contents/.github/workflows" -q '.[].name' 2>/dev/null)
  if [ -z "$wf_list" ]; then
    echo "  $repo: UNREADABLE — cannot list .github/workflows; pass 2 did NOT run for this repo"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi

  while IFS= read -r wf; do
    [ -z "$wf" ] && continue
    body=$(gh api "repos/$OWNER/$repo/contents/.github/workflows/$wf" -q .content 2>/dev/null |
      base64 -d 2>/dev/null)
    if [ -z "$body" ]; then
      echo "  $repo: UNREADABLE — cannot fetch or decode $wf; it was NOT checked for path filters"
      PROBLEMS=$((PROBLEMS + 1))
      continue
    fi

    # Is the pull_request trigger path-filtered? Read only the `on:` block so a
    # `paths` key elsewhere (a step input, for instance) cannot false-positive.
    filtered=$(printf '%s' "$body" | awk '
      /^on:/                            { inon = 1; next }
      inon && /^[^[:space:]#]/          { exit }
      inon && /pull_request:?/          { inpr = 1; next }
      inpr && /^[[:space:]]{2}[a-z_]+:/ { inpr = 0 }
      inpr && /paths(-ignore)?:/        { print "yes"; exit }
    ')
    [ -z "$filtered" ] && continue

    # Job names this filtered workflow declares, both explicit `name:` and job ids.
    declared=$(printf '%s' "$body" | awk '
      /^jobs:/                                   { injobs = 1; next }
      injobs && /^[[:space:]]{2}[A-Za-z0-9_-]+:/ { gsub(/[[:space:]:]/, ""); print }
      injobs && /^[[:space:]]{4}name:/           { sub(/^[[:space:]]*name:[[:space:]]*/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print }
    ')

    while IFS= read -r ctx; do
      [ -z "$ctx" ] && continue

      # A qualified context "caller / nested" is reported by a job inside a reusable
      # workflow, so only the caller appears in this repository's workflow file. Match
      # either segment: the nested name catches an ordinary job, and the caller name
      # catches the case where a filtered workflow is the one doing the calling —
      # `lint / Shell Unit Tests` would otherwise evade this entirely, because
      # `Shell Unit Tests` is declared in the reusable workflow, not the caller.
      nested="${ctx##*/ }"
      caller="${ctx%% / *}"
      hit=""
      printf '%s\n' "$declared" | grep -qxF "$nested" && hit="$nested"
      if [ -z "$hit" ] && [ "$caller" != "$ctx" ]; then
        printf '%s\n' "$declared" | grep -qxF "$caller" && hit="$caller (caller job)"
      fi

      if [ -n "$hit" ]; then
        echo "  $repo: PATHS-FILTERED  $ctx — matched '$hit' in $wf, whose pull_request trigger is path-filtered"
        echo "      a PR touching none of those paths never starts it, so the context stays Pending forever"
        PROBLEMS=$((PROBLEMS + 1))
      fi
    done <<<"$contexts"
  done <<<"$wf_list"
done
echo "  (no output above means no required context is declared by a path-filtered workflow)"

echo ""
echo "checked $CHECKED context(s) against real check runs, $PROBLEMS problem(s)"
[ "$PROBLEMS" -eq 0 ]
