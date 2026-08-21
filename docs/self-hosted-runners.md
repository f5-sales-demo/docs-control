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

The docs-control `automation` profile is a separate socketless runner for its scheduled fleet
watcher. It keeps long-running fleet collection and optional triage from occupying the
general runners that serve pull-request trust and shell-test gates. Docs-control has two
independent socketless profiles advertising the `ubuntu-24.04` scheduling label, so two general
jobs can run concurrently without duplicating the Docker-capable profile. Together its four
runners are capped at 40 GiB of memory and 18 CPUs on the 64 GiB workstation.

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

## Image authority and publication

[`f5-sales-demo/self-hosted-runner`](https://github.com/f5-sales-demo/self-hosted-runner)
is the fleet’s sole runner-image builder and publisher. It publishes the socketless standard and
trust-gated container-build targets to `ghcr.io/f5-sales-demo/self-hosted-runner`, with an SBOM
and provenance supplied by its hosted build workflow. `docs-control` deliberately does not build
or publish runner images.

The policy accepts only immutable `@sha256:` references. Before changing a policy digest, verify
the builder repository’s published digest, provenance, SBOM, and smoke-test evidence; preload that
exact digest into the Ubuntu workstation cache, then run the harmless pilot workflow. Tags are
only discovery aids and are never accepted by the controller.

Before merging a runner release:

1. Confirm the upstream runner version is the latest stable release in the builder repository.
2. Confirm the builder’s image jobs, catalog verification, SBOM, and provenance succeed.
3. Smoke-test `config.sh --ephemeral --disableupdate` and one harmless workflow in the pilot
   repository.
4. Confirm the runner de-registers, the container is gone, and diagnostics remain.
5. Confirm the policy references contain no placeholder or tag.

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

### Capacity guard

`install` enables `f5-actions-runner-capacity.timer`. Every 15 minutes it checks the distinct
filesystems backing `/data/actions-runners` and the host root filesystem. The guard writes exact
free-space metrics to the system journal and fails when either filesystem has less than 50 GiB or
10% free. It never deletes runner workspaces, diagnostics, images, or caches.

Run the check immediately or inspect the latest timer result with:

```bash
sudo python3 scripts/provision-ephemeral-runners.py capacity-check
systemctl status f5-actions-runner-capacity.service
journalctl -u f5-actions-runner-capacity.service --since '1 hour ago'
```

A failed guard is an operational alert: preserve the affected runner diagnostics and active jobs,
then add storage or perform a reviewed, scope-limited cleanup. Do not remove active runner
workspaces as a capacity response.

### Automatic profile dispatch

`install` also enables `f5-actions-runner-profile-dispatch.timer` every minute. It polls queued
GitHub Actions jobs and starts only the repository/profile service whose complete label set matches
the job. This supplies automatic capacity for `ubuntu-24.04`, `automation`, and `container-build`
without treating a Docker-socket runner as general standby capacity.

A `container-build` instance is started only when the same workflow run already contains a
successful `Trust Docker-capable job`. Malformed GitHub API data, unmatched labels, duplicate
labels, and missing trust evidence fail closed: no profile is started. Operators must not use a
manual profile start as evidence that automatic profile capacity is healthy; prove it from the
dispatcher's journal and the automatically claimed job instead.

If a runner or image may be compromised:

1. Disable the affected systemd runner instance without changing other repositories.
2. Revoke the fleet credential and any repository secrets exposed to the job.
3. Preserve the instance's diagnostics and journal before cleanup.
4. Rebuild from newly verified base and runner digests.
5. Replace the policy digest through a reviewed pull request.
6. Re-enable the pilot and repeat one-job acceptance before broader rollout.

## Fleet rollout batches

Prepare and review audit-clean repositories in groups. A group may contain multiple repository
issues, isolated worktrees, PRs, and smoke workflows at once. Each repository keeps its existing
repository-scoped label; do not replace a repository label with an organization-wide runner group.

The workstation fan and ventilation remediation allows approved runner groups to execute
concurrently. Temperature is operational telemetry, not a scheduling throttle. Investigate a
hardware alert or a failed job, but do not serialize a healthy rollout merely because several
approved jobs are running.

For every repository in a rollout group:

1. Run the workflow/catalog audit and resolve floating versions, direct privileged installers, or
   uncatalogued shared tools before onboarding.
2. Create a linked issue and isolated worktree, then add the manual standard-profile smoke workflow.
3. Validate actionlint, YAML syntax, runner-policy routing, diff hygiene, and changed-file PII
   enforcement locally; open a linked PR and enable squash auto-merge.
4. Verify that the automatic profile dispatcher claims the queued job. It routes standard jobs to
   `ubuntu-24.04`, Fleet Watcher jobs to `automation`, and Docker/socket jobs to `container-build`
   only after their same-run trust gate passes. Manual profile starts are break-glass remediation,
   never rollout acceptance evidence.
5. After merge, dispatch the repository's manual smoke workflow, capture its successful run URL,
   stop the exact temporary runner units, and clean the merged branch and worktree.

A successful smoke proves the job-local writable tool cache is seeded from the immutable image,
root and `/opt/hostedtoolcache` remain read-only, `actions/setup-python` resolves the catalogued
Python version without downloading it, and the image-resident `uv` version is available.

## PII scan scope

Normal pull-request and pre-push PII enforcement scans changed files only. Before a commit the
scanner uses the staged index; after a commit it uses the branch delta from its upstream merge base.
This is the default behavior and is the required path for normal development and CI remediation.

Use full-repository `--scope head` only for an explicitly approved repository-sweep exception.
Use `--scope history` only for a separately authorized incident, forensic, or pre-rewrite history
assessment. Neither broad scope replaces changed-file enforcement for the pull request itself.
