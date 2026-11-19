#!/usr/bin/env bash
# Watcher absence is distinct from a failed inspection in the managed test.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REAL_GREP=$(command -v grep)
failed=0
fixture() {
  mkdir -p "$WORK/$1/scripts" "$WORK/$1/tests" "$WORK/$1/bin"
  cp "$ROOT/scripts/translation-release-policy.sh" "$WORK/$1/scripts/translation-release-policy.sh"
  cp "$ROOT/tests/test-translation-release-policy.sh" "$WORK/$1/tests/test-translation-release-policy.sh"
}
check() {
  local name="$1" expected="$2" actual=0
  PATH="$WORK/$name/bin:$PATH" REAL_GREP="$REAL_GREP" \
    bash "$WORK/$name/tests/test-translation-release-policy.sh" \
    >"$WORK/$name/stdout" 2>"$WORK/$name/stderr" || actual=$?
  if { [ "$expected" = pass ] && [ "$actual" -eq 0 ]; } ||
    { [ "$expected" = fail ] && [ "$actual" -ne 0 ]; }; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s returned %s\n' "$name" "$actual" >&2
    failed=1
  fi
}
fixture absent
check absent pass
if [ -s "$WORK/absent/stderr" ] || ! grep -qF 'no fleet watcher is shipped' "$WORK/absent/stdout"; then
  echo 'FAIL: absent watcher must be explicit without a failed grep' >&2
  failed=1
fi
fixture clean
printf '#!/bin/sh\nexit 0\n' >"$WORK/clean/scripts/collect-antigravity-fleet-state.sh"
check clean pass
for pattern in antigravity-translate TRANSLATIONS_ENABLED; do
  fixture "$pattern"
  printf '%s\n' "$pattern" >"$WORK/$pattern/scripts/collect-antigravity-fleet-state.sh"
  check "$pattern" fail
done
fixture inspection-error
printf '#!/bin/sh\nexit 0\n' >"$WORK/inspection-error/scripts/collect-antigravity-fleet-state.sh"
cat >"$WORK/inspection-error/bin/grep" <<'STUB'
#!/bin/sh
case "$*" in
  *'/scripts/collect-antigravity-fleet-state.sh'*) exit 2 ;;
esac
exec "$REAL_GREP" "$@"
STUB
chmod 700 "$WORK/inspection-error/bin/grep"
check inspection-error fail
fixture directory
mkdir "$WORK/directory/scripts/collect-antigravity-fleet-state.sh"
check directory fail
fixture dangling-link
ln -s missing "$WORK/dangling-link/scripts/collect-antigravity-fleet-state.sh"
check dangling-link fail
fixture linked-file
printf '#!/bin/sh\nexit 0\n' >"$WORK/linked-file/scripts/actual-watcher.sh"
ln -s actual-watcher.sh "$WORK/linked-file/scripts/collect-antigravity-fleet-state.sh"
check linked-file fail
exit "$failed"
