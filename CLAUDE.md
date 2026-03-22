# Claude Code Project Instructions

## Organization Overview

This repository is part of the **f5xc-salesdemos** GitHub
organization (21 repositories). Understanding the full
ecosystem helps when navigating cross-repo dependencies.

### Infrastructure repos

| Repo | Role |
| ---- | ---- |
| `docs-control` | Source-of-truth — CI workflows, governance, settings enforcement |
| `docs-theme` | npm package — Starlight plugin, Astro config, CSS, fonts, layout |
| `docs-builder` | Docker image — build orchestration, npm deps, Puppeteer PDF |
| `docs-icons` | npm packages — Iconify JSON icon sets, Astro icon components |
| `terraform-provider-f5xc` | Custom Go Terraform provider for F5 XC |
| `terraform-provider-mcp` | MCP server exposing Terraform provider schemas |
| `api-mcp` | MCP server for the F5 XC API |

### Content repos

All content repos follow the same pattern: a `docs/`
directory with Markdown/MDX content, built by the shared
Docker image and deployed to GitHub Pages.

`docs` · `administration` · `nginx` · `observability` ·
`was` · `mcn` · `dns` · `cdn` · `bot-standard` ·
`bot-advanced` · `ddos` · `waf` · `api-protection` · `csd`

## Plugin Directives

Use these installed plugins for all standard operations.
Invoke the relevant skill **before** starting work.

| Operation | Plugin/Skill |
| --------- | ------------ |
| Commit, push, and PR | `/commit-push-pr` |
| Commit only | `/commit` |
| Branch cleanup | `/clean_gone` |
| Planning | `superpowers:writing-plans` |
| Verification mindset | `superpowers:verification-before-completion` |
| Branch completion | `superpowers:finishing-a-development-branch` |
| PR review | `/review-pr` |
| Repo workflow and governance | `f5xc-repo-governance:workflow-lifecycle` |
| Docs pipeline and ownership | `f5xc-docs-pipeline:pipeline-navigator` |
| Content authoring | `f5xc-docs-pipeline:content-author` |
| MDX validation | `/review-mdx` |
| Local docs preview | `/preview-docs` |

**Activation rules:**

- When starting any development task, invoke
  `workflow-lifecycle` for the full governance protocol
- When making docs infrastructure changes, invoke
  `pipeline-navigator` for config ownership guidance
- When editing docs content, invoke `content-author`
  for structure and MDX rules

## Project-Specific Overrides

These constraints apply on top of all plugin defaults:

- **Create a GitHub issue** before making any changes
- **Link PRs to issues** using `Closes #N` — fill out
  the PR template completely
- **Conventional commits** — use `feat:`, `fix:`, `docs:`
- **Squash merge** —
  `gh pr merge <NUMBER> --squash --delete-branch`
- **No manual approval required** — merge once CI passes
- **Branch naming** —
  `<prefix>/<issue-number>-short-description`
- **DO NOT STOP after creating a PR** — the task is not
  complete until post-merge workflows pass
- Never push directly to `main`
- Never force push

## Reference

Read `CONTRIBUTING.md` for full governance details.
