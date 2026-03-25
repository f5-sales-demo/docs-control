# Claude Code Project Instructions

## Organization Overview

This repository is part of **f5xc-salesdemos** (21 repos).

### Infrastructure repos

| Repo | Role |
| ---- | ---- |
| `docs-control` | Source-of-truth — CI, governance, settings enforcement |
| `docs-theme` | npm — Starlight plugin, Astro config, CSS, fonts, layout |
| `docs-builder` | Docker — build orchestration, npm deps, Puppeteer PDF |
| `docs-icons` | npm — Iconify JSON icon sets, Astro icon components |
| `terraform-provider-f5xc` | Custom Go Terraform provider for F5 XC |
| `terraform-provider-mcp` | MCP server — Terraform provider schemas |
| `api-mcp` | MCP server for the F5 XC API |

### Content repos

`docs` `administration` `nginx` `observability` `was` `mcn` `dns` `cdn` `bot-standard` `bot-advanced` `ddos` `waf` `api-protection` `csd`

## Plugin Directives

Invoke the relevant skill **before** starting work.

### User-invocable skills

| Operation | Skill |
| --------- | ----- |
| Branch cleanup | `/clean_gone` |
| PR review | `/review-pr` |
| Brand compliance review | `/review-brand` |
| MDX validation | `/review-mdx` |
| Local docs preview | `/preview-docs` |

### Auto-activated skills

| Skill | Activates when... |
| ----- | ----------------- |
| `f5xc-github-ops:workflow-lifecycle` | Starting any development task |
| `f5xc-docs-pipeline:pipeline-navigator` | Changing docs infrastructure config |
| `f5xc-docs-pipeline:content-author` | Editing docs content (MDX/Markdown) |
| `f5xc-brand:brand-guardian` | Creating any visual content or assets |
| `f5xc-brand:visual-content` | Creating Mermaid, PPT, diagrams, slides |
| `superpowers:writing-plans` | Planning implementation work |
| `superpowers:verification-before-completion` | Verifying work before marking complete |
| `superpowers:finishing-a-development-branch` | Completing work on a branch |
| `f5xc-devcontainer:tool-catalog` | Asking which command-line tool to use, how to use a tool, or any task requiring a tool decision |
| `f5xc-devcontainer:self-awareness` | Asking "who are you", container identity, version, self-diagnosis, health check |

**Activation rules** — invoke the matching skill automatically:

1. Development task → `workflow-lifecycle`
2. Docs infra change → `pipeline-navigator`
3. Docs content edit → `content-author`
4. Visual/brand asset creation → `brand-guardian`
5. Format-specific creation (Mermaid, PPT) → `visual-content`
6. Tool question → `tool-catalog`
7. Identity/self-diagnosis question → `self-awareness`

## GitHub Operations Routing

ALL Git and GitHub operations are handled exclusively by the
`f5xc-github-ops:github-ops` agent. This supersedes the
`commit-commands` official plugin for all f5xc-salesdemos repos.

**Never** run these directly in the main session:

- `git commit`, `git push`, `gh pr create`, `gh issue create`
- `pre-commit run`, `gh pr merge`, `gh pr checks`

**Always** delegate to `github-ops` after code changes are
complete. The agent will:

1. Idempotently install pre-commit hooks
2. Run fast lint checks (`SKIP=super-linter`)
3. Handle the full lifecycle (issue → branch → commit → PR → CI → merge)
4. Post CI errors as issue comments if failures occur
5. Return structured status reports

**Delegation pattern:**

```
Agent(
  subagent_type="f5xc-github-ops:github-ops",
  prompt="<type>: <description>\n\nFiles to stage:\n- <file-list>\n\nWhy: <motivation>"
)
```

If the agent returns `PRE_COMMIT_FAILED` or `CI_FAILED`,
fix the code in the main session and re-delegate.

## Container Awareness

When running inside the f5xc-salesdemos devcontainer, the
`f5xc-devcontainer` plugin provides:

- **Tool catalog** — 300+ command-line tools indexed by category with usage and auth info
- **Self-awareness** — live identity introspection via GitHub API
- **Tool maintenance** — install/remove tools with automated GitHub issues
- **Drift detection** — compare Dockerfile against tool catalog

All container queries are delegated to plugin agents to preserve
main context. The plugin activates automatically — no manual
invocation needed.

## Project-Specific Overrides

These constraints are enforced by the `github-ops` agent:

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
