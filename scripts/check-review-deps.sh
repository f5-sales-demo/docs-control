#!/usr/bin/env bash
# check-review-deps.sh — assert the CLIs the agentic reviewer depends on are
# actually usable in THIS process's environment (not merely installed somewhere).
#
#   check-review-deps.sh [--probe]
#     --probe : also run each tool's cheap version command (catches a resolvable
#               but broken tool, e.g. a shim pointing at a missing binary).
#
# Prints one line per tool (OK / MISSING / NOEXEC / BROKEN) and a final verdict.
# Exit 0 = every dependency usable. Exit 1 = at least one is not.
#
# WHY THIS EXISTS: the reviewer's stated reason to exist is proving a change works
# against real internal APIs using the operator's live CLIs on the self-hosted
# runner. That leg can break WITHOUT any review failing — a review then looks
# complete while having silently skipped the one check no diff-only reviewer can
# do. That happened: a non-executable `terraform` shim in ~/.local/bin was the ONLY
# terraform on the runner's PATH (~/.tfenv/bin is added by interactive rc files only),
# so every `terraform` call died with "Permission denied" while reviews kept reporting
# success. This check exists so that degradation is always VISIBLE.
#
# NOTE on PATH semantics (verified, not assumed): bash SKIPS a non-executable match
# and uses a later executable one, so a non-executable entry only breaks things when
# it is the sole match. This check reports exactly that condition.
#
# The runner is started by launchd, whose environment differs from an interactive
# shell, so this must be evaluated in the runner's own environment to be truthful.
set -uo pipefail

PROBE=0
[ "${1:-}" = "--probe" ] && PROBE=1

# Tools the reviewer cannot function without at all.
CORE="git jq gh"
# Tools the AUTHENTICATED VERIFICATION leg needs. Missing these does not stop a
# review, but it must be reported so the review never implies it verified.
VERIFY="terraform az"

fail=0
degraded=""

probe_cmd() { # <tool> -> cheap, offline-ish version invocation
  case "$1" in
  terraform) terraform version ;;
  az) az version ;;
  gh) gh --version ;;
  git) git --version ;;
  jq) jq --version ;;
  *) "$1" --version ;;
  esac
}

check_one() { # <tool> <class>
  local c="$1" class="$2" p
  if ! p=$(command -v "$c" 2>/dev/null) || [ -z "$p" ]; then
    echo "MISSING  ${c} (${class}) — not on PATH"
    return 1
  fi
  if [ ! -x "$p" ]; then
    echo "NOEXEC   ${c} (${class}) -> ${p} — resolves to a NON-EXECUTABLE file and no working copy exists later on PATH; every invocation fails with \"Permission denied\""
    return 1
  fi
  if [ "$PROBE" -eq 1 ]; then
    if ! probe_cmd "$c" >/dev/null 2>&1; then
      echo "BROKEN   ${c} (${class}) -> ${p} — resolves but its version command failed"
      return 1
    fi
  fi
  echo "OK       ${c} (${class}) -> ${p}"
  return 0
}

for c in $CORE; do
  check_one "$c" core || {
    fail=1
    degraded="${degraded} ${c}"
  }
done
for c in $VERIFY; do
  check_one "$c" verification || {
    fail=1
    degraded="${degraded} ${c}"
  }
done

echo "---"
if [ "$fail" -eq 0 ]; then
  echo "VERDICT: all reviewer dependencies usable"
  exit 0
fi
echo "VERDICT: DEGRADED — unusable:${degraded}"
echo "IMPACT: any review relying on these must NOT claim it verified anything with them."
exit 1
