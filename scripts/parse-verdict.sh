#!/usr/bin/env bash
# Reads a Claude structured verdict JSON and fails on blocking findings.
# Usage: parse-verdict.sh <verdict.json>  (defaults to verdict.json)
set -euo pipefail
f="${1:-verdict.json}"
if [[ ! -s "$f" ]]; then
  echo "::error::verdict file '$f' missing or empty — treating as blocking"
  exit 1
fi
blocking=$(jq -r '.blocking // false' "$f")
high=$(jq -r '.severity_counts.high // 0' "$f")
# Also count high-severity entries recorded only in findings[] (a verdict could
# list a high finding without setting severity_counts.high — block on it too).
high_findings=$(jq '[.findings[]? | select(.severity=="high")] | length' "$f")
echo "verdict: blocking=$blocking high=$high high_findings=$high_findings"
jq -r '.findings[]? | "- [\(.severity)] \(.title) (\(.location // "n/a"))"' "$f" || true
if [[ "$blocking" == "true" || "$high" -gt 0 || "$high_findings" -gt 0 ]]; then
  echo "::error::Claude Review found blocking (🔴) finding(s) — failing check."
  exit 1
fi
echo "Claude Review: no blocking findings."
