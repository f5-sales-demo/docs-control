# Migrating a Repository to the Astro Starlight Pipeline

This runbook documents how to onboard a downstream repo into the docs-control governance model and Astro Starlight documentation pipeline.

## Prerequisites

- The repo is owned by `f5xc-salesdemos` on GitHub
- You have the `REPO_ADMIN_TOKEN` secret configured in the downstream repo
- The docs-builder Docker image (`ghcr.io/f5xc-salesdemos/docs-builder:latest`) supports Astro Starlight builds
- GitHub Pages is enabled (or will be enabled by enforcement)

## Step-by-Step Process

### 1. Add Per-Repo Config

Create `.github/config/repo-settings.json`:

```json
{
  "repository": {
    "description": "Your repo description",
    "homepage": "https://f5xc-salesdemos.github.io/REPO_NAME/"
  },
  "topics": ["f5xc"]
}
```

### 2. Add Caller Workflows

Copy these from the template's `workflows/` directory into the downstream repo's `.github/workflows/`:

| File | Source in Template | Purpose |
|------|-------------------|---------|
| `enforce-repo-settings.yml` | `workflows/enforce-repo-settings.yml` | Calls reusable enforcement workflow |
| `github-pages-deploy.yml` | `workflows/github-pages-deploy.yml` | Builds and deploys docs via Astro |
| `require-linked-issue.yml` | `.github/workflows/require-linked-issue.yml` | Blocks PRs without linked issues |

### 3. Consolidate .gitignore

Before onboarding, merge the downstream repo's `.gitignore` entries into the template. The enforcement workflow **overwrites** the downstream `.gitignore` entirely, so any entries not in the template will be lost.

```bash
# Fetch the downstream .gitignore
gh api repos/f5xc-salesdemos/REPO_NAME/contents/.gitignore \
  --jq '.content' | base64 -d > /tmp/downstream-gitignore

# Compare with the template
diff /tmp/downstream-gitignore .gitignore

# Add any missing entries to the template .gitignore, organized by category
# Commit the template change before proceeding with onboarding
```

Extra ignore patterns in repos that don't have those file types are harmless — they simply have no effect.

### 4. Add Governance Files

Copy from the template root:

- `CONTRIBUTING.md` -- contributor workflow rules
- `CLAUDE.md` -- AI assistant instructions
- `.editorconfig` -- editor style settings
- `LICENSE` -- MIT license
- `.github/PULL_REQUEST_TEMPLATE.md`
- `.github/ISSUE_TEMPLATE/bug_report.md`
- `.github/ISSUE_TEMPLATE/feature_request.md`
- `.github/ISSUE_TEMPLATE/documentation.md`
- `.github/ISSUE_TEMPLATE/config.yml`
- `.github/CODEOWNERS` (set `* @robinmordasiewicz`)

### 5. Convert Docs to Starlight MDX

Replace any existing `docs/` content with Starlight-compatible `.mdx` files.

**Landing page** (`docs/index.mdx`):

```yaml
---
title: Site Title
description: Site description
template: splash
sidebar:
  hidden: true
hero:
  tagline: Your tagline
  actions:
    - text: Get Started
      link: 01-getting-started/
      icon: right-arrow
      variant: primary
---
```

**Content pages** (`docs/01-page-name.mdx`):

```yaml
---
title: Page Title
description: Page description
---

Content here in standard Markdown.
```

### 6. Delete Legacy Files

Remove any previous docs tooling:

- `mkdocs.yml`
- `requirements-docs.txt`
- `docs/overrides/`
- `docs/stylesheets/`
- `docs/javascripts/`
- Any MkDocs-specific Markdown (`.md` files with MkDocs admonitions)

### 7. Add to Downstream Registry

In docs-control, add the repo to `.github/config/downstream-repos.json`.

### 8. Verify

```bash
# Trigger enforcement
gh workflow run enforce-repo-settings.yml --repo f5xc-salesdemos/REPO_NAME

# Check Pages config — confirm build_type is "workflow"
gh api repos/f5xc-salesdemos/REPO_NAME/pages

# Confirm docs site loads
open https://f5xc-salesdemos.github.io/REPO_NAME/
```

### 9. Clean Up Branches

After migration is verified and working, clean up legacy and stale remote branches. This prevents clutter and confusion in the branch list.

#### 9.1 List and Identify Stale Branches

```bash
# List all remote branches sorted by last commit date
gh api repos/f5xc-salesdemos/REPO_NAME/branches --paginate \
  --jq 'sort_by(.commit.date) | reverse | .[] | "\(.name): \(.commit.date)"'

# Filter to show only old branches (e.g., branches with commits >1 month old)
gh api repos/f5xc-salesdemos/REPO_NAME/branches --paginate \
  --jq '.[] | select(.commit.date < "2024-01-08T00:00:00Z") | .name'

# List branches without commits in the past 30 days
for branch in $(gh api repos/f5xc-salesdemos/REPO_NAME/branches --paginate --jq '.[].name'); do
  last_commit=$(gh api repos/f5xc-salesdemos/REPO_NAME/commits --per-page 1 -B "$branch" --jq '.[0].commit.author.date' 2>/dev/null || echo "")
  if [ -z "$last_commit" ]; then
    echo "$branch: No commits found"
  fi
done
```

#### 9.2 Delete Remote Branches

```bash
# Delete the legacy gh-pages branch (safe after Pages config is updated)
gh api repos/f5xc-salesdemos/REPO_NAME/git/refs/heads/gh-pages --method DELETE

# Delete specific stale branches
gh api repos/f5xc-salesdemos/REPO_NAME/git/refs/heads/BRANCH_NAME --method DELETE

# Bulk delete multiple branches (use with caution)
for branch in old-feature-1 old-feature-2 old-docs-build; do
  gh api repos/f5xc-salesdemos/REPO_NAME/git/refs/heads/$branch --method DELETE && echo "✓ Deleted $branch"
done
```

#### 9.3 Prune Local Tracking References

After deleting remote branches, clean up local references:

```bash
# Prune stale local references to deleted remote branches
git fetch --prune

# Verify deletions
git branch -r
```

#### 9.4 Identify and Delete Merged Feature Branches

Feature branches that were merged to main can safely be deleted:

```bash
# List branches merged to main
git branch --merged main | grep -v main

# Delete all merged branches (except main)
git branch --merged main | grep -v main | xargs -r git branch -d

# Delete merged remote branches
git branch -r --merged main | grep -v main | sed 's/origin\///' | \
  xargs -r -I {} gh api repos/f5xc-salesdemos/REPO_NAME/git/refs/heads/{} --method DELETE
```

#### 9.5 Clean Dependabot and Automation Branches

If Dependabot or other automation created branches that are no longer needed:

```bash
# List all dependabot branches
gh api repos/f5xc-salesdemos/REPO_NAME/branches --paginate \
  --jq '.[] | select(.name | contains("dependabot")) | .name'

# Delete dependabot branches that are not in use
for branch in $(gh api repos/f5xc-salesdemos/REPO_NAME/branches --paginate \
  --jq '.[] | select(.name | contains("dependabot")) | .name'); do
  gh api repos/f5xc-salesdemos/REPO_NAME/git/refs/heads/$branch --method DELETE && echo "✓ Deleted $branch"
done
```

**What to delete:**
- `gh-pages` — no longer needed; Pages now deploys via GitHub Actions
- Feature/fix branches already merged to main (use `git branch --merged`)
- Dependabot branches for old dependencies or closed PRs
- Release branches from previous release workflows
- Any branches with last commit >6 months ago (assess first for unfinished work)

**What to keep:**
- `main` — the primary branch
- Any active branches with unmerged work that is still in progress
- `develop` or similar long-lived branches if part of your workflow

## Starlight MDX Format Reference

### Admonitions

MkDocs Material uses `!!! type "Title"` with indented content. Starlight uses fenced directives:

| MkDocs Material | Starlight MDX |
|---|---|
| `!!! note "Title"` + indented content | `:::note[Title]` + content + `:::` |
| `!!! success "Title"` + indented content | `:::tip[Title]` + content + `:::` |
| `!!! warning "Title"` + indented content | `:::caution[Title]` + content + `:::` |
| `!!! danger "Title"` + indented content | `:::danger[Title]` + content + `:::` |
| `??? info "Title"` (collapsible) | `<details><summary>Title</summary>` + content + `</details>` |

### Icons

Replace Material icons with emoji or text:

| Material Icon | Replacement |
|---|---|
| `:material-arrow-up-bold-circle:` | Up arrow or text badge |
| `:material-arrow-down-bold-circle:` | Down arrow or text badge |
| `:material-plus-circle:` | `+` or text badge |
| `:material-minus-circle:` | `-` or text badge |
| `:material-refresh:` | Refresh symbol or text badge |

## Dynamic Doc Generation Pattern

For repos where docs are generated from pipeline artifacts (e.g., validation reports):

1. The pipeline workflow generates MDX files and commits them back to `docs/` via a PR
2. The commit to `docs/` on main triggers the standard `github-pages-deploy.yml` workflow
3. This keeps the template's reusable workflow standard while supporting dynamic content

Example update-docs job to add to the pipeline workflow:

```yaml
  update-docs:
    name: Update Documentation
    needs: [validate]
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.11' }
      - run: pip install -e .
      - uses: actions/download-artifact@v4
        with: { name: validation-reports, path: reports/ }
      - run: python -m scripts.generate_docs --output docs/01-validation-report.mdx
      - name: Commit and PR if changed
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add docs/
          if git diff --cached --quiet; then
            echo "No docs changes"
            exit 0
          fi
          BRANCH="docs/update-validation-report-$(date +%s)"
          git checkout -b "$BRANCH"
          git commit -m "docs: update validation report"
          git push origin "$BRANCH"
          gh pr create --title "docs: update validation report" \
            --body "Auto-generated from validation pipeline run."
```

## Troubleshooting

### Chicken-and-egg problem
If the enforcement workflow itself is broken in downstream repos, it can't self-heal. Use the GitHub Contents API to manually push fixes:

1. Get file SHA via `gh api repos/OWNER/REPO/contents/PATH`
2. Create branch from main SHA
3. PUT file with base64 content + old SHA + branch
4. Create PR
5. Auto-merge

### Pages not building
- Verify `build_type: workflow` via `gh api repos/OWNER/REPO/pages`
- Check that `docs/` directory exists with at least `index.mdx`
- Ensure the docs-builder image is accessible

### Stale branches after migration

Old feature, dependabot, and `gh-pages` branches may linger after migration. These won't cause failures but create clutter and confusion.

#### Identification and Assessment

```bash
# List all branches with their last commit date
gh api repos/OWNER/REPO/branches --paginate \
  --jq 'sort_by(.commit.date) | reverse | .[] | {name: .name, lastCommit: .commit.date}'

# Identify gh-pages branch specifically
gh api repos/OWNER/REPO/branches --paginate --jq '.[] | select(.name == "gh-pages") | .name'

# Check if any branch is stale (e.g., last commit >6 months ago)
CUTOFF_DATE="2023-08-08T00:00:00Z"  # Adjust to your 6-month-ago date
gh api repos/OWNER/REPO/branches --paginate \
  --jq ".[] | select(.commit.date < \"$CUTOFF_DATE\") | .name"
```

#### Cleanup and Verification

- Delete via API: `gh api repos/OWNER/REPO/git/refs/heads/BRANCH --method DELETE`
- Prune local tracking: `git fetch --prune`
- Verify deletions: `git branch -r` should not list deleted branches
- The `gh-pages` branch is safe to delete once Pages is confirmed using `build_type: workflow`

#### Common Stale Branch Patterns

| Pattern | Reason | Safe to Delete? | Action |
|---------|--------|-----------------|--------|
| `gh-pages` | Old Pages deployment branch | ✓ Yes (after verifying workflow-based Pages) | Delete immediately after Step 8 verification |
| `dependabot/*` (old) | Closed dependency update PR | ✓ Yes (if PR is merged/closed) | Use bulk delete for old dependabot branches |
| `feature/*` (merged) | Feature branches merged to main | ✓ Yes | Use `git branch --merged main \| xargs git branch -d` |
| `release/*` (old) | Release branches from previous versions | ✓ Yes | Delete if release is complete and tagged |
| `hotfix/*` (old) | Hotfix branches applied to main | ✓ Yes | Delete after verification |
| `experiment/*` (stale) | Abandoned experiments | ✓ Yes | Assess if work is needed; if not, delete |
| Custom long-lived branches | Branches like `develop`, `staging`, `staging-*` | ❌ No | Keep if part of your active workflow |

#### Troubleshooting Stale Branches

**Problem**: Cannot delete a remote branch — "ref does not exist"

```bash
# The branch may already be deleted locally but tracked remotely
git fetch --prune  # Refresh local tracking
git branch -r      # Verify it's gone from tracking
```

**Problem**: Dependabot branches accumulate

```bash
# List all dependabot branches and filter by PR status
gh api repos/OWNER/REPO/branches --paginate \
  --jq '.[] | select(.name | contains("dependabot")) | .name' | \
  while read branch; do
    # Check if an open PR exists for this branch
    pr_count=$(gh pr list -H "$branch" --state open --json number | jq 'length')
    if [ "$pr_count" -eq 0 ]; then
      echo "No open PR for $branch — candidate for deletion"
    fi
  done
```

**Problem**: Local branch references linger after remote deletion

```bash
# Force clean up all stale local tracking branches
git fetch --prune origin
git remote prune origin

# Verify cleanup
git branch -r | wc -l  # Count remaining remote branches
```

**Problem**: Uncertain if a branch contains important work

```bash
# Check if branch has commits not in main
git log main..$branch --oneline | head -20

# If output is empty, the branch is fully merged to main and safe to delete
# If output exists, review commits before deleting
```

## Full Doc Conversion Process

When migrating from MkDocs Material to Astro Starlight, every `.md` file under `docs/` must be converted. This section documents the complete conversion procedure for a comprehensive migration from start to finish.

### Overview of Conversion Phases

1. **Preparation**: Audit existing docs and plan the conversion structure
2. **File Conversion**: Rename, frontmatter, and syntax updates
3. **Validation**: Test the build and fix any issues
4. **Deployment**: Verify the site works correctly
5. **Cleanup**: Remove old artifacts and finalize

### Phase 1: Preparation and Audit

Before starting the conversion, inventory your current docs to plan the migration:

```bash
# Count markdown files
find docs/ -name '*.md' | wc -l

# List directory structure
tree docs/ -L 2  # or: find docs/ -type f -name '*.md' | sort

# Check for custom CSS, JS, or overrides
find docs/ -type f \( -name '*.css' -o -name '*.js' \) -o -type d -name 'overrides'

# Identify Material icon usage
grep -r ':material-' docs/ --include='*.md' | head -20

# Identify MkDocs admonitions
grep -r '^!!!' docs/ --include='*.md' | wc -l
grep -r '^???' docs/ --include='*.md' | wc -l
```

**Create a conversion checklist:**

- [ ] Total files to convert: _____
- [ ] Files with Material icons: _____
- [ ] Files with admonitions: _____
- [ ] Files with Material JS/CSS: _____
- [ ] Subdirectories to preserve: _____
- [ ] Dynamic doc generation scripts: _____

**Plan the structure:**

Decide whether to preserve the existing directory hierarchy or flatten the structure. Starlight works with nested directories, but a flat structure with numbered prefixes (e.g., `01-getting-started.mdx`) is simpler:

```yaml
# Option A: Nested (preserves subdirectories)
docs/
  index.mdx
  getting-started.mdx
  api/
    index.mdx
    authentication.mdx
    endpoints.mdx

# Option B: Flat (easier to manage)
docs/
  index.mdx
  01-getting-started.mdx
  02-api-authentication.mdx
  03-api-endpoints.mdx
```

### 1. Rename Files

Rename all `.md` files to `.mdx`:

```bash
find docs/ -name '*.md' -exec bash -c 'mv "$0" "${0%.md}.mdx"' {} \;
```

### 2. Add Starlight Frontmatter

Every `.mdx` file needs YAML frontmatter. MkDocs files often have none or use MkDocs-specific keys.

**Landing page** (`docs/index.mdx`):

```yaml
---
title: Project Name
description: Short project description
template: splash
sidebar:
  hidden: true
hero:
  tagline: Your tagline here
  actions:
    - text: Get Started
      link: getting-started/
      icon: right-arrow
      variant: primary
---
```

**Content pages**:

```yaml
---
title: Page Title
description: One-line description of the page content
---
```

Remove any MkDocs-specific frontmatter keys (e.g., `hide:`, `icon:`, `status:`).

### 3. Convert Admonitions

MkDocs Material uses `!!!` for admonitions and `???` for collapsible admonitions. Starlight uses fenced directives.

**Standard admonitions** — replace `!!! type "Title"` with `:::type[Title]`:

```
# MkDocs Material                    # Starlight MDX
!!! note "Important"                  :::note[Important]
    Content indented 4 spaces.        Content (no indent required).
                                      :::

!!! warning "Caution"                 :::caution[Caution]
    Warning content.                  Warning content.
                                      :::

!!! tip "Helpful"                     :::tip[Helpful]
    Tip content.                      Tip content.
                                      :::

!!! danger "Critical"                 :::danger[Critical]
    Danger content.                   Danger content.
                                      :::
```

**Type mapping** (MkDocs → Starlight):

| MkDocs type | Starlight directive |
|---|---|
| `note` | `:::note` |
| `info` | `:::note` |
| `tip`, `hint` | `:::tip` |
| `success`, `check` | `:::tip` |
| `warning`, `attention` | `:::caution` |
| `danger`, `error`, `fail` | `:::danger` |
| `question`, `help`, `faq` | `:::note` |
| `example` | `:::tip` |
| `abstract`, `summary`, `tldr` | `:::note` |
| `bug` | `:::danger` |
| `quote`, `cite` | `:::note` |

**Collapsible admonitions** — replace `??? type "Title"` with HTML details/summary:

```
# MkDocs Material                    # Starlight MDX
??? question "FAQ Item"               <details>
    Answer content                    <summary>FAQ Item</summary>
    indented 4 spaces.               Answer content.
                                      </details>

???+ info "Expanded by default"       <details open>
    Content shown initially.          <summary>Expanded by default</summary>
                                      Content shown initially.
                                      </details>
```

**Key difference**: MkDocs admonition content is indented 4 spaces. After conversion, remove the extra indentation.

### 4. Replace Material Icons

MkDocs Material uses `:material-icon-name:` syntax. Replace with emoji or plain text.

| Material Icon | Replacement |
|---|---|
| `:material-check:` | ✓ |
| `:material-close:` | ✗ |
| `:material-arrow-right:` | → |
| `:material-arrow-left:` | ← |
| `:material-arrow-up-bold-circle:` | ⬆ |
| `:material-arrow-down-bold-circle:` | ⬇ |
| `:material-plus-circle:` | + |
| `:material-minus-circle:` | − |
| `:material-refresh:` | ↻ |
| `:material-information:` | ℹ |
| `:material-alert:` | ⚠ |
| `:material-cog:`, `:material-wrench:` | ⚙ |
| `:material-file-document:` | 📄 |
| `:material-link:` | 🔗 |
| `:material-code-tags:` | `</>` |
| `:material-key:` | 🔑 |
| `:material-lock:` | 🔒 |
| `:material-shield:` | 🛡 |

For any icon not listed, use descriptive text (e.g., `:material-database:` → "Database").

### 5. Handle Subdirectory Structures

MkDocs often organizes docs in subdirectories with their own `index.md`. Starlight handles this similarly but requires frontmatter on every file.

```
# MkDocs structure                    # Starlight structure
docs/                                 docs/
  index.md                              index.mdx (splash template)
  getting-started.md                    getting-started.mdx
  api/                                  api/
    index.md                              index.mdx
    authentication.md                     authentication.mdx
    endpoints.md                          endpoints.mdx
  guides/                              guides/
    index.md                              index.mdx
    quickstart.md                         quickstart.mdx
```

Starlight sidebar order is controlled by frontmatter or file/directory prefixes (e.g., `01-getting-started.mdx`). If you need explicit ordering without numeric prefixes, add `sidebar: { order: N }` to the frontmatter.

### 6. Handle Generated/Dynamic Docs

For repos where docs are generated by a script (e.g., `generate-docs.ts`, `generate-plugin-docs.py`):

1. **Update the generator script** to output `.mdx` files with Starlight frontmatter instead of `.md`
2. **Add an update-docs workflow job** that runs the generator, commits changes, and creates a PR (see the "Dynamic Doc Generation Pattern" section above)
3. **Generated files tracked in git**: Update `.gitignore` if needed; the generator should produce files that are committed to the repo
4. **Generated files not tracked**: The workflow job handles generation and commit in CI

### 7. Remove MkDocs Artifacts

Delete all MkDocs-specific files and directories:

- `mkdocs.yml` — MkDocs configuration
- `requirements-docs.txt` or `requirements.txt` (if docs-only)
- `docs/overrides/` — MkDocs theme overrides
- `docs/stylesheets/` — custom CSS for MkDocs
- `docs/javascripts/` — custom JS for MkDocs
- `docs/includes/` — MkDocs includes/snippets
- `docs/assets/` — if only used by MkDocs theme (check first)
- Any MkDocs-specific workflow (e.g., `docs.yml`, `deploy-docs.yml`)

### Phase 2: Validation and Testing

After conversion, validate the build locally and test the site:

#### 8.1 Local Build and Testing

```bash
# Install dependencies (assumes Astro Starlight project is set up)
npm install

# Build the docs locally
npm run build

# Watch for build errors — fix any issues before proceeding
npm run dev

# Open browser and manually test all pages
open http://localhost:3000
```

#### 8.2 Automated Checks

Run these checks to catch common migration issues:

```bash
# 1. Find any remaining Material icon references
grep -r ':material-' docs/ --include='*.mdx' | head -20

# 2. Find any remaining MkDocs admonitions (should be empty)
grep -r '^!!!' docs/ --include='*.mdx' | head -5
grep -r '^???' docs/ --include='*.mdx' | head -5

# 3. Find files missing frontmatter (except assets)
for file in $(find docs/ -name '*.mdx'); do
  if ! head -1 "$file" | grep -q '^---'; then
    echo "Missing frontmatter: $file"
  fi
done

# 4. Find unescaped curly braces (potential JSX issues)
grep -r '[^`]{[^}]*}' docs/ --include='*.mdx' | head -10

# 5. Check for tab characters (MDX prefers spaces)
grep -r $'\t' docs/ --include='*.mdx' | head -5
```

#### 8.3 Manual Content Validation

Check for common issues:

- **Broken internal links**: MkDocs uses `[text](file.md)` — update to `[text](../file/)` or Starlight-relative paths
- **Image paths**: Ensure images are in `docs/` or a public assets directory accessible to Astro
- **HTML in MDX**: MDX is stricter than Markdown — self-close tags like `<br />`, `<img />`, and use `className` instead of `class`
- **Unescaped curly braces**: MDX treats `{` and `}` as JSX expressions — escape with `\{` and `\}` or wrap in backticks
- **Tab-indented content**: MDX prefers spaces; convert tabs to spaces in code blocks and content
- **Code block syntax**: Verify `` ```language `` blocks render correctly
- **Sidebar navigation**: Check sidebar order and nesting in the Starlight UI

#### 8.4 Test Navigation and Links

```bash
# Manually test these scenarios:
# 1. Click all sidebar links — verify they load without errors
# 2. Test internal links in page content — verify they point to correct pages
# 3. Test image loading — all images should display
# 4. Test code blocks — syntax highlighting should work
# 5. Test admonitions — :::note, :::caution, etc. should render correctly
# 6. Test collapsible sections — <details> elements should expand/collapse
```

#### 8.5 Accessibility and Performance

```bash
# Run Lighthouse audit in browser DevTools
# Check:
# - Accessibility score >90
# - Performance score >80
# - No console errors

# Manual accessibility checks:
# - All images have alt text
# - Headings follow a logical hierarchy (h1 → h2 → h3)
# - Links have descriptive text (not "click here")
# - Color contrast is sufficient
```

#### 8.6 Common Conversion Issues and Fixes

| Issue | Detection | Fix |
|-------|-----------|-----|
| Build fails: "unexpected token" | `npm run build` fails | Check for unescaped curly braces or invalid MDX syntax |
| Build fails: "cannot find module" | Import/require error | Verify image paths and asset locations |
| Admonition not rendering | Visual inspection | Ensure closing `:::` on own line with no extra content |
| Links broken | Click test or 404 errors | Update `.md` paths to `.mdx` and verify relative paths |
| Sidebar not showing pages | Visual inspection | Verify `astro.config.mjs` sidebar configuration matches file structure |
| Icons not rendering | Visual inspection | Replace `:material-*:` with emoji or text |
| Code block not highlighting | Visual inspection | Ensure language identifier is correct (e.g., `` ```javascript `` not `` ```js ``) |
| Images missing | Visual inspection | Move to `public/` or `docs/assets/` and update path |

### Phase 3: Deployment and Finalization

After local validation passes, deploy the converted docs and finalize the migration.

#### 9. Push Changes and Trigger Deployment

```bash
# Create a feature branch for the migration
git checkout -b docs/migrate-to-starlight

# Stage all conversion changes
git add docs/
git add -A  # Also add workflow changes if any

# Commit with descriptive message
git commit -m "docs: migrate from MkDocs Material to Astro Starlight

- Rename all .md files to .mdx with Starlight frontmatter
- Convert MkDocs admonitions to Starlight directives
- Replace Material icons with emoji and text
- Update internal links for Starlight navigation
- Remove MkDocs configuration and artifacts

All docs validated locally via 'npm run build'"

# Push to remote
git push -u origin docs/migrate-to-starlight

# Create PR
gh pr create --title "docs: migrate from MkDocs to Astro Starlight" \
  --body "Migrates entire docs/ to Starlight MDX format with full validation.

- All .md → .mdx with proper frontmatter
- Admonitions converted to :::directive syntax
- Material icons replaced
- MkDocs artifacts removed
- Local build verified

Ready for deployment."
```

#### 10. Monitor Deployment Workflow

```bash
# Watch the github-pages-deploy workflow
gh run list -w github-pages-deploy.yml --repo f5xc-salesdemos/REPO_NAME \
  --json number,status,conclusion -L 1

# Get detailed logs if build fails
gh run view {RUN_ID} --log

# Check Pages deployment status
gh api repos/f5xc-salesdemos/REPO_NAME/pages --jq '.status'
```

#### 11. Verify Live Deployment

```bash
# Open the live site
open https://f5xc-salesdemos.github.io/REPO_NAME/

# Run Lighthouse audit on production
# (Use Chrome DevTools or web.dev/measure)

# Verify key pages load correctly:
# - Home page (splash template)
# - About/Getting started page
# - API or main content pages
# - All sidebar links
```

#### 12. Final Cleanup

After deployment is verified:

```bash
# Delete any remaining MkDocs configuration
rm mkdocs.yml requirements-docs.txt

# Remove the migration branch
git checkout main
git branch -D docs/migrate-to-starlight
git push origin --delete docs/migrate-to-starlight

# Mark migration as complete
git log --oneline main | head -1
echo "✓ Migration complete: $(git log --oneline main | head -1)"
```

#### 13. Document Migration Decisions

Create a `docs/MIGRATION_NOTES.md` file to document any custom decisions for future maintainers:

```markdown
# Migration Notes

## MkDocs to Astro Starlight (2024)

### Structure Changes
- Changed from nested directories to flat structure with numeric prefixes
- Removed all MkDocs theme customizations
- Starlight sidebar now auto-generated from file structure

### Content Changes
- Replaced all Material icons (`:material-*:`) with emoji
- Converted admonitions to Starlight directives (:::note, :::caution, etc.)
- Updated all internal links from `.md` to `.mdx` format

### Removed Artifacts
- `mkdocs.yml` — no longer needed
- `docs/overrides/` — Starlight handles styling
- `docs/stylesheets/` — custom CSS removed
- Material JS extensions — not needed in Starlight

### Known Limitations
- Collapsible admonitions use `<details>` instead of `??? type` syntax
- Code block language identifiers must match Astro/Shiki support
- Custom Material color schemes not available — use Starlight defaults

### Future Enhancements
- [ ] Add custom Starlight components if needed
- [ ] Consider sidebar grouping if hierarchy becomes complex
- [ ] Evaluate Starlight plugins for enhanced functionality
```

### Rollback Plan (if needed)

If the migration fails or needs to be reverted:

```bash
# Revert to the last known good commit before migration
git log --oneline | grep -i starlight
git revert <commit-hash>

# Or, reset to main if changes aren't pushed yet
git reset --hard origin/main

# Re-enable old Pages branch if needed
git checkout gh-pages-old  # If you kept a backup
git push origin gh-pages-old:gh-pages
```
