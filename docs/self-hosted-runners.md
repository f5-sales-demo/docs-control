# Self-hosted runner operations

This repository governs the Linux GitHub Actions runner fleet for the 39 repositories in
`self-hosted-runner-policy.json`. The workstation uses repository-scoped registration because
the organization plan does not provide organization-wide runner groups. The other active
organization repositories are inventory-only and are not changed by this system.

## Security model

Every Linux job routes to labels that identify one repository and one isolation profile:

```yaml
runs-on: [self-hosted, Linux, X64, "${{ github.event.repository.name }}", ubuntu-24.04]
```

A controller registers a new runner with `--ephemeral --disableupdate`, launches it in a
Docker container on the shared host Engine, and destroys the container after one job. The
immutable runner distribution is copied into an exact host-visible private workspace for
registration, work, and credentials. Runner
diagnostics persist outside the container under
`/data/actions-runners/f5-sales-demo-ephemeral/diagnostics`; systemd captures controller and
container standard output in the journal.

The default profile has:

- A read-only container root, all capabilities dropped, and `no-new-privileges`.
- A private network namespace with workstation loopback access disabled.
- CPU, memory, process, stop-timeout, and network limits applied directly to the outer Docker
  container.
- No host container socket.

The explicit profile label prevents a default job from matching a more privileged builder.
The `container-build` profile mounts the exact shared `/run/docker.sock`. Docker daemon control is
host-root-equivalent, so the profile is limited to same-repository pull requests and trusted manual
dispatches behind a socketless trust gate. Fork pull requests fail that gate explicitly. The
controller stops the exact labeled outer runner before workspace deletion and removes nested
containers only when every validated bind mount is beneath that runner's exact workspace.

Native macOS, Windows, and ARM64 jobs remain on GitHub-hosted runners only when their exact
workflow and job identifiers appear in the hosted-exception inventory. The audit rejects every
other hosted label, mutable action reference, unapproved profile, and cross-repository route.

## GitHub guidance implemented here

The design follows GitHub's current primary guidance:

- GitHub recommends ephemeral self-hosted runners for autoscaling and states that persistent
  autoscaling is not recommended. An ephemeral runner receives one job and is then
  de-registered: [Self-hosted runners: Ephemeral runners for autoscaling](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#ephemeral-runners-for-autoscaling).
- Ephemeral runner application logs should be preserved outside the runner before production
  deployment. This fleet bind-mounts `_diag` to persistent workstation storage and retains
  systemd journal output: [the same GitHub guidance](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#ephemeral-runners-for-autoscaling).
- A container runner registered with `--disableupdate` must be rebuilt within 30 days of a new
  runner release: [Runner software updates](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#runner-software-updates-on-self-hosted-runners).
- Self-hosted runners can be persistently compromised by untrusted workflow code. Public
  repositories therefore require approval for all external contributors before jobs are sent to
  this fleet: [Secure use: Hardening for self-hosted runners](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners).
- A full commit SHA is the only immutable release reference for an action. Dependabot checks
  GitHub Actions daily and the fleet audit rejects mutable references:
  [Secure use: Pin actions to a full-length commit SHA](https://docs.github.com/en/actions/reference/security/secure-use#using-third-party-actions).
- Docker documents daemon access as privileged host control, which is why socket profiles are
  trust-gated: [Docker Engine security](https://docs.docker.com/engine/security/).
- Engine release and Noble package selection follow Docker's primary documentation:
  [Docker Engine 29 release notes](https://docs.docker.com/engine/release-notes/29/) and
  [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/).

## Image publication

`publish-runner-images.yml` builds Ubuntu 24.04, Ubuntu 22.04, and container-build images from
digest-pinned Ubuntu bases. Every image includes PyYAML. Socketless targets omit Docker completely;
the builder target copies the Docker 29.7.2 CLI, Buildx, and Compose from the digest-pinned official
Docker CLI image. Publication uses `docker buildx build --push --metadata-file`, validates the
registry manifest digest, and smoke-tests each published target before reporting its digest.
It verifies the GitHub runner archive checksum and publishes to GHCR.
Record the manifest digest reported in the job summary and place that exact digest in the policy.
Tags are discovery aids only and are never accepted by the controller.

Before merging a runner release:

1. Confirm the upstream runner version is the latest stable release.
2. Confirm every image job succeeds.
3. Smoke-test `config.sh --ephemeral --disableupdate` and one harmless workflow in the pilot
   repository.
4. Confirm the runner de-registers, the container is gone, and diagnostics remain.
5. Confirm the image references in policy contain no placeholder or tag.

## Provision and pilot

Run these commands on the Ubuntu workstation from a clean `docs-control` checkout:

```bash
sudo systemctl stop "f5-actions-runner@$(systemd-escape 'docs-control--container-build--0').service"
sudo python3 scripts/provision-ephemeral-runners.py install
printf '%s\n' '<RUNNER_FLEET_GITHUB_TOKEN>' |
  sudo python3 scripts/provision-ephemeral-runners.py install-credential
sudo python3 scripts/provision-ephemeral-runners.py enable \
  f5-sales-demo/docs-control --profile ubuntu-24.04
python3 scripts/provision-ephemeral-runners.py audit f5-sales-demo/docs-control
```

The credential is read only from standard input, stored root-only, and never passed in a process
argument. Use the narrowest token that can create repository runner registration tokens and pull
the private runner packages. Prefer a GitHub App installation token when that credential path is
available.

Podman is not part of the runner fleet. Runner services are Docker-backed ephemeral instances only.

## Docker Engine maintenance

Schema v3 accepts Docker Engine 29.2.1 as the migration canary and records 29.7.2 as the target.
Before the Engine change, capture exact container/image/mount/network/port/restart-policy,
package-version, daemon-configuration, storage-driver, and runner-unit inventories. Cache the exact
29.2.1 packages, quiesce runner units, and stop only the previously recorded running container set.
Install exact Noble packages for Docker CE, CLI, containerd, Buildx, and Compose from Docker's
official stable repository. Preserve `/data/docker`, `overlay2`, logging/GC settings, and NVIDIA
runtime configuration, and enable `live-restore`.

Afterward, verify Engine 29.7.2, socket ownership and mode, storage integrity, networks, Buildx,
Compose, and the exact prior workload set before rerunning default-runner, nested-Docker,
Super-Linter, image-build, cleanup, and registration canaries. If validation fails, stop the daemon,
restore the captured configuration and cached 29.2.1 packages, restart the exact prior workload set,
and audit final state.

## Audits and incident response

Run the local policy checks with:

```bash
python3 scripts/audit-runner-workflows.py \
  --repository f5-sales-demo/docs-control --root .
python3 scripts/ephemeral-runner-controller.py audit
sudo python3 scripts/provision-ephemeral-runners.py audit
```

If a runner or image may be compromised:

1. Disable the affected systemd runner instance without changing other repositories.
2. Revoke the fleet credential and any repository secrets exposed to the job.
3. Preserve the instance's diagnostics and journal before cleanup.
4. Rebuild from newly verified base and runner digests.
5. Replace the policy digest through a reviewed pull request.
6. Re-enable the pilot and repeat one-job acceptance before broader rollout.
