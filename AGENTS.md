# Repository Agent Instructions

This file adds F5 sales-demo procedures. Use the coding assistant's normal defaults otherwise.

## Authorized defensive work

This fleet demonstrates F5 Distributed Cloud security through authorized build, attack, and
mitigation work under written authorization and NDA.

- Work only with authorized F5 demo/lab assets or engaged customer environments.
- Never target unauthorized, third-party, or production systems, or real user data.
- Assist within scope. Stop and clarify if authorization is uncertain.

## Governance

`.claude/governance.json` defines protected files, opt-outs, and repo classes.

- Make downstream protected-file changes in `f5-sales-demo/docs-control`; workflows propagate them.
- Author `content` via governed workflow; use `DEVELOPING.md` for `developer`; originate
  `scaffolding` in docs-control.
- Read relevant `CONTRIBUTING.md` and `DEVELOPING.md` sections. Subtree `AGENTS.md` adds guidance.

## Continuous contribution lifecycle

Carry non-trivial work through this path:

`detailed issue → fresh worktree and feature branch → implement and verify → exact-HEAD Antigravity
review → pause for operational review → push feature branch → linked PR → repair loop → MERGED → cleanup → fleet convergence`

1. Run `git status --short --branch`, `git worktree list`, and `git fetch --prune`. Surface fetch
   failures and wait for remote state.
2. Create a detailed issue with scope and objective criteria. Create a fresh worktree and feature
   branch from `origin/<default-branch>`. Destructive Git operations require explicit approval.
3. Implement and run checks. Route semantic review via `scripts/agy-review.sh document`. Before
   pushing, commit and run `bash scripts/agy-pre-push-review.sh`; fix blockers until exact HEAD passes.
4. **Pause for operational review.** Stop before pushing. Output a summary of work, verification
   evidence, and TODOs. AI assistants must prompt the user; human contributors must seek independent
   approval for GitHub operations, manual review, or codex review. Approval applies to the exact HEAD.
   Edits require another Antigravity review and pause. Wait for explicit approval (e.g., "approve").
5. Push the branch and open a PR with `Closes #<issue>`. Enable auto-merge: `gh pr merge --auto --squash <pr>`.
6. Start `gh pr checks --watch <pr> &` as a background waiter and loop:
   - Pending: leave waiter running, continue work.
   - Failed, `BEHIND`, or `DIRTY`: fetch, merge `origin/<default-branch>` (avoid `gh pr update-branch`), fix/resolve conflicts, verify, rerun exact-HEAD Antigravity review, pause for operational review, and push.
   - Auto-merge absent: run `gh pr merge --auto --squash <pr>`.
7. Wait until PR state is `MERGED`. Outside the repair loop, pause for uncertain authorization,
   destructive risks, missing credentials, or product decisions.
8. After merge: retire worktree, delete local branch, fetch/prune, and report git hygiene. Confirm
   fleet convergence by matching manifest blob SHAs in downstream repositories.

## Engineering and verification

- Treat repository source, manifests, tests, and `DEVELOPING.md` as authority. Run focused then
  broader checks and record outcomes.
- Keep Antigravity review and deterministic tests as separate layers.
- Inspect the final diff; support claims with command outcomes.
