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
rootless Podman container, and destroys the container after one job. The immutable runner
distribution is copied into a private tmpfs for registration, work, and credentials. Runner
diagnostics persist outside the container under
`/data/actions-runners/f5-sales-demo-ephemeral/diagnostics`; systemd captures controller and
container standard output in the journal.

The default profile has:

- A read-only container root, all capabilities dropped, and `no-new-privileges`.
- A private network namespace with workstation loopback access disabled.
- CPU, memory, and process limits enforced by the per-instance systemd cgroup.
- A dedicated Unix account and rootless Podman storage for each repository.
- No host container socket.

The explicit profile label prevents a default job from matching a more privileged builder.
The `container-build` profile uses a second account with a repository-specific rootless Podman
API socket. It cannot reach another repository's images or containers. A build job can control
its own builder account, so only workflows that require container builds receive this profile.

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

## Image publication

`publish-runner-images.yml` builds Ubuntu 24.04, Ubuntu 22.04, and container-build images from
digest-pinned Ubuntu bases. It verifies the GitHub runner archive checksum and publishes to GHCR.
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

Do not stop a persistent legacy runner during the pilot. First verify that the new runner is
online with only the canonical repository and profile labels, dispatch a harmless job, and
validate one-job de-registration. Cut over one repository at a time. Stop and remove a legacy
runner only after its replacement has completed the repository's required workflows and no job is
running.

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

The legacy `manage-github-runners.py` remains only for evidence-based management and retirement
of the first-generation persistent runners. New runner creation uses the ephemeral controller and
provisioner.
