#!/usr/bin/env python3
"""Provision and audit repository-scoped ephemeral runner systemd services."""

from __future__ import annotations

import argparse
import importlib.util
import os
import pwd
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parent.parent
CONTROLLER_SOURCE = SOURCE_ROOT / "scripts/ephemeral-runner-controller.py"
POLICY_SOURCE = SOURCE_ROOT / ".github/config/self-hosted-runner-policy.json"
INSTALL_ROOT = Path("/opt/f5-actions-runner")
CONFIG_ROOT = Path("/etc/f5-actions-runner")
INSTANCE_ROOT = CONFIG_ROOT / "instances"
SYSTEMD_ROOT = Path("/etc/systemd/system")
DATA_ROOT = Path("/data/actions-runners")
USER_ROOT = DATA_ROOT / "users"
STATE_ROOT = DATA_ROOT / "f5-sales-demo-ephemeral"
TOKEN_PATH = CONFIG_ROOT / "github.token"
RUNNER_UNIT = "f5-actions-runner@.service"
ACCOUNT_RE = re.compile(r"gh[ab]-[A-Za-z0-9_.-]+")


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
    account: str
    container_socket: bool

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
                        spec.account_for(profile),
                        profile.container_socket,
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


def subid_accounts(path):
    result = set()
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return result
    for line in lines:
        fields = line.split(":")
        if len(fields) == 3:
            result.add(fields[0])
    return result


def all_instances():
    return instances(active_policy())


def all_accounts():
    return {item.account for item in all_instances()}


def ensure_account(account):
    if not ACCOUNT_RE.fullmatch(account) or len(account) > 31:
        raise ProvisionError(f"unsafe runner account: {account!r}")
    home = USER_ROOT / account
    try:
        record = pwd.getpwnam(account)
    except KeyError:
        command(
            [
                "useradd",
                "--create-home",
                "--home-dir",
                str(home),
                "--shell",
                "/usr/sbin/nologin",
                "--user-group",
                account,
            ]
        )
        record = pwd.getpwnam(account)
    if Path(record.pw_dir) != home or record.pw_shell != "/usr/sbin/nologin":
        raise ProvisionError(f"existing account has unexpected identity: {account}")
    present = subid_accounts("/etc/subuid") & subid_accounts("/etc/subgid")
    if account not in present:
        offset = 1_000_000 + sorted(all_accounts()).index(account) * 65_536
        end = offset + 65_535
        command(["usermod", "--add-subuids", f"{offset}-{end}", account])
        command(["usermod", "--add-subgids", f"{offset}-{end}", account])
    command(["install", "-d", "-m", "0700", "-o", account, "-g", account, str(home)])


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
Wants=network-online.target

[Service]
Type=simple
Environment=RUNNER_FLEET_GITHUB_TOKEN_FILE={TOKEN_PATH}
EnvironmentFile={INSTANCE_ROOT}/%i.env
ExecStartPre=/usr/bin/test -r {TOKEN_PATH}
ExecStart=/usr/bin/python3 {INSTALL_ROOT}/ephemeral-runner-controller.py --policy {INSTALL_ROOT}/self-hosted-runner-policy.json --base-dir {STATE_ROOT} serve ${{RUNNER_REPOSITORY}} --profile ${{RUNNER_PROFILE}} --slot ${{RUNNER_SLOT}}
Restart=always
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
ReadWritePaths={DATA_ROOT} /run/f5-actions-podman

[Install]
WantedBy=multi-user.target
"""


def podman_unit_text(item):
    home = USER_ROOT / item.account
    socket_dir = f"/run/f5-actions-podman/{item.repository_name}"
    return f"""[Unit]
Description=Rootless Podman API for {item.repository}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={item.account}
Group={item.account}
Environment=HOME={home}
Environment=XDG_RUNTIME_DIR={socket_dir}
RuntimeDirectory=f5-actions-podman/{item.repository_name}
RuntimeDirectoryMode=0700
ExecStart=/usr/bin/podman system service --time=0 unix://{socket_dir}/podman.sock
Restart=on-failure
RestartSec=5
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths={home} {socket_dir}

[Install]
WantedBy=multi-user.target
"""


def install_definition():
    require_root()
    policy = active_policy()
    for path in (
        DATA_ROOT,
        USER_ROOT,
        STATE_ROOT,
        CONFIG_ROOT,
        INSTANCE_ROOT,
        INSTALL_ROOT,
    ):
        path.mkdir(parents=True, exist_ok=True)
    for account in sorted(all_accounts()):
        ensure_account(account)
    command(
        [
            "install",
            "-o",
            "root",
            "-g",
            "root",
            "-m",
            "0755",
            str(CONTROLLER_SOURCE),
            str(INSTALL_ROOT / CONTROLLER_SOURCE.name),
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
    socket_repositories = set()
    for item in instances(policy):
        safe_write(
            INSTANCE_ROOT / f"{item.identifier}.env",
            f"RUNNER_REPOSITORY={item.repository}\nRUNNER_PROFILE={item.profile}\nRUNNER_SLOT={item.slot}\n",
            0o600,
        )
        if item.container_socket and item.repository_name not in socket_repositories:
            safe_write(
                SYSTEMD_ROOT / f"f5-actions-podman-{item.repository_name}.service",
                podman_unit_text(item),
            )
            socket_repositories.add(item.repository_name)
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
    for item in select(repository, profile):
        if item.container_socket:
            command(
                [
                    "systemctl",
                    "enable",
                    "--now",
                    f"f5-actions-podman-{item.repository_name}.service",
                ]
            )
        command(["systemctl", "enable", "--now", item.unit])


def audit(repository=None):
    selected = select(repository) if repository else list(all_instances())
    failed = False
    for item in selected:
        env_file = INSTANCE_ROOT / f"{item.identifier}.env"
        try:
            record = pwd.getpwnam(item.account)
            account_ok = Path(record.pw_dir) == USER_ROOT / item.account
        except KeyError:
            account_ok = False
        unit_result = command(
            ["systemctl", "is-active", item.unit], check=False, capture=True
        )
        state = unit_result.stdout.strip() or "inactive"
        definition_ok = env_file.is_file() and account_ok
        marker = "OK" if definition_ok else "ERROR"
        print(
            f"[{marker}] {item.unit} definition={'ready' if definition_ok else 'missing'} state={state}"
        )
        failed |= not definition_ok
    return 1 if failed else 0


def plan():
    for item in all_instances():
        socket = " socket" if item.container_socket else ""
        print(f"{item.unit}\t{item.account}{socket}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("plan")
    subparsers.add_parser("install")
    subparsers.add_parser("install-credential")
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
