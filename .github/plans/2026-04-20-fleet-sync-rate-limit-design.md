# Fleet-sync rate-limit mitigation

**Date:** 2026-04-20
**Status:** Draft (pending review)
**Owner:** @robinmordasiewicz
**Related work:** commit `03466b6` (first-pass hardening), issue #354 / PR #355 (last merge that exposed the storm)

## Problem

`dispatch-downstream.yml` fans out to 25 downstream repos on every push to `main` of `docs-control`.
Each downstream runs `enforce-repo-settings.yml` + `sync-managed-files.yml`, which together make
~15 API calls in the no-drift case and ~80 API calls per drifted repo. Twenty-five downstreams
firing concurrently drain the shared `REPO_SETTINGS_TOKEN` PAT budget (5000/hr) and trigger
secondary (write) rate limits.

Observed on 2026-04-20 after merging PR #355: the shared PAT showed `5000/5000` consumed with a ~18-minute reset window; the user cancelled the `dispatch` job at 2m 45 s; downstream `enforce-repo-settings` runs that did launch returned HTTP 403 rate-limit errors mid-execution.

First-pass hardening in `03466b6` (retry backoff cap, rate-limit sleep-to-reset, manifest-based drift detection, doubled poll intervals) reduced the problem but did not eliminate it at the 25-repo fan-out scale.

## Goals

1. Eliminate the shared-PAT read storm (downstream → docs-control content fetches).
2. Spread write bursts (PR/branch/file creates on each downstream) so GitHub's secondary write limits are not tripped.
3. Preserve the current pull/self-healing model — a downstream that is offline or late must still catch up on its next trigger.
4. Preserve notification semantics — a merge to `docs-control main` still causes every downstream to synchronize within a reasonable window.

## Non-goals

- Full inversion to a push model (docs-control opens all PRs centrally). Deferred as option C in brainstorming — only considered if A + B prove insufficient.
- Moving to a GitHub App credential. Future follow-up; orthogonal to the storm mechanics.
- Changing what counts as a managed file or the governance semantics of `.claude/governance.json`.

## Design

### Layer A — Read-path moves to GitHub Pages

`docs-control` already publishes a Pages site via `github-pages-deploy.yml` on push to `main` when `docs/**`, `.github/config/**`, or `workflows/**` change. Extend that deploy with a governance-assets staging step that writes five artifacts to the Pages output under `/api/`:

| Served path | Replaces API call | Consumers |
| --- | --- | --- |
| `/api/repo-settings.json` | `gh api repos/…/contents/.github/config/repo-settings.json` | `enforce-repo-settings.yml`, `sync-managed-files.yml` |
| `/api/managed-files-manifest.json` | `gh api repos/…/contents/.github/config/managed-files-manifest.json` | `sync-managed-files.yml` |
| `/api/docs-sites.json` | `gh api repos/…/contents/.github/config/docs-sites.json` | `sync-managed-files.yml` |
| `/api/README.md.tpl` | `gh api repos/…/contents/README.md.tpl` | `sync-managed-files.yml` |
| `/api/files/<dest-path>` | `gh api repos/…/contents/<src>` (per-file fallback) | `sync-managed-files.yml` |
| `/api/revision.json` | (new) `{commit: "<sha>", generated_at: "<iso>"}` | staleness check |

Downstreams fetch with `curl -fsSL --retry 2 --retry-delay 2 --max-time 10`. HTTPS requests to `github.io` are CDN-served and do **not** consume GitHub API rate-limit budget.

**Staleness guard.** Pages has its own deploy lag (~2–5 min after merge). To avoid serving a
stale manifest that makes a downstream decide "no drift" when the canonical content has already
moved, downstreams fetch `/api/revision.json` first and compare its `commit` against the SHA
that triggered their enforcement run. The SHA is passed from `dispatch-downstream.yml` via
`gh workflow run … --field source_sha=<sha>` and read downstream as `${{ inputs.source_sha }}`
on the `workflow_dispatch` trigger (requires adding an optional `source_sha` input to
`enforce-repo-settings.yml`). If Pages is behind or the input is absent (e.g. a human-triggered
manual run), the downstream falls back to API-path reads for that cycle. This is expected to be
rare and self-correcting within one minute.

**Content encoding.** The GitHub Contents API returns file bodies base64-wrapped inside a JSON envelope. The Pages `/api/` path serves raw file bytes directly (same MIME, no envelope). The helper returns the decoded content to the caller either way, so call sites are unchanged; only the helper itself branches on source.

**Error fallback.** Every Pages fetch is wrapped in a helper that, on non-200 or empty/invalid body, falls back to the existing `retry 3 gh api …` path. The fallback is the current storm behavior, but only triggered when Pages is unavailable — net-new pressure vs. status quo is zero.

**Scope check.** Downstreams also use `gh api repos/…/contents/<path>?ref=governance/sync-managed-files` calls to read PR-branch file SHAs before updating them (lines 427, 446, 465 of `sync-managed-files.yml`). These are reads of the *downstream's own* branch state, not docs-control content, and cannot be moved to Pages. They remain on the API.

### Layer B — Throttle the fan-out

Restructure `dispatch-downstream.yml` into two jobs:

```yaml
jobs:
  read-config:
    runs-on: ubuntu-latest
    outputs:
      repos: ${{ steps.list.outputs.repos }}
    steps:
      - uses: actions/checkout@v6
      - id: list
        run: echo "repos=$(jq -c . .github/config/downstream-repos.json)" >> "$GITHUB_OUTPUT"

  dispatch:
    needs: read-config
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      max-parallel: 5
      matrix:
        repo: ${{ fromJson(needs.read-config.outputs.repos) }}
    steps:
      - name: Dispatch
        env:
          GH_TOKEN: ${{ secrets.REPO_SETTINGS_TOKEN }}
        run: |
          retry 3 gh workflow run enforce-repo-settings.yml \
            --repo "${{ matrix.repo }}" \
            --field source_sha=${{ github.sha }}
```

`max-parallel: 5` caps concurrent downstream kickoffs to 5. Each downstream run takes ~2 min, so 25 repos finish in ~10 min (was ~30 s). Throughput drop is acceptable; the window between merge and full propagation stays under CI fast-feedback expectations.

Passing `source_sha` lets downstreams compare against `/api/revision.json` (see Layer A staleness guard).

### Interaction between A and B

A reduces *per-downstream* API calls by ~80 % (manifest/config/template reads move to Pages;
content fetches for drifted files move to Pages/files/). B reduces *concurrent* downstreams
by 5×. Multiplicatively: expected API consumption per push drops from ~2 000 calls
concentrated in 30 s to ~400 calls spread over 10 min — well under the 5 000/hr PAT budget
and well under secondary-limit burst thresholds.

A works alone (preserves storm pacing but drops volume). B works alone (preserves storm volume but spreads it). Landing both yields a comfortable margin; landing neither is status quo. Land A first, verify PAT usage drops, then land B.

## Tests

**Unit tests (shell, in `tests/`):**

1. `test-pages-fetch-helper.sh` — the fetch-from-Pages-with-API-fallback shell function (canonical source at `tests/fixtures/fetch-governed.sh`, inlined into each consumer workflow) with stubbable `curl`/`gh`. Cases:
   - Pages returns 200 + valid JSON → use Pages result, no `gh api` call.
   - Pages returns 404 → fallback to `gh api`, verify exit 0 and content matches.
   - Pages returns 200 + empty body → fallback to `gh api`.
   - Pages times out → fallback to `gh api`.
   - Both Pages and `gh api` fail → exit non-zero.
2. `test-revision-staleness.sh` — helper that compares `/api/revision.json` SHA against `$source_sha`. Cases: equal SHA → proceed with Pages; Pages ahead → proceed (shouldn't happen); Pages behind → force-fallback flag set.
3. `test-dispatch-matrix.sh` — YAML-lint and schema-validate the new two-job `dispatch-downstream.yml`; `actionlint` it; verify `fromJson()` expansion on a sample `downstream-repos.json`.

**Integration check (acceptance, not CI):**

After merge, trigger a dummy change (bump a comment in `repo-settings.json`), observe:

- `/api/revision.json` appears on Pages site within 5 min of merge.
- First 5 downstream runs begin within ~10 s of each other; next batch follows ~2 min later.
- Downstream `sync-managed-files` logs include `[OK] Fetched … from Pages` lines and zero or few `[WARN] Pages unavailable, falling back to API` lines.
- `gh api rate_limit` for the PAT stays above 4 000 / 5 000 across the cycle.

## Acceptance criteria

- Shell unit tests pass under `bash` and under `dash` (portability — downstream runners may vary).
- `actionlint` and `yamllint` pass on modified workflow files.
- After one post-merge fleet cycle, PAT core-rate-limit remaining stays ≥ 4 000 / 5 000 during the propagation window.
- Any downstream run that trips the Pages fallback emits a `[WARN] Pages unavailable` log line — observability, not a test gate.
- No change to which files get synced, PR titles, issue titles, or commit messages — purely a transport-and-pacing change.

## Risks

| Risk | Probability | Mitigation |
| --- | --- | --- |
| Pages serves stale manifest → downstream decides "no drift" when drift exists | Medium | Revision staleness guard with `source_sha` comparison; fallback to API on mismatch. |
| Pages CDN outage blocks all read paths | Low | Every Pages call has API fallback; worst case is reverting to status-quo storm. |
| `max-parallel: 5` too conservative, propagation too slow | Low | Tuneable; if acceptable post-rollout, raise to 8 or 10 in a follow-up PR. |
| Source SHA plumbing fails for `workflow_dispatch` (manual) runs | Low | Absent `source_sha` → force-fallback to API path for that run only. |
| Helper script not available downstream | Low | Downstream `actions/checkout@v6` pulls the downstream repo, not docs-control, so external helpers are unreachable. Inline the helper as a shell function in each consumer workflow; a drift-check test keeps the copies in sync with the canonical source. |

## Rollout

1. **PR 1** — Add Layer A: extend `github-pages-deploy.yml` with governance-assets staging + `revision.json`; add fetch helper (inline function) to `sync-managed-files.yml` and `enforce-repo-settings.yml`; shell unit tests; actionlint. Reads now prefer Pages, fall back to API on any failure.
2. **Verify** — After merge, trigger a dummy change and confirm `/api/revision.json` publishes and downstream logs show Pages reads. Expected PAT usage drops ~80 % per cycle.
3. **PR 2** — Add Layer B: split `dispatch-downstream.yml` into `read-config` + matrix'd `dispatch`; pass `source_sha` through. Integration test by dummy-trigger again.
4. **Observe** — Two post-merge cycles. Tune `max-parallel` in a small follow-up if needed.

If PR 1 regresses anything, revert it cleanly — downstreams return to API-only reads with zero state carried forward. PR 2 is equally safe to revert independently.

## Open questions

- Should `/api/files/<dest>` expose every managed file, or only the ones currently in `managed_files` config? Proposing: only the current set, regenerated each deploy, pruned otherwise. Reduces attack surface and keeps the Pages site focused.
- Should the staleness guard hard-fail or silently fall back? Proposing: silently fall back with a `[WARN]` log line — operators don't want a red downstream run just because Pages hadn't caught up yet.
