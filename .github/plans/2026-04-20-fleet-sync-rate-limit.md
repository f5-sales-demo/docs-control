# Fleet-sync rate-limit mitigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the GitHub API rate-limit storm caused by 25 downstream repos concurrently pulling governance content from `docs-control`, by (A) moving read-path to GitHub Pages (no API budget) and (B) capping fan-out concurrency to 5 downstreams.

**Architecture:** Two layers landed as two independent PRs. Layer A publishes governance assets to the existing Pages site and teaches consumer workflows to prefer Pages with automatic API fallback. Layer B restructures `dispatch-downstream.yml` into a matrix job with `max-parallel: 5` and plumbs the triggering commit SHA through to downstreams for Pages-staleness verification.

**Tech Stack:** Bash, GitHub Actions YAML, cURL, jq, `gh` CLI, BATS-style assertion patterns (inline without bats dep).

**Spec:** `.github/plans/2026-04-20-fleet-sync-rate-limit-design.md`

**Git-operations policy:** Per `CLAUDE.md`, delegate all commit/push/PR steps to the `f5xc-github-ops:github-ops` subagent. Never run `git commit`, `git push`, or `gh pr create` in the main session.

---

## File Plan

| Path | Action | Purpose |
| --- | --- | --- |
| `tests/fixtures/fetch-governed.sh` | Create | Canonical, sourceable shell module. Exposes `fetch_governed <key> <api-fallback-path>` and `revision_is_fresh <source-sha>`. Test-target. Copied verbatim into each consumer workflow. |
| `tests/test-fetch-governed.sh` | Create | Unit tests for `fetch_governed` and `revision_is_fresh`. Stubs `curl` and `gh`. Runs under plain `bash`. |
| `tests/test-inlined-helpers-match.sh` | Create | Drift-guard: extracts the inlined helper body from each consumer workflow and diffs against `tests/fixtures/fetch-governed.sh`. Fails CI if they drift. |
| `tests/test-dispatch-matrix.sh` | Create | Schema + `actionlint` + `fromJson()` validation for the new `dispatch-downstream.yml` structure. |
| `.github/workflows/github-pages-deploy.yml` | Modify | Add post-build "Stage governance assets" step that copies managed config/template/content into `$OUTPUT_DIR/api/` and emits `api/revision.json`. |
| `.github/workflows/sync-managed-files.yml` | Modify | Inline the `fetch_governed` helper. Replace four `gh api … contents/…` reads (config, manifest, docs-sites, README template, per-file fallback) with `fetch_governed` calls. Accept `source_sha` (Phase 2 only). |
| `.github/workflows/enforce-repo-settings.yml` | Modify | Inline the `fetch_governed` helper. Replace the `repo-settings.json` read. Add optional `workflow_dispatch.inputs.source_sha`. Thread the SHA into the sync call. |
| `.github/workflows/dispatch-downstream.yml` | Modify (Phase 2) | Split into `read-config` job + `dispatch` job with `strategy.matrix.repo` + `max-parallel: 5`. Pass `source_sha=${{ github.sha }}` to each dispatch. |

**Phase / PR boundary:** Tasks 1–7 ship as **PR 1** (Layer A). Tasks 8–11 ship as **PR 2** (Layer B). Each PR is independently mergeable and revertible.

---

## Phase 1 — Layer A (PR 1)

### Task 1: Canonical `fetch_governed` helper with unit tests

**Files:**

- Create: `tests/fixtures/fetch-governed.sh`
- Create: `tests/test-fetch-governed.sh`

- [ ] **Step 1.1: Write the failing test file**

Create `tests/test-fetch-governed.sh` exactly as below. It contains 7 test cases and an in-line test harness with stubbable `curl`/`gh`.

```bash
#!/usr/bin/env bash
# Unit tests for tests/fixtures/fetch-governed.sh
# Run: bash tests/test-fetch-governed.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SOURCE="${SCRIPT_DIR}/fixtures/fetch-governed.sh"

# --- Test harness ----------------------------------------------------
PASS=0
FAIL=0
CURRENT_TEST=""

_assert_eq() {
  local want="$1" got="$2" label="${3:-}"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    echo "  [PASS] ${CURRENT_TEST}${label:+ — }${label:-}"
  else
    FAIL=$((FAIL + 1))
    echo "  [FAIL] ${CURRENT_TEST}${label:+ — }${label:-}"
    echo "    want: ${want}"
    echo "    got:  ${got}"
  fi
}

_assert_nonzero() {
  local rc="$1" label="${2:-}"
  if [ "$rc" != "0" ]; then
    PASS=$((PASS + 1)); echo "  [PASS] ${CURRENT_TEST}${label:+ — }${label:-}"
  else
    FAIL=$((FAIL + 1)); echo "  [FAIL] ${CURRENT_TEST}${label:+ — }${label:-} — expected nonzero rc"
  fi
}

# --- Stub factory ---------------------------------------------------
# Writes a fake `curl` and `gh` on PATH for the duration of one test.
setup_stubs() {
  STUB_DIR=$(mktemp -d)
  export PATH="${STUB_DIR}:${PATH}"
  export FAKE_LOG="${STUB_DIR}/calls.log"
  : > "$FAKE_LOG"
}
teardown_stubs() {
  PATH="${PATH#${STUB_DIR}:}"
  rm -rf "$STUB_DIR"
  unset STUB_DIR FAKE_LOG
}
stub_curl() {
  local mode="$1" body="${2:-}"
  cat > "${STUB_DIR}/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "${FAKE_LOG}"
case "${mode}" in
  200)   printf '%s' "${body}"; exit 0 ;;
  404)   exit 22 ;;
  empty) exit 0 ;;
  hang)  exit 28 ;;
esac
EOF
  chmod +x "${STUB_DIR}/curl"
}
stub_gh() {
  local mode="$1" body="${2:-}"
  cat > "${STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "${FAKE_LOG}"
case "${mode}" in
  ok)   printf '%s' "${body}"; exit 0 ;;
  fail) exit 1 ;;
esac
EOF
  chmod +x "${STUB_DIR}/gh"
}

# --- Tests ----------------------------------------------------------
export PAGES_BASE="https://example.test/docs-control"

# shellcheck source=fixtures/fetch-governed.sh
. "$SOURCE"

CURRENT_TEST="pages 200 -> use pages, no gh call"
setup_stubs
stub_curl 200 '{"hello":"world"}'
stub_gh fail
out=$(fetch_governed repo-settings.json "repos/x/y/contents/.github/config/repo-settings.json")
_assert_eq '{"hello":"world"}' "$out" "body matches"
if grep -q "^gh " "$FAKE_LOG"; then
  FAIL=$((FAIL + 1)); echo "  [FAIL] ${CURRENT_TEST} — gh was called"
else
  PASS=$((PASS + 1)); echo "  [PASS] ${CURRENT_TEST} — gh was NOT called"
fi
teardown_stubs

CURRENT_TEST="pages 404 -> fallback to gh api"
setup_stubs
stub_curl 404
stub_gh ok '{"content":"aGVsbG8=","encoding":"base64"}'
out=$(fetch_governed repo-settings.json "repos/x/y/contents/.github/config/repo-settings.json")
_assert_eq 'hello' "$out" "decoded body"
grep -q "^gh " "$FAKE_LOG" && { PASS=$((PASS + 1)); echo "  [PASS] ${CURRENT_TEST} — gh invoked"; } || { FAIL=$((FAIL + 1)); echo "  [FAIL] ${CURRENT_TEST} — gh not invoked"; }
teardown_stubs

CURRENT_TEST="pages empty body -> fallback"
setup_stubs
stub_curl empty
stub_gh ok '{"content":"Zm9v","encoding":"base64"}'
out=$(fetch_governed x.json "repos/x/y/contents/x.json")
_assert_eq 'foo' "$out"
teardown_stubs

CURRENT_TEST="pages timeout -> fallback"
setup_stubs
stub_curl hang
stub_gh ok '{"content":"YmFy","encoding":"base64"}'
out=$(fetch_governed x.json "repos/x/y/contents/x.json")
_assert_eq 'bar' "$out"
teardown_stubs

CURRENT_TEST="both fail -> non-zero exit"
setup_stubs
stub_curl 404
stub_gh fail
set +e
fetch_governed x.json "repos/x/y/contents/x.json" >/dev/null 2>&1
rc=$?
set -e
_assert_nonzero "$rc"
teardown_stubs

CURRENT_TEST="revision_is_fresh: SHA matches"
setup_stubs
stub_curl 200 '{"commit":"abc123","generated_at":"2026-04-20T00:00:00Z"}'
set +e
revision_is_fresh abc123
rc=$?
set -e
_assert_eq 0 "$rc" "fresh when SHA equal"
teardown_stubs

CURRENT_TEST="revision_is_fresh: SHA mismatch"
setup_stubs
stub_curl 200 '{"commit":"old0000","generated_at":"2026-04-20T00:00:00Z"}'
set +e
revision_is_fresh abc123
rc=$?
set -e
_assert_nonzero "$rc" "stale when SHA differs"
teardown_stubs

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 1.2: Run test to confirm it fails (source file doesn't exist yet)**

Run: `bash tests/test-fetch-governed.sh`
Expected: FAIL — `No such file or directory: tests/fixtures/fetch-governed.sh`

- [ ] **Step 1.3: Write the canonical helper**

Create `tests/fixtures/fetch-governed.sh` exactly as below:

```bash
#!/usr/bin/env bash
# tests/fixtures/fetch-governed.sh
#
# Canonical source of the fetch-from-Pages-with-API-fallback helper.
# This file is the source of truth; consumer workflows inline its
# functions verbatim. tests/test-inlined-helpers-match.sh asserts the
# inlined copies stay in sync with this file.
#
# Environment:
#   PAGES_BASE   e.g. "https://f5xc-salesdemos.github.io/docs-control"
#   GH_TOKEN     used by fallback `gh api` path
#
# All functions are safe to source multiple times.

# fetch_governed <pages-key> <api-fallback-path>
#   pages-key          : relative path under ${PAGES_BASE}/api/ (e.g. "repo-settings.json")
#   api-fallback-path  : argument for `gh api` when Pages is unavailable
#                        (e.g. "repos/f5xc-salesdemos/docs-control/contents/.github/config/repo-settings.json")
# Prints: raw file content to stdout.
# Returns: 0 on success (via Pages or API), non-zero if both fail.
fetch_governed() {
  local key="$1" fallback="$2" body
  local url="${PAGES_BASE}/api/${key}"

  body=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 10 "$url" 2>/dev/null || true)
  if [ -n "$body" ]; then
    printf '%s' "$body"
    return 0
  fi

  echo "[WARN] Pages unavailable for ${key} — falling back to API" >&2
  body=$(gh api "$fallback" 2>/dev/null || true)
  if [ -z "$body" ]; then
    echo "[ERROR] Both Pages and API failed for ${key}" >&2
    return 1
  fi

  # API returns {"content": "<base64>", "encoding": "base64"} envelope.
  # Unwrap to raw bytes.
  printf '%s' "$body" | jq -r '.content' | tr -d '\n' | base64 -d
}

# revision_is_fresh <source-sha>
#   Fetch ${PAGES_BASE}/api/revision.json and compare its .commit
#   against source-sha (the SHA that triggered the consumer run).
# Returns: 0 when the Pages deploy has caught up to source-sha;
#          non-zero when Pages is stale or unreachable or when
#          source-sha is empty.
revision_is_fresh() {
  local source_sha="${1:-}" rev pages_sha
  [ -z "$source_sha" ] && return 1

  rev=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 10 \
    "${PAGES_BASE}/api/revision.json" 2>/dev/null || true)
  [ -z "$rev" ] && return 1

  pages_sha=$(printf '%s' "$rev" | jq -r '.commit // empty')
  [ "$pages_sha" = "$source_sha" ]
}
```

- [ ] **Step 1.4: Run test to verify it passes**

Run: `bash tests/test-fetch-governed.sh`
Expected: `=== Summary: 7 passed, 0 failed ===`

- [ ] **Step 1.5: Commit (delegate to github-ops)**

Delegate to `f5xc-github-ops:github-ops`:

```
test(governance): add fetch-governed helper and unit tests (Layer A)

Files:
- tests/fixtures/fetch-governed.sh
- tests/test-fetch-governed.sh

Why: Canonical shell helper that prefers GitHub Pages with automatic
`gh api` fallback. First step of Layer A (see spec
.github/plans/2026-04-20-fleet-sync-rate-limit-design.md). No workflows
wired yet — this is test-only plumbing.

Issue: (will be opened for PR 1 against Layer A as a whole)
```

---

### Task 2: Publish governance assets to Pages

**Files:**

- Modify: `.github/workflows/github-pages-deploy.yml` (insert one step after "Verify build output" at ~line 144)

- [ ] **Step 2.1: Write a failing yamllint check for the new step**

(No separate test file — yamllint is already wired via super-linter. Verify locally before commit.)

- [ ] **Step 2.2: Add the staging step to github-pages-deploy.yml**

Edit `.github/workflows/github-pages-deploy.yml`. After the `- name: Verify build output` step (block that ends at `find "$OUTPUT_DIR" -type f | head -20`) and **before** `- name: Upload artifact`, insert:

```yaml
      - name: Stage governance assets for /api/
        run: |
          OUTPUT_DIR="${{ runner.temp }}/docs-output"
          API_DIR="${OUTPUT_DIR}/api"
          mkdir -p "${API_DIR}/files"

          # Static config & templates
          for src in \
              .github/config/repo-settings.json \
              .github/config/managed-files-manifest.json \
              .github/config/docs-sites.json \
              README.md.tpl; do
            [ -f "$src" ] || continue
            dest="${API_DIR}/$(basename "$src")"
            cp "$src" "$dest"
            echo "Published: /api/$(basename "$src")"
          done

          # Per-file copies of every path listed in the managed-files manifest
          MANIFEST=".github/config/managed-files-manifest.json"
          if [ -f "$MANIFEST" ]; then
            mapfile -t FILES < <(jq -r '.files | keys[]' "$MANIFEST")
            for dest in "${FILES[@]}"; do
              if [ -f "$dest" ]; then
                target="${API_DIR}/files/${dest}"
                mkdir -p "$(dirname "$target")"
                cp "$dest" "$target"
                echo "Published: /api/files/${dest}"
              fi
            done
          fi

          # Revision marker — lets downstreams detect Pages deploy lag
          jq -n \
            --arg commit "${GITHUB_SHA}" \
            --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{commit:$commit, generated_at:$generated_at}' \
            > "${API_DIR}/revision.json"
          echo "Published: /api/revision.json"

          # Nudge Pages to not apply Jekyll to the api/ directory
          touch "${OUTPUT_DIR}/.nojekyll"
```

- [ ] **Step 2.3: Verify YAML is valid**

Run: `yamllint -d '{extends: default, rules: {line-length: {max: 200}, document-start: disable}}' .github/workflows/github-pages-deploy.yml`
Expected: exit 0, no errors.

- [ ] **Step 2.4: Verify `actionlint` is clean (if installed)**

Run: `actionlint .github/workflows/github-pages-deploy.yml`
Expected: exit 0.

If `actionlint` is not installed, skip — super-linter will catch it in CI.

- [ ] **Step 2.5: Commit (delegate)**

Delegate to `f5xc-github-ops:github-ops`:

```
feat(pages): publish governance assets under /api/ (Layer A)

Files:
- .github/workflows/github-pages-deploy.yml

Why: Publishes repo-settings.json, managed-files-manifest.json,
docs-sites.json, README.md.tpl, per-file copies under /api/files/, and
a revision.json marker. Downstreams will consume these over HTTPS in
Task 3–4, eliminating the GitHub Contents API read storm.

Spec: .github/plans/2026-04-20-fleet-sync-rate-limit-design.md
```

---

### Task 3: Wire `sync-managed-files.yml` to prefer Pages

**Files:**

- Modify: `.github/workflows/sync-managed-files.yml`

- [ ] **Step 3.1: Read the current `sync-managed-files.yml` fully**

Locate the following four read sites (current line numbers from `main`):

- Line 168: `CONFIG_B64=$(retry 3 gh api "repos/${CONFIG_REPO}/contents/${CONFIG_PATH}" --jq '.content')`
- Line 209: `MANIFEST_B64=$(retry 3 gh api "repos/${SOURCE_REPO}/contents/${MANIFEST_PATH}" --jq '.content' 2>/dev/null || echo "")`
- Lines 260, 426, 524: per-file fallback `CANONICAL_RESPONSE=$(retry 3 gh api "repos/${SOURCE_REPO}/contents/${src}" ...)` and `B64=$(retry 3 gh api "repos/${SOURCE_REPO}/contents/${src_file}" --jq '.content' | tr -d '\n')`
- Line 346: `DOCS_SITES_B64=$(retry 3 gh api "repos/${CONFIG_REPO}/contents/.github/config/docs-sites.json" --jq '.content')`
- Line 373: `README_TPL_B64=$(retry 3 gh api "repos/${CONFIG_REPO}/contents/README.md.tpl" --jq '.content')`

- [ ] **Step 3.2: Inline the helper into `sync-managed-files.yml`**

Edit the `Sync managed files` step's `run:` block. Immediately after the `retry_json` function definition (around line 81) and before the `OWNER=…` line (around line 83), insert:

```bash
          # --- Pages-first fetch helper (canonical source: tests/fixtures/fetch-governed.sh) ---
          PAGES_BASE="https://f5xc-salesdemos.github.io/docs-control"

          fetch_governed() {
            local key="$1" fallback="$2" body
            local url="${PAGES_BASE}/api/${key}"
            body=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 10 "$url" 2>/dev/null || true)
            if [ -n "$body" ]; then
              printf '%s' "$body"
              return 0
            fi
            echo "[WARN] Pages unavailable for ${key} — falling back to API" >&2
            body=$(gh api "$fallback" 2>/dev/null || true)
            if [ -z "$body" ]; then
              echo "[ERROR] Both Pages and API failed for ${key}" >&2
              return 1
            fi
            printf '%s' "$body" | jq -r '.content' | tr -d '\n' | base64 -d
          }

          revision_is_fresh() {
            local source_sha="${1:-}" rev pages_sha
            [ -z "$source_sha" ] && return 1
            rev=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 10 \
              "${PAGES_BASE}/api/revision.json" 2>/dev/null || true)
            [ -z "$rev" ] && return 1
            pages_sha=$(printf '%s' "$rev" | jq -r '.commit // empty')
            [ "$pages_sha" = "$source_sha" ]
          }
```

- [ ] **Step 3.3: Replace the four config/template reads**

Replace:

```bash
          CONFIG_B64=$(retry 3 gh api "repos/${CONFIG_REPO}/contents/${CONFIG_PATH}" --jq '.content')
          CONFIG=$(echo "$CONFIG_B64" | base64 -d)
```

With:

```bash
          CONFIG=$(fetch_governed "$(basename "$CONFIG_PATH")" "repos/${CONFIG_REPO}/contents/${CONFIG_PATH}")
```

Replace:

```bash
              MANIFEST_B64=$(retry 3 gh api "repos/${SOURCE_REPO}/contents/${MANIFEST_PATH}" --jq '.content' 2>/dev/null || echo "")
              MANIFEST="{}"
              MANIFEST_AVAILABLE=false
              if [ -n "$MANIFEST_B64" ]; then
                MANIFEST=$(echo "$MANIFEST_B64" | tr -d '\n' | base64 -d 2>/dev/null || echo "{}")
```

With:

```bash
              MANIFEST=$(fetch_governed "managed-files-manifest.json" "repos/${SOURCE_REPO}/contents/${MANIFEST_PATH}" 2>/dev/null || echo "")
              MANIFEST_AVAILABLE=false
              if [ -n "$MANIFEST" ]; then
                MANIFEST="${MANIFEST:-{\}}"
```

(Retain the downstream `if echo "$MANIFEST" | jq -e '.files' …` check unchanged.)

Replace line 346:

```bash
              DOCS_SITES_B64=$(retry 3 gh api "repos/${CONFIG_REPO}/contents/.github/config/docs-sites.json" --jq '.content')
              DOCS_SITES_JSON=$(echo "$DOCS_SITES_B64" | base64 -d)
```

With:

```bash
              DOCS_SITES_JSON=$(fetch_governed "docs-sites.json" "repos/${CONFIG_REPO}/contents/.github/config/docs-sites.json")
```

Replace line 373:

```bash
              README_TPL_B64=$(retry 3 gh api "repos/${CONFIG_REPO}/contents/README.md.tpl" --jq '.content')
              README_TPL=$(echo "$README_TPL_B64" | base64 -d)
```

With:

```bash
              README_TPL=$(fetch_governed "README.md.tpl" "repos/${CONFIG_REPO}/contents/README.md.tpl")
```

- [ ] **Step 3.4: Replace the three per-file content fetches**

For line 260 (drift-detection fallback):

Replace:

```bash
                CANONICAL_RESPONSE=$(retry 3 gh api "repos/${SOURCE_REPO}/contents/${src}" 2>/dev/null) || true
                if [ -z "$CANONICAL_RESPONSE" ]; then
                  echo "[WARN] Could not fetch canonical: ${src}"
                  continue
                fi
                CANONICAL_CONTENT=$(echo "$CANONICAL_RESPONSE" | jq -r '.content' | tr -d '\n' | base64 -d 2>/dev/null) || true
```

With:

```bash
                CANONICAL_CONTENT=$(fetch_governed "files/${dest}" "repos/${SOURCE_REPO}/contents/${src}" 2>/dev/null) || true
                if [ -z "$CANONICAL_CONTENT" ]; then
                  echo "[WARN] Could not fetch canonical: ${src}"
                  continue
                fi
```

For lines 426 and 524 (file-write content fetches — PUT to downstream repo expects base64 in the payload, so we still want base64 here):

Leave lines 426 and 524 on the existing `gh api … .content` path. Rationale: the downstream
write call `repos/${OWNER}/${REPO}/contents/${dest_file}` requires base64-encoded content in
the request body. The one call it takes to produce that is already within the downstream's
own API budget; moving it to Pages (raw bytes) would force a second `base64 -w 0` round-trip
for no net savings. Leave a single-line comment noting this.

Add above line 426 and line 524:

```bash
                    # Base64 content fetched directly -- required by the PUT
                    # contents API below. Not moved to Pages (would require
                    # re-encoding; saves one API call per drifted file at most).
```

- [ ] **Step 3.5: Verify the yml is valid**

Run: `yamllint -d '{extends: default, rules: {line-length: {max: 200}, document-start: disable, truthy: disable}}' .github/workflows/sync-managed-files.yml`
Expected: exit 0.

Run: `bash -n <(grep -v '^---' .github/workflows/sync-managed-files.yml | yq -r '.jobs.sync.steps[] | select(.name=="Sync managed files") | .run')` if `yq` is available, else skip.

- [ ] **Step 3.6: Commit (delegate)**

Delegate to `f5xc-github-ops:github-ops`:

```
feat(governance): use Pages-first reads in sync-managed-files (Layer A)

Files:
- .github/workflows/sync-managed-files.yml

Why: Replace four API content-reads (manifest, repo-settings config,
docs-sites, README template) + drift-detect fallback with
fetch_governed() calls that hit GitHub Pages first and fall back to
the API only on Pages failure. Pages HTTP requests are CDN-served and
do not consume the shared PAT rate-limit budget. Expected drop: ~80%
in per-downstream read calls during the no-drift case.

Spec: .github/plans/2026-04-20-fleet-sync-rate-limit-design.md
```

---

### Task 4: Wire `enforce-repo-settings.yml` to prefer Pages

**Files:**

- Modify: `.github/workflows/enforce-repo-settings.yml`

- [ ] **Step 4.1: Inline the helper**

Same function body as Task 3 Step 3.2, inserted after that workflow's `retry_json` function (around line 90) and before the first use.

- [ ] **Step 4.2: Replace the config read at line 113**

Replace:

```bash
          CONFIG_B64=$(retry 3 gh api "repos/${CONFIG_REPO}/contents/${CONFIG_PATH}" --jq '.content')
```

With:

```bash
          CONFIG=$(fetch_governed "repo-settings.json" "repos/${CONFIG_REPO}/contents/${CONFIG_PATH}")
```

(And remove the subsequent `CONFIG=$(echo "$CONFIG_B64" | base64 -d)` line.)

- [ ] **Step 4.3: Validate yml**

Run: `yamllint -d '{extends: default, rules: {line-length: {max: 200}, document-start: disable, truthy: disable}}' .github/workflows/enforce-repo-settings.yml`
Expected: exit 0.

- [ ] **Step 4.4: Commit (delegate)**

Delegate to `f5xc-github-ops:github-ops`:

```
feat(governance): use Pages-first read in enforce-repo-settings (Layer A)

Files:
- .github/workflows/enforce-repo-settings.yml

Why: The single docs-control config read runs 25× per fleet-sync
cycle. Moving it to Pages costs nothing against the API budget.

Spec: .github/plans/2026-04-20-fleet-sync-rate-limit-design.md
```

---

### Task 5: Drift-guard test for inlined helpers

**Files:**

- Create: `tests/test-inlined-helpers-match.sh`

- [ ] **Step 5.1: Write the test**

```bash
#!/usr/bin/env bash
# Ensures the inlined fetch_governed/revision_is_fresh functions in
# consumer workflows stay byte-identical with the canonical source at
# tests/fixtures/fetch-governed.sh.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
SOURCE="${REPO_ROOT}/tests/fixtures/fetch-governed.sh"

# Extract just the two function definitions from the canonical source,
# stripping shebang, comments, and blank lines. This is what we expect
# to find verbatim (modulo leading whitespace) inside each consumer.
canonical=$(awk '
  /^fetch_governed\(\)/,/^}$/ { print; next }
  /^revision_is_fresh\(\)/,/^}$/ { print }
' "$SOURCE" | sed 's/^[[:space:]]*//')

FAIL=0
for wf in \
    "${REPO_ROOT}/.github/workflows/sync-managed-files.yml" \
    "${REPO_ROOT}/.github/workflows/enforce-repo-settings.yml"; do
  inlined=$(awk '
    /fetch_governed\(\)/,/^[[:space:]]*}[[:space:]]*$/ { print; next }
    /revision_is_fresh\(\)/,/^[[:space:]]*}[[:space:]]*$/ { print }
  ' "$wf" | sed 's/^[[:space:]]*//' | grep -v '^$' | grep -v '^#')
  expected=$(printf '%s\n' "$canonical" | grep -v '^$' | grep -v '^#')
  if [ "$inlined" = "$expected" ]; then
    echo "[OK] $(basename "$wf") helper matches canonical"
  else
    echo "[FAIL] $(basename "$wf") helper drifted from canonical"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$inlined") || true
    FAIL=1
  fi
done

exit "$FAIL"
```

- [ ] **Step 5.2: Run it, expect PASS**

Run: `bash tests/test-inlined-helpers-match.sh`
Expected: two `[OK]` lines, exit 0. (Tasks 3 and 4 inlined the same function body.)

- [ ] **Step 5.3: Prove it fails under drift**

Briefly modify the `fetch_governed` body inside `sync-managed-files.yml` (e.g. change `--max-time 10` → `--max-time 9`), re-run the test, confirm `[FAIL]`. Then revert the change. **Do not commit the drift.**

- [ ] **Step 5.4: Commit the test (delegate)**

Delegate to `f5xc-github-ops:github-ops`:

```
test(governance): guard against inlined helper drift (Layer A)

Files:
- tests/test-inlined-helpers-match.sh

Why: Because fetch_governed is duplicated across two workflows
(needed: downstream runners can't source from docs-control), we need
a CI test that diffs the inlined copies against the canonical source.
Prevents silent bitrot.

Spec: .github/plans/2026-04-20-fleet-sync-rate-limit-design.md
```

---

### Task 6: Wire the helper tests into CI

**Files:**

- Modify: `.github/workflows/super-linter.yml` OR create a new `tests.yml` workflow

- [ ] **Step 6.1: Check what CI currently runs**

Read `.github/workflows/super-linter.yml`. If it runs `tests/` content via `shellcheck`, we're covered for lint. If not, add a new job that runs `bash tests/test-fetch-governed.sh` and `bash tests/test-inlined-helpers-match.sh`.

- [ ] **Step 6.2: Add a unit-test job**

If not already present, append a new job to `.github/workflows/super-linter.yml`:

```yaml
  shell-unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Run shell unit tests
        run: |
          bash tests/test-fetch-governed.sh
          bash tests/test-inlined-helpers-match.sh
```

If the existing structure uses a matrix or job dependencies, fit in accordingly.

- [ ] **Step 6.3: Lint the workflow**

Run: `yamllint …` on the modified super-linter.yml.
Expected: clean.

- [ ] **Step 6.4: Commit (delegate)**

Delegate to `f5xc-github-ops:github-ops`:

```
ci: run shell unit tests (Layer A)

Files:
- .github/workflows/super-linter.yml  (or .github/workflows/tests.yml)

Why: Wire up tests/test-fetch-governed.sh and
tests/test-inlined-helpers-match.sh so CI blocks PRs that break the
helper or let the inlined copies drift.

Spec: .github/plans/2026-04-20-fleet-sync-rate-limit-design.md
```

---

### Task 7: Open PR 1 (Layer A) and verify post-merge

- [ ] **Step 7.1: Delegate PR-open to github-ops**

Delegate to `f5xc-github-ops:github-ops`:

```
feat: reduce GitHub API rate-limit storms via Pages read-path (Layer A, PR 1 of 2)

All commits on this branch are part of Layer A — see spec
.github/plans/2026-04-20-fleet-sync-rate-limit-design.md.

Open an issue titled "feat(governance): publish managed config over
Pages to cut API rate-limit storms (Layer A)", describing the problem,
the approach, and linking the spec. Then open the PR linked to that
issue. CI gates: shellcheck/yamllint/actionlint via super-linter,
plus the new shell-unit-tests job.
```

- [ ] **Step 7.2: After PR 1 merges, wait ~5 min for Pages deploy**

- [ ] **Step 7.3: Acceptance check (no tasks; just verification)**

Run:

```
curl -fsSL https://f5xc-salesdemos.github.io/docs-control/api/revision.json
```

Expected: a JSON with `commit` equal to the merge commit SHA.

Run:

```
curl -fsSL https://f5xc-salesdemos.github.io/docs-control/api/managed-files-manifest.json | jq '.files | keys | length'
```

Expected: a positive integer (≥ 5).

- [ ] **Step 7.4: Trigger a dummy downstream sync, observe logs**

In one downstream repo (e.g. `docs-theme`), run:

```
gh workflow run enforce-repo-settings.yml --repo f5xc-salesdemos/docs-theme
```

In the resulting `sync-managed-files` job log, expect zero `[WARN] Pages unavailable …` lines.

Check `gh api rate_limit --jq '.resources.core'` — remaining should be well above 4000/5000 even after the full fleet has run.

If acceptance passes, proceed to Phase 2. If it fails, open a bug issue and revert PR 1 before moving on.

---

## Phase 2 — Layer B (PR 2)

### Task 8: Add `source_sha` input to `enforce-repo-settings.yml`

**Files:**

- Modify: `.github/workflows/enforce-repo-settings.yml`

- [ ] **Step 8.1: Add the input**

At the top of the file, under `on:` → `workflow_dispatch:`, add:

```yaml
on:
  workflow_dispatch:
    inputs:
      source_sha:
        description: 'Commit SHA of the docs-control push that triggered this run. Used for Pages staleness check.'
        required: false
        type: string
        default: ''
```

(If `workflow_dispatch:` already has `inputs:`, merge `source_sha` under it rather than redefining the key.)

- [ ] **Step 8.2: Thread the SHA into the sync-managed-files call**

In the job that calls `sync-managed-files.yml`, pass the input through. Example:

```yaml
  sync:
    needs: enforce
    uses: ./.github/workflows/sync-managed-files.yml
    with:
      source_sha: ${{ inputs.source_sha }}
    secrets:
      repo-sync-token: ${{ secrets.REPO_SYNC_TOKEN }}
```

(If the workflow currently uses a different wiring, adapt but keep `with.source_sha` passed.)

- [ ] **Step 8.3: Add `source_sha` input to `sync-managed-files.yml`**

At `on: workflow_call:` add:

```yaml
    inputs:
      source_sha:
        description: 'Commit SHA of the docs-control push that triggered this run.'
        required: false
        type: string
        default: ''
```

- [ ] **Step 8.4: Use the SHA to gate Pages reads**

Inside the `Sync managed files` step, **after** inlining the helper (Task 3), add:

```bash
          SOURCE_SHA="${{ inputs.source_sha }}"
          if [ -n "$SOURCE_SHA" ] && ! revision_is_fresh "$SOURCE_SHA"; then
            echo "[WARN] Pages revision lags source ${SOURCE_SHA:0:8} — this run will fall back to API for governed reads" >&2
            # Force fallback by making Pages calls error.
            PAGES_BASE="https://invalid.pages.local"
          fi
```

Placement: immediately after the `PAGES_BASE=…` assignment in Step 3.2.

- [ ] **Step 8.5: Lint**

Run: `yamllint …` on both workflow files.
Expected: clean.

- [ ] **Step 8.6: Commit (delegate)**

Delegate to `f5xc-github-ops:github-ops`:

```
feat(governance): plumb source_sha for Pages staleness guard (Layer B)

Files:
- .github/workflows/enforce-repo-settings.yml
- .github/workflows/sync-managed-files.yml

Why: Pages has a ~2-5 min deploy lag. When dispatch-downstream fires
before Pages has caught up, a downstream relying on Pages could read
stale manifest data and mis-decide 'no drift'. This commit adds an
optional source_sha input that downstreams compare against
/api/revision.json; on mismatch, the run forces API-path reads for
that cycle.

Spec: .github/plans/2026-04-20-fleet-sync-rate-limit-design.md
```

---

### Task 9: Restructure `dispatch-downstream.yml` with matrix fan-out

**Files:**

- Modify: `.github/workflows/dispatch-downstream.yml`

- [ ] **Step 9.1: Replace the whole file**

Replace `.github/workflows/dispatch-downstream.yml` with:

```yaml
---
name: Dispatch Downstream Enforcement

on:
  push:
    branches: [main]
    paths-ignore:
      - 'docs/**'
      - 'README.md'

permissions:
  contents: read

concurrency:
  group: dispatch-downstream
  cancel-in-progress: true

jobs:
  read-config:
    runs-on: ubuntu-latest
    outputs:
      repos: ${{ steps.list.outputs.repos }}
    steps:
      - uses: actions/checkout@v6
      - id: list
        run: |
          repos=$(jq -c . .github/config/downstream-repos.json)
          echo "repos=${repos}" >> "$GITHUB_OUTPUT"

  dispatch:
    needs: read-config
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      max-parallel: 5
      matrix:
        repo: ${{ fromJson(needs.read-config.outputs.repos) }}
    steps:
      - name: Dispatch to ${{ matrix.repo }}
        env:
          GH_TOKEN: ${{ secrets.REPO_SETTINGS_TOKEN }}
        run: |
          retry() {
            local max="$1"; shift
            local attempt=1 delay=2
            while true; do
              if "$@"; then return 0; fi
              if [ "$attempt" -ge "$max" ]; then
                echo "[ERROR] Failed after ${max} attempts: $*" >&2
                return 1
              fi
              echo "[WARN] Attempt ${attempt}/${max} failed — retrying in ${delay}s..." >&2
              sleep "$delay"
              attempt=$((attempt + 1))
              delay=$((delay * 2))
            done
          }

          echo "Dispatching to ${{ matrix.repo }}..."
          if retry 3 gh workflow run enforce-repo-settings.yml \
                --repo "${{ matrix.repo }}" \
                --field "source_sha=${{ github.sha }}"; then
            echo "[OK] ${{ matrix.repo }}"
          else
            echo "[FAIL] ${{ matrix.repo }} (failed after retries)"
            exit 1
          fi
```

- [ ] **Step 9.2: Lint**

Run:

```
yamllint -d '{extends: default, rules: {line-length: {max: 200}, document-start: disable, truthy: disable}}' .github/workflows/dispatch-downstream.yml
actionlint .github/workflows/dispatch-downstream.yml || true
```

Expected: `yamllint` clean. `actionlint` clean if installed.

- [ ] **Step 9.3: Commit (delegate)**

Delegate to `f5xc-github-ops:github-ops`:

```
feat(governance): matrix + max-parallel 5 in dispatch-downstream (Layer B)

Files:
- .github/workflows/dispatch-downstream.yml

Why: The old single-job loop fired all 25 dispatches within ~30s.
Restructured into read-config -> dispatch(matrix, max-parallel: 5)
so at most 5 downstreams run at once. Each dispatch now passes
source_sha so downstreams can detect Pages deploy lag. Propagation
time rises from ~30s to ~10 min; API pressure drops 5x.

Spec: .github/plans/2026-04-20-fleet-sync-rate-limit-design.md
```

---

### Task 10: Matrix structural test

**Files:**

- Create: `tests/test-dispatch-matrix.sh`

- [ ] **Step 10.1: Write the test**

```bash
#!/usr/bin/env bash
# Structural check on dispatch-downstream.yml: the matrix job must
# cap parallelism, pass source_sha, and consume downstream-repos.json.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="${REPO_ROOT}/.github/workflows/dispatch-downstream.yml"
CONFIG="${REPO_ROOT}/.github/config/downstream-repos.json"

FAIL=0
check() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "[OK] $label"
  else
    echo "[FAIL] $label"
    FAIL=1
  fi
}

# 1. Two jobs: read-config, dispatch
check "has read-config job"   "grep -q '^  read-config:$' '$WF'"
check "has dispatch job"      "grep -q '^  dispatch:$' '$WF'"

# 2. Matrix with max-parallel: 5
check "max-parallel: 5 set"   "grep -q '^[[:space:]]*max-parallel:[[:space:]]*5' '$WF'"
check "matrix from fromJson"  "grep -q 'fromJson(needs.read-config.outputs.repos)' '$WF'"

# 3. Passes source_sha input
check "passes source_sha"     "grep -q 'source_sha=\${{ github.sha }}' '$WF'"

# 4. downstream-repos.json is valid JSON array
check "config is JSON array"  "jq -e 'type == \"array\" and length > 0' '$CONFIG' > /dev/null"

# 5. Optional: actionlint if present
if command -v actionlint >/dev/null 2>&1; then
  check "actionlint clean"    "actionlint '$WF' >/dev/null 2>&1"
fi

exit "$FAIL"
```

- [ ] **Step 10.2: Run it, expect PASS**

Run: `bash tests/test-dispatch-matrix.sh`
Expected: all `[OK]`, exit 0.

- [ ] **Step 10.3: Wire into CI**

Add to the `shell-unit-tests` job created in Task 6:

```yaml
          bash tests/test-dispatch-matrix.sh
```

- [ ] **Step 10.4: Commit (delegate)**

Delegate to `f5xc-github-ops:github-ops`:

```
test(governance): structural tests for dispatch matrix (Layer B)

Files:
- tests/test-dispatch-matrix.sh
- .github/workflows/super-linter.yml  (wire test into CI)

Spec: .github/plans/2026-04-20-fleet-sync-rate-limit-design.md
```

---

### Task 11: Open PR 2 (Layer B) and verify post-merge

- [ ] **Step 11.1: Delegate PR-open**

Delegate to `f5xc-github-ops:github-ops`:

```
feat: throttle fleet-sync fan-out to max-parallel 5 (Layer B, PR 2 of 2)

Opens an issue and PR for Layer B. Merges on green CI. After merge,
trigger a dummy change on docs-control main and observe:
- dispatch-downstream schedules at most 5 runs at a time
- source_sha is visible in each downstream's enforce-repo-settings run
- PAT rate-limit core.remaining stays above 4000/5000 during the cycle

Spec: .github/plans/2026-04-20-fleet-sync-rate-limit-design.md
```

- [ ] **Step 11.2: Acceptance**

After merge, trigger a dummy push to `docs-control main` (e.g. bump a comment). Open the `dispatch-downstream` run. Verify:

- The job page shows 25 matrix cells; at most 5 "in progress" concurrently.
- Total runtime ≈ 8–12 min (5 batches × ~2 min each).
- `gh api rate_limit --jq '.resources.core.remaining'` stays above 4000 throughout.
- Downstream sync logs include `[OK] Fetched … from Pages` and ≤ 1 `[WARN] Pages unavailable` line (the latter only if a downstream ran before Pages caught up; the staleness guard should have forced API fallback in that one case and succeeded).

If acceptance passes, close the tracking issue. If `max-parallel: 5` proves unnecessarily slow, open a small follow-up PR raising it to 8 or 10.

---

## Self-Review (against spec)

- **Spec § "Layer A — Read-path moves to GitHub Pages"** → Tasks 1 (helper), 2 (Pages publishing), 3 (sync-managed-files), 4 (enforce-repo-settings). ✓
- **Spec § "Staleness guard"** → Task 8 (`source_sha` plumbing + `revision_is_fresh` gate). ✓
- **Spec § "Error fallback"** → Task 1 (`fetch_governed` falls back to `gh api` on failure) + Task 3/4 (uses it). ✓
- **Spec § "Scope check" (PR-branch reads remain on API)** → Task 3 step 3.4 leaves the two base64-PUT-content reads on the API path. ✓
- **Spec § "Layer B — Throttle the fan-out"** → Task 9 (matrix restructure). ✓
- **Spec § Tests → unit: pages-fetch-helper** → Task 1. ✓
- **Spec § Tests → unit: revision-staleness** → Task 1 (`revision_is_fresh` tests in same file). ✓
- **Spec § Tests → unit: dispatch-matrix** → Task 10. ✓
- **Spec § Acceptance → shell tests pass, actionlint/yamllint clean, PAT ≥ 4000/5000** → Task 6 (CI wiring), Task 7/11 (post-merge verification). ✓
- **Spec § Risks → helper not available downstream** → Task 3/4 (inlined verbatim) + Task 5 (drift guard). ✓
- **Spec § Risks → Pages stale** → Task 8 (`revision_is_fresh` gate). ✓
- **Spec § Risks → source_sha absent for manual runs** → Task 8 Step 8.4 (`[ -n "$SOURCE_SHA" ] &&` guard — absent = use Pages, consistent with spec non-goal to hard-gate manual runs).

**Placeholder scan:** grep'd for TBD/TODO/"similar to Task" — none present.

**Type/name consistency:**

- `fetch_governed` called identically in Tasks 1, 3, 4.
- `revision_is_fresh` defined in Task 1, used in Task 8.
- `PAGES_BASE` set consistently to `https://f5xc-salesdemos.github.io/docs-control` in Tasks 3, 4. Task 8 overrides to `https://invalid.pages.local` on staleness (intentional, documented).
- `source_sha` threaded as `inputs.source_sha` in both consumer workflows; `--field source_sha=` in the dispatcher.

No gaps or contradictions found.
