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
6. **Never claim an unverified check.** The authenticated-verification leg depends on
   the operator's CLIs on the self-hosted runner, which can break without any review
   failing. A preflight (`scripts/check-review-deps.sh`, run per review into
   `./review-deps.txt`) records whether each CLI is usable; when DEGRADED the review
   MUST say which capability was unavailable instead of reporting that it checked it.
   Deliberately non-blocking — a broken CLI must not deadlock every PR — but never
   silent. *(Added after a non-executable `terraform` shim was the only terraform on
   the launchd PATH, so verification silently no-op'd while reviews reported success.)*

## Severity taxonomy

Findings map to `high` (🔴, merge-blocking), `medium` (🟠, reported and counted,
non-blocking), and `low` (🟡, nit). `high` blocks; counts must match `findings`.
*(Note: `medium` was historically present in the schema but never emitted by the
rubric — WS1-PR1b activates it end-to-end.)*

## Planned work

- **Trusted default-branch-pinned `verify.sh` pre-step (WS2) — BUILT** (workflow step
  "Trusted verification (default-branch-pinned verify.sh)" in `claude-review.yml`; results
  consumed by the review agent via `./verify-output.txt`). Design as specified
  below. Consumer confirmed: `f5-sales-demo/dns` ships `.code-review/verify.sh`
  (terraform `fmt`/`init`/`validate` with a temporary local-backend override — no
  credentials, self-cleaning) and its docstring always assumed the reviewer runs it.
  Design:
  - **Trust boundary.** The PR head's `.code-review/verify.sh` is UNTRUSTED (a PR
    could carry a malicious script). The **default-branch** copy is trusted, having
    been merged and reviewed on a protected branch. The pre-step must run that
    script's *logic* while verifying the head's *code*.
  - **Mechanism.** Before the Claude step, if the **default branch** has the file:
    fetch that branch, then `git show origin/<default>:.code-review/verify.sh` and
    **overwrite the head working copy** at `.code-review/verify.sh` with it (so
    relative paths like `../terraform` resolve in-tree), then
    `bash .code-review/verify.sh`. This runs trusted script logic against head
    code — never the head's script bytes.
  - **Pin to the DEFAULT branch, never the PR base.** A PR may target ANY branch, so
    the base is only as trustworthy as that branch: a contributor could push a
    malicious `verify.sh` to an unprotected feature branch, open a PR targeting it,
    and have it executed with the operator's live credentials. The default branch is
    protected and review-required. PRs not targeting the default branch are skipped.
  - **Residual risk (documented).** `terraform init` on head HCL can still fetch a
    head-declared provider source — the SAME surface Agent 5's allow-listed
    `terraform init/plan` already has; not widened by this step. Bound with a
    step timeout; never echo secrets.
  - **Output → Agent 5.** Capture stdout+exit code to `verify-output.txt`; the
    verification agent reads that file (not the raw script) and flags a 🔴 only
    when a should-succeed verification fails because of the PR.
  - **UAT (proven live on `dns` PR #581).** (1) default-branch `verify.sh` present →
    it runs and its output is surfaced; (2) a PR that REPLACES `verify.sh` with a
    payload → the payload's bytes are NEVER executed (the pinned version is used —
    confirmed: the pinned script's exit code appeared, never the marker's, and the
    reviewer independently reported the boundary held); (3) repo with no
    `.code-review/verify.sh`, or a PR not targeting the default branch → pre-step is
    a no-op and the review proceeds.
  - **Rollout.** Ship behind the existing dark-bake posture; validate on `dns`
    first. This is the safe closure of E4.
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
