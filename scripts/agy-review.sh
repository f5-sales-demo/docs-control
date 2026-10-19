#!/usr/bin/env bash
# Two independent flagship High sessions must explicitly approve the stable target.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# The Python supervisor enforces process-group deadlines and exact input receipts.
# Local PII preflight uses run-with-progress.sh --phase pii-preflight.
exec python3 "$script_dir/agy_review.py" "$@"
