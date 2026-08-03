#!/bin/bash
# Antigravity Conventional Commit Trigger Parser

PR_TITLE="$1"
CHANGED_FILES_FILE="$2"
EVENT_NAME="$3"

echo "Parsing Translation Triggers..."
echo "  Event Name: $EVENT_NAME"
echo "  PR Title:   $PR_TITLE"

SHOULD_RUN="false"
FORCE_RECONCILE="false"
BYPASS="false"

# 1. Check for manual workflow dispatch
if [ "$EVENT_NAME" == "workflow_dispatch" ]; then
  echo "Workflow manually dispatched. Defaulting to execute."
  SHOULD_RUN="true"
fi

# 2. Check for explicit bypass keywords in PR title
if [[ "$PR_TITLE" =~ "\[skip i18n\]" || "$PR_TITLE" =~ "\[no i18n\]" || "$PR_TITLE" =~ "\(no-i18n\)" ]]; then
  echo "Bypass keyword detected."
  BYPASS="true"
fi

# 3. Check for explicit reconciliation (force rebuild) keywords
if [[ "$PR_TITLE" =~ "i18n.*reconcile" || "$PR_TITLE" =~ "reconcile.*i18n" || "$PR_TITLE" =~ "i18n-reconcile" ]]; then
  echo "Force reconciliation keyword detected."
  FORCE_RECONCILE="true"
  SHOULD_RUN="true"
fi

# 4. Check for conventional i18n scope patterns in PR title
if [[ "$PR_TITLE" =~ ^feat\(i18n\) || "$PR_TITLE" =~ ^fix\(i18n\) || "$PR_TITLE" =~ ^chore\(i18n\) || "$PR_TITLE" =~ ^docs\(i18n\) ]]; then
  echo "Conventional i18n scope pattern found in title."
  SHOULD_RUN="true"
fi

# 5. Fallback: Parse modified files if not bypassed or triggered
if [ "$BYPASS" != "true" ] && [ "$SHOULD_RUN" != "true" ]; then
  if [ -f "$CHANGED_FILES_FILE" ]; then
    while IFS= read -r file; do
      if [[ "$file" =~ ^docs/en/ || "$file" =~ ^src/content/docs/en/ ]]; then
        echo "Modified English document file detected: $file"
        SHOULD_RUN="true"
        break
      fi
    done < "$CHANGED_FILES_FILE"
  else
    echo "No changed files list provided."
  fi
fi

# 6. Apply bypass override
if [ "$BYPASS" == "true" ]; then
  echo "Bypassing translation execution."
  SHOULD_RUN="false"
  FORCE_RECONCILE="false"
fi

echo "Execution Decision:"
echo "  SHOULD_RUN=$SHOULD_RUN"
echo "  FORCE_RECONCILE=$FORCE_RECONCILE"

# Export to GitHub Actions step output
if [ -n "$GITHUB_OUTPUT" ]; then
  echo "should_run=$SHOULD_RUN" >> "$GITHUB_OUTPUT"
  echo "force_reconcile=$FORCE_RECONCILE" >> "$GITHUB_OUTPUT"
fi
