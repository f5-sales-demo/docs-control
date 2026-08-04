#!/usr/bin/env bash
# Hermetic coverage for deterministic translation output validation.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/validate-translations.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PASS=0
FAIL=0
LOCALES=(fr es de pt-br ja ko zh-cn zh-tw ar it hi th)

pass() {
  printf '  PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf '  FAIL: %s — %s\n' "$1" "$2"
  FAIL=$((FAIL + 1))
}

source_hash() {
  python3 - "$1" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()[:12])
PY
}

write_target() {
  local repo=$1 locale=$2 hash=$3 code=${4:-'echo safe'}
  mkdir -p "$repo/docs/$locale"
  printf '%s\n' \
    '---' \
    "title: Page $locale" \
    'i18n:' \
    "  sourceHash: \"$hash\"" \
    '  translator: "machine"' \
    '---' \
    '' \
    'Texte `literal` https://example.com/docs.' \
    '' \
    '```sh' \
    "$code" \
    '```' >"$repo/docs/$locale/page.mdx"
}

make_repo() {
  local repo="$WORK/repo"
  rm -rf -- "$repo"
  mkdir -p "$repo/docs/en"
  git -C "$WORK" init -q repo
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf '%s\n' \
    '---' \
    'title: Page' \
    '---' \
    '' \
    'Text `literal` https://example.com/docs.' \
    '' \
    '```sh' \
    'echo safe' \
    '```' >"$repo/docs/en/page.mdx"
  local hash
  hash=$(source_hash "$repo/docs/en/page.mdx")
  for locale in "${LOCALES[@]}"; do
    write_target "$repo" "$locale" "$hash"
  done
  git -C "$repo" add .
  git -C "$repo" commit -qm base
  printf '%s\n' "$repo"
}

echo "Deterministic translation validator tests"

repo=$(make_repo)
printf '\nEnglish update.\n' >>"$repo/docs/en/page.mdx"
git -C "$repo" add docs/en/page.mdx
if (cd "$repo" && bash "$SCRIPT" --staged); then
  pass "English-only staged changes can reach automation"
else
  fail "English-only staged changes can reach automation" "validator blocked source-only commit"
fi

repo=$(make_repo)
printf '\nEnglish update.\n' >>"$repo/docs/en/page.mdx"
hash=$(source_hash "$repo/docs/en/page.mdx")
write_target "$repo" fr "$hash"
git -C "$repo" add docs/en/page.mdx docs/fr/page.mdx
if (cd "$repo" && bash "$SCRIPT" --staged); then
  pass "fresh staged locale output passes"
else
  fail "fresh staged locale output passes" "validator rejected matching sourceHash"
fi

repo=$(make_repo)
sed -i.bak 's/sourceHash: "[0-9a-f]*"/sourceHash: "000000000000"/' "$repo/docs/fr/page.mdx"
rm -f "$repo/docs/fr/page.mdx.bak"
git -C "$repo" add docs/fr/page.mdx
if (cd "$repo" && bash "$SCRIPT" --staged >/dev/null 2>&1); then
  fail "stale staged locale output fails" "validator returned success"
else
  pass "stale staged locale output fails"
fi

repo=$(make_repo)
base=$(git -C "$repo" rev-parse HEAD)
printf '\nEnglish update.\n' >>"$repo/docs/en/page.mdx"
git -C "$repo" add docs/en/page.mdx
git -C "$repo" commit -qm source
head=$(git -C "$repo" rev-parse HEAD)
hash=$(source_hash "$repo/docs/en/page.mdx")
for locale in "${LOCALES[@]}"; do
  write_target "$repo" "$locale" "$hash"
done
if (cd "$repo" && bash "$SCRIPT" --base "$base" --head "$head"); then
  pass "complete exact-range output passes"
else
  fail "complete exact-range output passes" "validator rejected all 12 fresh targets"
fi

printf 'unrelated workspace state\n' >"$repo/notes.txt"
if (cd "$repo" && bash "$SCRIPT" --base "$base" --head "$head"); then
  pass "unrelated non-translation workspace files do not poison range validation"
else
  fail "unrelated non-translation workspace files do not poison range validation" \
    "validator treated non-translation workspace state as model output"
fi
rm -f "$repo/notes.txt"

rm -f "$repo/docs/th/page.mdx"
if (cd "$repo" && bash "$SCRIPT" --base "$base" --head "$head" >/dev/null 2>&1); then
  fail "missing exact-range locale fails" "validator returned success"
else
  pass "missing exact-range locale fails"
fi
write_target "$repo" th "$hash"

printf 'out of scope\n' >"$repo/docs/fr/unrelated.mdx"
if (cd "$repo" && bash "$SCRIPT" --base "$base" --head "$head" >/dev/null 2>&1); then
  fail "unrelated model output fails" "validator returned success"
else
  pass "unrelated model output fails"
fi
git -C "$repo" add docs/fr/unrelated.mdx
git -C "$repo" commit -qm out-of-scope
committed_head=$(git -C "$repo" rev-parse HEAD)
if (cd "$repo" && bash "$SCRIPT" --base "$base" --head "$committed_head" >/dev/null 2>&1); then
  fail "committed out-of-scope locale output fails" "validator returned success"
else
  pass "committed out-of-scope locale output fails"
fi
git -C "$repo" rm -q docs/fr/unrelated.mdx
git -C "$repo" commit -qm remove-out-of-scope
head=$(git -C "$repo" rev-parse HEAD)

write_target "$repo" fr "$hash" 'echo changed'
if (cd "$repo" && bash "$SCRIPT" --base "$base" --head "$head" >/dev/null 2>&1); then
  fail "translated fenced code fails" "validator returned success"
else
  pass "translated fenced code fails"
fi

repo=$(make_repo)
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" rm -q docs/en/page.mdx
git -C "$repo" commit -qm delete
head=$(git -C "$repo" rev-parse HEAD)
for locale in "${LOCALES[@]}"; do
  rm -f "$repo/docs/$locale/page.mdx"
done
if (cd "$repo" && bash "$SCRIPT" --base "$base" --head "$head"); then
  pass "source deletion requires all locale counterparts deleted"
else
  fail "source deletion requires all locale counterparts deleted" "validator rejected complete deletion"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
