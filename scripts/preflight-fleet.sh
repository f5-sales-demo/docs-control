#!/usr/bin/env bash
# Answers one question before a check is enforced fleet-wide: which governed
# repositories would it break?
#
# A check added to the Lint Code Base gate becomes a REQUIRED check in every
# governed repository the moment it syncs. Two checks written in this repository
# were measured this way first, and both needed the answer: one would have failed
# 10 of 38 repositories with only 2 real findings, and one flagged the very package
# that owns the data it tells everyone else to import. Neither was visible from the
# diff, so no amount of review would have surfaced them.
#
# Judges each repository's LIVE default branch (origin/HEAD) in a throwaway
# worktree, never the operator's working tree. A local clone is usually stale or
# dirty, and reading it produces confident, wrong answers.
#
# Usage:
#   bash scripts/preflight-fleet.sh --check scripts/check-repo-hygiene.sh
#   bash scripts/preflight-fleet.sh --check scripts/locale-lint.sh --json
#   bash scripts/preflight-fleet.sh --check ./my-check.sh --args "--include-paths"
#
# Options:
#   --check <path>            The check to trial. Required. Run with the repository
#                             root as its working directory.
#   --args "<string>"         Arguments forwarded to the check, word-split.
#   --repos-file <path>       Repository list. Default .github/config/downstream-repos.json
#   --governance-file <path>  skip_files source. Default .claude/governance.json
#   --search-path <dir>       Where to look for local clones. Repeatable.
#                             Default: $HOME/GIT and $HOME/GIT/security
#   --no-fetch                Skip `git fetch`. Offline and for tests; results are
#                             then only as current as the last fetch.
#   --json                    Emit machine-readable results.
#
# Exit 0 = no governed repository would break. Exit 1 = at least one would, or the
# invocation was invalid. Repositories that are not cloned locally are reported as a
# coverage gap rather than counted as clean: a repository nobody checked is not a
# repository known to be fine.
set -euo pipefail

CHECK=""
CHECK_ARGS=""
REPOS_FILE=".github/config/downstream-repos.json"
GOVERNANCE_FILE=".claude/governance.json"
NO_FETCH=0
AS_JSON=0
SEARCH_PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
  --check)
    CHECK="${2:-}"
    shift 2
    ;;
  --args)
    CHECK_ARGS="${2:-}"
    shift 2
    ;;
  --repos-file)
    REPOS_FILE="${2:-}"
    shift 2
    ;;
  --governance-file)
    GOVERNANCE_FILE="${2:-}"
    shift 2
    ;;
  --search-path)
    SEARCH_PATHS+=("${2:-}")
    shift 2
    ;;
  --no-fetch)
    NO_FETCH=1
    shift
    ;;
  --json)
    AS_JSON=1
    shift
    ;;
  -h | --help)
    sed -n '2,40p' "$0"
    exit 0
    ;;
  *)
    echo "::error::unknown argument: $1" >&2
    exit 1
    ;;
  esac
done

if [ -z "$CHECK" ]; then
  echo "::error::--check <path> is required." >&2
  exit 1
fi
if [ ! -f "$CHECK" ]; then
  echo "::error::check script not found: ${CHECK}" >&2
  exit 1
fi
CHECK=$(cd "$(dirname "$CHECK")" && pwd)/$(basename "$CHECK")

if [ ! -f "$REPOS_FILE" ]; then
  echo "::error::repository list not found: ${REPOS_FILE}" >&2
  exit 1
fi

if [ ${#SEARCH_PATHS[@]} -eq 0 ]; then
  SEARCH_PATHS=("${HOME}/GIT" "${HOME}/GIT/security")
fi

CHECK_BASENAME=$(basename "$CHECK")

# A while-read loop rather than `mapfile`: this is an operator tool, and macOS
# ships bash 3.2, which has no mapfile.
REPOS=()
while IFS= read -r repo_name; do
  [ -n "$repo_name" ] && REPOS+=("$repo_name")
done < <(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
names = data if isinstance(data, list) else data.get("repos", data.get("repositories", []))
for entry in names:
    name = entry if isinstance(entry, str) else (entry.get("name") or entry.get("repo") or "")
    if name:
        print(name.split("/")[-1])
' "$REPOS_FILE")

if [ ${#REPOS[@]} -eq 0 ]; then
  echo "::error::no repositories parsed from ${REPOS_FILE}" >&2
  exit 1
fi

# A repository that opts out of the check never receives it, so a finding there
# would be a phantom.
skips_check() {
  local repo="$1"
  [ -f "$GOVERNANCE_FILE" ] || return 1
  python3 -c '
import json, os, sys
repo, basename, path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    skip = json.load(open(path)).get("skip_files", {}).get(repo, [])
except Exception:
    sys.exit(1)
sys.exit(0 if any(os.path.basename(entry) == basename for entry in skip) else 1)
' "$repo" "$CHECK_BASENAME" "$GOVERNANCE_FILE"
}

find_clone() {
  local repo="$1" base
  for base in "${SEARCH_PATHS[@]}"; do
    if [ -d "${base}/${repo}/.git" ]; then
      echo "${base}/${repo}"
      return 0
    fi
  done
  return 1
}

# origin/HEAD is the honest target, but not every clone has it set.
default_ref() {
  local clone="$1" ref
  for ref in origin/HEAD origin/main origin/master; do
    if git -C "$clone" rev-parse --verify -q "$ref" >/dev/null; then
      echo "$ref"
      return 0
    fi
  done
  return 1
}

CLEAN=()
BROKEN=()
SKIPPED=()
UNCLONED=()
ERRORED=()

for repo in "${REPOS[@]}"; do
  if skips_check "$repo"; then
    SKIPPED+=("$repo")
    continue
  fi

  clone=$(find_clone "$repo" || true)
  if [ -z "$clone" ]; then
    UNCLONED+=("$repo")
    continue
  fi

  if [ "$NO_FETCH" -eq 0 ]; then
    git -C "$clone" fetch --quiet --no-tags origin 2>/dev/null || true
  fi

  ref=$(default_ref "$clone" || true)
  if [ -z "$ref" ]; then
    ERRORED+=("${repo}: no origin/HEAD, origin/main or origin/master")
    continue
  fi

  worktree=$(mktemp -d "${TMPDIR:-/tmp}/preflight-${repo}-XXXXXX")
  rm -rf "$worktree"
  if ! git -C "$clone" worktree add -q --detach "$worktree" "$ref" 2>/dev/null; then
    ERRORED+=("${repo}: could not check out ${ref}")
    rm -rf "$worktree"
    continue
  fi

  rc=0
  output=$(
    cd "$worktree" || exit 1
    # Word splitting of CHECK_ARGS is the point: they are the check's own flags.
    # shellcheck disable=SC2086
    bash "$CHECK" ${CHECK_ARGS} 2>&1
  ) || rc=$?

  # Always give the clone back exactly as it was found.
  git -C "$clone" worktree remove --force "$worktree" 2>/dev/null || true
  git -C "$clone" worktree prune 2>/dev/null || true
  rm -rf "$worktree"

  if [ "$rc" -eq 0 ]; then
    CLEAN+=("$repo")
  else
    BROKEN+=("$repo")
    if [ "$AS_JSON" -eq 0 ]; then
      echo "WOULD BREAK: ${repo} (at ${ref})"
      printf '%s\n' "$output" | grep -E '::error|FAIL|error' | head -3 | sed 's/^/    /'
    fi
  fi
done

if [ "$AS_JSON" -eq 1 ]; then
  python3 -c '
import json, sys
keys = ["clean", "broken", "skipped", "uncloned", "errored"]
payload = {k: [v for v in sys.argv[i + 1].split("\n") if v] for i, k in enumerate(keys)}
payload["counts"] = {k: len(v) for k, v in payload.items()}
payload["would_break"] = bool(payload["broken"]) or bool(payload["errored"])
print(json.dumps(payload, indent=2))
' "$(printf '%s\n' "${CLEAN[@]+"${CLEAN[@]}"}")" \
    "$(printf '%s\n' "${BROKEN[@]+"${BROKEN[@]}"}")" \
    "$(printf '%s\n' "${SKIPPED[@]+"${SKIPPED[@]}"}")" \
    "$(printf '%s\n' "${UNCLONED[@]+"${UNCLONED[@]}"}")" \
    "$(printf '%s\n' "${ERRORED[@]+"${ERRORED[@]}"}")"
else
  echo ""
  echo "Pre-flight: ${CHECK_BASENAME} against ${#REPOS[@]} governed repositories"
  echo "  clean=${#CLEAN[@]} would_break=${#BROKEN[@]} skipped=${#SKIPPED[@]} uncloned=${#UNCLONED[@]} errored=${#ERRORED[@]}"
  [ ${#SKIPPED[@]} -gt 0 ] && echo "  skipped (opted out): ${SKIPPED[*]}"
  [ ${#UNCLONED[@]} -gt 0 ] && echo "  NOT CHECKED (no local clone): ${UNCLONED[*]}"
  for entry in ${ERRORED[@]+"${ERRORED[@]}"}; do
    echo "  ERROR: ${entry}"
  done
  if [ ${#UNCLONED[@]} -gt 0 ]; then
    echo "  Coverage is incomplete: a repository nobody checked is not a repository known to be fine."
  fi
fi

if [ ${#BROKEN[@]} -gt 0 ] || [ ${#ERRORED[@]} -gt 0 ]; then
  exit 1
fi
exit 0
