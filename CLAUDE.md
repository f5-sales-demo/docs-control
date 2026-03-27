# Claude Code Project Instructions

## Managed Files

Files listed in `.claude/governance.json` are centrally managed by
`f5xc-salesdemos/docs-control` and synced to all downstream repos.
A PreToolUse hook blocks direct edits — to change a managed file,
open an issue in [docs-control](https://github.com/f5xc-salesdemos/docs-control).

## GitHub Operations Routing

ALL git and GitHub operations must be delegated to the
`f5xc-github-ops:github-ops` agent. Never run `git commit`,
`git push`, `gh pr create`, or `gh issue create` directly.

```
Agent(
  subagent_type="f5xc-github-ops:github-ops",
  prompt="<type>: <description>\n\nFiles to stage:\n- <file-list>\n\nWhy: <motivation>"
)
```

If the agent returns `PRE_COMMIT_FAILED` or `CI_FAILED`,
fix the code in the main session and re-delegate.

## Project Rules

- **Create a GitHub issue** before making any changes
- **Link PRs to issues** using `Closes #N` — fill out the PR template completely
- **Conventional commits** — use `feat:`, `fix:`, `docs:`
- **Squash merge** — `gh pr merge <NUMBER> --squash --delete-branch`
- **No manual approval required** — merge once CI passes
- **Branch naming** — `<prefix>/<issue-number>-short-description`
- **Pre-commit lint gate** — fast hooks run before every commit
- **DO NOT STOP after creating a PR** — the task is not complete until post-merge workflows pass
- Never push directly to `main`
- Never force push

## Reference

Read `CONTRIBUTING.md` for full governance details.
