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
| Commit, push, and PR | `/commit-push-pr` |
| Commit only | `/commit` |
| Branch cleanup | `/clean_gone` |
| PR review | `/review-pr` |
| Brand compliance review | `/review-brand` |
| MDX validation | `/review-mdx` |
| Local docs preview | `/preview-docs` |

### Auto-activated skills

| Skill | Activates when... |
| ----- | ----------------- |
| `f5xc-repo-governance:workflow-lifecycle` | Starting any development task |
| `f5xc-docs-pipeline:pipeline-navigator` | Changing docs infrastructure config |
| `f5xc-docs-pipeline:content-author` | Editing docs content (MDX/Markdown) |
| `f5xc-brand:brand-guardian` | Creating any visual content or assets |
| `f5xc-brand:visual-content` | Creating Mermaid, PPT, diagrams, slides |
| `superpowers:writing-plans` | Planning implementation work |
| `superpowers:verification-before-completion` | Verifying work before marking complete |
| `superpowers:finishing-a-development-branch` | Completing work on a branch |

**Activation rules** — invoke the matching skill automatically:

1. Development task → `workflow-lifecycle`
2. Docs infra change → `pipeline-navigator`
3. Docs content edit → `content-author`
4. Visual/brand asset creation → `brand-guardian`
5. Format-specific creation (Mermaid, PPT) → `visual-content`

## Project-Specific Overrides

These constraints apply on top of all plugin defaults:

- **Create a GitHub issue** before making any changes
- **Link PRs to issues** using `Closes #N` — fill out the PR template completely
- **Conventional commits** — use `feat:`, `fix:`, `docs:`
- **Squash merge** — `gh pr merge <NUMBER> --squash --delete-branch`
- **No manual approval required** — merge once CI passes
- **Branch naming** — `<prefix>/<issue-number>-short-description`
- **DO NOT STOP after creating a PR** — the task is not complete until post-merge workflows pass
- Never push directly to `main`
- Never force push

## Reference

Read `CONTRIBUTING.md` for full governance details.
