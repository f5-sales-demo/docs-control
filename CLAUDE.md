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

## Repository Workflow

This repository enforces a strict governance workflow.
**DO NOT STOP after creating a PR** — the task is
not complete until the PR is merged, all post-merge
workflows succeed, and local branches are cleaned.

### Making Changes (Steps 1-6)

1. **Create a GitHub issue** before making any
   changes
2. **Sync local main** — pull the latest changes
   before branching to avoid conflicts with recent
   work:

   ```
   git checkout main
   git pull origin main
   ```

3. **Create a feature branch** from `main` — never
   commit to `main` directly
4. **Commit changes** with conventional format
   (`feat:`, `fix:`, `docs:`) and push to remote
5. **Open a PR** that links to the issue using
   `Closes #N` — fill out the PR template completely
6. **Fix any CI failures** — monitor checks with
   `gh pr checks <NUMBER>`, fix locally, push to
   trigger re-runs

### Merging (Step 7)

7. **Merge after CI passes** — once all status checks
   are green, merge the PR yourself. Do not wait for
   manual approval (none is required).

   Poll PR checks using single-shot queries (never
   `--watch`) per the **Polling Protocol**:

   ```
   gh pr checks <NUMBER> --json bucket \
     --jq 'map(.bucket) | unique | if . == ["pass"] then "pass"
     elif any(. == "fail") then "fail" else "pending" end'
   ```

   Once all checks pass:

   ```
   gh pr merge <NUMBER> --squash --delete-branch
   ```

   If the merge fails, check why:

   ```
   gh pr view <NUMBER> --json mergeable,mergeStateStatus
   ```

### Post-Merge Monitoring (Steps 8-9)

8. **Monitor post-merge workflows** — merging to
   `main` triggers additional workflows (docs
   builds, governance sync, etc.). Discover and
   poll them using single-shot checks (never
   `--watch`):

   ```
   git checkout main && git pull origin main
   MERGE_SHA=$(git rev-parse HEAD)
   sleep 15
   gh run list --branch main --commit $MERGE_SHA
   ```

   Then poll each run using the **Polling Protocol**
   from the rate limit section:

   ```
   gh run view <RUN-ID> --json status,conclusion \
     --jq '"\(.status) \(.conclusion)"'
   ```

   Sleep for the interval matching the current
   consumption zone (30s GREEN, 60s YELLOW).
   Maximum 20 iterations — then report to user.

9. **Iterate on failures** — if any workflow fails:
   - View logs: `gh run view <RUN-ID> --log-failed`
   - Analyze the root cause
   - Fix the code locally
   - Create a new issue, branch, and PR with the fix
   - Return to Step 6 and repeat until all workflows
     pass

### Cleanup (Steps 10-11)

10. **Clean up branches** — only after all workflows
    succeed. Delete your feature branch and any other
    stale local branches already merged to `main`:

    ```
    git branch -d <branch-name>
    git branch --merged main | grep -v '^\*\|main' | xargs -r git branch -d
    ```

11. **Verify completion** — confirm clean state:

    ```
    git status
    git branch
    ```

### Verification (Steps 12-13)

12. **Verify outcomes** — confirm changes had the
    intended effect, not just that workflows passed:

    Always check:

    ```
    # Issue was closed by the PR
    gh issue view <NUMBER> --json state --jq '.state'

    # Branch protection matches expected state
    gh api repos/{owner}/{repo}/branches/main/protection \
      --jq '.required_status_checks.contexts'
    ```

    If `docs/**` changed:

    ```
    # Docs site is accessible
    REPO=$(basename $(pwd))
    curl -sf "https://f5xc-salesdemos.github.io/${REPO}/" \
      && echo "OK" || echo "FAIL"
    ```

    If governance or config files changed, check
    rate limits first and adapt scope:

    - **GREEN** (>1,000 remaining): check all repos
    - **YELLOW** (200–1,000): spot-check 3 repos
      (first, middle, last from the list)
    - **RED** (<200): skip entirely, report deferral
      to user

    ```
    # Downstream repos were dispatched successfully
    for repo in $(jq -r '.[]' .github/config/downstream-repos.json); do
      echo "$repo:"
      gh run list --repo "$repo" \
        --workflow enforce-repo-settings.yml --limit 1
    done
    ```

13. **Check repository health** — after your task is fully
    done, check for outstanding items:

    ```
    # Open issues
    gh issue list --state open

    # Unmerged PRs
    gh pr list --state open
    ```

    If any open issues or stale PRs are found,
    report them to the user.

## Task Completion Criteria

A task is **not complete** until ALL of the
following are true:

- GitHub issue created and linked to PR
- PR merged to `main`
- All workflows triggered by the merge completed
  successfully
- Local feature branch deleted
- No stale merged branches remain locally
- Current branch is `main` with clean working tree
- GitHub issue is in `closed` state
- Outcome verification passed (settings applied, docs
  accessible if changed, downstream dispatched if changed)
- Repository health checked (open issues and unmerged PRs
  reported)

If any post-merge workflow fails due to your
changes, fix and resubmit. Do not clean up branches
until all workflows are green.

## Branch Naming

Use the format `<prefix>/<issue-number>-short-description`:

- `feature/42-add-rate-limiting`
- `fix/17-correct-threshold`
- `docs/8-update-guide`

## Rules

- Never push directly to `main`
- Never force push
- Every PR must link to an issue
- Fill out the PR template completely
- Follow conventional commit messages (`feat:`, `fix:`, `docs:`)
- Never consider a task complete until post-merge workflows pass
- Always delete local feature branches after successful merge
- Always clean up stale merged branches and workspace clutter when noticed

## GitHub API Rate Limit Management

The GitHub REST API allows 5,000 calls per hour.
Unthrottled polling (`--watch` flags) can consume
hundreds to thousands of calls per task cycle,
triggering HTTP 403 errors that block all further
operations until the hourly window resets.

### Rate Limit Check

Run this before any polling loop or when budget
is uncertain (costs 1 API call):

```
gh api rate_limit --jq '{
  remaining: .rate.remaining,
  limit: .rate.limit,
  reset_minutes: ((.rate.reset - now) / 60 | ceil)
}'
```

### When to Check

Check rate limits at exactly these 4 points:

1. **Before starting any new task** (Step 1)
2. **Before entering a polling loop** (Steps 7, 8)
3. **Before the downstream verification loop**
   (Step 12)
4. **After any HTTP 403 or 429 response**

### Consumption Zones

| Zone | Remaining | Poll Interval | Behavior |
| ---- | --------- | ------------- | -------- |
| GREEN | >1,000 | 30s | Normal operation |
| YELLOW | 200–1,000 | 60s | Spot-check 3 downstream repos (first, middle, last); skip redundant verification |
| RED | <200 | No polling | Stop and report to user; wait for reset if <15 min away |

### Banned Commands

Never use these — they poll every 3-10 seconds
and consume API calls rapidly:

- `gh pr checks <NUMBER> --watch`
- `gh run watch <RUN-ID>`
- `gh run watch <RUN-ID> --exit-status`

### Polling Protocol

Replace all `--watch` patterns with single-shot
checks in a sleep loop:

**PR checks** (pass/fail/pending in one call):

```
gh pr checks <NUMBER> --json bucket \
  --jq 'map(.bucket) | unique | if . == ["pass"] then "pass"
  elif any(. == "fail") then "fail" else "pending" end'
```

**Workflow run status** (one call per run):

```
gh run view <RUN-ID> --json status,conclusion \
  --jq '"\(.status) \(.conclusion)"'
```

**Loop rules**:

- Sleep for the interval defined by the current
  consumption zone (30s GREEN, 60s YELLOW)
- Maximum 20 iterations per polling loop — if
  still pending, report status to user and ask
  whether to continue
- Poll all triggered workflows in one iteration
  before sleeping (batch, not sequential)
- Re-check rate limit every 5 iterations

### Budget Estimates

Approximate API calls per operation:

| Operation | Calls |
| --------- | ----- |
| Rate limit check | 1 |
| PR checks (single-shot) | 1 |
| Workflow run status | 1 |
| PR merge | 1 |
| Run list (discover workflows) | 1 |
| Run view (logs) | 1 |
| Issue view | 1 |
| Branch protection check | 1 |
| Downstream repo check (per repo) | 1 |
| Full polling loop (20 iter, 3 runs) | ~65 |
| Full task cycle (standard) | ~100 |
| Full task cycle (governance, 18 repos) | ~150 |

### 403 Recovery Protocol

When an HTTP 403 or 429 response is encountered:

1. Run the rate limit check to extract reset time
2. Calculate minutes until reset
3. Report to user: remaining calls, reset time,
   and what operation was blocked
4. If reset is <15 minutes away, recommend waiting
5. If reset is >15 minutes away, stop all `gh`
   operations and ask user how to proceed

## Managed Files

The following files are centrally managed by the
[docs-control](https://github.com/f5xc-salesdemos/docs-control)
repository and automatically synced to all repos in the
`f5xc-salesdemos` organization. **Do not modify these
files here** — local changes will be overwritten on the
next enforcement run.

To change any of these files, open a PR in
`f5xc-salesdemos/docs-control` instead.

- `.github/workflows/github-pages-deploy.yml`
- `.github/workflows/enforce-repo-settings.yml`
- `.github/workflows/require-linked-issue.yml`
- `.github/workflows/dependabot-auto-merge.yml`
- `.github/workflows/super-linter.yml`
- `.github/PULL_REQUEST_TEMPLATE.md`
- `.github/ISSUE_TEMPLATE/bug_report.md`
- `.github/ISSUE_TEMPLATE/feature_request.md`
- `.github/ISSUE_TEMPLATE/documentation.md`
- `.github/ISSUE_TEMPLATE/config.yml`
- `CONTRIBUTING.md`
- `CLAUDE.md`
- `.editorconfig`
- `.gitignore`
- `LICENSE`
- `.pre-commit-config.yaml`
- `.yamllint.yaml`
- `.markdownlint.json`
- `biome.json`
- `.jscpd.json`
- `.textlintrc`
- `.editorconfig-checker.json`
- `.checkov.yaml`
- `zizmor.yaml`
- `.shellcheckrc`
- `.codespellrc`

## Planning Before Execution

**Default to plan mode.** Before making any code or
configuration changes, enter plan mode to present your
approach for user review. Do not start writing code,
creating branches, or modifying files until the user
approves the plan.

Plan mode is **required** when:

- The task involves creating or modifying multiple files
- The scope, approach, or requirements are ambiguous
- The change affects CI workflows, governance, or shared
  infrastructure
- You need to make architectural or design decisions
- The task could reasonably be done in more than one way

Plan mode may be **skipped** when:

- The user gives an explicit, complete instruction with
  no ambiguity (e.g., "change X to Y in file Z")
- The task is a single-line fix (typo, obvious syntax
  error)
- The operation is read-only (searching, explaining
  code, reviewing logs)
- The user explicitly says to skip planning (e.g.,
  "just do it", "no need to plan")

When in doubt, plan first. A 30-second planning pause
is always cheaper than undoing unwanted changes.

## CI Monitoring

When monitoring CI workflows, focus only on
workflows triggered by your current changes.
Use the merge commit SHA (`$MERGE_SHA`) to scope
`gh run list` and `gh run view` commands.

If a workflow triggered by your commit fails:

1. **Investigate the failure** — view logs with
   `gh run view <RUN-ID> --log-failed`
2. **Fix the root cause** — create a new issue,
   branch, and PR with the fix
3. **Report to the user** what failed and what
   you did to fix it

Do not investigate or report on workflow failures
from other commits. Historical failures are out
of scope for the current task.

Rate limit awareness applies to all `gh` commands
during CI monitoring. Before entering any polling
loop, check remaining API budget per the
**GitHub API Rate Limit Management** section. Use
single-shot status checks with sleep intervals —
never `--watch` flags.

## Workspace Hygiene

Apply the same proactive approach as CI monitoring
to local workspace cleanliness. Do not ignore
problems just because they predate your current
task.

When you notice stale local branches, leftover
files, or other workspace issues:

1. **Fix it immediately** — delete merged branches,
   remove temp files, clean up artifacts
2. **Report what you cleaned** — tell the user what
   housekeeping you performed
3. **Do not skip cleanup because "it's not my
   task"** — a clean workspace is everyone's
   responsibility

Stale branch cleanup command:

```
git branch --merged main | grep -v '^\*\|main' | xargs -r git branch -d
```

## Documentation Pipeline

All `f5xc-salesdemos` repositories publish docs to
GitHub Pages using a shared pipeline:

| Repository | Role | Owns |
| ---- | ---- | ---- |
| `docs-theme` | npm package — Starlight plugin, Astro config, CSS, fonts, logos, layout components | `astro.config.mjs`, `config.ts`, `content.config.ts`, all Starlight plugins and Astro integrations |
| `docs-builder` | Docker image — build orchestration, npm deps, Puppeteer PDF generation, interactive components | `Dockerfile`, `entrypoint.sh`, `package.json` (npm dependency set only) |
| `docs-control` | Source-of-truth — reusable CI workflows, governance templates, repository settings enforcement | CI workflows, `CLAUDE.md`, PR/issue templates, repository settings |
| `docs-icons` | npm packages — Iconify JSON icon sets, Astro icon components | Icon packaging, npm publishing, dispatch to docs-builder on release |

Content repositories only need a `docs/` directory — the
build container and workflow handle everything else.
CI builds trigger when files in `docs/` change on
`main`.

### Where to make changes

- **Site appearance, navigation, or Astro config** —
  change `docs-theme` (owns
  `astro.config.mjs`, `content.config.ts`,
  CSS, fonts, logos, and layout components)
- **Build process, Docker image, or npm deps** —
  change `docs-builder` (owns the
  Dockerfile, entrypoint, and dependency set)
- **Interactive components** (placeholder forms,
  API viewers, Mermaid rendering) —
  change `docs-builder`
- **Icon packages** (Iconify JSON sets, Astro icon
  components) — change `docs-icons` (publishes npm
  packages consumed by `docs-builder`)
- **CI workflow or governance files** —
  change `docs-control` (syncs managed files
  and repository settings to downstream repositories)
- **Page content and images** —
  change the `docs/` directory in the content
  repository itself
- **Never** add `astro.config.mjs`,
  `package.json`, or build config to a content
  repository — the pipeline provides these
- **Never** create `astro.config.mjs`,
  `uno.config.ts`, or Astro integration config
  in `docs-builder` — these are owned exclusively
  by `docs-theme`

### Configuration ownership rules

The build image (`docs-builder`) copies configuration
files from the theme package at image build time.
This is the mechanism that enforces
single-source-of-truth:

- `astro.config.mjs` — copied from `docs-theme`
  into the image. **Never** create or override this
  file in `docs-builder` or any content repository.
- `content.config.ts` — copied from `docs-theme`
  into the image. Same rule applies.
- Astro integrations and Starlight plugins — defined
  in `docs-theme/config.ts`. To add a new
  integration, add it to docs-theme, not
  docs-builder.
- npm packages (icon packs, runtime libraries) —
  added to `docs-builder/package.json`. These are
  build-time dependencies that integrations in
  docs-theme consume.
- `uno.config.ts`, `tsconfig.json`, and other
  tooling configs — owned by `docs-theme` if they
  affect the Astro build. `docs-builder` must not
  create competing configs.

**Pattern for adding new capabilities** (e.g., icon
packs):

1. Add the npm data packages to
   `docs-builder/package.json`
2. Add the Astro integration/plugin to
   `docs-theme/config.ts`
3. The Dockerfile copies the updated config from
   docs-theme at build time — no manual config in
   docs-builder needed

**Icon package pipeline**: `docs-icons` owns all icon
packaging — Iconify JSON sets and Astro components. On
npm publish, `docs-icons` dispatches to `docs-builder`
to rebuild the Docker image with updated icon packages.
Content repositories never install icon packages directly.

### Release dispatch chain

When an infrastructure package (`docs-theme` or
`docs-icons`) merges to `main`, the following
automated chain runs end-to-end — no manual
triggering should be needed:

1. **Semantic Release** publishes a new npm version
   and creates a GitHub release
2. **Dispatch to `docs-builder`** — the release
   event triggers `dispatch-downstream.yml`, which
   sends a `rebuild-image` repository dispatch
3. **Docker image rebuild** — `docs-builder`
   rebuilds the container with the updated package
4. **Dispatch to content repositories** — `docs-builder`
   reads `docs-sites.json` from `docs-control` and
   dispatches `github-pages-deploy.yml` to every
   content repository
5. **GitHub Pages rebuild** — each content repository
   rebuilds its site using the new image

If a theme or icon change does not appear on live
sites, check each step in this chain for failures —
do not manually trigger `github-pages-deploy.yml`
as a workaround.

### Other infrastructure repos

The organization also contains repos with their own
CI pipelines that are not part of the docs theme/build
dispatch chain but do receive managed files and publish
docs sites:

| Repo | Role |
| ---- | ---- |
| `terraform-provider-f5xc` | Go Terraform provider for F5 Distributed Cloud |
| `terraform-provider-mcp` | MCP server exposing Terraform provider schemas |
| `api-mcp` | MCP server for the F5 XC API |

## Content Authoring

### Structure

- Place `.md` or `.mdx` files in the `docs/`
  directory
- `docs/index.mdx` is required — include YAML
  frontmatter with at least a `title:` field
- Static assets (images, diagrams) go in
  subdirectories like `docs/images/` — folders
  with no `.md`/`.mdx` files are auto-mounted
  as public assets
- Reference assets with root-relative paths:
  `![alt](/images/diagram.png)`

### MDX Rules

- Bare `<` is treated as a JSX tag — use `&lt;`
  or wrap in backtick inline code
- `{` and `}` are JSX expressions — use `\{`
  and `\}` or wrap in backtick inline code
- Never use curly braces in `.mdx` filenames

### Local Preview

Run the live dev server (restart to pick up
changes):

```bash
docker run --rm -it \
  -v "$(pwd)/docs:/content/docs" \
  -p 4321:4321 \
  -e MODE=dev \
  ghcr.io/f5xc-salesdemos/docs-builder:latest
```

Open `http://localhost:4321`. File changes on the
host require restarting the container.

For a full production build:

```bash
docker run --rm \
  -v "$(pwd)/docs:/content/docs:ro" \
  -v "$(pwd)/output:/output" \
  -e GITHUB_REPOSITORY="<owner>/<repo>" \
  ghcr.io/f5xc-salesdemos/docs-builder:latest
```

Serve with `npx serve output/ -l 8080` and open
`http://localhost:8080/<repo>/`.

Full content authoring guide:
<https://f5xc-salesdemos.github.io/docs-builder/content-authors/>

## Reference

Read `CONTRIBUTING.md` for full governance details.
