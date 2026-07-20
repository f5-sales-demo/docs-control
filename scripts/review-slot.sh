#!/usr/bin/env bash
#
# review-slot.sh — machine-wide counting semaphore for the self-hosted Claude PR
# reviewer. Caps how many reviews execute concurrently across ALL repo runners on
# this host and queues the rest.
#
# Why this exists: the org is on GitHub Free, so runners are repo-level (one
# ephemeral instance per repo) — GitHub's per-repo `concurrency:` cannot express a
# fleet-wide "max N". macOS has no `flock` and `shlock` is a single mutex, so the
# cap is a set of N slot directories claimed with atomic `mkdir` (mkdir either
# creates the dir and succeeds, or fails if it exists — the atomic primitive).
#
# Usage (from claude-review.yml, tooling checked out into .review-tooling):
#   bash .review-tooling/scripts/review-slot.sh acquire   # blocks until a slot is free
#   ...run the review...
#   REVIEW_SLOT=$REVIEW_SLOT bash .review-tooling/scripts/review-slot.sh release
#
# acquire appends `REVIEW_SLOT=slot-<n>` to $GITHUB_ENV so a later step (and the
# `if: always()` release step) knows which slot to free.
#
# Tunables (env; machine-wide, not per-repo):
#   REVIEW_MAX_SLOTS        max concurrent reviews          (default 5)
#   REVIEW_SLOTS_DIR        slot state dir                  (default ~/.config/code-review-runner/slots)
#   REVIEW_STALE_SECONDS    reclaim a held slot older than  (default 2700 = 45m > the 30m review cap)
#   REVIEW_POLL_SECONDS     wait between acquire sweeps      (default 10)
#   REVIEW_MAX_WAIT_SECONDS give up acquiring after         (default 10800 = 3h)
#
set -euo pipefail

N="${REVIEW_MAX_SLOTS:-5}"
SLOTS_DIR="${REVIEW_SLOTS_DIR:-$HOME/.config/code-review-runner/slots}"
STALE="${REVIEW_STALE_SECONDS:-2700}"
POLL="${REVIEW_POLL_SECONDS:-10}"
MAX_WAIT="${REVIEW_MAX_WAIT_SECONDS:-10800}"

log() { echo "review-slot: $*" >&2; }

write_meta() {
  # $1 = slot dir. Record claim epoch (the staleness signal) + provenance.
  {
    printf 'epoch=%s\n' "$(date +%s)"
    printf 'repo=%s\n' "${GITHUB_REPOSITORY:-}"
    printf 'pr=%s\n' "${PR_NUMBER:-}"
    printf 'run=%s\n' "${GITHUB_RUN_ID:-}"
  } >"$1/meta"
  return 0
}

# Free any slot whose holder is gone: a claim whose recorded epoch is older than
# STALE (holder cancelled/crashed/timed out — a live review is bounded to 30m), or
# a meta-less dir left by a crash between mkdir and meta-write, older than STALE by
# mtime. `find -mmin` is portable across macOS and the Linux CI runner.
reclaim_stale() {
  local now d epoch age stale_min
  now="$(date +%s)"
  for d in "$SLOTS_DIR"/slot-*; do
    [ -d "$d" ] || continue
    epoch="$(sed -n 's/^epoch=//p' "$d/meta" 2>/dev/null | head -1)"
    # Only act on a numeric epoch; empty/partial meta (just-created slot) is skipped.
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
      age=$((now - epoch))
      if [ "$age" -ge "$STALE" ]; then rm -rf "$d" 2>/dev/null || true; fi
    fi
  done
  # Belt-and-suspenders: meta-less dirs older than STALE minutes (crash window).
  stale_min=$((STALE / 60))
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [ ! -e "$m/meta" ]; then rm -rf "$m" 2>/dev/null || true; fi
  done < <(find "$SLOTS_DIR" -mindepth 1 -maxdepth 1 -type d -mmin +"$stale_min" 2>/dev/null || true)
  return 0
}

try_claim() {
  # Attempt one atomic claim sweep; on success echo the slot name and return 0.
  local i slot
  for ((i = 1; i <= N; i++)); do
    slot="$SLOTS_DIR/slot-$i"
    if mkdir "$slot" 2>/dev/null; then
      write_meta "$slot"
      echo "slot-$i"
      return 0
    fi
  done
  return 1
}

acquire() {
  mkdir -p "$SLOTS_DIR"
  local deadline claimed
  deadline=$(($(date +%s) + MAX_WAIT))
  while :; do
    if claimed="$(try_claim)"; then
      log "acquired $claimed (max $N)"
      echo "REVIEW_SLOT=$claimed"
      if [ -n "${GITHUB_ENV:-}" ]; then echo "REVIEW_SLOT=$claimed" >>"$GITHUB_ENV"; fi
      return 0
    fi
    reclaim_stale || true
    if claimed="$(try_claim)"; then
      log "acquired $claimed after reclaim (max $N)"
      echo "REVIEW_SLOT=$claimed"
      if [ -n "${GITHUB_ENV:-}" ]; then echo "REVIEW_SLOT=$claimed" >>"$GITHUB_ENV"; fi
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "timed out after ${MAX_WAIT}s waiting for a free slot (all $N busy)"
      return 1
    fi
    log "all $N slots busy; waiting ${POLL}s"
    sleep "$POLL"
  done
}

release() {
  local slot="${REVIEW_SLOT:-}"
  if [ -z "$slot" ]; then
    log "no REVIEW_SLOT set; nothing to release"
    return 0
  fi
  rm -rf "${SLOTS_DIR:?}/$slot" 2>/dev/null || true
  log "released $slot"
  return 0
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
  acquire) acquire ;;
  release) release ;;
  *)
    log "usage: $0 {acquire|release}"
    return 2
    ;;
  esac
}

main "$@"
