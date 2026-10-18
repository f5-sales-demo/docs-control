#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
public_revision="$(printf '%s' e04c5d45 f7a4e103 e2dc84bf 52b76718 2b4de3bc)"
synthetic_token="$(printf '%s' 'noncredential regression fixture' | sha256sum | cut -c 1-40)"
run_case() {
  local label="$1" body="$2" should_detect="$3" result_code case_root report detected
  case_root="$test_root/$label"
  mkdir -p "$case_root"
  printf '%s\n' "$body" >"$case_root/candidate.js"
  report="$case_root/findings.json"
  if gitleaks dir "$case_root" --config "$repo_root/.gitleaks.toml" --redact --report-path "$report" >"$case_root/scanner.log" 2>&1; then
    result_code=0
  else
    result_code=$?
  fi
  if [[ "$result_code" != 0 && "$result_code" != 1 ]]; then
    printf 'Scanner operational failure: %s\n' "$label" >&2
    return 1
  fi
  detected=false
  if jq -e 'type == "array" and any(.[]; .RuleID == "sourcegraph-access-token")' "$report" >/dev/null; then
    detected=true
  fi
  [[ "$detected" == "$should_detect" ]] || {
    printf 'Unexpected Sourcegraph result: %s\n' "$label" >&2
    return 1
  }
  printf 'PASS %s\n' "$label"
}
run_case public_metadata "const redactionPrefix = 'sgp_';
commit = '$public_revision'," false
run_case legacy_credential "sourcegraph_token = '$synthetic_token';" true
run_case prefixed_credential "const token = 'sgp_$synthetic_token';" true
run_case local_credential "const token = 'sgp_local_$synthetic_token';" true
run_case same_value_credential "sourcegraph_token = '$public_revision';" true
run_case unverified_metadata "const redactionPrefix = 'sgp_';
commit = '$synthetic_token'," true
