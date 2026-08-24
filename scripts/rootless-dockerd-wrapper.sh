#!/bin/sh
set -eu

if [ "${_DOCKERD_ROOTLESS_CHILD:-}" != "1" ]; then
  echo "rootless dockerd wrapper must run inside RootlessKit" >&2
  exit 1
fi

dedicated_socket=/run/f5-actions-runner/container-build/docker.sock
runner_socket=/run/docker.sock

# RootlessKit copy-up makes this replacement private to the daemon mount namespace.
rm -f "$runner_socket"
ln -s "$dedicated_socket" "$runner_socket"
exec /usr/bin/dockerd "$@"
