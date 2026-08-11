#!/usr/bin/env python3
# pylint: disable=invalid-name,too-many-arguments,too-many-branches,too-many-instance-attributes,too-many-return-statements,broad-exception-caught,no-else-return
"""Manage repository GitHub runners with fail-closed local identity checks."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

DEFAULT_ORG = "f5-sales-demo"
DEFAULT_BASE_DIR = Path("/data/actions-runners/f5-sales-demo")
DEFAULT_PROC_ROOT = Path("/proc")
DEFAULT_SYSTEMD_ROOT = Path("/etc/systemd/system")
DEFAULT_USER = "robin"
DEFAULT_RUNNER_VERSION = "2.336.0"
CGROUP_FIELD_COUNT = 3
DOCS_CONTROL_GOVERNANCE_PATH = (
    Path(__file__).resolve().parent.parent / ".claude/governance.json"
)


def run_cmd(command, cwd=None, check=True, capture=True, sudo=False):
    if sudo and os.geteuid() != 0:
        command = ["sudo", *command]
    return subprocess.run(  # noqa: S603 - argv is explicit and shell execution is disabled
        command,
        cwd=cwd,
        check=check,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )


def get_latest_runner_version(command=run_cmd):
    try:
        result = command(
            ["gh", "api", "repos/actions/runner/releases/latest", "--jq", ".tag_name"]
        )
        version = result.stdout.strip().removeprefix("v")
    except (OSError, subprocess.SubprocessError):
        return DEFAULT_RUNNER_VERSION
    else:
        return version or DEFAULT_RUNNER_VERSION


def download_runner_tarball(version, cache_dir):
    cache_dir = Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    name = f"actions-runner-linux-x64-{version}.tar.gz"
    destination = cache_dir / name
    if destination.is_file() and destination.stat().st_size > 0:
        return destination
    temporary = cache_dir / f"{name}.tmp"
    if temporary.exists():
        temporary.unlink()
    url = f"https://github.com/actions/runner/releases/download/v{version}/{name}"
    urllib.request.urlretrieve(  # noqa: S310 - immutable GitHub HTTPS origin
        url, temporary
    )
    if not temporary.is_file() or temporary.stat().st_size == 0:
        raise RuntimeError("downloaded runner archive is empty")
    temporary.replace(destination)
    return destination


def get_registration_token(org, repo, command=run_cmd):
    result = command(
        [
            "gh",
            "api",
            "-X",
            "POST",
            f"/repos/{org}/{repo}/actions/runners/registration-token",
            "--jq",
            ".token",
        ]
    )
    token = result.stdout.strip()
    if not token:
        raise RuntimeError("GitHub returned an empty runner registration token")
    return token


def get_removal_token(org, repo, command=run_cmd):
    result = command(
        [
            "gh",
            "api",
            "-X",
            "POST",
            f"/repos/{org}/{repo}/actions/runners/remove-token",
            "--jq",
            ".token",
        ]
    )
    token = result.stdout.strip()
    if not token:
        raise RuntimeError("GitHub returned an empty runner removal token")
    return token


def load_governed_repos(path=DOCS_CONTROL_GOVERNANCE_PATH):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    repos = data.get("repo_classes", {}).get("repos")
    if not isinstance(repos, dict) or not repos:
        raise ValueError("governance does not contain a non-empty repository inventory")
    return sorted(repos)


def validate_repo_dir(base_dir, repo):
    if not repo or not re.fullmatch(r"[A-Za-z0-9_.-]+", repo):
        raise ValueError(f"invalid repository name: {repo!r}")
    base = Path(base_dir).resolve()
    candidate = base / repo
    if candidate.is_symlink():
        raise ValueError("repository directory must not be a symlink")
    result = candidate.resolve()
    if result.parent != base:
        raise ValueError("repository directory escapes base")
    return result


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    parent_pid: int
    executable: Path
    cwd: Path
    start_time: int
    cgroups: tuple[str, ...]
    command_line: tuple[str, ...]


@dataclass(frozen=True)
class ServiceMetadata:
    load_state: str
    active_state: str
    sub_state: str
    main_pid: int
    fragment_path: Path
    exec_start: Path
    user: str
    control_group: str


class CommandGitHubClient:
    def __init__(self, command=run_cmd):
        self.command = command

    def runners(self, org, repo):
        result = self.command(["gh", "api", f"/repos/{org}/{repo}/actions/runners"])
        response = json.loads(result.stdout)
        runners = response.get("runners")
        if not isinstance(runners, list):
            raise TypeError("GitHub runner response is malformed")
        return runners


class RunnerManager:
    def __init__(
        self,
        base_dir=DEFAULT_BASE_DIR,
        proc_root=DEFAULT_PROC_ROOT,
        systemd_root=DEFAULT_SYSTEMD_ROOT,
        command=run_cmd,
        github=None,
        sleep=time.sleep,
        monotonic=time.monotonic,
        signal_process=os.kill,
        remove_tree=shutil.rmtree,
        rename=os.replace,
        downloader=download_runner_tarball,
        latest_version=None,
        registration_token=None,
        removal_token=None,
        user=DEFAULT_USER,
    ):
        self.base_dir = Path(base_dir)
        self.proc_root = Path(proc_root)
        self.systemd_root = Path(systemd_root)
        self.command = command
        self.github = github or CommandGitHubClient(command)
        self.sleep = sleep
        self.monotonic = monotonic
        self.signal_process = signal_process
        self.remove_tree = remove_tree
        self.rename = rename
        self.downloader = downloader
        self.latest_version = latest_version or (
            lambda: get_latest_runner_version(command)
        )
        self.registration_token = registration_token or (
            lambda org, repo: get_registration_token(org, repo, command)
        )
        self.removal_token = removal_token or (
            lambda org, repo: get_removal_token(org, repo, command)
        )
        self.user = user

    def repo_dir(self, repo):
        return validate_repo_dir(self.base_dir, repo)

    def _recovery_backup(self, repo):
        repo_dir = self.repo_dir(repo)
        return repo_dir.with_name(repo_dir.name + ".recovery-backup")

    def _validated_removal_target(self, repo, path):
        repo_dir = self.repo_dir(repo)
        backup = self._recovery_backup(repo)
        target = Path(path)
        if target not in {repo_dir, backup}:
            raise RuntimeError(f"refusing unrecognized runner removal target: {target}")
        if target.is_symlink():
            raise RuntimeError(f"refusing symlink runner removal target: {target}")
        if target.parent.resolve() != self.base_dir.resolve():
            raise RuntimeError("runner removal target escapes configured base")
        return target

    def _remove_runner_tree(self, repo, path):
        target = self._validated_removal_target(repo, path)
        if not target.exists():
            return
        self.command(
            [
                "chown",
                "--recursive",
                "--no-dereference",
                "--",
                f"{self.user}:{self.user}",
                str(target),
            ],
            sudo=True,
            check=True,
        )
        self.remove_tree(target)
        if target.exists() or target.is_symlink():
            raise RuntimeError(f"runner directory removal incomplete: {target}")

    @staticmethod
    def unit_name(org, repo):
        return f"actions.runner.{org}-{repo}.runner-ubuntu-{repo}.service"

    @staticmethod
    def runner_name(repo):
        return f"runner-ubuntu-{repo}"

    @staticmethod
    def expected_labels(org, repo):
        return {"self-hosted", "Linux", "X64", repo, org}

    def read_process(self, pid):
        root = self.proc_root / str(int(pid))
        try:
            executable = (root / "exe").resolve(strict=True)
            cwd = (root / "cwd").resolve(strict=True)
            stat = (root / "stat").read_text(encoding="utf-8")
            closing = stat.rfind(")")
            if closing < 0:
                return None
            fields = stat[closing + 2 :].split()
            parent_pid = int(fields[1])
            start_time = int(fields[19])
            cgroups = []
            for line in (root / "cgroup").read_text(encoding="utf-8").splitlines():
                parts = line.split(":", maxsplit=2)
                if len(parts) == CGROUP_FIELD_COUNT and parts[2].startswith("/"):
                    cgroups.append(parts[2])
            command_line = tuple(
                part.decode("utf-8", "surrogateescape")
                for part in (root / "cmdline").read_bytes().split(b"\0")
                if part
            )
            return ProcessIdentity(
                int(pid),
                parent_pid,
                executable,
                cwd,
                start_time,
                tuple(cgroups),
                command_line,
            )
        except (FileNotFoundError, PermissionError, OSError, ValueError, IndexError):
            return None

    def processes(self):
        try:
            entries = list(self.proc_root.iterdir())
        except OSError:
            return []
        processes = []
        for entry in entries:
            if entry.name.isdigit():
                identity = self.read_process(int(entry.name))
                if identity:
                    processes.append(identity)
        return sorted(processes, key=lambda item: item.pid)

    @staticmethod
    def _resolves_from_cwd(value, cwd):
        if not value:
            return None
        path = Path(value)
        try:
            return (path if path.is_absolute() else cwd / path).resolve()
        except OSError:
            return None

    def is_runner_process(self, identity, repo_dir):
        expected_dir = Path(repo_dir).resolve()
        if identity.cwd != expected_dir:
            return False
        executables = {
            (expected_dir / "bin/Runner.Listener").resolve(),
            (expected_dir / "bin/Runner.Worker").resolve(),
        }
        if identity.executable in executables:
            return True
        service_script = (expected_dir / "bin/RunnerService.js").resolve()
        return any(
            self._resolves_from_cwd(argument, expected_dir) == service_script
            for argument in identity.command_line
        )

    def owned_processes(self, repo_dir):
        return [
            process
            for process in self.processes()
            if self.is_runner_process(process, repo_dir)
        ]

    def listeners(self, repo_dir):
        expected = (Path(repo_dir).resolve() / "bin/Runner.Listener").resolve()
        return [
            process
            for process in self.owned_processes(repo_dir)
            if process.executable == expected
        ]

    def service_metadata(self, unit):
        properties = [
            "LoadState",
            "ActiveState",
            "SubState",
            "MainPID",
            "FragmentPath",
            "ExecStart",
            "User",
            "ControlGroup",
        ]
        result = self.command(
            [
                "systemctl",
                "show",
                unit,
                "--no-pager",
                *[f"--property={item}" for item in properties],
            ]
        )
        values = {}
        for line in result.stdout.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                if key in values:
                    raise RuntimeError(f"duplicate systemd property {key}")
                values[key] = value
        if set(values) != set(properties):
            missing = sorted(set(properties) - set(values))
            raise RuntimeError(f"incomplete systemd metadata: {missing}")
        match = re.match(r"^\{\s*path=([^ ;]+)\s*;", values["ExecStart"])
        if not match:
            match = re.match(r"^([^ ;]+)", values["ExecStart"])
        if not match:
            raise RuntimeError("cannot parse ExecStart")
        fragment = Path(values["FragmentPath"]).resolve()
        return ServiceMetadata(
            values["LoadState"],
            values["ActiveState"],
            values["SubState"],
            int(values["MainPID"]),
            fragment,
            Path(match.group(1)).resolve(),
            values["User"],
            values["ControlGroup"],
        )

    def unit_state(self, unit):
        result = self.command(
            [
                "systemctl",
                "show",
                unit,
                "--no-pager",
                "--property=LoadState",
                "--property=ActiveState",
            ],
            check=False,
        )
        values = {}
        for line in result.stdout.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
        if set(values) != {"LoadState", "ActiveState"}:
            raise RuntimeError("cannot prove systemd unit state")
        return values["LoadState"], values["ActiveState"]

    @staticmethod
    def in_control_group(identity, control_group):
        if not control_group.startswith("/"):
            return False
        prefix = control_group.rstrip("/") + "/"
        return any(
            group == control_group or group.startswith(prefix)
            for group in identity.cgroups
        )

    def main_process_matches(self, identity, repo_dir, control_group):
        if not identity or identity.cwd != Path(repo_dir).resolve():
            return False
        runsvc = (Path(repo_dir).resolve() / "runsvc.sh").resolve()
        command_matches = any(
            self._resolves_from_cwd(argument, identity.cwd) == runsvc
            for argument in identity.command_line
        )
        return command_matches and self.in_control_group(identity, control_group)

    def github_runner(self, org, repo):
        matches = [
            runner
            for runner in self.github.runners(org, repo)
            if runner.get("name") == self.runner_name(repo)
        ]
        if len(matches) != 1:
            raise RuntimeError(
                f"expected one GitHub runner {self.runner_name(repo)}, found {len(matches)}"
            )
        return matches[0]

    def audit(self, org, repo, require_idle=False):
        errors = []
        repo_dir = self.repo_dir(repo)
        unit = self.unit_name(org, repo)
        marker = repo_dir / ".service"
        if not repo_dir.is_dir() or not marker.is_file():
            return [f"runner directory or .service missing: {repo_dir}"]
        try:
            recorded = marker.read_text(encoding="utf-8").strip()
        except OSError as exc:
            return [f"cannot read .service: {exc}"]
        if recorded != unit:
            errors.append(f"unit name mismatch: {recorded!r} != {unit!r}")
        try:
            metadata = self.service_metadata(unit)
            expected_fragment = (self.systemd_root / unit).resolve()
            if metadata.load_state != "loaded":
                errors.append(f"LoadState={metadata.load_state}")
            if metadata.active_state != "active":
                errors.append(f"ActiveState={metadata.active_state}")
            if metadata.sub_state != "running":
                errors.append(f"SubState={metadata.sub_state}")
            if metadata.main_pid <= 0:
                errors.append(f"MainPID={metadata.main_pid}")
            if metadata.fragment_path != expected_fragment:
                errors.append("FragmentPath mismatch")
            if metadata.exec_start != (repo_dir / "runsvc.sh").resolve():
                errors.append("ExecStart mismatch")
            if metadata.user != self.user:
                errors.append(f"User={metadata.user!r}")
            if not metadata.control_group.startswith("/"):
                errors.append("ControlGroup is invalid")
            main_process = self.read_process(metadata.main_pid)
            if not self.main_process_matches(
                main_process, repo_dir, metadata.control_group
            ):
                errors.append("MainPID process identity does not match the service")
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
            metadata = None
            errors.append(f"systemd metadata failure: {exc}")
        listeners = self.listeners(repo_dir)
        if len(listeners) != 1:
            errors.append(f"expected exactly one listener, found {len(listeners)}")
        elif metadata and not self.in_control_group(
            listeners[0], metadata.control_group
        ):
            errors.append("listener is outside the service ControlGroup")
        try:
            runner = self.github_runner(org, repo)
            if runner.get("status") != "online":
                errors.append("GitHub runner is not online")
            if require_idle and runner.get("busy") is not False:
                errors.append("GitHub runner is busy")
            labels = {
                item["name"]
                for item in runner.get("labels", [])
                if isinstance(item, dict) and isinstance(item.get("name"), str)
            }
            if labels != self.expected_labels(org, repo):
                errors.append(f"label mismatch: {sorted(labels)}")
        except (
            OSError,
            RuntimeError,
            TypeError,
            ValueError,
            json.JSONDecodeError,
        ) as exc:
            errors.append(f"GitHub runner query failed: {exc}")
        return errors

    def same_process(self, identity):
        return self.read_process(identity.pid) == identity

    def wait_gone(self, identity, timeout, interval=0.1):
        deadline = self.monotonic() + timeout
        while self.monotonic() < deadline:
            if not self.same_process(identity):
                return True
            self.sleep(interval)
        return not self.same_process(identity)

    def terminate_identity(self, identity, term_timeout=5.0, kill_timeout=2.0):
        if not self.same_process(identity):
            return True
        self.signal_process(identity.pid, signal.SIGTERM)
        if self.wait_gone(identity, term_timeout):
            return True
        if not self.same_process(identity):
            return True
        self.signal_process(identity.pid, signal.SIGKILL)
        return self.wait_gone(identity, kill_timeout)

    def _run_service_script(self, repo_dir, action):
        result = self.command(
            ["./svc.sh", action],
            cwd=repo_dir,
            sudo=True,
            check=False,
        )
        return result.returncode

    def _prove_unit_inactive(self, unit):
        load_state, active_state = self.unit_state(unit)
        if load_state == "not-found":
            return True
        return active_state in {"inactive", "failed"}

    def cleanup_installation(self, org, repo, remove_directory=True):
        repo_dir = self.repo_dir(repo)
        unit = self.unit_name(org, repo)
        marker = repo_dir / ".service"
        if marker.exists():
            recorded = marker.read_text(encoding="utf-8").strip()
            if recorded != unit:
                raise RuntimeError(f"refusing unrecognized service marker {recorded!r}")
        if repo_dir.exists() and (repo_dir / "svc.sh").is_file():
            stop_rc = self._run_service_script(repo_dir, "stop")
            if not self._prove_unit_inactive(unit):
                raise RuntimeError(f"service stop failed (exit {stop_rc})")
            uninstall_rc = self._run_service_script(repo_dir, "uninstall")
            load_state, _ = self.unit_state(unit)
            if uninstall_rc != 0 and load_state == "loaded":
                raise RuntimeError(f"service uninstall failed (exit {uninstall_rc})")
        systemd_root = self.systemd_root.resolve()
        unit_path = systemd_root / unit
        if unit_path.parent != systemd_root:
            raise RuntimeError("systemd unit path escapes configured root")
        if unit_path.exists():
            self.command(["systemctl", "stop", unit], sudo=True, check=False)
            if not self._prove_unit_inactive(unit):
                raise RuntimeError("stale unit could not be stopped")
            disabled = self.command(
                ["systemctl", "disable", unit], sudo=True, check=False
            )
            if disabled.returncode != 0:
                raise RuntimeError(
                    f"stale unit disable failed (exit {disabled.returncode})"
                )
            self.command(["unlink", str(unit_path)], sudo=True, check=True)
            self.command(["systemctl", "daemon-reload"], sudo=True, check=True)
        for identity in self.owned_processes(repo_dir):
            if not self.terminate_identity(identity):
                raise RuntimeError(
                    f"runner process {identity.pid} survived SIGTERM/SIGKILL"
                )
        if not self._prove_unit_inactive(unit):
            raise RuntimeError("unit remains active after cleanup")
        if self.owned_processes(repo_dir):
            raise RuntimeError("runner-owned process remains after cleanup")
        if remove_directory and repo_dir.exists():
            self._remove_runner_tree(repo, repo_dir)

    def _secret_command(self, command, cwd):
        result = self.command(command, cwd=cwd, check=False)
        if result.returncode != 0:
            raise RuntimeError("runner credential command failed")

    def _install_new_runner(self, org, repo, repo_dir, archive):
        repo_dir.mkdir(parents=True, exist_ok=False)
        self.command(["tar", "-xzf", str(archive), "-C", str(repo_dir)])
        token = self.registration_token(org, repo)
        self._secret_command(
            [
                "./config.sh",
                "--url",
                f"https://github.com/{org}/{repo}",
                "--token",
                token,
                "--name",
                self.runner_name(repo),
                "--labels",
                f"{repo},{org}",
                "--unattended",
                "--replace",
            ],
            repo_dir,
        )
        self.command(["./svc.sh", "install", self.user], cwd=repo_dir, sudo=True)
        self.command(["./svc.sh", "start"], cwd=repo_dir, sudo=True)

    def wait_for_audit(self, org, repo, timeout=30.0, interval=1.0):
        deadline = self.monotonic() + timeout
        last_errors = []
        while self.monotonic() < deadline:
            last_errors = self.audit(org, repo, require_idle=False)
            if not last_errors:
                return []
            self.sleep(interval)
        return last_errors or self.audit(org, repo, require_idle=False)

    def setup(self, org, repo):
        existing = [
            runner
            for runner in self.github.runners(org, repo)
            if runner.get("name") == self.runner_name(repo)
        ]
        if len(existing) > 1:
            raise RuntimeError("duplicate GitHub runner registrations must be resolved")
        if existing and existing[0].get("busy") is not False:
            raise RuntimeError("refusing to reconfigure a busy runner")
        repo_dir = self.repo_dir(repo)
        backup = self._recovery_backup(repo)
        if backup.exists() or backup.is_symlink():
            raise RuntimeError(f"recovery backup already exists: {backup}")
        version = self.latest_version()
        archive = self.downloader(version, self.base_dir / ".cache")
        had_old = repo_dir.exists()
        self.cleanup_installation(org, repo, remove_directory=False)
        if had_old:
            self.rename(repo_dir, backup)
        try:
            self._install_new_runner(org, repo, repo_dir, archive)
            errors = self.wait_for_audit(org, repo)
            if errors:
                raise RuntimeError(  # noqa: TRY301 - rollback handles audit failure
                    "post-setup audit failed: " + "; ".join(errors)
                )
        except Exception:  # rollback must run for every setup failure
            if repo_dir.exists():
                try:
                    self.cleanup_installation(org, repo, remove_directory=True)
                except Exception as cleanup_error:  # report a safe combined failure
                    raise RuntimeError(
                        "setup failed and rollback cleanup also failed"
                    ) from cleanup_error
            if had_old and backup.exists() and not repo_dir.exists():
                self.rename(backup, repo_dir)
            raise
        if backup.exists():
            self._remove_runner_tree(repo, backup)

    def cleanup_backup(self, org, repo):
        backup = self._recovery_backup(repo)
        if not backup.exists() and not backup.is_symlink():
            return
        errors = self.audit(org, repo)
        if errors:
            raise RuntimeError(
                "refusing recovery-backup removal while runner audit fails: "
                + "; ".join(errors)
            )
        self._remove_runner_tree(repo, backup)

    def remove(self, org, repo):
        repo_dir = self.repo_dir(repo)
        if not repo_dir.exists():
            return
        self.cleanup_installation(org, repo, remove_directory=False)
        config = repo_dir / "config.sh"
        if config.is_file():
            token = self.removal_token(org, repo)
            self._secret_command(["./config.sh", "remove", "--token", token], repo_dir)
        self._remove_runner_tree(repo, repo_dir)

    def stop(self, org, repo):
        repo_dir = self.repo_dir(repo)
        if not (repo_dir / "svc.sh").is_file():
            raise RuntimeError(f"runner service script missing: {repo_dir}")
        rc = self._run_service_script(repo_dir, "stop")
        if not self._prove_unit_inactive(self.unit_name(org, repo)):
            raise RuntimeError(f"service stop failed (exit {rc})")

    def restart(self, org, repo):
        repo_dir = self.repo_dir(repo)
        if not (repo_dir / "svc.sh").is_file():
            raise RuntimeError(f"runner service script missing: {repo_dir}")
        self.command(["./svc.sh", "restart"], cwd=repo_dir, sudo=True)
        errors = self.wait_for_audit(org, repo)
        if errors:
            raise RuntimeError("post-restart audit failed: " + "; ".join(errors))


def print_audit(manager, org, repo):
    errors = manager.audit(org, repo)
    if errors:
        for error in errors:
            print(f"[AUDIT ERROR] {error}", file=sys.stderr)
        return False
    print(f"[OK] {org}/{repo} runner is healthy")
    return True


def main(argv=None):  # noqa: PLR0911 - each CLI action has a distinct exit contract
    parser = argparse.ArgumentParser(
        description="Manage repository-level GitHub Actions runners"
    )
    parser.add_argument("--org", default=DEFAULT_ORG)
    parser.add_argument("--base-dir", type=Path, default=DEFAULT_BASE_DIR)
    parser.add_argument("--proc-root", type=Path, default=DEFAULT_PROC_ROOT)
    parser.add_argument("--systemd-root", type=Path, default=DEFAULT_SYSTEMD_ROOT)
    parser.add_argument("--user", default=DEFAULT_USER)
    parser.add_argument(
        "--governance-path", type=Path, default=DOCS_CONTROL_GOVERNANCE_PATH
    )
    subparsers = parser.add_subparsers(dest="action", required=True)
    for action in (
        "setup",
        "audit",
        "restart",
        "stop",
        "remove",
        "cleanup-backup",
    ):
        command_parser = subparsers.add_parser(action)
        command_parser.add_argument("repo")
    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("repo", nargs="?")
    setup_all = subparsers.add_parser("setup-governed", aliases=["setup-all"])
    setup_all.add_argument("-y", "--yes", action="store_true")
    subparsers.add_parser("clean-ungoverned")
    subparsers.add_parser("health-check")
    args = parser.parse_args(argv)
    manager = RunnerManager(
        args.base_dir,
        args.proc_root,
        args.systemd_root,
        user=args.user,
    )
    governed = load_governed_repos(args.governance_path)
    try:
        if args.action in {
            "setup",
            "audit",
            "status",
            "restart",
            "stop",
            "remove",
            "cleanup-backup",
        }:
            if args.repo is None:
                results = [print_audit(manager, args.org, repo) for repo in governed]
                return 0 if all(results) else 1
            if args.action == "setup" and args.repo not in governed:
                raise RuntimeError(f"repository {args.repo!r} is not governed")  # noqa: TRY301
            if args.action in {"audit", "status"}:
                return 0 if print_audit(manager, args.org, args.repo) else 1
            action = args.action.replace("-", "_")
            getattr(manager, action)(args.org, args.repo)
            return 0
        if args.action in {"setup-governed", "setup-all"}:
            if not args.yes:
                answer = input(f"Set up {len(governed)} governed runners? [y/N] ")
                if answer.strip().lower() != "y":
                    return 0
            for repo in governed:
                manager.setup(args.org, repo)
            return 0
        if args.action == "clean-ungoverned":
            if not args.base_dir.exists():
                return 0
            for entry in args.base_dir.iterdir():
                if (
                    entry.is_dir()
                    and not entry.name.startswith(".")
                    and entry.name not in governed
                ):
                    manager.remove(args.org, entry.name)
            return 0
        if args.action == "health-check":
            results = [print_audit(manager, args.org, repo) for repo in governed]
            return 0 if all(results) else 1
    except Exception as exc:
        print(f"runner management failed: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
