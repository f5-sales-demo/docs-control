#!/usr/bin/env bash
# Hermetic test for scripts/lint-mdx-prose.sh — the gate that lints MDX prose.
#
# Neither of the two linters that own prose can see .mdx on its own. pre-commit's
# markdownlint hook selects `types: [markdown]` and `identify` tags .mdx as `mdx`;
# Super-Linter v8.7.0 routes only the `md` extension into MARKDOWN and
# NATURAL_LANGUAGE. So a repository whose documentation is .mdx — mcn's docs/en is
# 100% .mdx — passes both gates without either having opened a file.
#
# The linters are stubbed on PATH so this test asserts our selection and exit
# behaviour without a network round trip or a pinned tool version.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/lint-mdx-prose.sh"

FAIL=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"

# Stubs record their arguments and honour a failure switch, so a test can assert
# both "was this linter asked about this file" and "does a finding fail the gate".
for tool in markdownlint-cli2 textlint; do
  cat >"$WORK/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$WORK/${tool}.args"
if [ -n "\${STUB_FAIL_${tool//-/_}:-}" ]; then exit 1; fi
exit 0
STUB
  chmod +x "$WORK/bin/$tool"
done

reset_calls() { rm -f "$WORK"/markdownlint-cli2.args "$WORK"/textlint.args; }

run_gate() { # run_gate <paths...> -> echoes exit code
  local rc=0
  MDX_LINT_MARKDOWNLINT_BIN="$WORK/bin/markdownlint-cli2" MDX_LINT_TEXTLINT_BIN="$WORK/bin/textlint" \
    bash "$SCRIPT" "$@" >"$WORK/out" 2>&1 || rc=$?
  echo "$rc"
}

ok() { echo "[OK] $1"; }
bad() {
  echo "[FAIL] $1"
  FAIL=1
}

# --- fixtures -------------------------------------------------------------
mkdir -p "$WORK/docs/en"
printf -- '---\ntitle: Good\n---\n\nSome prose.\n' >"$WORK/docs/en/good.mdx"
printf -- '---\ntitle: Also good\n---\n\nMore prose.\n' >"$WORK/docs/en/other.mdx"
printf -- '# Plain markdown\n' >"$WORK/docs/en/plain.md"

# --- cases ----------------------------------------------------------------

reset_calls
rc=$(run_gate)
if [ "$rc" -eq 0 ] && [ ! -f "$WORK/markdownlint-cli2.args" ]; then
  ok "no arguments: exits 0 and invokes no linter"
else
  bad "no arguments should be a clean no-op (rc=$rc)"
fi

reset_calls
rc=$(run_gate "$WORK/docs/en/plain.md")
if [ "$rc" -eq 0 ] && [ ! -f "$WORK/textlint.args" ]; then
  ok ".md only: no-op, because Super-Linter already owns that extension"
else
  bad ".md must not be linted here — it would double-report (rc=$rc)"
fi

reset_calls
rc=$(run_gate "$WORK/docs/en/good.mdx")
if [ "$rc" -ne 0 ]; then
  bad "a clean .mdx must pass (rc=$rc): $(cat "$WORK/out")"
elif ! grep -qF "$WORK/docs/en/good.mdx" "$WORK/markdownlint-cli2.args" 2>/dev/null; then
  bad "markdownlint was not asked about the .mdx file"
elif ! grep -qF "$WORK/docs/en/good.mdx" "$WORK/textlint.args" 2>/dev/null; then
  bad "textlint was not asked about the .mdx file"
else
  ok "a .mdx file reaches both markdownlint and textlint"
fi

reset_calls
rc=$(run_gate "$WORK/docs/en/good.mdx")
if grep -q -- '--plugin' "$WORK/textlint.args" && grep -q 'mdx' "$WORK/textlint.args"; then
  ok "textlint is invoked with the mdx plugin"
else
  bad "textlint must be given --plugin mdx or it cannot parse the file"
fi

reset_calls
rc=$(run_gate "$WORK/docs/en/good.mdx" "$WORK/docs/en/other.mdx" "$WORK/docs/en/plain.md")
if [ "$(grep -c '\.mdx$' "$WORK/markdownlint-cli2.args" 2>/dev/null || echo 0)" -eq 2 ] &&
  ! grep -q '\.md$' "$WORK/markdownlint-cli2.args"; then
  ok "a mixed list is filtered to .mdx only"
else
  bad "mixed list filtering is wrong: $(cat "$WORK/markdownlint-cli2.args" 2>/dev/null)"
fi

reset_calls
rc=$(
  STUB_FAIL_markdownlint_cli2=1 MDX_LINT_MARKDOWNLINT_BIN="$WORK/bin/markdownlint-cli2" \
    MDX_LINT_TEXTLINT_BIN="$WORK/bin/textlint" bash "$SCRIPT" "$WORK/docs/en/good.mdx" >/dev/null 2>&1
  echo $?
)
if [ "$rc" -ne 0 ]; then
  ok "a markdownlint finding fails the gate"
else
  bad "markdownlint findings must fail the gate, got rc=$rc"
fi

reset_calls
rc=$(
  STUB_FAIL_textlint=1 MDX_LINT_MARKDOWNLINT_BIN="$WORK/bin/markdownlint-cli2" \
    MDX_LINT_TEXTLINT_BIN="$WORK/bin/textlint" bash "$SCRIPT" "$WORK/docs/en/good.mdx" >/dev/null 2>&1
  echo $?
)
if [ "$rc" -ne 0 ]; then
  ok "a textlint finding fails the gate"
else
  bad "textlint findings must fail the gate, got rc=$rc"
fi

reset_calls
rc=$(run_gate "$WORK/docs/en/deleted.mdx")
if [ "$rc" -eq 0 ]; then
  ok "a path that no longer exists is skipped, not an error"
else
  bad "a deleted file in a changed-file list must not fail the gate (rc=$rc)"
fi

# --- the routing facts this gate exists to compensate for -----------------

# The gate must be reachable locally as well as in CI, and both must run the same
# script — a hook that only widened markdownlint would still leave textlint blind.
if grep -q 'lint-mdx-prose' "${REPO_ROOT}/.pre-commit-config.yaml"; then
  ok "pre-commit invokes the MDX prose gate"
else
  bad "pre-commit does not invoke scripts/lint-mdx-prose.sh"
fi

mdx_hook_types=$(awk '/id: lint-mdx-prose$/,/^$/' "${REPO_ROOT}/.pre-commit-config.yaml" | grep -E 'types(_or)?:' || true)
if printf '%s' "$mdx_hook_types" | grep -q 'mdx'; then
  ok "the pre-commit MDX hook selects mdx files"
else
  bad "the pre-commit MDX hook must select types: [mdx], got: ${mdx_hook_types}"
fi

if grep -q 'lint-mdx-prose.sh' "${REPO_ROOT}/.github/workflows/super-linter.yml"; then
  ok "super-linter workflow invokes the MDX prose gate"
else
  bad "super-linter workflow does not invoke scripts/lint-mdx-prose.sh"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: MDX prose gate selects and fails as specified"
else
  echo "FAIL: MDX prose gate is wrong"
fi
exit "$FAIL"
