# Canonical scanner reconciliation

The owning `Reconcile Canonical Scanners` workflow delivers exactly four governed
paths: `.gitleaks.toml`, `scripts/check-pii.sh`, `scripts/check_pii.py`, and
`tests/test-check-pii.sh`. It has no push trigger and does not invoke the full
content or settings reconciler. The existing full reconciler remains unchanged.

Start with `dry-run`, the workflow default. Supply the explicit four-path JSON
array and an optional repository selection from the canonical downstream inventory.
`pilot` requires exactly one selected repository. `full` considers the selected
active inventory, with the same two-active-governance-PR limit and concurrency
group used by full content reconciliation. Archived repositories are reported as
`skipped-archived`; their archive flags are never changed.

Before any write, the coordinator validates the complete manifest, its exact source
commit and tree through GitHub, local source bytes, path selection, and opt-outs.
The source SHA must equal the manifest source receipt. It uploads canonical blobs
into each destination object database and verifies their SHA before constructing
a tree from protected main. Only scoped scanner paths can change in that tree.

Separate scanner branches and markers bind the source, fixed scope, desired tree
and original base. Recovery verifies the issue and PR owner, exact commit, complete
file inventory, and current head/ref identity. Partial branches require an exact
comparison before recovery. A PR changing a scanner path defers new delivery;
unrelated full-content owners remain untouched. Stale or foreign scoped owners
fail explicitly. Dry-run performs no writes, including recovered auto-merge.

`retire-only` retires only an exact selected scanner owner for the current source
and desired tree. It verifies ownership before closing its PR and tracker or
removing its exact branch. Closed retirement resumes idempotently. It never
retires full-content owners or infers authority over stale sources.

Required review and green CI precede producer merge and workflow dispatch. Each
downstream PR follows normal review and branch protection. After merge, independent
receipts must verify the exact main commit and four file blobs/modes. Source tests,
a request acknowledgement or an archived skip cannot establish fleet convergence.
Scanner convergence does not qualify CE interface transitions or release UAT.

Run focused checks with `bash tests/test-scanner-scope.sh` and
`bash tests/test-scanner-lifecycle.sh`, followed by the existing reconciler suite,
workflow validation and repository checks.
