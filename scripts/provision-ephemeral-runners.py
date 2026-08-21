#!/usr/bin/env python3
# pylint: disable=global-statement,invalid-name,too-many-lines
"""Provision and audit repository-scoped ephemeral runner systemd services."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import time
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
            INSTALL_ROOT / "self-hosted-runner-policy.json",
        )
    source_root = provisioner.parent.parent
    return (
        source_root,
        source_root / "scripts/ephemeral-runner-controller.py",
        source_root / "scripts/runner-entrypoint.sh",
        source_root / "scripts/prepare-runner-tool-cache.sh",
        source_root / ".github/config/self-hosted-runner-policy.json",
    )


(
    SOURCE_ROOT,
    CONTROLLER_SOURCE,
    ENTRYPOINT_SOURCE,
    TOOL_CACHE_INITIALIZER_SOURCE,
    POLICY_SOURCE,
) = source_paths(PROVISIONER_SOURCE)
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
RETIRED_UNIT = "f5-actions-runner-retired.service"
RETIRED_TIMER = "f5-actions-runner-retired.timer"
STANDBY_INVENTORY_CACHE = STATE_ROOT / ".standby-runner-inventory.json"
STANDBY_INVENTORY_CACHE_SECONDS = 120
CAPACITY_MIN_FREE_BYTES = 50 * 1024 * 1024 * 1024
CAPACITY_MIN_FREE_PERCENT = 10
ROTATION_REQUEST_INTERVAL_SECONDS = 1


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


def all_standby_instances():
    return standby_instances(active_policy())


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
        f"{item.identifier}.env"
        for item in (*all_instances(), *all_standby_instances())
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
OnCalendar=*:0/15
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
ReadWritePaths={DATA_ROOT}

"""


def standby_scaler_timer_text():
    return f"""[Unit]
Description=Schedule F5 Actions runner standby scaler

[Timer]
OnCalendar=*:*:00
Persistent=true
Unit={STANDBY_UNIT}

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
OnBootSec=2min
OnUnitActiveSec=60s
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


def install_definition(enable_timers=True):
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
    for source in (
        PROVISIONER_SOURCE,
        CONTROLLER_SOURCE,
        ENTRYPOINT_SOURCE,
        TOOL_CACHE_INITIALIZER_SOURCE,
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
    safe_write(SYSTEMD_ROOT / RUNNER_UNIT, runner_unit_text())
    safe_write(SYSTEMD_ROOT / CAPACITY_UNIT, capacity_unit_text())
    safe_write(SYSTEMD_ROOT / CAPACITY_TIMER, capacity_timer_text())
    safe_write(SYSTEMD_ROOT / STANDBY_UNIT, standby_scaler_unit_text())
    safe_write(SYSTEMD_ROOT / STANDBY_TIMER, standby_scaler_timer_text())
    safe_write(SYSTEMD_ROOT / RETIRED_UNIT, retired_reconciler_unit_text())
    safe_write(SYSTEMD_ROOT / RETIRED_TIMER, retired_reconciler_timer_text())
    for item in (*instances(policy), *standby_instances(policy)):
        safe_write(
            INSTANCE_ROOT / f"{item.identifier}.env",
            f"RUNNER_REPOSITORY={item.repository}\nRUNNER_PROFILE={item.profile}\nRUNNER_SLOT={item.slot}\nRUNNER_MODE={item.mode}\n",
            0o600,
        )
    command(["systemctl", "daemon-reload"])
    if enable_timers:
        command(["systemctl", "enable", "--now", STANDBY_TIMER])
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


def enable(repository, profile=None):
    require_root()
    if not TOKEN_PATH.is_file():
        raise ProvisionError(f"credential is not installed at {TOKEN_PATH}")
    command(["systemctl", "start", "docker.service"])
    for item in select(repository, profile):
        command(["systemctl", "enable", "--now", item.unit])


def standby_inventory_cache(policy, now):
    """Return a fresh, complete cached runner inventory, if one is available."""
    try:
        cached = json.loads(STANDBY_INVENTORY_CACHE.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, ValueError):
        return None
    if not isinstance(cached, dict) or set(cached) != {"recorded_at", "inventories"}:
        return None
    recorded_at = cached["recorded_at"]
    inventories = cached["inventories"]
    cache_is_fresh = isinstance(recorded_at, int) and not isinstance(recorded_at, bool)
    if cache_is_fresh:
        cache_is_fresh = 0 <= now - recorded_at <= STANDBY_INVENTORY_CACHE_SECONDS
    inventory_is_complete = isinstance(inventories, dict) and set(inventories) == set(
        policy.governed()
    )
    inventory_records_are_lists = inventory_is_complete and all(
        isinstance(records, list) for records in inventories.values()
    )
    if cache_is_fresh and inventory_records_are_lists:
        return inventories
    return None


def standby_inventories(policy, controller_module):
    """Fetch and cache the whole fleet inventory at a bounded core-API rate."""
    now = int(time.time())
    cached = standby_inventory_cache(policy, now)
    if cached is not None:
        return cached
    github = controller_module.GitHubClient(controller_module.token_from_environment())
    inventories = {
        repository: github.runners(repository) for repository in policy.governed()
    }
    safe_write(
        STANDBY_INVENTORY_CACHE,
        json.dumps({"recorded_at": now, "inventories": inventories}, sort_keys=True),
        0o600,
    )
    return inventories


def single_idle_runner(runners):
    """Return whether exactly one runner is online and idle."""
    return (
        len(runners) == 1
        and runners[0].get("status") == "online"
        and runners[0].get("busy") is False
    )


def standby_scale():
    """Start an inactive socketless standby when warm capacity is unavailable."""
    require_root()
    controller_module = load_controller()
    policy = active_policy()
    standby = standby_instances(policy)
    inventories = standby_inventories(policy, controller_module)
    if any(
        not isinstance(record, dict)
        for inventory in inventories.values()
        for record in inventory
    ):
        raise ProvisionError("GitHub runner inventory is malformed")
    capacity = []
    for item in standby:
        spec = policy.repository(item.repository)
        warm_prefixes = tuple(
            f"gha-{spec.name}-{item.profile}-{slot}-" for slot in range(spec.replicas)
        )
        warm = [
            record
            for record in inventories[item.repository]
            if isinstance(record.get("name"), str)
            and record["name"].startswith(warm_prefixes)
        ]
        if any(
            record.get("status") not in {"online", "offline"}
            or not isinstance(record.get("busy"), bool)
            for record in warm
        ):
            raise ProvisionError("GitHub warm runner inventory is malformed")
        standby_prefix = f"gha-{spec.name}-{item.profile}-{item.slot}-"
        standby_runners = [
            record
            for record in inventories[item.repository]
            if isinstance(record.get("name"), str)
            and record["name"].startswith(standby_prefix)
        ]
        if any(
            record.get("status") not in {"online", "offline"}
            or not isinstance(record.get("busy"), bool)
            for record in standby_runners
        ):
            raise ProvisionError("GitHub standby runner inventory is malformed")
        capacity.append(
            (
                item,
                spec,
                any(record["busy"] for record in warm),
                any(record["status"] == "online" for record in warm),
                standby_runners,
            )
        )
    for item, spec, warm_busy, warm_online, standby_runners in capacity:
        state = command(
            ["systemctl", "is-active", item.unit], check=False, capture=True
        )
        active = state.returncode == 0 and state.stdout.strip() == "active"
        # A warm runner is deliberately ephemeral. During its cleanup and next
        # registration no matching runner is online, so cover that gap with the
        # existing socketless one-job standby as well as ordinary busy scale-out.
        if (warm_busy or not warm_online) and not active:
            command(["systemctl", "start", item.unit])

        elif (
            active
            and not warm_busy
            and warm_online
            and single_idle_runner(standby_runners)
        ):
            # An idle standby must not remain warm after primary capacity returns.
            fresh_inventory = controller_module.GitHubClient(
                controller_module.token_from_environment()
            ).runners(item.repository)
            if not isinstance(fresh_inventory, list) or any(
                not isinstance(record, dict) for record in fresh_inventory
            ):
                raise ProvisionError("GitHub runner inventory is malformed")
            warm_prefixes = tuple(
                f"gha-{spec.name}-{item.profile}-{slot}-"
                for slot in range(spec.replicas)
            )
            fresh_warm = [
                record
                for record in fresh_inventory
                if isinstance(record.get("name"), str)
                and record["name"].startswith(warm_prefixes)
            ]
            fresh_standby = [
                record
                for record in fresh_inventory
                if isinstance(record.get("name"), str)
                and record["name"].startswith(
                    f"gha-{spec.name}-{item.profile}-{item.slot}-"
                )
            ]
            if any(
                record.get("status") not in {"online", "offline"}
                or not isinstance(record.get("busy"), bool)
                for record in (*fresh_warm, *fresh_standby)
            ):
                raise ProvisionError("GitHub runner inventory is malformed")
            if (
                not any(record["busy"] for record in fresh_warm)
                and any(record["status"] == "online" for record in fresh_warm)
                and single_idle_runner(fresh_standby)
            ):
                command(["systemctl", "stop", item.unit])


def rotation_profile(policy, item):
    spec = policy.repository(item.repository)
    profile = next(
        (candidate for candidate in spec.profiles if candidate.name == item.profile),
        None,
    )
    if profile is None:
        raise ProvisionError(f"runner profile is not governed: {item.identifier}")
    return spec, profile


def rotation_runner_record(controller, spec, profile, item, inventory):
    prefix = controller.container_name(spec, profile, item.slot) + "-"
    matches = [
        runner
        for runner in inventory
        if isinstance(runner, dict)
        and isinstance(runner.get("name"), str)
        and runner["name"].startswith(prefix)
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


def rotate_idle(*, apply=False):
    # Replace only verified-idle warm runners whose image differs from policy.
    if apply:
        require_root()
    policy = active_policy()
    controller_module = load_controller()
    controller = controller_module.EphemeralController(policy, None)
    github = (
        controller_module.GitHubClient(controller_module.token_from_environment())
        if apply
        else None
    )
    inventories: dict[str, list[dict]] = {}
    rotated = 0
    skipped = 0
    for item in all_instances():
        spec, profile = rotation_profile(policy, item)
        image = controller.outer_image(spec, profile, item.slot)
        if image is None:
            print(f"[SKIP] {item.unit} container=absent")
            skipped += 1
            continue
        if image == profile.image:
            print(f"[OK] {item.unit} image=policy")
            continue
        if not apply:
            print(f"[PLAN] {item.unit} image=mismatch")
            continue
        if github is None:
            raise ProvisionError("rotation client is unavailable")
        inventory = inventories.get(item.repository)
        if inventory is None:
            if inventories:
                time.sleep(ROTATION_REQUEST_INTERVAL_SECONDS)
            inventory = github.runners(item.repository)
            if not isinstance(inventory, list) or any(
                not isinstance(record, dict) for record in inventory
            ):
                raise ProvisionError("GitHub runner inventory is malformed")
            inventories[item.repository] = inventory
        runner = rotation_runner_record(controller, spec, profile, item, inventory)
        if runner is None:
            print(f"[SKIP] {item.unit} runner=not-verified-idle")
            skipped += 1
            continue
        github.delete_runner(item.repository, runner["id"])
        command(["systemctl", "stop", item.unit])
        command(["systemctl", "start", item.unit])
        print(f"[ROTATED] {item.unit} image=policy")
        rotated += 1
    print(f"rotation rotated={rotated} skipped={skipped} apply={str(apply).lower()}")
    return 0


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
    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("--no-enable-timers", action="store_true")
    subparsers.add_parser("install-credential")
    subparsers.add_parser("capacity-check")
    enable_parser = subparsers.add_parser("enable")
    enable_parser.add_argument("repository")
    enable_parser.add_argument("--profile")
    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("repository", nargs="?")
    rotate_parser = subparsers.add_parser("rotate-idle")
    rotate_parser.add_argument("--apply", action="store_true")
    retire_parser = subparsers.add_parser("retire-orphans")
    retire_parser.add_argument("--apply", action="store_true")
    subparsers.add_parser("standby-scale")
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
        elif args.action == "enable":
            enable(args.repository, args.profile)
        elif args.action == "standby-scale":
            standby_scale()
        elif args.action == "rotate-idle":
            return rotate_idle(apply=args.apply)
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
