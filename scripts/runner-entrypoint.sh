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

unexpected_path="$(find /runner-runtime -mindepth 1 -maxdepth 1 ! -name _diag -print -quit)"
if [[ ! -d /runner-runtime/_diag || -n "$unexpected_path" ]]; then
  echo "runner runtime tmpfs or diagnostics mount is invalid" >&2
  exit 1
fi
find /opt/actions-runner -mindepth 1 -maxdepth 1 \
  -exec cp --archive --no-preserve=ownership --target-directory=/runner-runtime {} +
install -d -m 0700 /runner-runtime/home
cd /runner-runtime
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
