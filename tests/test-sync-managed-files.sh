#!/usr/bin/env bash
# Assertions on how sync-managed-files updates an existing sync PR.
#
# When drift is found and a sync PR is already open, the branch has to be
# rebased onto main so the PR diff shows only managed files rather than
# reverting whatever landed in between. Doing that as a standalone force-reset
# to main's SHA empties the PR: for the interval between the reset and the
# follow-up commit the branch IS main, so the PR has zero commits ahead of
# base, and GitHub closes it and disables auto-merge. The content comes back on
# the next call, but a closed PR does not reopen (#836).
#
# The rebase and the commit therefore have to be a single ref update.
#
# Run from repo root: bash tests/test-sync-managed-files.sh
set -euo pipefail

PASS=0
FAIL=0
TESTS_RUN=0

pass() {
  PASS=$((PASS + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "  PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "  FAIL: $1 — $2"
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$REPO_ROOT/.github/workflows/sync-managed-files.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The branch of the drift handler that runs when a sync PR is already open.
awk '/if \[ -n "\$EXISTING_PR" \]; then/{f=1} f{print} f&&/^                else$/{exit}' \
  "$SYNC" >"$WORK/existing_pr_block.txt"

echo ""
echo "=== Section 1: the existing-PR path is present ==="

if [ -s "$WORK/existing_pr_block.txt" ]; then
  pass "1.1 located the existing-PR branch of the drift handler"
else
  fail "1.1 located the existing-PR branch of the drift handler" \
    "extraction produced nothing; the assertions below would be vacuous"
fi

if grep -q 'gh pr close' "$WORK/existing_pr_block.txt"; then
  pass "1.2 the existing-PR path retires the superseded automation PR"
else
  fail "1.2 the existing-PR path retires the superseded automation PR" \
    "the shared mutable PR remains in place"
fi

echo ""
echo "=== Section 2: the branch is never reset to main on its own ==="

# The defect: a PATCH of the sync branch ref carrying main's SHA, separate from
# the commit. Detected structurally rather than by message, so rewording the
# echo cannot hide it.
if grep -q 'refs/heads/governance/sync-managed-files.*--method PATCH' \
  "$WORK/existing_pr_block.txt"; then
  fail "2.1 no standalone reset of the sync branch to main's SHA" \
    "the existing-PR path force-updates the branch ref directly; that empties the PR and GitHub closes it (#836)"
else
  pass "2.1 no standalone reset of the sync branch to main's SHA"
fi

if grep -qE 'Rebased PR branch onto main HEAD' "$WORK/existing_pr_block.txt"; then
  fail "2.2 the emptying rebase step is gone" \
    "the standalone rebase echo is still present"
else
  pass "2.2 the emptying rebase step is gone"
fi

echo ""
echo "=== Section 3: replacement uses a unique non-destructive branch ==="

# A fixed automation branch requires a destructive force update to rebase an
# existing PR. Use a unique run-owned branch from current main instead: an
# unproved pre-existing branch can never be overwritten.
perl -0pe 's/\\\n\s*/ /g' "$WORK/existing_pr_block.txt" >"$WORK/existing_pr_joined.txt"

if grep -q 'SYNC_BRANCH=.*GITHUB_RUN_ID.*GITHUB_RUN_ATTEMPT' "$SYNC"; then
  pass "3.1 each sync transition owns a unique run branch"
else
  fail "3.1 each sync transition owns a unique run branch" \
    "the workflow still depends on a shared mutable automation branch"
fi

if grep -q 'gh pr close "$EXISTING_PR"' "$SYNC" &&
  grep -q -- '--comment "Superseded by exact managed-file receipt' "$SYNC"; then
  pass "3.2 a proved prior automation PR is closed before replacement"
else
  fail "3.2 a proved prior automation PR is closed before replacement" \
    "an existing mutable PR can still be force-rebased in place"
fi

if ! grep -qE '"force": *(true|\$force)|base_override' "$SYNC" &&
  grep -q -- '--base main' "$SYNC"; then
  pass "3.3 sync branch updates are non-force and PR base is explicit"
else
  fail "3.3 sync branch updates are non-force and PR base is explicit" \
    "force movement or an implicit PR base remains"
fi

echo ""
echo "=== Section 4: tree payloads are file-backed ==="

# File content and the cumulative tree can each exceed the runner's argument
# limits. Extract the actual payload helpers from the workflow so the stress
# test exercises production code instead of a test-only reimplementation.
awk '
  /^          # --- Helper: file-backed Git tree payloads/ { found=1 }
  found && /^          # --- Helper: atomic commit via Git Trees API/ { exit }
  found { sub(/^          /, ""); print }
' "$SYNC" >"$WORK/tree_payload_helpers.sh"

if [ -s "$WORK/tree_payload_helpers.sh" ]; then
  pass "4.1 located the file-backed tree payload helpers"
else
  fail "4.1 located the file-backed tree payload helpers" \
    "the workflow does not expose the production payload helpers"
fi

if grep -qE -- '--arg +content|--argjson +tree' "$SYNC"; then
  fail "4.2 managed content and cumulative trees never enter argv" \
    "commit_tree still passes a potentially unbounded payload through --arg or --argjson"
else
  pass "4.2 managed content and cumulative trees never enter argv"
fi

if grep -q -- '--rawfile content' "$SYNC" && grep -q -- '--slurpfile tree' "$SYNC"; then
  pass "4.3 jq reads managed content and cumulative trees from files"
else
  fail "4.3 jq reads managed content and cumulative trees from files" \
    "expected both --rawfile content and --slurpfile tree"
fi

if [ -s "$WORK/tree_payload_helpers.sh" ]; then
  # shellcheck source=/dev/null
  source "$WORK/tree_payload_helpers.sh"

  TREE_ITEMS="$WORK/tree-items.json"
  printf '[]\n' >"$TREE_ITEMS"
  LARGE_BYTES=262144
  LARGE_FILE_COUNT=10
  for index in $(seq 1 "$LARGE_FILE_COUNT"); do
    RAW_CONTENT="$WORK/raw-${index}.txt"
    NORMALIZED_CONTENT="$WORK/normalized-${index}.txt"
    # Each 256 KiB file exceeds Linux's usual per-argument MAX_ARG_STRLEN, and
    # the combined request exceeds its usual 2 MiB ARG_MAX. This succeeds only
    # when neither payload becomes an exec argument.
    dd if=/dev/zero bs="$LARGE_BYTES" count=1 2>/dev/null | tr '\0' X >"$RAW_CONTENT"
    if [ "$index" -eq 2 ]; then
      printf '\n\n' >>"$RAW_CONTENT"
    fi
    normalize_tree_content "$RAW_CONTENT" "$NORMALIZED_CONTENT"
    if [ $((index % 2)) -eq 0 ]; then
      FILE_MODE=100755
    else
      FILE_MODE=100644
    fi
    append_tree_item "$TREE_ITEMS" "fixtures/large-${index}.txt" "$FILE_MODE" "$NORMALIZED_CONTENT"
  done

  TREE_REQUEST="$WORK/tree-request.json"
  BASE_TREE="0123456789abcdef0123456789abcdef01234567"
  write_tree_request "$BASE_TREE" "$TREE_ITEMS" "$TREE_REQUEST"

  if jq -e \
    --arg base_tree "$BASE_TREE" \
    --argjson expected_count "$LARGE_FILE_COUNT" \
    --argjson expected_length "$((LARGE_BYTES + 1))" \
    '.base_tree == $base_tree and
     (.tree | length) == $expected_count and
     all(.tree[]; (.mode == "100644" or .mode == "100755") and .type == "blob") and
     ([.tree[].mode] == ["100644","100755","100644","100755","100644","100755","100644","100755","100644","100755"]) and
     all(.tree[]; (.content | length) == $expected_length) and
     all(.tree[]; .content | endswith("\n")) and
     (.tree[1].path == "fixtures/large-2.txt")' \
    "$TREE_REQUEST" >/dev/null; then
    pass "4.4 production helpers assemble multiple oversized entries exactly"
  else
    fail "4.4 production helpers assemble multiple oversized entries exactly" \
      "large entries, paths, or trailing-newline normalization were corrupted"
  fi
else
  fail "4.4 production helpers assemble multiple oversized entries exactly" \
    "payload helpers were unavailable for the stress test"
fi

echo ""
echo "=== Section 5: exact managed content fails closed ==="

if grep -qE 'fetch_governed.*(\|\| true|\|\| echo)' "$SYNC"; then
  fail "5.1 governed fetch failures are fatal" \
    "required canonical content fetches are suppressed"
else
  pass "5.1 governed fetch failures are fatal"
fi

if grep -q 'No cached content.*skipping' "$SYNC"; then
  fail "5.2 every drifted path must have cached canonical bytes" \
    "commit_tree silently skips drifted files with missing content"
else
  pass "5.2 every drifted path must have cached canonical bytes"
fi

if grep -qE '(canonical.*git hash-object|git hash-object.*canonical)' "$SYNC" &&
  grep -q 'Canonical blob mismatch' "$SYNC"; then
  pass "5.3 fetched managed bytes are checked against the manifest blob"
else
  fail "5.3 fetched managed bytes are checked against the manifest blob" \
    "cached managed content is not verified against its exact manifest entry"
fi

if grep -q 'Manifest entry missing or inconsistent' "$SYNC" &&
  ! grep -q 'falling back to per-file' "$SYNC"; then
  pass "5.4 missing manifest evidence fails closed"
else
  fail "5.4 missing manifest evidence fails closed" \
    "managed content can bypass the manifest receipt"
fi

if grep -Fq 'git/trees/${expected_source_sha}?recursive=1' "$SYNC" &&
  grep -Fq 'compare/${MANIFEST_COMMIT}...${expected_source_sha}' "$SYNC" &&
  grep -q 'truncated == false' "$SYNC" &&
  grep -q 'Exact source tree does not match the managed manifest' "$SYNC"; then
  pass "5.5 manifest bytes are proved against the requested commit tree"
else
  fail "5.5 manifest bytes are proved against the requested commit tree" \
    "manifest source_commit shape is accepted without exact-tree evidence"
fi

if grep -q '\.mode | type == "string"' "$SYNC" &&
  grep -q 'LOCAL_MODE' "$SYNC" &&
  grep -q 'CANONICAL_MODE' "$SYNC"; then
  pass "5.6 executable modes participate in drift detection"
else
  fail "5.6 executable modes participate in drift detection" \
    "blob-equal executable managed files can be silently demoted"
fi

MANIFEST_BUILDER="$REPO_ROOT/.github/workflows/build-managed-files-manifest.yml"
if grep -q 'git ls-files -s' "$MANIFEST_BUILDER" &&
  grep -q 'mode: \$mode' "$MANIFEST_BUILDER"; then
  pass "5.7 manifest publication records canonical Git modes"
else
  fail "5.7 manifest publication records canonical Git modes" \
    "manifest cannot carry executable-file identity"
fi

if ! grep -qE 'generated_at|date -u' "$MANIFEST_BUILDER"; then
  pass "5.8 manifest bytes contain no wall-clock data"
else
  fail "5.8 manifest bytes contain no wall-clock data" \
    "repeating the same source/configuration can publish different canonical bytes"
fi

echo ""
echo "=== Section 6: required PR transitions fail closed ==="

if grep -qE 'auto_merge .*\|\| true' "$SYNC"; then
  fail "6.1 managed-file auto-merge failures are fatal" \
    "a sync path suppresses the required auto-merge result"
else
  pass "6.1 managed-file auto-merge failures are fatal"
fi

if grep -q 'merge attempted' "$SYNC"; then
  fail "6.2 sync reports only confirmed auto-merge state" \
    "the workflow reports an attempt instead of the required confirmed transition"
else
  pass "6.2 sync reports only confirmed auto-merge state"
fi

if grep -qE 'gh pr merge .*\|\| true' "$MANIFEST_BUILDER"; then
  fail "6.3 manifest auto-merge failures are fatal" \
    "manifest publication suppresses failure while claiming auto-merge is enabled"
else
  pass "6.3 manifest auto-merge failures are fatal"
fi

perl -0pe 's/\\\n\s*/ /g' "$SYNC" >"$WORK/sync-joined.txt"
perl -0pe 's/\\\n\s*/ /g' "$MANIFEST_BUILDER" >"$WORK/manifest-joined.txt"

if grep -q 'gh pr list' "$WORK/sync-joined.txt" &&
  grep -qE -- '--head +"?governance/sync-managed-files' "$WORK/sync-joined.txt"; then
  fail "6.4 existing sync PR selection inventories ownership" \
    "gh pr list cannot express or prove same-repository head ownership"
elif grep -Fq 'pulls?state=open&per_page=100' "$SYNC" &&
  grep -q -- '--paginate --slurp' "$SYNC" &&
  grep -q 'head.repo.full_name' "$SYNC" &&
  grep -q 'base.ref' "$SYNC" &&
  grep -q 'head.sha' "$SYNC" &&
  grep -q 'Multiple open sync PRs' "$SYNC"; then
  pass "6.4 existing sync PR selection inventories ownership"
else
  fail "6.4 existing sync PR selection inventories ownership" \
    "same-name fork, base, exact head, or duplicate ownership is not proved"
fi

if grep -qE '(EXISTING_PR|STALE_ISSUES)=.*\|\| true|gh issue close .*\|\| true' \
  "$WORK/sync-joined.txt"; then
  fail "6.5 sync PR and issue inventory failures are fatal" \
    "required inventory or close errors are suppressed"
else
  pass "6.5 sync PR and issue inventory failures are fatal"
fi

if grep -q 'assert_sync_pr_head()' "$SYNC" &&
  [ "$(grep -Ec 'assert_sync_pr_head +"' "$WORK/sync-joined.txt")" -ge 2 ]; then
  pass "6.6 selected sync PR head is re-proved before auto-merge"
else
  fail "6.6 selected sync PR head is re-proved before auto-merge" \
    "existing and newly-created PR paths do not prove the branch commit"
fi

if grep -q 'BRANCH_LOOKUP_RC' "$SYNC" &&
  grep -q 'api_value_or_404.*git/ref/heads/${SYNC_BRANCH}' "$WORK/sync-joined.txt" &&
  ! grep -qE 'if ! retry_json .*git/refs.*--method POST' "$WORK/sync-joined.txt"; then
  pass "6.7 branch creation distinguishes absence from API failure"
else
  fail "6.7 branch creation distinguishes absence from API failure" \
    "any create error can still be treated as a proved existing branch"
fi

if grep -q 'managed_cache_path()' "$SYNC" &&
  grep -q 'git hash-object --stdin' "$SYNC" &&
  ! grep -q "tr '/' '__'" "$SYNC"; then
  pass "6.8 managed drift cache keys cannot collide on slash and underscore"
else
  fail "6.8 managed drift cache keys cannot collide on slash and underscore" \
    "destination paths still use a lossy cache-key encoding"
fi

if grep -q 'Duplicate managed-file destinations' "$MANIFEST_BUILDER" &&
  grep -q 'group_by' "$MANIFEST_BUILDER"; then
  pass "6.9 manifest publication rejects duplicate destinations"
else
  fail "6.9 manifest publication rejects duplicate destinations" \
    "last-writer-wins manifest construction remains possible"
fi

if grep -Fq 'git show "HEAD:${MANIFEST_PATH}"' "$MANIFEST_BUILDER" &&
  ! grep -qE "CURRENT_FILES=.*\|\| echo '\{\}'" "$WORK/manifest-joined.txt"; then
  pass "6.10 current manifest comparison fails closed at the exact checkout"
else
  fail "6.10 current manifest comparison fails closed at the exact checkout" \
    "API, decode, or schema failure can still masquerade as an empty manifest"
fi

if grep -q 'read_manifest_prs()' "$MANIFEST_BUILDER" &&
  grep -q 'head.repo.full_name' "$MANIFEST_BUILDER" &&
  grep -q 'base.ref' "$MANIFEST_BUILDER" &&
  grep -q 'head.sha' "$MANIFEST_BUILDER" &&
  grep -q 'Multiple open manifest PRs' "$MANIFEST_BUILDER" &&
  ! grep -q 'gh pr list --head' "$MANIFEST_BUILDER"; then
  pass "6.11 manifest PR ownership and exact head fail closed"
else
  fail "6.11 manifest PR ownership and exact head fail closed" \
    "manifest auto-merge can act on an unowned, duplicate, or stale-head PR"
fi

echo ""
echo "=== Section 7: hostile and duplicate PR inventories are rejected ==="

awk '
  /^          select_owned_sync_pr\(\) \{/ { found=1 }
  found {
    line=$0
    sub(/^          /, "")
    print
    if (line == "          }") exit
  }
' "$SYNC" >"$WORK/select-owned-sync-pr.sh"

if [ -s "$WORK/select-owned-sync-pr.sh" ]; then
  # shellcheck source=/dev/null
  source "$WORK/select-owned-sync-pr.sh"
  OWNER=example
  REPO=consumer
  PR_SHA=0123456789abcdef0123456789abcdef01234567

  jq -n --arg sha "$PR_SHA" --arg repo "$OWNER/$REPO" '
    [[{number: 17,
       head: {ref: "governance/sync-managed-files", sha: $sha,
              repo: {full_name: $repo}},
       base: {ref: "main"}}]]
  ' >"$WORK/sync-owned.json"
  jq -n --arg sha "$PR_SHA" --arg repo "attacker/$REPO" '
    [[{number: 18,
       head: {ref: "governance/sync-managed-files", sha: $sha,
              repo: {full_name: $repo}},
       base: {ref: "main"}}]]
  ' >"$WORK/sync-fork.json"
  jq -n --arg sha "$PR_SHA" --arg repo "$OWNER/$REPO" '
    [[{number: 19,
       head: {ref: "governance/sync-managed-files", sha: $sha,
              repo: {full_name: $repo}},
       base: {ref: "main"}},
      {number: 20,
       head: {ref: "governance/sync-managed-files", sha: $sha,
              repo: {full_name: $repo}},
       base: {ref: "main"}}]]
  ' >"$WORK/sync-duplicate.json"

  selected=$(select_owned_sync_pr "$WORK/sync-owned.json")
  if [ "$selected" = "$(printf '17\tgovernance/sync-managed-files\t%s' "$PR_SHA")" ]; then
    pass "7.1 exact same-repository sync PR is selected"
  else
    fail "7.1 exact same-repository sync PR is selected" "selected $(printf '%q' "$selected")"
  fi
  if select_owned_sync_pr "$WORK/sync-fork.json" >/dev/null 2>&1; then
    fail "7.2 same-name fork sync PR is rejected" "hostile fork returned success"
  else
    pass "7.2 same-name fork sync PR is rejected"
  fi
  if select_owned_sync_pr "$WORK/sync-duplicate.json" >/dev/null 2>&1; then
    fail "7.3 duplicate sync PR owners are rejected" "duplicate inventory returned success"
  else
    pass "7.3 duplicate sync PR owners are rejected"
  fi
else
  fail "7.1 exact same-repository sync PR is selected" "selection helper is absent"
  fail "7.2 same-name fork sync PR is rejected" "selection helper is absent"
  fail "7.3 duplicate sync PR owners are rejected" "selection helper is absent"
fi

awk '
  /^          select_owned_manifest_pr\(\) \{/ { found=1 }
  found {
    line=$0
    sub(/^          /, "")
    print
    if (line == "          }") exit
  }
' "$MANIFEST_BUILDER" >"$WORK/select-owned-manifest-pr.sh"

if [ -s "$WORK/select-owned-manifest-pr.sh" ]; then
  # shellcheck source=/dev/null
  source "$WORK/select-owned-manifest-pr.sh"
  GITHUB_REPOSITORY=example/docs-control
  BRANCH=sync/manifest
  PR_SHA=89abcdef0123456789abcdef0123456789abcdef

  jq -n --arg sha "$PR_SHA" --arg repo "$GITHUB_REPOSITORY" '
    [[{number: 21,
       head: {ref: "sync/manifest", sha: $sha,
              repo: {full_name: $repo}},
       base: {ref: "main"}}]]
  ' >"$WORK/manifest-owned.json"
  jq -n --arg sha "$PR_SHA" --arg repo "attacker/${GITHUB_REPOSITORY#*/}" '
    [[{number: 22,
       head: {ref: "sync/manifest", sha: $sha,
              repo: {full_name: $repo}},
       base: {ref: "main"}}]]
  ' >"$WORK/manifest-fork.json"
  jq -n --arg sha "$PR_SHA" --arg repo "$GITHUB_REPOSITORY" '
    [[{number: 23,
       head: {ref: "sync/manifest", sha: $sha,
              repo: {full_name: $repo}},
       base: {ref: "main"}},
      {number: 24,
       head: {ref: "sync/manifest", sha: $sha,
              repo: {full_name: $repo}},
       base: {ref: "main"}}]]
  ' >"$WORK/manifest-duplicate.json"

  selected=$(select_owned_manifest_pr "$WORK/manifest-owned.json")
  if [ "$selected" = "$(printf '21\t%s' "$PR_SHA")" ]; then
    pass "7.4 exact same-repository manifest PR is selected"
  else
    fail "7.4 exact same-repository manifest PR is selected" "selected $(printf '%q' "$selected")"
  fi
  if select_owned_manifest_pr "$WORK/manifest-fork.json" >/dev/null 2>&1; then
    fail "7.5 same-name fork manifest PR is rejected" "hostile fork returned success"
  else
    pass "7.5 same-name fork manifest PR is rejected"
  fi
  if select_owned_manifest_pr "$WORK/manifest-duplicate.json" >/dev/null 2>&1; then
    fail "7.6 duplicate manifest PR owners are rejected" "duplicate inventory returned success"
  else
    pass "7.6 duplicate manifest PR owners are rejected"
  fi
else
  fail "7.4 exact same-repository manifest PR is selected" "selection helper is absent"
  fail "7.5 same-name fork manifest PR is rejected" "selection helper is absent"
  fail "7.6 duplicate manifest PR owners are rejected" "selection helper is absent"
fi

echo ""
echo "=== Section 8: protected-source and exact mutation receipts ==="

if grep -q -- '--match-head-commit "$expected_sha"' "$SYNC" &&
  grep -q -- '--match-head-commit "$EXPECTED_HEAD"' "$MANIFEST_BUILDER"; then
  pass "8.1 every sync and manifest merge is bound to its verified head"
else
  fail "8.1 every sync and manifest merge is bound to its verified head" \
    "a delayed auto-merge can merge a head that changed after verification"
fi

protected_main_remote_reads=$(grep -cF \
  'git ls-remote --exit-code --heads origin refs/heads/main' \
  "$MANIFEST_BUILDER" || true)
protected_main_receipt_reads=$(grep -cF \
  'PROTECTED_MAIN_SHA=$(resolve_protected_main_sha)' \
  "$MANIFEST_BUILDER" || true)
current_main_receipt_reads=$(grep -cF \
  'CURRENT_MAIN_SHA=$(resolve_protected_main_sha)' \
  "$MANIFEST_BUILDER" || true)
manifest_commit_line=$(grep -nF \
  'git commit -m "chore(governance): regenerate managed-files-manifest.json"' \
  "$MANIFEST_BUILDER" | cut -d: -f1)
current_main_guard_line=$(grep -nF \
  'CURRENT_MAIN_SHA=$(resolve_protected_main_sha)' \
  "$MANIFEST_BUILDER" | cut -d: -f1)
first_manifest_push_line=$(grep -nE '^[[:space:]]+git push' \
  "$MANIFEST_BUILDER" | head -1 | cut -d: -f1)
if [ "$protected_main_remote_reads" -eq 2 ] &&
  [ "$protected_main_receipt_reads" -eq 2 ] &&
  [ "$current_main_receipt_reads" -eq 1 ] &&
  [ -n "$manifest_commit_line" ] &&
  [ -n "$current_main_guard_line" ] &&
  [ -n "$first_manifest_push_line" ] &&
  [ "$manifest_commit_line" -lt "$current_main_guard_line" ] &&
  [ "$current_main_guard_line" -lt "$first_manifest_push_line" ] &&
  grep -qF 'persist-credentials: true' "$MANIFEST_BUILDER" &&
  ! grep -qF 'gh api "repos/${GITHUB_REPOSITORY}/commits/main"' "$MANIFEST_BUILDER" &&
  grep -q 'PROTECTED_MAIN_SHA' "$MANIFEST_BUILDER" &&
  grep -q '\[ "$SOURCE_COMMIT" != "$PROTECTED_MAIN_SHA" \]' "$MANIFEST_BUILDER" &&
  grep -q 'CHECKED_OUT_SHA=$(git rev-parse HEAD)' "$MANIFEST_BUILDER"; then
  pass "8.2 manifest guards prove exact protected main without the REST API"
else
  fail "8.2 manifest guards prove exact protected main without the REST API" \
    "generation can be stranded by REST throttling or publish a stale ref"
fi

extract_remote_main_helper() {
  local target="$1"
  awk -v target="$target" '
    /^          resolve_protected_main_sha\(\) \{/ {
      seen++
      if (seen == target) capture = 1
    }
    capture {
      finished = ($0 == "          }")
      sub(/^          /, "")
      print
      if (finished) exit
    }
  ' "$MANIFEST_BUILDER"
}
remote_main_helper=$(extract_remote_main_helper 1)
second_remote_main_helper=$(extract_remote_main_helper 2)
mkdir -p "$WORK/remote-main-bin"
cat >"$WORK/remote-main-bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$*" != "ls-remote --exit-code --heads origin refs/heads/main" ]; then
  exit 99
fi
printf '%b' "${GIT_STUB_RESPONSE:-}"
exit "${GIT_STUB_RC:-0}"
EOF
chmod +x "$WORK/remote-main-bin/git"
run_remote_main_helper() {
  local helper="$1" response="$2" git_rc="$3"
  (
    eval "$helper"
    export GIT_STUB_RESPONSE="$response" GIT_STUB_RC="$git_rc"
    PATH="$WORK/remote-main-bin:$PATH"
    export PATH
    resolve_protected_main_sha
  )
}

REMOTE_MAIN_SHA=0123456789abcdef0123456789abcdef01234567
if [ -n "$remote_main_helper" ] &&
  [ "$remote_main_helper" = "$second_remote_main_helper" ]; then
  pass "8.2a both manifest steps use one exact remote-main parser"
else
  fail "8.2a both manifest steps use one exact remote-main parser" \
    "helper bodies are missing or differ across generation and publication"
fi
if resolved_main=$(run_remote_main_helper "$remote_main_helper" \
  "$REMOTE_MAIN_SHA\trefs/heads/main\n" 0 2>/dev/null) &&
  second_resolved_main=$(run_remote_main_helper "$second_remote_main_helper" \
    "$REMOTE_MAIN_SHA\trefs/heads/main\n" 0 2>/dev/null) &&
  [ "$resolved_main" = "$REMOTE_MAIN_SHA" ] &&
  [ "$second_resolved_main" = "$REMOTE_MAIN_SHA" ]; then
  pass "8.2b exact Git remote main receipt is accepted by both steps"
else
  fail "8.2b exact Git remote main receipt is accepted by both steps" \
    "a production helper did not return the sole exact main SHA"
fi

if run_remote_main_helper "$remote_main_helper" "" 2 >/dev/null 2>&1; then
  fail "8.2c Git transport failure is rejected" "ls-remote failure returned success"
else
  pass "8.2c Git transport failure is rejected"
fi
if run_remote_main_helper "$remote_main_helper" \
  "deadbeef\trefs/heads/main\n" 0 >/dev/null 2>&1; then
  fail "8.2d abbreviated Git remote receipt is rejected" "short SHA returned success"
else
  pass "8.2d abbreviated Git remote receipt is rejected"
fi
if run_remote_main_helper "$remote_main_helper" \
  "$REMOTE_MAIN_SHA\trefs/heads/main\n$REMOTE_MAIN_SHA\trefs/heads/main\n" \
  0 >/dev/null 2>&1; then
  fail "8.2e duplicate Git remote receipts are rejected" "duplicate main rows returned success"
else
  pass "8.2e duplicate Git remote receipts are rejected"
fi
if run_remote_main_helper "$remote_main_helper" \
  "$REMOTE_MAIN_SHA\trefs/heads/not-main\n" 0 >/dev/null 2>&1; then
  fail "8.2f wrong Git remote ref is rejected" "non-main ref returned success"
else
  pass "8.2f wrong Git remote ref is rejected"
fi
if run_remote_main_helper "$remote_main_helper" \
  "$REMOTE_MAIN_SHA\trefs/heads/main\ngarbage\n" 0 >/dev/null 2>&1; then
  fail "8.2g trailing garbage row is rejected" "unparsed output returned success"
else
  pass "8.2g trailing garbage row is rejected"
fi
if run_remote_main_helper "$remote_main_helper" \
  "$REMOTE_MAIN_SHA\trefs/heads/main\n$REMOTE_MAIN_SHA\trefs/heads/not-main\n" \
  0 >/dev/null 2>&1; then
  fail "8.2h an additional wrong-ref row is rejected" "extra ref returned success"
else
  pass "8.2h an additional wrong-ref row is rejected"
fi
if run_remote_main_helper "$remote_main_helper" \
  "$REMOTE_MAIN_SHA\trefs/heads/main\textra\n" 0 >/dev/null 2>&1; then
  fail "8.2i an additional field is rejected" "extra field returned success"
else
  pass "8.2i an additional field is rejected"
fi
if run_remote_main_helper "$remote_main_helper" \
  "$REMOTE_MAIN_SHA refs/heads/main\n" 0 >/dev/null 2>&1; then
  fail "8.2j a space-delimited row is rejected" "non-canonical delimiter returned success"
else
  pass "8.2j a space-delimited row is rejected"
fi
if run_remote_main_helper "$remote_main_helper" \
  "garbage\n$REMOTE_MAIN_SHA\trefs/heads/main\n" 0 >/dev/null 2>&1; then
  fail "8.2k a leading garbage row is rejected" "leading unparsed output returned success"
else
  pass "8.2k a leading garbage row is rejected"
fi
if run_remote_main_helper "$remote_main_helper" \
  "\n$REMOTE_MAIN_SHA\trefs/heads/main\n" 0 >/dev/null 2>&1; then
  fail "8.2l a leading blank row is rejected" "leading blank output returned success"
else
  pass "8.2l a leading blank row is rejected"
fi
for trailing_blank_rows in \
  "$REMOTE_MAIN_SHA\trefs/heads/main\n\n" \
  "$REMOTE_MAIN_SHA\trefs/heads/main\n\n\n" \
  "$REMOTE_MAIN_SHA\trefs/heads/main\n\n\n\n"; do
  if run_remote_main_helper "$remote_main_helper" \
    "$trailing_blank_rows" 0 >/dev/null 2>&1; then
    fail "8.2m additional terminal blank rows are rejected" \
      "command substitution normalized malformed output"
  else
    pass "8.2m additional terminal blank rows are rejected"
  fi
done

if grep -q 'assert_manifest_pr_diff()' "$MANIFEST_BUILDER" &&
  grep -q 'total_commits == 1' "$MANIFEST_BUILDER" &&
  grep -q '\.files | length) == 1' "$MANIFEST_BUILDER" &&
  grep -q '\.files\[0\]\.filename == $manifest_path' "$MANIFEST_BUILDER"; then
  pass "8.3 manifest PR is an exact one-file commit on protected main"
else
  fail "8.3 manifest PR is an exact one-file commit on protected main" \
    "unrelated branch commits can ride into the manifest PR"
fi

first_inventory_line=$(grep -n 'read_manifest_prs "$MANIFEST_PR_INVENTORY"' "$MANIFEST_BUILDER" |
  head -1 | cut -d: -f1)
push_line=$(grep -n 'git push' "$MANIFEST_BUILDER" | head -1 | cut -d: -f1)
if [ -n "$first_inventory_line" ] && [ -n "$push_line" ] &&
  [ "$first_inventory_line" -lt "$push_line" ] &&
  grep -q -- '--force-with-lease=refs/heads/$BRANCH:$REMOTE_BRANCH_SHA' "$MANIFEST_BUILDER" &&
  ! grep -q 'git push --force origin' "$MANIFEST_BUILDER"; then
  pass "8.4 manifest ownership is proved before a lease-protected push"
else
  fail "8.4 manifest ownership is proved before a lease-protected push" \
    "mutation precedes inventory or can overwrite a concurrently changed head"
fi

if grep -q 'validate_managed_routing()' "$SYNC" &&
  grep -q 'only_repos' "$SYNC" &&
  grep -q 'skip_files' "$SYNC"; then
  pass "8.5 managed routing schema fails closed before drift evaluation"
else
  fail "8.5 managed routing schema fails closed before drift evaluation" \
    "malformed routing can silently skip managed paths"
fi

if grep -q 'validate_docs_sites()' "$SYNC" &&
  grep -q '\[ERROR\] No canonical docs-site metadata' "$SYNC" &&
  ! grep -q '\[SKIP\] README.md -- no canonical docs-site metadata' "$SYNC" &&
  ! grep -qE 'README_DESC=\$\(gh api|README_(TITLE|DESC|BADGES|CONTENT)=.*\|\| true' \
    "$WORK/sync-joined.txt"; then
  pass "8.6 missing canonical README metadata fails closed"
else
  fail "8.6 missing canonical README metadata fails closed" \
    "absence of metadata can still silently opt a repository out of governance"
fi

if jq -e --slurpfile sites "$REPO_ROOT/.github/config/docs-sites.json" '
    .managed_files.skip_files as $skip_files |
    $sites[0] as $sites |
    all($repos[];
      . as $repo |
      (($skip_files[$repo] // []) | index("README.md")) != null or
      any($sites[]; .url == ("https://f5-sales-demo.github.io/" + $repo + "/llms-full.txt")))
  ' --argjson repos "$(jq -c '.' "$REPO_ROOT/.github/config/downstream-repos.json")" \
  "$REPO_ROOT/.github/config/repo-settings.json" >/dev/null; then
  pass "8.7 every downstream README has canonical metadata or an explicit opt-out"
else
  fail "8.7 every downstream README has canonical metadata or an explicit opt-out" \
    "the canonical fleet configuration contains an implicit README ownership gap"
fi

if grep -q 'select_owned_stale_issues()' "$SYNC" &&
  grep -q 'This issue was created automatically by the governance enforcement workflow' "$SYNC"; then
  pass "8.8 stale issue closure requires an exact automation ownership marker"
else
  fail "8.8 stale issue closure requires an exact automation ownership marker" \
    "free-text search results can still close unrelated issues"
fi

echo ""
echo "════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed ($TESTS_RUN total)"
echo "════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
