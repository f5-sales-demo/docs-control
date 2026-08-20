#!/usr/bin/env python3
# pylint: disable=global-statement,invalid-name
"""Provision and audit repository-scoped ephemeral runner systemd services."""

from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

INSTALL_ROOT = Path("/opt/f5-actions-runner")
PROVISIONER_SOURCE = Path(__file__).resolve()


def source_paths(provisioner):
    """Return controller assets for either source or installed execution."""
    provisioner = Path(provisioner).resolve()
    if provisioner.parent == INSTALL_ROOT:
        return (
            INSTALL_ROOT,
            INSTALL_ROOT / "ephemeral-runner-controller.py",
            INSTALL_ROOT / "runner-entrypoint.sh",
            INSTALL_ROOT / "self-hosted-runner-policy.json",
        )
    source_root = provisioner.parent.parent
    return (
        source_root,
        source_root / "scripts/ephemeral-runner-controller.py",
        source_root / "scripts/runner-entrypoint.sh",
        source_root / ".github/config/self-hosted-runner-policy.json",
    )


SOURCE_ROOT, CONTROLLER_SOURCE, ENTRYPOINT_SOURCE, POLICY_SOURCE = source_paths(
    PROVISIONER_SOURCE
)
CONFIG_ROOT = Path("/etc/f5-actions-runner")
INSTANCE_ROOT = CONFIG_ROOT / "instances"
SYSTEMD_ROOT = Path("/etc/systemd/system")
DATA_ROOT = Path("/data/actions-runners")
STATE_ROOT = DATA_ROOT / "f5-sales-demo-ephemeral"
TOKEN_PATH = CONFIG_ROOT / "github.token"
RUNNER_UNIT = "f5-actions-runner@.service"
CAPACITY_UNIT = "f5-actions-runner-capacity.service"
CAPACITY_TIMER = "f5-actions-runner-capacity.timer"
STANDBY_UNIT = "f5-actions-runner-standby.service"
STANDBY_TIMER = "f5-actions-runner-standby.timer"
CAPACITY_MIN_FREE_BYTES = 50 * 1024 * 1024 * 1024
CAPACITY_MIN_FREE_PERCENT = 10


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
    mode: str

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
                        "serve",
                    )
                )
    return tuple(result)


def standby_instances(policy=None):
    policy = active_policy() if policy is None else policy
    result = []
    for repository in policy.governed():
        spec = policy.repository(repository)
        for profile in spec.standby_profiles:
            result.append(
                Instance(
                    repository,
                    spec.name,
                    profile.name,
                    spec.replicas,
                    profile.docker_socket,
                    profile.memory,
                    profile.cpus,
                    profile.pids_limit,
                    profile.stop_timeout,
                    profile.network,
                    "once",
                )
            )
    return tuple(result)


def all_standby_instances():
    return standby_instances(active_policy())


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
ExecStart=/usr/bin/python3 {INSTALL_ROOT}/ephemeral-runner-controller.py --policy {INSTALL_ROOT}/self-hosted-runner-policy.json --base-dir {STATE_ROOT} ${{RUNNER_MODE}} ${{RUNNER_REPOSITORY}} --profile ${{RUNNER_PROFILE}} --slot ${{RUNNER_SLOT}}
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


def capacity_paths():
    """Return distinct host filesystems that hold runner state or containers."""
    paths = []
    devices = set()
    for path in (Path("/"), DATA_ROOT):
        try:
            device = path.stat().st_dev
        except OSError as exc:
            raise ProvisionError(
                f"cannot inspect runner capacity path {path}: {exc}"
            ) from exc
        if device not in devices:
            devices.add(device)
            paths.append(path)
    return tuple(paths)


def capacity_unit_text():
    return f"""[Unit]
Description=F5 Actions runner capacity guard
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot

ExecStart=/usr/bin/python3 {INSTALL_ROOT}/provision-ephemeral-runners.py capacity-check
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
"""


def capacity_timer_text():
    return f"""[Unit]
Description=Schedule F5 Actions runner capacity guard

[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
Persistent=true
Unit={CAPACITY_UNIT}

[Install]
WantedBy=timers.target
"""


def standby_scaler_unit_text():
    return f"""[Unit]
Description=F5 Actions runner standby scaler
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=RUNNER_FLEET_GITHUB_TOKEN_FILE={TOKEN_PATH}
ExecStartPre=/usr/bin/test -r {TOKEN_PATH}
ExecStart=/usr/bin/python3 {INSTALL_ROOT}/provision-ephemeral-runners.py standby-scale
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

"""


def standby_scaler_timer_text():
    return f"""[Unit]
Description=Schedule F5 Actions runner standby scaler

[Timer]
OnBootSec=1min
OnUnitActiveSec=60s
Persistent=true
Unit={STANDBY_UNIT}

[Install]
WantedBy=timers.target
"""


def capacity_check():
    """Emit a systemd-visible alert before runner storage reaches exhaustion."""
    failed = False
    for path in capacity_paths():
        usage = shutil.disk_usage(path)
        free_percent = usage.free * 100 / usage.total
        healthy = (
            usage.free >= CAPACITY_MIN_FREE_BYTES
            and free_percent >= CAPACITY_MIN_FREE_PERCENT
        )
        marker = "OK" if healthy else "ERROR"
        print(
            f"[{marker}] runner capacity path={path} free_bytes={usage.free} "
            f"free_percent={free_percent:.1f} minimum_bytes={CAPACITY_MIN_FREE_BYTES} "
            f"minimum_percent={CAPACITY_MIN_FREE_PERCENT}"
        )
        failed |= not healthy
    return 1 if failed else 0


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
    for source in (PROVISIONER_SOURCE, CONTROLLER_SOURCE, ENTRYPOINT_SOURCE):
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
    safe_write(SYSTEMD_ROOT / CAPACITY_UNIT, capacity_unit_text())
    safe_write(SYSTEMD_ROOT / CAPACITY_TIMER, capacity_timer_text())
    safe_write(SYSTEMD_ROOT / STANDBY_UNIT, standby_scaler_unit_text())
    safe_write(SYSTEMD_ROOT / STANDBY_TIMER, standby_scaler_timer_text())
    for item in (*instances(policy), *standby_instances(policy)):
        safe_write(
            INSTANCE_ROOT / f"{item.identifier}.env",
            f"RUNNER_REPOSITORY={item.repository}\nRUNNER_PROFILE={item.profile}\nRUNNER_SLOT={item.slot}\nRUNNER_MODE={item.mode}\n",
            0o600,
        )
    command(["systemctl", "daemon-reload"])
    command(["systemctl", "enable", "--now", STANDBY_TIMER])
    command(["systemctl", "enable", "--now", CAPACITY_TIMER])


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


def standby_scale():
    """Start an inactive one-job standby only after warm capacity is busy."""
    require_root()
    controller_module = load_controller()
    policy = active_policy()
    standby = standby_instances(policy)
    github = controller_module.GitHubClient(controller_module.token_from_environment())
    inventories = {
        repository: github.runners(repository) for repository in policy.governed()
    }
    for item in standby:
        spec = policy.repository(item.repository)
        warm_prefixes = tuple(
            f"gha-{spec.name}-{item.profile}-{slot}-" for slot in range(spec.replicas)
        )
        warm_busy = any(
            isinstance(record.get("name"), str)
            and record["name"].startswith(warm_prefixes)
            and record.get("busy") is True
            for record in inventories[item.repository]
        )
        state = command(
            ["systemctl", "is-active", item.unit], check=False, capture=True
        )
        active = state.returncode == 0 and state.stdout.strip() == "active"
        if warm_busy and not active:
            command(["systemctl", "start", item.unit])


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
    return errors


def audit(repository=None):
    capacity_failed = capacity_check() != 0
    selected = select(repository) if repository else list(all_instances())
    host_errors = docker_host_errors(active_policy())
    for error in host_errors:
        print(f"[ERROR] {error}")
    failed = capacity_failed or bool(host_errors)
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
    subparsers.add_parser("capacity-check")
    enable_parser = subparsers.add_parser("enable")
    enable_parser.add_argument("repository")
    enable_parser.add_argument("--profile")
    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("repository", nargs="?")
    subparsers.add_parser("standby-scale")
    args = parser.parse_args(argv)
    try:
        if args.action == "plan":
            plan()
        elif args.action == "install":
            install_definition()
        elif args.action == "install-credential":
            install_credential()
        elif args.action == "capacity-check":
            return capacity_check()
        elif args.action == "enable":
            enable(args.repository, args.profile)
        elif args.action == "standby-scale":
            standby_scale()
        else:
            return audit(args.repository)
        return 0
    except (
        ProvisionError,
        RuntimeError,
        OSError,
        subprocess.SubprocessError,
        ValueError,
    ) as exc:
        print(f"runner provisioning failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
