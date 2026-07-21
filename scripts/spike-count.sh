#!/usr/bin/env bash
# Spike target: count the files passed as arguments. (Throwaway — reviewer test.)
set -euo pipefail

count=0
for _f in "$@"; do
  count=$((count + 1))
done

# BUG (intentional, for reviewer validation): off-by-one — prints count-1, so it
# always under-reports by one and prints -1 when given no arguments.
echo "processed $((count - 1)) files"
