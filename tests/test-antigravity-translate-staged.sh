#!/usr/bin/env bash
# Hermetic tests for the managed Antigravity pre-commit translation hook.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/antigravity-translate-staged.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s — %s\n' "$1" "$2"
}

locales=(fr es de pt-br ja ko zh-cn zh-tw ar it hi th)

source_path() {
  case "$1" in
  docs) printf 'docs/en/page.mdx' ;;
  content) printf 'src/content/docs/en/page.mdx' ;;
  esac
}

target_path() {
  local layout="$1" locale="$2"
  case "$layout" in
  docs) printf 'docs/%s/page.mdx' "$locale" ;;
  content) printf 'src/content/docs/%s/page.mdx' "$locale" ;;
  esac
}

write_translation() {
  local repo="$1" layout="$2" locale="$3" hash="$4" target
  target=$(target_path "$layout" "$locale")
  mkdir -p "$repo/$(dirname "$target")"
  printf '%s\n' '---' "title: Example" 'i18n:' "  sourceHash: \"$hash\"" \
    '  translator: "machine"' '---' '' '# Example' '' \
    'Keep `literal` and <Callout type="note"> unchanged.' '' \
    'Visit https://example.com/docs.' >"$repo/$target"
}

setup_repo() {
  local layout="$1" repo="$WORK/repo" source hash
  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  source=$(source_path "$layout")
  mkdir -p "$repo/$(dirname "$source")" "$repo/.agents/skills/i18n-translate"
  printf '%s\n' 'test skill' >"$repo/.agents/skills/i18n-translate/SKILL.md"
  printf '%s\n' '---' 'title: Example' '---' '' '# Example' '' \
    'Keep `literal` and <Callout type="note"> unchanged.' '' \
    'Visit https://example.com/docs.' >"$repo/$source"
  hash=$(shasum -a 256 "$repo/$source" | awk '{print substr($1, 1, 12)}')
  for locale in "${locales[@]}"; do
    write_translation "$repo" "$layout" "$locale" "$hash"
  done
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline
  printf '\nUpdated prose.\n' >>"$repo/$source"
  git -C "$repo" add "$source"
}

make_fake_agy() {
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/agy" <<'PY'
#!/usr/bin/env python3
import os
from pathlib import Path
import re
import sys

args = sys.argv[1:]
Path(os.environ["FAKE_AGY_ARGS"]).write_text("\n".join(args), encoding="utf-8")
if os.environ.get("FAKE_AGY_MODE") == "fail":
    raise SystemExit(9)
prompt = args[-1]
requests = re.findall(r"^- (.+) sourceHash=([0-9a-f]{12})$", prompt, re.MULTILINE)
locales = ("fr", "es", "de", "pt-br", "ja", "ko", "zh-cn", "zh-tw", "ar", "it", "hi", "th")
for source, expected_hash in requests:
    raw = Path(source).read_text(encoding="utf-8")
    if raw.startswith("---\n"):
        end = raw.find("\n---\n", 4)
        frontmatter = raw[4:end]
        body = raw[end + 5:]
        rendered = (
            "---\n" + frontmatter + "\ni18n:\n"
            f"  sourceHash: \"{expected_hash}\"\n"
            "  translator: \"machine\"\n---\n" + body
        )
    else:
        rendered = (
            "---\ni18n:\n"
            f"  sourceHash: \"{expected_hash}\"\n"
            "  translator: \"machine\"\n---\n" + raw
        )
    if os.environ.get("FAKE_AGY_MODE") == "bad-hash":
        rendered = rendered.replace(expected_hash, "000000000000")
    if source.startswith("docs/en/"):
        relative = source.removeprefix("docs/en/")
        target = lambda locale: Path("docs") / locale / relative
    else:
        relative = source.removeprefix("src/content/docs/en/")
        target = lambda locale: Path("src/content/docs") / locale / relative
    for locale in locales:
        if os.environ.get("FAKE_AGY_MODE") == "missing" and locale == "th":
            target(locale).unlink(missing_ok=True)
            continue
        target(locale).parent.mkdir(parents=True, exist_ok=True)
        target(locale).write_text(rendered, encoding="utf-8")
if os.environ.get("FAKE_AGY_MODE") == "unexpected":
    Path("unexpected.txt").write_text("not allowed\n", encoding="utf-8")
PY
  chmod +x "$WORK/bin/agy"
}

run_hook() {
  local repo="$1" mode="${2:-valid}" rc=0
  (
    cd "$repo"
    PATH="$WORK/bin:/usr/bin:/bin" FAKE_AGY_ARGS="$WORK/agy-args" \
      FAKE_AGY_MODE="$mode" bash "$SCRIPT"
  ) >"$WORK/output" 2>&1 || rc=$?
  return "$rc"
}

echo "Antigravity staged translation tests"

setup_repo docs
rm -rf "${WORK:?}/bin"
if run_hook "$WORK/repo" 2>/dev/null; then
  fail "missing agy blocks the commit" "hook returned success"
elif grep -q 'requires agy' "$WORK/output"; then
  pass "missing agy blocks the commit"
else
  fail "missing agy blocks the commit" "expected diagnostic missing"
fi

make_fake_agy
if run_hook "$WORK/repo"; then
  expected_hash=$(shasum -a 256 "$WORK/repo/docs/en/page.mdx" | awk '{print substr($1, 1, 12)}')
  staged=0
  for locale in "${locales[@]}"; do
    target=$(target_path docs "$locale")
    if git -C "$WORK/repo" diff --cached --name-only -- "$target" | grep -qxF "$target" &&
      grep -q "sourceHash: \"$expected_hash\"" "$WORK/repo/$target"; then
      staged=$((staged + 1))
    fi
  done
  if [ "$staged" -eq 12 ]; then
    pass "valid agy output stages all 12 fresh locale files"
  else
    fail "valid agy output stages all 12 fresh locale files" "staged=$staged"
  fi
else
  fail "valid agy output is accepted" "$(cat "$WORK/output")"
fi

if grep -qx -- '--sandbox' "$WORK/agy-args" &&
  grep -qx -- 'plan' "$WORK/agy-args"; then
  fail "translation uses sandboxed edit mode" "plan mode was used"
elif grep -qx -- '--sandbox' "$WORK/agy-args" &&
  grep -qx -- 'accept-edits' "$WORK/agy-args" &&
  ! grep -q -- 'dangerously-skip-permissions' "$WORK/agy-args"; then
  pass "translation uses sandboxed edit mode without permission bypass"
else
  fail "translation uses sandboxed edit mode" "required flags missing"
fi

rm -f "$WORK/agy-args"
if run_hook "$WORK/repo" && [ ! -e "$WORK/agy-args" ]; then
  pass "fresh translations do not spend another model call"
else
  fail "fresh translations do not spend another model call" "agy ran or hook failed"
fi

for mode in unexpected missing bad-hash fail; do
  setup_repo docs
  make_fake_agy
  if run_hook "$WORK/repo" "$mode"; then
    fail "$mode output blocks the commit" "hook returned success"
  elif [ ! -e "$WORK/repo/unexpected.txt" ]; then
    pass "$mode output blocks without copying unvalidated files"
  else
    fail "$mode output stays isolated" "unexpected file reached the real worktree"
  fi
done

setup_repo content
make_fake_agy
if run_hook "$WORK/repo"; then
  content_count=$(git -C "$WORK/repo" diff --cached --name-only |
    awk '$0 ~ /^src\/content\/docs\/(fr|es|de|pt-br|ja|ko|zh-cn|zh-tw|ar|it|hi|th)\/page\.mdx$/ { count++ } END { print count + 0 }')
  if [ "$content_count" -eq 12 ]; then
    pass "src/content/docs/en layout produces 12 locale files"
  else
    fail "src/content/docs/en layout produces 12 locale files" "count=$content_count"
  fi
else
  fail "src/content/docs/en layout is supported" "$(cat "$WORK/output")"
fi

setup_repo docs
source=$(source_path docs)
git -C "$WORK/repo" restore --staged --worktree "$source"
git -C "$WORK/repo" rm -q "$source"
rm -rf "${WORK:?}/bin"
if run_hook "$WORK/repo"; then
  deleted_count=$(git -C "$WORK/repo" diff --cached --name-status |
    awk '$1 == "D" && $2 ~ /^docs\/(fr|es|de|pt-br|ja|ko|zh-cn|zh-tw|ar|it|hi|th)\/page\.mdx$/ { count++ } END { print count + 0 }')
  if [ "$deleted_count" -eq 12 ]; then
    pass "English deletion removes all locale counterparts without agy"
  else
    fail "English deletion removes all locale counterparts" "count=$deleted_count"
  fi
else
  fail "English deletion is deterministic" "$(cat "$WORK/output")"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
