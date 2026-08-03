# Reviewer spec

The Claude reviewer runs on an ephemeral GitHub-hosted runner for same-repository,
human-authored pull requests. It is currently advisory at the branch-protection
layer: `review / claude-review` is not a required context. Promote it back to a
required context only after a representative fleet pilot has completed end-to-end.

Canonical design for the fleet's agentic PR reviewer. It complements `REVIEW.md`
(the highest-priority review rubric baked into the plugin command) by documenting
the reviewer's **architecture, invariants, and planned work**. Earlier code
referenced "the reviewer spec" before this file existed
(`plugins/f5-review/code-review-f5/UPSTREAM.md`,
`plugins/f5-review/code-review-f5/commands/code-review.md`); this is that file.

## Architecture

- **Caller** (`workflows/code-review.yml`, synced to opted-in repos) triggers on
  `pull_request` and delegates to the **reusable reviewer**
  (`.github/workflows/claude-review.yml@main`) on an ephemeral GitHub-hosted runner.
- The reusable workflow self-provisions the vendored, F5-extended `code-review`
  plugin (`plugins/f5-review/`) and runs it via `anthropics/claude-code-action`
  (SHA-pinned) against the F5 LiteLLM gateway (`claude-opus-4-8`, 1M context).
- The plugin command fans out: triage (haiku) → CLAUDE.md path list (haiku) →
  summary (sonnet) → 5 parallel reviewers (2× CLAUDE.md compliance, 2×
  bug/logic/security, 1× repository-local verification) → per-finding validation →
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
4. **Fork isolation.** Fork PRs never reach the reviewer (hard guard in both caller
   and reusable workflow).
5. **Fail-safe reliability.** Per-PR concurrency cancellation; bounded job and step
   timeouts; a single safe retry only when nothing was posted and no verdict exists.
6. **Never claim an unverified check.** Repository-local verification depends on
   tools in the ephemeral job, which can break without the model review failing. A
   preflight (`scripts/check-review-deps.sh`, run per review into
   `./review-deps.txt`) records whether each tool is usable; when DEGRADED the review
   MUST state which capability was unavailable. The hosted job deliberately has no
   operator cloud session and must never claim authenticated cloud verification.

## Severity taxonomy

Findings map to `high` (🔴, merge-blocking), `medium` (🟠, reported and counted,
non-blocking), and `low` (🟡, nit). `high` blocks; counts must match `findings`.
*(Note: `medium` was historically present in the schema but never emitted by the
rubric — WS1-PR1b activates it end-to-end.)*

## Local pre-push layer (Codex second opinion)

A second, **advisory** review layer runs on the engineer's machine before the pull
request exists. It is not the gate described above and must not be confused with it.

- **Advisory, not a gate.** It emits no `verdict.json`, posts no commit status, and
  **Invariant 1 does not apply to it** — there is no required check for it to
  deadlock. It never blocks work; if the tooling is absent it is skipped.
- **Where it runs.** Locally, at the spec and plan review gates, before a push that
  opens or updates a pull request, and after each round of fixes. Tooling:
  `f5-sales-demo/codex-plugin-cc`, skill `verified-code-review`, subcommands
  `review-doc` and `review-gate`.
- **Read-only sandbox.** The reviewer runs with the `read-only` sandbox so it cannot
  modify the tree it is judging. **This does not satisfy Invariant 3.** Read-only
  prevents writes; it does not prevent command execution, network access, or reading
  anything the user can read. Invariant 3 governs the CI reviewer, which faces
  third-party pull-request content; this layer reviews the engineer's own branch
  before a pull request exists. Do not describe read-only as an untrusted-content
  boundary.
- **Severity mapping.** Codex emits four severities against its own schema; they map
  onto the three tiers above as `critical`/`high` → 🔴, `medium` → 🟠, `low` → 🟡.
  A missing or unrecognized severity maps to 🔴 (fail-closed), because the plugin's
  `parseStructuredOutput` performs no schema validation.
- **Verification is mandatory.** A finding blocks the local loop only when a
  verification pass CONFIRMED it against the codebase — for code, with a test that
  fails today; for a document, with a quotation. This is not ceremony: an AI reviewer
  misattributes findings to files that do not contain them, and a hallucinated
  blocking finding can never be fixed, so treating it as blocking would prevent the
  loop from ever terminating.
- **Bounded.** Three iterations maximum, with no-progress detection when two
  consecutive rounds produce the same blocking set. On either, the outstanding
  findings go to a human rather than round four.

The two layers are complementary: the local layer catches issues before the pull
request exists and costs nothing when it is wrong, while CI remains the gate that
decides whether a change merges.

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
    and have it executed with the job token and network access. The default branch
    is protected and review-required. PRs not targeting it are skipped.
  - **Residual risk (documented).** `terraform init` on head HCL can still fetch a
    head-declared provider source. The hosted job therefore carries no cloud
    credentials. It is bounded with a step timeout and never echoes secrets.
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
- **Reliability/ops (WS6).** Findings/override telemetry and model fallback.

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
