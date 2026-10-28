#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
node --test "$root/tests/scanner-lifecycle.test.cjs"
