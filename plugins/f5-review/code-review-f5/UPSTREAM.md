# Vendored plugin provenance

`code-review-f5` is a **vendored, pinned** copy of Anthropic's `code-review`
plugin, extended for the F5 self-hosted reviewer. Vendoring (not runtime
marketplace fetch) keeps the reviewer closed-loop: no runtime dependency on
github.com/anthropics, and the exact review logic is pinned by docs-control's own
commit SHA.

## Source

- Repo: `anthropics/claude-code`
- Path: `plugins/code-review/`
- Pinned commit: `c4dbd740a7ed59b64cecbe6881b9e0f1c60b29e8`
- Vendored: 2026-07-21

## F5 extensions applied on top of upstream `commands/code-review.md`

Marked with `F5-EXTENSION` comments in the command so a re-sync diff is obvious:

- **E2 — verdict.json**: a final step writes `./verdict.json`
  (`{blocking, severity_counts, findings}`) so `scripts/parse-verdict.sh` can
  block merges on 🔴. Upstream is advisory-only and emits no machine-readable
  verdict; blocking is a deliberate F5 divergence.
- **E3 — F5 rubric**: the highest-priority rules from `REVIEW.md`
  (prompt-injection hardening, secret non-exfiltration, "prove it against the real
  internal APIs" verification requirement, 🔴 merge-blocking severity) are baked in.
- **E4 — verification subagent**: a 5th parallel review agent runs the reviewed
  repo's `.code-review/verify.sh` / `terraform plan` / `az` read calls over the
  VPN and flags a 🔴 when a command that should succeed fails.

## Model tiers (E1)

Upstream fans out to `haiku`/`sonnet`/`opus` subagents. The reusable workflow sets
`ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL=claude-opus-4-8` so every subagent
resolves to a model our LiteLLM gateway serves (also = the always-use-opus policy).

## Re-syncing from upstream

1. Fetch the new upstream `commands/code-review.md` at the new pin.
2. Re-apply the `F5-EXTENSION` blocks (they are self-contained and clearly marked).
3. Update the pinned commit above and re-run the UAT matrix before merging.
