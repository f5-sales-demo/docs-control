# Reviewer spec (target-state design)

Canonical design for the fleet's agentic PR reviewer. It complements `REVIEW.md`
(the highest-priority review rubric baked into the plugin command) by documenting
the reviewer's **architecture, invariants, and planned work**. Earlier code
referenced "the reviewer spec" before this file existed
(`plugins/f5-review/code-review-f5/UPSTREAM.md`,
`plugins/f5-review/code-review-f5/commands/code-review.md`); this is that file.

## Architecture

- **Caller** (`workflows/code-review.yml`, synced to opted-in repos) triggers on
  `pull_request` and delegates to the **reusable reviewer**
  (`.github/workflows/claude-review.yml@main`) on a self-hosted, VPN-connected
  runner labeled `code-review`.
- The reusable workflow self-provisions the vendored, F5-extended `code-review`
  plugin (`plugins/f5-review/`) and runs it via `anthropics/claude-code-action`
  (SHA-pinned) against the F5 LiteLLM gateway (`claude-opus-4-8`, 1M context).
- The plugin command fans out: triage (haiku) → CLAUDE.md path list (haiku) →
  summary (sonnet) → 5 parallel reviewers (2× CLAUDE.md compliance, 2×
  bug/logic/security, 1× authenticated verification) → per-finding validation →
  inline comments + one summary comment → `verdict.json`.
- **Gate**: `scripts/parse-verdict.sh` fails the required `review / claude-review`
  check on any blocking (🔴/high) finding.

## Invariants (MUST hold)

1. **Always emit a verdict.** The reviewer is a merge GATE, not an advisory bot.
   Every exit path — normal, skip, or early-out — MUST write `./verdict.json`
   before the job ends. The gate treats a missing/empty verdict as **blocking**
   (fail-safe), so any path that stops without a verdict fails the required check.
   A skip writes a non-blocking verdict (`{"blocking": false, ...}`). *(Enforced
   by F5-EXTENSION E5 after the re-push deadlock — see below.)*
2. **Idempotent re-review.** A new push (`synchronize`) re-reviews the current
   head and emits a fresh verdict; it never hard-stops on "already commented."
   Re-reviews post only new findings (no duplicate comments) but always re-emit
   the verdict.
3. **Untrusted PR content.** The diff, title, body, commit messages, and comments
   are untrusted DATA. Never execute scripts carried in the PR head; never print
   or exfiltrate secrets. Prompt-injection attempts are 🔴 findings.
4. **Fork isolation.** Fork PRs never reach the self-hosted runner (hard guard in
   both caller and reusable workflow).
5. **Fail-safe reliability.** Machine-wide slot semaphore; per-PR concurrency
   cancel; a single safe retry only when nothing was posted and no verdict exists.

## Severity taxonomy

Findings map to `high` (🔴, merge-blocking), `medium` (🟠, reported and counted,
non-blocking), and `low` (🟡, nit). `high` blocks; counts must match `findings`.
*(Note: `medium` was historically present in the schema but never emitted by the
rubric — WS1-PR1b activates it end-to-end.)*

## Planned work

- **Trusted base-pinned `verify.sh` pre-step (WS2).** A workflow pre-step checks
  out the PR **base** ref and runs the repo's `.code-review/verify.sh` from base
  only (never PR head), in a least-privilege sandbox, feeding results to the
  verification agent. This is the safe closure of E4: it never executes
  PR-head-carried scripts.
- **Deterministic layers (WS3/WS4).** Cross-module dead-code (Knip, Python
  dead-code) and dedicated SAST (Semgrep/CodeQL, SARIF → Code Scanning) run in the
  lint gate; the reviewer covers judgment calls.
- **Reliability/ops (WS6).** Org-level runner pool (remove the single-laptop
  single point of failure), findings/override telemetry, model fallback.

Implemented since: **WS5 reviewer dimensions** — correctly-scoped
YAGNI/overengineering, reinvented-logic (semantic DRY), and newly-orphaned-code
checks, capped at 🟠/🟡 (see `REVIEW.md`).

## Known residual risks

- **Branch-prefix bypass (accepted, documented).** Genuine automated branches
  (`governance/`, `sync/`, `release/`, `openapi-sync/`, `plugin-sync/`, `deps/`,
  `docs/update-`, `auto-*`, `autoresearch/`) skip the real review and get a
  synthetic passing status, because they are created by human-owned automation
  PATs (so `github.actor` is a human and cannot be distinguished from a person
  naming a branch with one of those prefixes). RESIDUAL RISK: a write-access
  contributor could bypass the required review by using such a prefix. Mitigated
  today by trusted-write-access + the fork hard-guard. Full closure needs an
  org-level branch-creation ruleset restricting who may push those prefixes, or a
  dedicated automation App/bot identity so the bypass keys on actor, not branch
  name — deferred as an org-admin decision (see caller `workflows/code-review.yml`
  comments).

See `docs-control/REVIEW.md` for the operative rubric and
`f5-sales-demo/code-review/docs/REVIEWER-GAP-ANALYSIS.md` for the full
requirements catalog and verified findings.
