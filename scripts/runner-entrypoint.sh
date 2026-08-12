#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_REPOSITORY:?RUNNER_REPOSITORY is required}"
: "${RUNNER_NAME:?RUNNER_NAME is required}"
: "${RUNNER_LABELS:?RUNNER_LABELS is required}"

IFS= read -r registration_token
if [[ -z "$registration_token" ]]; then
  echo "runner registration token was not supplied on standard input" >&2
  exit 1
fi

cd /runner
./config.sh \
  --url "https://github.com/${RUNNER_REPOSITORY}" \
  --token "$registration_token" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work _work \
  --ephemeral \
  --disableupdate \
  --unattended \
  --replace

registration_token=
unset registration_token RUNNER_REPOSITORY RUNNER_NAME RUNNER_LABELS
exec ./run.sh
