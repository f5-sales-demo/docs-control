#!/usr/bin/env bash
# Hermetic contract for the inline docs/_imports staging block in the reusable
# Pages workflow. The test executes the exact block, not a reimplementation.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$REPO_ROOT/.github/workflows/github-pages-deploy.yml"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
RUNNER="$TEST_ROOT/stage-imports.sh"

python3 - "$WORKFLOW" "$RUNNER" <<'PY'
import sys

import yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for job in workflow["jobs"].values():
    for step in job.get("steps", []):
        if step.get("name") == "Stage imported files for documentation":
            with open(sys.argv[2], "w", encoding="utf-8") as handle:
                handle.write("#!/usr/bin/env bash\nset -euo pipefail\n")
                handle.write(step["run"])
            raise SystemExit(0)
raise SystemExit("Pages import staging step is missing")
PY
chmod +x "$RUNNER"

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'PASS: %s\n' "$1"
}

assert_file() {
  local expected="$1" actual="$2" label="$3"
  if [ -f "$actual" ] && cmp -s "$expected" "$actual"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_absent() {
  local path="$1" label="$2"
  if [ ! -e "$path" ]; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_rejects() {
  local root="$1" label="$2"
  if (cd "$root" && CONTENT_PATH=docs "$RUNNER") >/dev/null 2>&1; then
    fail "$label"
  else
    pass "$label"
  fi
}

fixture() {
  local root="$1"
  mkdir -p "$root/docs" "$root/legacy" "$root/terraform/modules/one" "$root/source files"
  printf 'legacy\n' >"$root/legacy/flat.txt"
  printf 'root main\n' >"$root/terraform/main.tf"
  printf 'nested main\n' >"$root/terraform/modules/one/main.tf"
  printf 'spaced\n' >"$root/source files/with space.txt"
  printf 'tail\n' >"$root/terraform/tail.tf"
}

valid="$TEST_ROOT/valid"
fixture "$valid"
cat >"$valid/docs/_imports" <<'EOF'
# Existing flat imports keep their basename destination.
legacy/flat.txt

  # Whitespace before comments is ignored.
 terraform/main.tf   ->   terraform/main.tf
terraform/modules/one/main.tf -> terraform/modules/one/main.tf
source files/with space.txt -> nested/with space.txt
missing/not-present.tf -> nested/missing.tf
EOF
printf 'terraform/tail.tf -> terraform/tail.tf' >>"$valid/docs/_imports"
(cd "$valid" && CONTENT_PATH=docs "$RUNNER")
assert_file "$valid/legacy/flat.txt" "$valid/docs/_data/flat.txt" "legacy flat import preserves basename behavior"
assert_file "$valid/terraform/main.tf" "$valid/docs/_data/terraform/main.tf" "explicit root destination is staged"
assert_file "$valid/terraform/modules/one/main.tf" "$valid/docs/_data/terraform/modules/one/main.tf" "nested duplicate basename is staged without collision"
assert_file "$valid/source files/with space.txt" "$valid/docs/_data/nested/with space.txt" "trimmed mapping preserves spaces within paths"
assert_file "$valid/terraform/tail.tf" "$valid/docs/_data/terraform/tail.tf" "final non-newline mapping is processed"
assert_absent "$valid/docs/_data/nested/missing.tf" "missing sources remain skipped"

for case_name in absolute-source traversal-source absolute-destination traversal-destination empty-source empty-destination multiple-delimiters duplicate-destination; do
  root="$TEST_ROOT/$case_name"
  fixture "$root"
  case "$case_name" in
  absolute-source) printf '/etc/hosts -> nested/hosts\n' >"$root/docs/_imports" ;;
  traversal-source) printf '../legacy/flat.txt -> nested/flat.txt\n' >"$root/docs/_imports" ;;
  absolute-destination) printf 'legacy/flat.txt -> /tmp/flat.txt\n' >"$root/docs/_imports" ;;
  traversal-destination) printf 'legacy/flat.txt -> ../flat.txt\n' >"$root/docs/_imports" ;;
  empty-source) printf ' -> nested/flat.txt\n' >"$root/docs/_imports" ;;
  empty-destination) printf 'legacy/flat.txt -> \n' >"$root/docs/_imports" ;;
  multiple-delimiters) printf 'legacy/flat.txt -> nested -> flat.txt\n' >"$root/docs/_imports" ;;
  duplicate-destination) printf 'legacy/flat.txt -> nested/file.txt\nterraform/main.tf -> nested/file.txt\n' >"$root/docs/_imports" ;;
  esac
  assert_rejects "$root" "$case_name is rejected"
done

if [ "$failures" -ne 0 ]; then
  exit 1
fi

printf 'Pages import staging tests passed\n'
