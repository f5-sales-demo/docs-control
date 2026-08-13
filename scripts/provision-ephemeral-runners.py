#!/usr/bin/env python3
# pylint: disable=global-statement,invalid-name
"""Provision and audit repository-scoped ephemeral runner systemd services."""

from __future__ import annotations

import argparse
import errno
import importlib.util
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parent.parent
CONTROLLER_SOURCE = SOURCE_ROOT / "scripts/ephemeral-runner-controller.py"
ENTRYPOINT_SOURCE = SOURCE_ROOT / "scripts/runner-entrypoint.sh"
POLICY_SOURCE = SOURCE_ROOT / ".github/config/self-hosted-runner-policy.json"
INSTALL_ROOT = Path("/opt/f5-actions-runner")
CONFIG_ROOT = Path("/etc/f5-actions-runner")
INSTANCE_ROOT = CONFIG_ROOT / "instances"
SYSTEMD_ROOT = Path("/etc/systemd/system")
DATA_ROOT = Path("/data/actions-runners")
STATE_ROOT = DATA_ROOT / "f5-sales-demo-ephemeral"
TOKEN_PATH = CONFIG_ROOT / "github.token"
RUNNER_UNIT = "f5-actions-runner@.service"
LEGACY_UNIT_RE = re.compile(r"f5-actions-podman-([A-Za-z0-9_.-]+)\.service")


class ProvisionError(RuntimeError):
    """Fail-closed provisioning error."""


def command(argv, *, check=True, capture=False):
    return subprocess.run(
        argv,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def load_controller():
    spec = importlib.util.spec_from_file_location(
        "runner_controller", CONTROLLER_SOURCE
    )
    if spec is None or spec.loader is None:
        raise ProvisionError("cannot load ephemeral runner controller")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@dataclass(frozen=True)
class Instance:
    repository: str
    repository_name: str
    profile: str
    slot: int
    docker_socket: bool
    memory: str
    cpus: str
    pids_limit: int
    stop_timeout: int
    network: str

    @property
    def identifier(self):
        return f"{self.repository_name}--{self.profile}--{self.slot}"

    @property
    def unit(self):
        return f"f5-actions-runner@{self.identifier}.service"


def instances(policy):
    result = []
    for repository in policy.governed():
        spec = policy.repository(repository)
        for profile in spec.profiles:
            for slot in range(spec.replicas):
                result.append(
                    Instance(
                        repository,
                        spec.name,
                        profile.name,
                        slot,
                        profile.docker_socket,
                        profile.memory,
                        profile.cpus,
                        profile.pids_limit,
                        profile.stop_timeout,
                        profile.network,
                    )
                )
    return tuple(result)


def require_root():
    if os.geteuid() != 0:
        raise ProvisionError("provisioning mutations require root")


def safe_write(path, content, mode=0o644):
    path = Path(path)
    if path.is_symlink():
        raise ProvisionError(f"refusing symlink destination: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, mode)
    try:
        os.write(descriptor, content.encode())
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def all_instances():
    return instances(active_policy())


_POLICY = None


def active_policy():
    global _POLICY
    if _POLICY is None:
        _POLICY = load_controller().FleetPolicy(POLICY_SOURCE)
    return _POLICY


def remove_legacy_resource_dropin(item):
    """Remove the exact rootless-Podman-era drop-in for a managed runner unit."""
    directory = SYSTEMD_ROOT / f"{item.unit}.d"
    path = directory / "resources.conf"
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ProvisionError(f"refusing unsafe legacy runner drop-in: {path}")
    if path.exists():
        path.unlink()
    try:
        directory.rmdir()
    except FileNotFoundError:
        pass
    except OSError as exc:
        if exc.errno != errno.ENOTEMPTY:
            raise


def runner_unit_text():
    return f"""[Unit]
Description=Ephemeral GitHub Actions runner (%i)
After=network-online.target
After=docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Environment=RUNNER_FLEET_GITHUB_TOKEN_FILE={TOKEN_PATH}
EnvironmentFile={INSTANCE_ROOT}/%i.env
ExecStartPre=/usr/bin/test -r {TOKEN_PATH}
ExecStart=/usr/bin/python3 {INSTALL_ROOT}/ephemeral-runner-controller.py --policy {INSTALL_ROOT}/self-hosted-runner-policy.json --base-dir {STATE_ROOT} serve ${{RUNNER_REPOSITORY}} --profile ${{RUNNER_PROFILE}} --slot ${{RUNNER_SLOT}}
Restart=on-failure
RestartSec=5
TimeoutStopSec=6min
KillMode=mixed
UMask=0077
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths={DATA_ROOT} /run/docker.sock

[Install]
WantedBy=multi-user.target
"""


def install_definition():
    require_root()
    policy = active_policy()
    for path in (
        DATA_ROOT,
        STATE_ROOT,
        CONFIG_ROOT,
        INSTANCE_ROOT,
        INSTALL_ROOT,
    ):
        path.mkdir(parents=True, exist_ok=True)
    for source in (CONTROLLER_SOURCE, ENTRYPOINT_SOURCE):
        command(
            [
                "install",
                "-o",
                "root",
                "-g",
                "root",
                "-m",
                "0755",
                str(source),
                str(INSTALL_ROOT / source.name),
            ]
        )
    command(
        [
            "install",
            "-o",
            "root",
            "-g",
            "root",
            "-m",
            "0644",
            str(POLICY_SOURCE),
            str(INSTALL_ROOT / POLICY_SOURCE.name),
        ]
    )
    safe_write(SYSTEMD_ROOT / RUNNER_UNIT, runner_unit_text())
    for item in instances(policy):
        remove_legacy_resource_dropin(item)
        safe_write(
            INSTANCE_ROOT / f"{item.identifier}.env",
            f"RUNNER_REPOSITORY={item.repository}\nRUNNER_PROFILE={item.profile}\nRUNNER_SLOT={item.slot}\n",
            0o600,
        )
    command(["systemctl", "daemon-reload"])


def install_credential():
    require_root()
    token = sys.stdin.readline().strip()
    if len(token) < 20 or any(character.isspace() for character in token):
        raise ProvisionError("credential on standard input is empty or malformed")
    safe_write(TOKEN_PATH, token + "\n", 0o600)
    token = ""


def select(repository, profile=None):
    wanted = [
        item
        for item in all_instances()
        if item.repository == repository
        and (profile is None or item.profile == profile)
    ]
    if not wanted:
        raise ProvisionError("repository/profile is not governed")
    return wanted


def enable(repository, profile=None):
    require_root()
    if not TOKEN_PATH.is_file():
        raise ProvisionError(f"credential is not installed at {TOKEN_PATH}")
    command(["systemctl", "start", "docker.service"])
    for item in select(repository, profile):
        command(["systemctl", "enable", "--now", item.unit])


def retire_legacy_podman_units():
    """Remove only inactive runner-owned Podman API unit definitions."""
    require_root()
    governed = {item.repository_name for item in all_instances()}
    for path in sorted(SYSTEMD_ROOT.glob("f5-actions-podman-*.service")):
        match = LEGACY_UNIT_RE.fullmatch(path.name)
        if match is None or match.group(1) not in governed or path.is_symlink():
            raise ProvisionError(f"refusing unknown legacy runner unit: {path.name}")
        repository_name = match.group(1)
        related = [
            item
            for item in all_instances()
            if item.repository_name == repository_name and item.docker_socket
        ]
        for item in related:
            state = command(
                ["systemctl", "is-active", item.unit], check=False, capture=True
            )
            if state.returncode == 0 or state.stdout.strip() == "active":
                raise ProvisionError(
                    f"runner must be inactive before retiring {path.name}: {item.unit}"
                )
        command(["systemctl", "disable", "--now", path.name])
        path.unlink()
    command(["systemctl", "daemon-reload"])


def docker_host_errors(policy):
    errors = []
    service = command(
        ["systemctl", "is-active", "docker.service"], check=False, capture=True
    )
    if service.returncode != 0 or service.stdout.strip() != "active":
        errors.append("docker.service is not active")
    try:
        metadata = Path(policy.docker.socket).stat(follow_symlinks=False)
        if not stat.S_ISSOCK(metadata.st_mode):
            errors.append(f"Docker socket is not a socket: {policy.docker.socket}")
        if metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) != 0o660:
            errors.append("Docker socket must be root-owned with mode 0660")
    except OSError as exc:
        errors.append(f"cannot inspect Docker socket: {exc}")
    version = command(
        ["docker", "version", "--format", "{{.Server.Version}}"],
        check=False,
        capture=True,
    )
    if version.returncode != 0:
        errors.append("cannot query Docker Engine version")
    else:
        try:
            actual = load_controller().version_tuple(version.stdout.strip())
            minimum = load_controller().version_tuple(policy.docker.minimum_version)
            if actual < minimum:
                errors.append(
                    f"Docker Engine {version.stdout.strip()} is below {policy.docker.minimum_version}"
                )
        except (RuntimeError, ValueError) as exc:
            errors.append(str(exc))
    stale = sorted(
        path.name for path in SYSTEMD_ROOT.glob("f5-actions-podman-*.service")
    )
    if stale:
        errors.append(f"stale runner Podman units: {stale}")
    return errors


def audit(repository=None):
    selected = select(repository) if repository else list(all_instances())
    host_errors = docker_host_errors(active_policy())
    for error in host_errors:
        print(f"[ERROR] {error}")
    failed = bool(host_errors)
    controller_module = load_controller()
    controller = controller_module.EphemeralController(active_policy(), None)
    for full_name in sorted({item.repository for item in selected}):
        for error in controller.audit_containers(full_name):
            print(f"[ERROR] {full_name}: {error}")
            failed = True
    for item in selected:
        env_file = INSTANCE_ROOT / f"{item.identifier}.env"
        unit_result = command(
            ["systemctl", "is-active", item.unit], check=False, capture=True
        )
        state = unit_result.stdout.strip() or "inactive"
        definition_ok = env_file.is_file()
        marker = "OK" if definition_ok else "ERROR"
        print(
            f"[{marker}] {item.unit} definition={'ready' if definition_ok else 'missing'} state={state}"
        )
        failed |= not definition_ok
    return 1 if failed else 0


def plan():
    for item in all_instances():
        socket = " docker-socket" if item.docker_socket else " socketless"
        print(f"{item.unit}\t{socket}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("plan")
    subparsers.add_parser("install")
    subparsers.add_parser("install-credential")
    subparsers.add_parser("retire-legacy-podman-units")
    enable_parser = subparsers.add_parser("enable")
    enable_parser.add_argument("repository")
    enable_parser.add_argument("--profile")
    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("repository", nargs="?")
    args = parser.parse_args(argv)
    try:
        if args.action == "plan":
            plan()
        elif args.action == "install":
            install_definition()
        elif args.action == "install-credential":
            install_credential()
        elif args.action == "retire-legacy-podman-units":
            retire_legacy_podman_units()
        elif args.action == "enable":
            enable(args.repository, args.profile)
        else:
            return audit(args.repository)
        return 0
    except (ProvisionError, OSError, subprocess.SubprocessError, ValueError) as exc:
        print(f"runner provisioning failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
