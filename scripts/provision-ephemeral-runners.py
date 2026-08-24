#!/usr/bin/env python3
# pylint: disable=global-statement,invalid-name,too-many-lines
"""Provision and audit repository-scoped ephemeral runner systemd services."""

from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import time
from contextlib import contextmanager
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
            INSTALL_ROOT / "prepare-runner-tool-cache.sh",
            INSTALL_ROOT / "rootless-dockerd-wrapper.sh",
            INSTALL_ROOT / "self-hosted-runner-policy.json",
        )
    source_root = provisioner.parent.parent
    return (
        source_root,
        source_root / "scripts/ephemeral-runner-controller.py",
        source_root / "scripts/runner-entrypoint.sh",
        source_root / "scripts/prepare-runner-tool-cache.sh",
        source_root / "scripts/rootless-dockerd-wrapper.sh",
        source_root / ".github/config/self-hosted-runner-policy.json",
    )


(
    SOURCE_ROOT,
    CONTROLLER_SOURCE,
    ENTRYPOINT_SOURCE,
    TOOL_CACHE_INITIALIZER_SOURCE,
    ROOTLESS_DOCKER_WRAPPER_SOURCE,
    POLICY_SOURCE,
) = source_paths(PROVISIONER_SOURCE)
FLEET_DISPATCHER_SOURCE = (
    INSTALL_ROOT / "fleet-runner-dispatch.py"
    if PROVISIONER_SOURCE.parent == INSTALL_ROOT
    else SOURCE_ROOT / "scripts/fleet-runner-dispatch.py"
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
RETIRED_LEGACY_DISPATCH_TIMERS = (
    "f5-actions-runner-standby.timer",
    "f5-actions-runner-profile-dispatch.timer",
    "f5-actions-runner-xcsh-dispatch.timer",
)
RETIRED_LEGACY_DISPATCH_UNIT_FILES = (
    "f5-actions-runner-standby.service",
    "f5-actions-runner-profile-dispatch.service",
    "f5-actions-runner-xcsh-dispatch.service",
    *RETIRED_LEGACY_DISPATCH_TIMERS,
)
FLEET_DISPATCH_UNIT = "f5-actions-runner-fleet-dispatch.service"
FLEET_DISPATCH_TIMER = "f5-actions-runner-fleet-dispatch.timer"
ROOTLESS_DOCKER_UNIT = "f5-actions-container-build-docker.service"
FLEET_SLICE_UNIT = "f5-actions.slice"
RUNNER_SLICE_UNIT = "f5-actions-runner.slice"
CONTAINER_BUILD_SLICE_UNIT = "f5-actions-container-build.slice"
ROOTLESS_DOCKER_CONFIG = CONFIG_ROOT / "container-build-daemon.json"
ROOTLESS_DOCKER_DATA_ROOT = DATA_ROOT / "container-build-docker"
ROOTLESS_RUNTIME_ROOT = Path("/run/f5-actions-runner/container-build")
FLEET_DISPATCH_ROOT = STATE_ROOT / "fleet-dispatch"
ADMISSION_LOCK = STATE_ROOT / "admission.lock"
ADMISSION_PERMIT_ROOT = STATE_ROOT / "admission-permits"
RUNNER_START_PERMIT_SECONDS = 60
SUBORDINATE_START = 231072
SUBORDINATE_COUNT = 65536
RETIRED_UNIT = "f5-actions-runner-retired.service"
RETIRED_TIMER = "f5-actions-runner-retired.timer"
CAPACITY_MIN_FREE_BYTES = 50 * 1024 * 1024 * 1024
CAPACITY_MIN_FREE_PERCENT = 10


TRUSTED_DOCKER_JOB_NAMES = frozenset(
    ("Trust Docker-capable job", "lint / Trust Docker-capable job")
)


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
class Instance:  # pylint: disable=too-many-instance-attributes
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


@dataclass(frozen=True)
class RetiredInstance:
    """A previously installed runner definition absent from current policy."""

    repository: str
    repository_name: str
    profile: str
    slot: int
    mode: str
    definition: Path

    @property
    def identifier(self):
        return f"{self.repository_name}--{self.profile}--{self.slot}"

    @property
    def unit(self):
        return f"f5-actions-runner@{self.identifier}.service"

    @property
    def runner_prefix(self):
        return f"gha-{self.repository_name}-{self.profile}-{self.slot}-"


def valid_runner_component(value):
    """Return whether a runner profile or repository component is safe."""
    return bool(value) and all(
        character.islower() or character.isdigit() or character in "-."
        for character in value
    )


def configured_definition_names():
    """Return the root-owned instance definitions required by current policy."""
    return {
        f"{item.identifier}.env" for item in (*all_instances(), *standby_instances())
    }


def retired_instance(path):
    """Parse one retired root-owned instance definition without trusting its name."""
    try:
        metadata = path.stat(follow_symlinks=False)
    except OSError as exc:
        raise ProvisionError(
            f"cannot inspect retired runner definition {path}: {exc}"
        ) from exc
    if not stat.S_ISREG(metadata.st_mode):
        raise ProvisionError(f"retired runner definition is not a regular file: {path}")
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ProvisionError(
            f"cannot read retired runner definition {path}: {exc}"
        ) from exc
    for line in lines:
        key, separator, value = line.partition("=")
        if not separator or not key or key in values:
            raise ProvisionError(f"retired runner definition is malformed: {path}")
        values[key] = value
    expected = {"RUNNER_REPOSITORY", "RUNNER_PROFILE", "RUNNER_SLOT", "RUNNER_MODE"}
    if set(values) != expected:
        raise ProvisionError(f"retired runner definition is malformed: {path}")
    repository = values["RUNNER_REPOSITORY"]
    owner, separator, repository_name = repository.partition("/")
    profile = values["RUNNER_PROFILE"]
    slot_text = values["RUNNER_SLOT"]
    mode = values["RUNNER_MODE"]
    repository_is_valid = (
        owner == "f5-sales-demo"
        and bool(separator)
        and "/" not in repository_name
        and valid_runner_component(repository_name)
    )
    definition_is_valid = all(
        (
            repository_is_valid,
            valid_runner_component(profile),
            slot_text.isdecimal(),
            mode in {"serve", "once"},
        )
    )
    if not definition_is_valid:
        raise ProvisionError(f"retired runner definition is malformed: {path}")
    slot = int(slot_text)
    instance = RetiredInstance(repository, repository_name, profile, slot, mode, path)
    if path.name != f"{instance.identifier}.env":
        raise ProvisionError(f"retired runner definition identity mismatch: {path}")
    return instance


def retired_instances():
    """Return definitions for runner slots that the current policy retired."""
    expected = configured_definition_names()
    return tuple(
        retired_instance(path)
        for path in sorted(INSTANCE_ROOT.glob("*.env"))
        if path.name not in expected
    )


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
After=docker.service {ROOTLESS_DOCKER_UNIT}
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Slice={RUNNER_SLICE_UNIT}
Environment=RUNNER_FLEET_GITHUB_TOKEN_FILE={TOKEN_PATH}
EnvironmentFile={INSTANCE_ROOT}/%i.env
ExecStartPre=/usr/bin/test -r {TOKEN_PATH}
ExecStartPre=/usr/bin/python3 {INSTALL_ROOT}/provision-ephemeral-runners.py admission-check ${{RUNNER_REPOSITORY}} --profile ${{RUNNER_PROFILE}} --slot ${{RUNNER_SLOT}}
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
ReadWritePaths={DATA_ROOT} /run/docker.sock {ROOTLESS_RUNTIME_ROOT}

[Install]
WantedBy=multi-user.target
"""


def container_build_slice_text():
    return """[Unit]
Description=Bounded cgroup for F5 Actions container builds

[Slice]
MemoryHigh=14G
MemoryMax=16G
MemorySwapMax=0
CPUQuota=600%
"""


def fleet_slice_text():
    return """[Unit]
Description=Aggregate bounded cgroup for F5 Actions fleet work

[Slice]
MemoryHigh=44G
MemoryMax=48G
CPUQuota=1800%
"""


def runner_slice_text():
    return """[Unit]
Description=Bounded cgroup for F5 Actions socketless runners

[Slice]
MemoryHigh=44G
MemoryMax=48G
CPUQuota=1800%
"""


def rootless_docker_config_text(policy):
    return (
        json.dumps(
            {
                "builder": {
                    "gc": {
                        "enabled": True,
                        "defaultKeepStorage": policy.docker.cache_max,
                    }
                },
                "data-root": policy.docker.data_root,
                "exec-opts": ["native.cgroupdriver=cgroupfs"],
                "features": {"buildkit": True},
                "hosts": [f"unix://{policy.docker.host_socket}"],
                "log-driver": "local",
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )


def rootless_docker_unit_text():
    return f"""[Unit]
Description=Rootless Docker daemon for F5 Actions container builds
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=simple
User=gha-ephemeral
Group=gha-ephemeral
Slice={CONTAINER_BUILD_SLICE_UNIT}
Delegate=yes
RuntimeDirectory=f5-actions-runner/container-build
RuntimeDirectoryMode=0770
RuntimeDirectoryPreserve=yes
Environment=HOME={ROOTLESS_DOCKER_DATA_ROOT}/home
Environment=XDG_RUNTIME_DIR={ROOTLESS_RUNTIME_ROOT}
Environment=DOCKERD={INSTALL_ROOT}/rootless-dockerd-wrapper.sh
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns
ExecStart=/usr/bin/dockerd-rootless.sh --config-file={ROOTLESS_DOCKER_CONFIG}
ExecStartPost=/usr/bin/timeout 60 /bin/sh -c 'until test -S {ROOTLESS_RUNTIME_ROOT}/docker.sock; do sleep 1; done'
ExecStartPost=/bin/chgrp gha-ephemeral {ROOTLESS_RUNTIME_ROOT}/docker.sock
ExecStartPost=/bin/chmod 0660 {ROOTLESS_RUNTIME_ROOT}/docker.sock
Restart=on-failure
RestartSec=5
TimeoutStartSec=2min
TimeoutStopSec=2min
UMask=0007
PrivateTmp=true
PrivateMounts=true
# newuidmap/newgidmap are setuid helpers required to enter the bounded user namespace.
NoNewPrivileges=false
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=false
ProtectKernelModules=false
ProtectControlGroups=false
ReadWritePaths={ROOTLESS_DOCKER_DATA_ROOT} {ROOTLESS_RUNTIME_ROOT} {STATE_ROOT}

[Install]
WantedBy=multi-user.target
"""


def fleet_dispatcher_unit_text():
    return f"""[Unit]
Description=F5 Actions bounded fleet runner dispatcher
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=115
Environment=RUNNER_FLEET_GITHUB_TOKEN_FILE={TOKEN_PATH}
ExecStartPre=/usr/bin/test -r {TOKEN_PATH}
ExecStart=/usr/bin/python3 {INSTALL_ROOT}/fleet-runner-dispatch.py
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths={FLEET_DISPATCH_ROOT} {DATA_ROOT}

"""


def fleet_dispatcher_timer_text():
    return f"""[Unit]
Description=Schedule F5 Actions bounded fleet runner dispatcher

[Timer]
OnCalendar=*:0/2
AccuracySec=1s
Persistent=true
Unit={FLEET_DISPATCH_UNIT}

[Install]
WantedBy=timers.target
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
OnCalendar=*:0/15
Persistent=true
Unit={CAPACITY_UNIT}

[Install]
WantedBy=timers.target
"""


def retired_reconciler_unit_text():
    return f"""[Unit]
Description=Retire orphaned F5 Actions runners
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=RUNNER_FLEET_GITHUB_TOKEN_FILE={TOKEN_PATH}
ExecStartPre=/usr/bin/test -r {TOKEN_PATH}
ExecStart=/usr/bin/python3 {INSTALL_ROOT}/provision-ephemeral-runners.py retire-orphans --apply
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths={CONFIG_ROOT}

"""


def retired_reconciler_timer_text():
    return f"""[Unit]
Description=Schedule retirement of orphaned F5 Actions runners

[Timer]
OnCalendar=*:0/15
Persistent=true
Unit={RETIRED_UNIT}

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


def subordinate_ranges(path):
    ranges = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        name, start, count = line.split(":")
        ranges.append((name, int(start), int(count)))
    return ranges


def ensure_subordinate_ranges():
    """Assign the one preselected unused range without changing userns policy."""
    require_root()
    for path, flag in (
        (Path("/etc/subuid"), "--add-subuids"),
        (Path("/etc/subgid"), "--add-subgids"),
    ):
        ranges = subordinate_ranges(path)
        expected = ("gha-ephemeral", SUBORDINATE_START, SUBORDINATE_COUNT)
        if expected in ranges:
            continue
        wanted_end = SUBORDINATE_START + SUBORDINATE_COUNT
        for name, start, count in ranges:
            if max(start, SUBORDINATE_START) < min(start + count, wanted_end):
                raise ProvisionError(f"subordinate range overlaps {name} in {path}")
        command(
            [
                "usermod",
                flag,
                f"{SUBORDINATE_START}-{wanted_end - 1}",
                "gha-ephemeral",
            ]
        )


def rootless_prerequisite_errors():
    errors = []
    try:
        account = command(["id", "-u", "gha-ephemeral"], check=False, capture=True)
        if account.returncode != 0 or account.stdout.strip() != "1001":
            errors.append("gha-ephemeral must exist with UID 1001")
    except OSError as exc:
        errors.append(f"cannot inspect gha-ephemeral: {exc}")
    for executable in (
        "/usr/bin/dockerd-rootless.sh",
        "/usr/bin/rootlesskit",
        "/usr/bin/slirp4netns",
        "/usr/bin/newuidmap",
        "/usr/bin/newgidmap",
    ):
        if not Path(executable).is_file():
            errors.append(f"rootless prerequisite is missing: {executable}")
    for path in (Path("/etc/subuid"), Path("/etc/subgid")):
        try:
            expected = ("gha-ephemeral", SUBORDINATE_START, SUBORDINATE_COUNT)
            if expected not in subordinate_ranges(path):
                errors.append(f"dedicated subordinate range is missing from {path}")
        except (OSError, ValueError) as exc:
            errors.append(f"cannot validate {path}: {exc}")
    controls = {
        Path("/proc/sys/kernel/unprivileged_userns_clone"): "1",
        Path("/proc/sys/kernel/apparmor_restrict_unprivileged_userns"): "1",
    }
    for path, expected in controls.items():
        try:
            if path.read_text(encoding="utf-8").strip() != expected:
                errors.append(f"rootless prerequisite must remain {path}={expected}")
        except OSError as exc:
            errors.append(f"cannot validate {path}: {exc}")
    try:
        if (
            Path("/sys/fs/cgroup/cgroup.controllers")
            .read_text(encoding="utf-8")
            .find("memory")
            < 0
        ):
            errors.append("unified cgroup v2 memory controller is unavailable")
    except OSError as exc:
        errors.append(f"cannot validate cgroup v2: {exc}")
    return errors


def retire_legacy_dispatch_units():
    """Disable and remove obsolete non-fleet dispatcher units."""
    for timer in RETIRED_LEGACY_DISPATCH_TIMERS:
        command(["systemctl", "disable", "--now", timer], check=False)
    for name in RETIRED_LEGACY_DISPATCH_UNIT_FILES:
        path = SYSTEMD_ROOT / name
        try:
            metadata = path.stat(follow_symlinks=False)
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise ProvisionError(
                f"cannot inspect retired dispatcher unit {path}: {exc}"
            ) from exc
        if not stat.S_ISREG(metadata.st_mode):
            raise ProvisionError(
                f"retired dispatcher unit is not a regular file: {path}"
            )
        path.unlink()


def install_definition(enable_timers=True):
    require_root()
    ensure_subordinate_ranges()
    errors = rootless_prerequisite_errors()
    if errors:
        raise ProvisionError("; ".join(errors))
    policy = active_policy()
    for path in (
        DATA_ROOT,
        STATE_ROOT,
        CONFIG_ROOT,
        INSTANCE_ROOT,
        INSTALL_ROOT,
        FLEET_DISPATCH_ROOT,
    ):
        path.mkdir(parents=True, exist_ok=True)
    command(
        [
            "install",
            "-d",
            "-o",
            "gha-ephemeral",
            "-g",
            "gha-ephemeral",
            "-m",
            "0700",
            str(ROOTLESS_DOCKER_DATA_ROOT),
            str(ROOTLESS_DOCKER_DATA_ROOT / "home"),
        ]
    )
    for source in (
        PROVISIONER_SOURCE,
        CONTROLLER_SOURCE,
        ENTRYPOINT_SOURCE,
        TOOL_CACHE_INITIALIZER_SOURCE,
        ROOTLESS_DOCKER_WRAPPER_SOURCE,
        FLEET_DISPATCHER_SOURCE,
    ):
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
    safe_write(ROOTLESS_DOCKER_CONFIG, rootless_docker_config_text(policy))
    safe_write(SYSTEMD_ROOT / FLEET_SLICE_UNIT, fleet_slice_text())
    safe_write(SYSTEMD_ROOT / RUNNER_SLICE_UNIT, runner_slice_text())
    safe_write(SYSTEMD_ROOT / CONTAINER_BUILD_SLICE_UNIT, container_build_slice_text())
    safe_write(SYSTEMD_ROOT / ROOTLESS_DOCKER_UNIT, rootless_docker_unit_text())
    safe_write(SYSTEMD_ROOT / RUNNER_UNIT, runner_unit_text())
    safe_write(SYSTEMD_ROOT / CAPACITY_UNIT, capacity_unit_text())
    safe_write(SYSTEMD_ROOT / CAPACITY_TIMER, capacity_timer_text())
    safe_write(SYSTEMD_ROOT / FLEET_DISPATCH_UNIT, fleet_dispatcher_unit_text())
    safe_write(SYSTEMD_ROOT / FLEET_DISPATCH_TIMER, fleet_dispatcher_timer_text())
    safe_write(SYSTEMD_ROOT / RETIRED_UNIT, retired_reconciler_unit_text())
    safe_write(SYSTEMD_ROOT / RETIRED_TIMER, retired_reconciler_timer_text())
    for item in (*instances(policy), *standby_instances(policy)):
        safe_write(
            INSTANCE_ROOT / f"{item.identifier}.env",
            f"RUNNER_REPOSITORY={item.repository}\nRUNNER_PROFILE={item.profile}\nRUNNER_SLOT={item.slot}\nRUNNER_MODE={item.mode}\n",
            0o600,
        )
    retire_legacy_dispatch_units()
    command(["systemctl", "daemon-reload"])
    if enable_timers:
        command(["systemctl", "enable", "--now", FLEET_DISPATCH_TIMER])
        command(["systemctl", "enable", "--now", CAPACITY_TIMER])
        command(["systemctl", "enable", "--now", RETIRED_TIMER])


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


def instance_profile(policy, item):
    spec = policy.repository(item.repository)
    return next(profile for profile in spec.profiles if profile.name == item.profile)


def fleet_instances(policy):
    """Return only policy-enabled instances subject to the shared pool."""
    enabled = set(policy.dispatcher.repositories)
    return tuple(
        item
        for item in (*instances(policy), *standby_instances(policy))
        if item.repository in enabled
    )


def configured_fleet_instance(policy, repository, profile, slot):
    """Resolve one exact policy-owned instance or reject the request."""
    matches = [
        item
        for item in fleet_instances(policy)
        if item.repository == repository
        and item.profile == profile
        and item.slot == slot
    ]
    if len(matches) != 1:
        raise ProvisionError(
            "runner admission requires an exact enabled policy instance"
        )
    return matches[0]


def unit_active_state(item):
    state = command(
        ["systemctl", "show", "--property=ActiveState", "--value", item.unit],
        check=False,
        capture=True,
    )
    if state.returncode != 0:
        raise ProvisionError(f"cannot read runner unit state: {item.unit}")
    return state.stdout.strip()


def reserved_fleet_instances(policy):
    return [
        item
        for item in fleet_instances(policy)
        if unit_active_state(item) in {"active", "activating"}
    ]


def admission_allows_instances(policy, reserved):
    profiles = [instance_profile(policy, item) for item in reserved]
    standard = sum(not profile.docker_socket for profile in profiles)
    builders = sum(profile.docker_socket for profile in profiles)
    memory = sum(load_controller().memory_bytes(profile.memory) for profile in profiles)
    cpus = sum(float(profile.cpus) for profile in profiles)
    return (
        standard <= policy.dispatcher.standard_runners
        and builders <= policy.dispatcher.container_build_runners
        and memory <= load_controller().memory_bytes(policy.dispatcher.memory)
        and cpus <= float(policy.dispatcher.cpus)
    )


@contextmanager
def admission_lock():
    ADMISSION_LOCK.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        ADMISSION_LOCK, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600
    )
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def runner_start_permit_path(candidate):
    return ADMISSION_PERMIT_ROOT / f"{candidate.identifier}.json"


def authorize_runner_start(candidate):
    require_root()
    policy = active_policy()
    if (
        configured_fleet_instance(
            policy, candidate.repository, candidate.profile, candidate.slot
        )
        != candidate
    ):
        raise ProvisionError("runner start authorization does not match policy")
    with admission_lock():
        ADMISSION_PERMIT_ROOT.mkdir(parents=True, exist_ok=True)
        safe_write(
            runner_start_permit_path(candidate),
            json.dumps(
                {
                    "expires_at": int(time.time()) + RUNNER_START_PERMIT_SECONDS,
                    "unit": candidate.unit,
                },
                sort_keys=True,
            ),
            0o600,
        )


def consume_runner_start_authorization(candidate):
    permit = runner_start_permit_path(candidate)
    try:
        descriptor = os.open(permit, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with os.fdopen(descriptor, encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError as exc:
        raise ProvisionError(
            "runner start lacks fleet dispatcher authorization"
        ) from exc
    except (OSError, ValueError) as exc:
        raise ProvisionError("runner start authorization is malformed") from exc
    if (
        not isinstance(payload, dict)
        or set(payload) != {"expires_at", "unit"}
        or payload["unit"] != candidate.unit
        or not isinstance(payload["expires_at"], int)
        or payload["expires_at"] < int(time.time())
    ):
        raise ProvisionError("runner start authorization is invalid or expired")
    permit.unlink()


def revoke_runner_start(candidate):
    with admission_lock():
        try:
            runner_start_permit_path(candidate).unlink()
        except FileNotFoundError:
            return


def admission_check(repository, profile, slot):
    require_root()
    policy = active_policy()
    candidate = configured_fleet_instance(policy, repository, profile, slot)
    with admission_lock():
        consume_runner_start_authorization(candidate)
        reserved = reserved_fleet_instances(policy)
        if candidate not in reserved:
            reserved.append(candidate)
        if not admission_allows_instances(policy, reserved):
            raise ProvisionError(
                f"fleet admission denied for {candidate.unit}: shared capacity exhausted"
            )


def active_fleet_instances(policy):
    active = []
    for item in (*instances(policy), *standby_instances(policy)):
        state = command(
            ["systemctl", "is-active", item.unit], check=False, capture=True
        )
        if state.returncode == 0 and state.stdout.strip() == "active":
            active.append(item)
    return active


def admission_allows(policy, candidate):
    active = active_fleet_instances(policy)
    if candidate not in active:
        active.append(candidate)
    return admission_allows_instances(policy, active)


def successful_docker_trust_gate(job):
    """Recognize only canonical direct or reusable Docker trust gates."""
    return (
        job.get("name") in TRUSTED_DOCKER_JOB_NAMES
        and job.get("conclusion") == "success"
    )


def retirement_runner_record(item, inventory):
    """Return the exact online, idle GitHub runner for one retired definition."""
    matches = [
        runner
        for runner in inventory
        if isinstance(runner, dict)
        and isinstance(runner.get("name"), str)
        and runner["name"].startswith(item.runner_prefix)
    ]
    if len(matches) != 1:
        return None
    runner = matches[0]
    runner_id = runner.get("id")
    if (
        not isinstance(runner_id, int)
        or runner_id <= 0
        or runner.get("status") != "online"
        or runner.get("busy") is not False
    ):
        return None
    return runner


def retire_orphans(*, apply=False):
    """Retire only policy-orphaned runner services proven idle by GitHub."""
    if apply:
        require_root()
    retired = retired_instances()
    if not apply:
        for item in retired:
            print(f"[PLAN] {item.unit} definition=retired")
        print(f"retirement retired=0 skipped={len(retired)} apply=false")
        return 0
    controller_module = load_controller()
    github = controller_module.GitHubClient(controller_module.token_from_environment())
    inventories: dict[str, list[dict]] = {}
    retired_count = 0
    skipped = 0
    for item in retired:
        inventory = inventories.get(item.repository)
        if inventory is None:
            inventory = github.runners(item.repository)
            if not isinstance(inventory, list) or any(
                not isinstance(record, dict) for record in inventory
            ):
                raise ProvisionError("GitHub runner inventory is malformed")
            inventories[item.repository] = inventory
        runner = retirement_runner_record(item, inventory)
        if runner is None:
            print(f"[SKIP] {item.unit} runner=not-verified-idle")
            skipped += 1
            continue
        state = command(
            ["systemctl", "is-active", item.unit], check=False, capture=True
        )
        if state.returncode != 0 or state.stdout.strip() != "active":
            print(f"[SKIP] {item.unit} service=not-active")
            skipped += 1
            continue
        github.delete_runner(item.repository, runner["id"])
        command(["systemctl", "stop", item.unit])
        item.definition.unlink()
        print(f"[RETIRED] {item.unit} definition=removed")
        retired_count += 1
    print(f"retirement retired={retired_count} skipped={skipped} apply=true")
    return 0


def docker_host_errors(policy):
    errors = []
    service = command(
        ["systemctl", "is-active", "docker.service"], check=False, capture=True
    )
    if service.returncode != 0 or service.stdout.strip() != "active":
        errors.append("docker.service is not active")
    rootless = command(
        ["systemctl", "is-active", ROOTLESS_DOCKER_UNIT], check=False, capture=True
    )
    if rootless.returncode != 0 or rootless.stdout.strip() != "active":
        errors.append(f"{ROOTLESS_DOCKER_UNIT} is not active")
    for socket, uid, description in (
        (Path("/run/docker.sock"), 0, "host"),
        (Path(policy.docker.host_socket), 1001, "dedicated"),
    ):
        try:
            metadata = socket.stat(follow_symlinks=False)
            if not stat.S_ISSOCK(metadata.st_mode):
                errors.append(f"{description} Docker socket is not a socket: {socket}")
            if metadata.st_uid != uid or stat.S_IMODE(metadata.st_mode) != 0o660:
                errors.append(
                    f"{description} Docker socket ownership or mode is invalid"
                )
        except OSError as exc:
            errors.append(f"cannot inspect {description} Docker socket: {exc}")
    version = command(
        [
            "docker",
            "--host",
            f"unix://{policy.docker.host_socket}",
            "version",
            "--format",
            "{{.Server.Version}}",
        ],
        check=False,
        capture=True,
    )
    if version.returncode != 0:
        errors.append("cannot query dedicated Docker Engine version")
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
    security = command(
        [
            "docker",
            "--host",
            f"unix://{policy.docker.host_socket}",
            "info",
            "--format",
            "{{json .SecurityOptions}}",
        ],
        check=False,
        capture=True,
    )
    if security.returncode != 0 or "rootless" not in security.stdout:
        errors.append("dedicated Docker Engine does not report rootless mode")
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
    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("--no-enable-timers", action="store_true")
    subparsers.add_parser("install-credential")
    subparsers.add_parser("capacity-check")
    admission_parser = subparsers.add_parser("admission-check")
    admission_parser.add_argument("repository")
    admission_parser.add_argument("--profile", required=True)
    admission_parser.add_argument("--slot", type=int, required=True)
    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("repository", nargs="?")
    retire_parser = subparsers.add_parser("retire-orphans")
    retire_parser.add_argument("--apply", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.action == "plan":
            plan()
        elif args.action == "install":
            install_definition(enable_timers=not args.no_enable_timers)
        elif args.action == "install-credential":
            install_credential()
        elif args.action == "capacity-check":
            return capacity_check()
        elif args.action == "admission-check":
            admission_check(args.repository, args.profile, args.slot)
        elif args.action == "retire-orphans":
            return retire_orphans(apply=args.apply)
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
