# Claude Code Project Instructions

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

   ```
   gh pr checks <NUMBER> --watch
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
   watch them:

   ```
   git checkout main && git pull origin main
   MERGE_SHA=$(git rev-parse HEAD)
   sleep 10
   gh run list --branch main --commit $MERGE_SHA
   gh run watch <RUN-ID> --exit-status
   ```

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
    gh run list --branch main --commit $MERGE_SHA
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

    If governance or config files changed:

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

## Managed Files

The following files are centrally managed by the
[docs-control](https://github.com/f5xc-salesdemos/docs-control)
repository and automatically synced to this repository.
**Do not modify these files here** — local changes
will be overwritten on the next enforcement run.

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
`gh run list` and `gh run watch` commands.

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

All repositories publish docs to GitHub Pages using a
shared pipeline:

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
