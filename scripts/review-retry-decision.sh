#!/usr/bin/env bash
# review-retry-decision.sh — decide whether a FAILED first attempt of the
# agentic Claude review may be safely retried.
#
#   review-retry-decision.sh decide <baseline> <current> <verdict_present 0|1>
#     -> prints exactly one of: retry | gate | fail   (and exits 0)
#
# The review posts inline + summary comments AS IT RUNS and writes verdict.json
# LAST. Therefore:
#   * verdict present            -> a complete review exists; let the verdict
#                                   gate decide. Never retry (would double-post). => gate
#   * no verdict, nothing posted -> failure happened BEFORE any posting
#                                   (launch/auth/rate-limit class). Safe.        => retry
#   * no verdict, something posted (or an anomalous count) -> partial review;
#                                   surface it, never silently retry.            => fail
#
# Fails safe: any malformed / missing input yields `fail` (never `retry`).
set -euo pipefail

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

cmd_decide() {
  local baseline="${1-}" current="${2-}" verdict="${3-}"

  # A complete verdict wins regardless of the comment delta.
  if [ "$verdict" = "1" ]; then
    echo gate
    return 0
  fi

  # The verdict flag must be an explicit "0" here; a missing/garbled flag is a
  # caller bug and fails safe (never retry).
  if [ "$verdict" != "0" ]; then
    echo fail
    return 0
  fi

  # No verdict: retry only when the counts are well-formed and equal (nothing
  # posted). Anything else — grew, shrank, or non-numeric — is `fail`.
  if is_uint "$baseline" && is_uint "$current" && [ "$baseline" = "$current" ]; then
    echo retry
  else
    echo fail
  fi
  return 0
}

main() {
  local sub="${1-}"
  shift || true
  case "$sub" in
  decide) cmd_decide "$@" ;;
  *)
    echo "usage: $0 decide <baseline> <current> <verdict_present 0|1>" >&2
    return 2
    ;;
  esac
}

main "$@"
