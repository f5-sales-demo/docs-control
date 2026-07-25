#!/usr/bin/env bash
# Hermetic test for scripts/check-review-deps.sh — the reviewer dependency preflight.
#
# Fully self-contained: every tool is a FAKE executable in a temp dir, so the test
# behaves identically on a GitHub-hosted runner (no terraform/az installed) and on
# the self-hosted macOS runner.
#
# Locks the failure mode that motivated the check: a PRESENT-BUT-NOT-EXECUTABLE tool
# earlier on PATH shadows a working copy and makes every invocation fail with
# "Permission denied" — while reviews kept reporting success.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/check-review-deps.sh"
FAIL=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkfake() { # <dir> <name> <mode>
  mkdir -p "$1"
  printf '#!/bin/sh\nexit 0\n' >"$1/$2"
  chmod "$3" "$1/$2"
}

# A directory with every dependency present and working.
GOOD="$WORK/good"
for t in git jq gh terraform az; do mkfake "$GOOD" "$t" 755; done

run() { # <PATH> [args...] -> prints output, sets RC
  local p="$1"
  shift
  # Absolute interpreter path: the fake PATH deliberately has no `bash`, so the
  # interpreter must not be resolved through it.
  OUT=$(env -i HOME="$WORK" PATH="$p" /bin/bash -c "/bin/bash '$SCRIPT' $*" 2>&1)
  RC=$?
}

ok() { echo "[OK] $1"; }
bad() {
  echo "[FAIL] $1"
  FAIL=1
}

# --- healthy -------------------------------------------------------------
run "$GOOD" --probe
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'all reviewer dependencies usable'; then
  ok "healthy env → exit 0"
else
  bad "healthy env — expected exit 0 + OK verdict, got rc=$RC"
fi

# --- the motivating bug: a non-executable tool is the ONLY copy on PATH ----
# (Verified bash semantics: a non-executable match is SKIPPED when a working copy
# exists later on PATH, so the break happens only when it is the sole match — which
# is exactly the runner case, where ~/.tfenv/bin is not on the non-interactive PATH.)
SOLE="$WORK/sole"
for t in git jq gh az; do mkfake "$SOLE" "$t" 755; done
mkfake "$SOLE" terraform 644 # present, NOT executable, and the only terraform
run "$SOLE"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'NOEXEC   terraform'; then
  ok "sole non-executable tool → NOEXEC, exit non-zero"
else
  bad "sole-non-executable NOEXEC not detected (rc=$RC)"
fi

# A non-executable entry FOLLOWED by a working copy is genuinely fine — bash skips
# it — so the check must NOT cry wolf.
SHADOW="$WORK/shadow"
mkfake "$SHADOW" terraform 644
run "$SHADOW:$GOOD"
if [ "$RC" -eq 0 ]; then
  ok "non-executable entry with a working copy later → correctly OK (no false alarm)"
else
  bad "false alarm: a usable terraform was reported broken (rc=$RC)"
fi

# --- missing verification tool -------------------------------------------
CORE_ONLY="$WORK/coreonly"
for t in git jq gh; do mkfake "$CORE_ONLY" "$t" 755; done
run "$CORE_ONLY"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'MISSING  terraform'; then
  ok "missing verification tool → MISSING, exit non-zero"
else
  bad "missing verification tool not detected (rc=$RC)"
fi

# --- missing core tool ---------------------------------------------------
NO_GH="$WORK/nogh"
for t in git jq terraform az; do mkfake "$NO_GH" "$t" 755; done
run "$NO_GH"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'MISSING  gh'; then
  ok "missing core tool → MISSING, exit non-zero"
else
  bad "missing core tool not detected (rc=$RC)"
fi

# --- --probe catches a resolvable but broken tool -------------------------
BROKEN="$WORK/broken"
for t in git jq gh az; do mkfake "$BROKEN" "$t" 755; done
mkdir -p "$BROKEN"
printf '#!/bin/sh\nexit 7\n' >"$BROKEN/terraform" # executable but always fails
chmod 755 "$BROKEN/terraform"
run "$BROKEN" --probe
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q 'BROKEN   terraform'; then
  ok "--probe catches an executable-but-failing tool"
else
  bad "--probe did not catch a failing tool (rc=$RC)"
fi
# ...and WITHOUT --probe that same tool passes (probe is the deeper check)
run "$BROKEN"
if [ "$RC" -eq 0 ]; then
  ok "without --probe, presence+exec is sufficient"
else
  bad "non-probe run should pass on a present+executable tool (rc=$RC)"
fi

# --- the degraded verdict must state the impact --------------------------
run "$CORE_ONLY"
if echo "$OUT" | grep -q 'must NOT claim it verified'; then
  ok "degraded verdict states the no-unverified-claims impact"
else
  bad "degraded verdict missing the impact statement"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "check-review-deps tests FAILED"
  exit 1
fi
echo "check-review-deps tests passed"
