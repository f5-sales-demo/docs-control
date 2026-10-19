# Exact-head AGY review repair

Issue: https://github.com/f5-sales-demo/docs-control/issues/2584

## Contract

Report envelope and target receipts are version 2. Code targets distinguish supplied base,
merge-base and head. Document targets bind kind, repository-relative path, content hash and
head. The supervisor binds source filesystem bytes before and after the two sessions.
Required coverage includes changed paths and the frozen input; deleted paths are covered by
the frozen diff. Two schema-valid explicit approvals, complete reads, distinct conversations,
the same stream-reported model and no high/critical findings are required.

`agy models` selects the highest numeric stable flagship High variant, excluding Flash,
Lite and previews. `--effort high` is explicit invocation evidence; the init event does not
currently expose an effort field. Thinking-token usage in live probes corroborates reasoning
execution but cannot independently establish the effort setting.

Fallback is disabled until the governed policy contains a live qualification under the
intended CI identity. Catalog ambiguity/failure or unavailable models may use that qualified
model; findings and invalid output cannot trigger fallback. Any fallback discards the pair.
Fallback approvals never claim latest-model acceptance.

Review and publication use a separate immutable docs-control checkout. Target checkout content
cannot replace the tools. All model streams remain private; only redacted diagnostics and
redacted structured output reach artifacts or publication. Process groups are terminated
externally at 720 seconds per attempt and within 2,700 seconds overall. Regular private output
files avoid FIFO draining or inherited descriptors keeping the wrapper alive.

## Tasks and evidence

- [x] Reproduce failing real-wrapper regression tests before repair.
- [x] Implement receipt, verdict, coverage, session, catalog, redaction and lifecycle repairs.
- [x] 17 real-wrapper regressions and executable exact-head workflow UAT pass on Ubuntu.
- [x] Existing PII suite, 67 routing, 11 suspension, 6 control-verifier and 239 guidance checks pass; Ruff, ShellCheck and Actionlint pass.
- [ ] Qualify two exact-target sessions under intended CI identity; promote governed fallback.
- [ ] Commit/push implementation, linked PR repair loop and merge.
- [ ] Update governed caller pins and prove downstream manifest convergence.

Disabled PII and Antigravity controls remain unchanged. The explicitly authorized enable of
`aiplatform.googleapis.com` succeeded, and a bounded Argon High probe returned SUCCESS.
A full native pair subsequently returned two explicit approvals with distinct conversations, complete coverage and stable input at b6c4d5db4165592bcc0b32a6ecd089f05f447242. The sanitized receipt is receipts/agy-review-2584-workstation.json. Workstation evidence does not establish CI identity acceptance.
