# Claude Code Project Instructions

## Repository Workflow

This repo enforces a strict governance workflow.
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
   - For pre-existing failures unrelated to your
     changes: create a GitHub issue (per CI
     Monitoring rules below) and continue

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
    gh run list --branch main --limit 5
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

13. **Check repo health** — after your task is fully
    done, scan for any outstanding problems across
    the repository:

    ```
    # Open issues
    gh issue list --state open

    # Unmerged PRs
    gh pr list --state open

    # Recent failing workflows on main
    gh run list --branch main --status failure --limit 5
    ```

    If any open issues, stale PRs, or failing
    workflows are found, report them to the user.
    For failures unrelated to your changes, create
    a GitHub issue (per CI Monitoring rules) and
    move on.

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
- Repo health checked (open issues, unmerged PRs, and
  failing workflows reported)

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
repository and automatically synced to this repo.
**Do not modify these files here** — local changes
will be overwritten on the next enforcement run.

To change any of these files, open a PR in
`f5xc-salesdemos/docs-control` instead.

- `.github/workflows/github-pages-deploy.yml`
- `.github/workflows/enforce-repo-settings.yml`
- `.github/workflows/require-linked-issue.yml`
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

## CI Monitoring and Problem Reporting

When monitoring CI workflows, **never ignore
failures** — even pre-existing or unrelated ones.
You are authorized to create GitHub issues without
asking for confirmation. This is a standing
instruction, not a suggestion.

For every problem observed:

1. **Immediately create a GitHub issue** — do not
   ask whether to create it, just create it
   - Use a clear, descriptive title
   - Include the workflow run URL or relevant logs
   - Note it was discovered during CI monitoring
   - Apply the `bug` label
2. **Continue with your primary task** — issue
   creation must not block your current work
3. **Report to the user** what issues you created

Do not ask "Want me to create an issue?" — the
answer is always yes. See a problem, file an issue,
move on.

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

All repos publish docs to GitHub Pages using a
shared pipeline:

| Repo | Role |
| ---- | ---- |
| `docs-theme` | npm package — Starlight plugin, Astro config, CSS, fonts, logos, layout components |
| `docs-builder` | Docker image — build orchestration, npm deps, Puppeteer PDF generation, interactive components |
| `docs-control` | Source-of-truth — reusable CI workflows, governance templates, repo settings enforcement |

Content repos only need a `docs/` directory — the
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
- **CI workflow or governance files** —
  change `docs-control` (syncs managed files
  and repo settings to downstream repos)
- **Page content and images** —
  change the `docs/` directory in the content
  repo itself
- **Never** add `astro.config.mjs`,
  `package.json`, or build config to a content
  repo — the pipeline provides these

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
  --entrypoint sh \
  ghcr.io/f5xc-salesdemos/docs-builder:latest \
  -c '
    npm install --legacy-peer-deps && \
    npm update --legacy-peer-deps && \
    cp /app/node_modules/f5xc-docs-theme/astro.config.mjs \
       /app/astro.config.mjs && \
    cp /app/node_modules/f5xc-docs-theme/src/content.config.ts \
       /app/src/content.config.ts && \
    cp -r /content/docs/* /app/src/content/docs/ && \
    DOCS_TITLE=$(grep -m1 "^title:" /app/src/content/docs/index.mdx \
      | sed "s/title: *[\"]*//;s/[\"]*$//") \
    npx astro dev --host
  '
```

Open `http://localhost:4321`. File changes on the
host require restarting the container.

If your `docs/` directory contains static asset
subdirectories (images, diagrams — folders with
no `.md`/`.mdx` files), add a volume mount for
each one so they are served as public assets:

```bash
-v "$(pwd)/docs/images:/app/public/images:ro"
```

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
