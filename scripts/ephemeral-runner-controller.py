#!/usr/bin/env python3
"""Run repository-scoped GitHub Actions runners in one-job Podman sandboxes."""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

DEFAULT_ORG = "f5-sales-demo"
DEFAULT_BASE_DIR = Path("/data/actions-runners/f5-sales-demo-ephemeral")
DEFAULT_POLICY = (
    Path(__file__).resolve().parent.parent
    / ".github/config/self-hosted-runner-policy.json"
)
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_.-]+")
PROFILE_RE = re.compile(r"[a-z0-9][a-z0-9.-]*")
IMAGE_RE = re.compile(r"ghcr\.io/f5-sales-demo/[a-z0-9._-]+@sha256:[0-9a-f]{64}")


class FleetError(RuntimeError):
    """A fail-closed runner fleet error."""


def run_command(command, *, input_text=None, check=True, capture=True):
    """Run an argv-only command without a shell."""
    return subprocess.run(  # noqa: S603 - every caller passes an argv list
        command,
        check=check,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def validate_name(value, pattern, description):
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise FleetError(f"invalid {description}: {value!r}")
    return value


def repository_name(full_name, org=DEFAULT_ORG):
    prefix = f"{org}/"
    if not isinstance(full_name, str) or not full_name.startswith(prefix):
        raise FleetError(f"repository must belong to {org}: {full_name!r}")
    return validate_name(full_name[len(prefix) :], REPOSITORY_RE, "repository")


@dataclass(frozen=True)
class Profile:
    name: str
    image: str
    labels: tuple[str, ...]
    memory: str
    cpus: str
    pids_limit: int
    container_socket: bool


@dataclass(frozen=True)
class RepositorySpec:
    full_name: str
    name: str
    account: str
    replicas: int
    profiles: tuple[Profile, ...]

    def account_for(self, profile):
        prefix = "ghb" if profile.container_socket else "gha"
        return f"{prefix}-{self.name}"


class FleetPolicy:
    """Strict schema-v2 fleet policy consumed by runtime and workflow audits."""

    TOP_LEVEL = {
        "schema_version",
        "defaults",
        "profiles",
        "hosted_exceptions",
        "repositories",
    }
    DEFAULT_FIELDS = {"replicas", "profile"}
    PROFILE_FIELDS = {
        "image",
        "labels",
        "memory",
        "cpus",
        "pids_limit",
        "container_socket",
    }
    REPOSITORY_RUNTIME_FIELDS = {"replicas", "profiles"}

    def __init__(self, path):
        self.path = Path(path)
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise FleetError(f"cannot read policy {self.path}: {exc}") from exc
        if not isinstance(raw, dict) or set(raw) != self.TOP_LEVEL:
            raise FleetError(
                f"policy top-level fields must equal {sorted(self.TOP_LEVEL)}"
            )
        if raw["schema_version"] != 2:
            raise FleetError("runner fleet requires policy schema_version 2")
        self.raw = raw
        self.defaults = self._defaults(raw["defaults"])
        self.profiles = self._profiles(raw["profiles"])
        if not isinstance(raw["hosted_exceptions"], dict):
            raise FleetError("hosted_exceptions must be an object")
        if not isinstance(raw["repositories"], dict) or not raw["repositories"]:
            raise FleetError("repositories must be a non-empty object")

    @classmethod
    def _defaults(cls, value):
        if not isinstance(value, dict) or set(value) != cls.DEFAULT_FIELDS:
            raise FleetError(f"defaults fields must equal {sorted(cls.DEFAULT_FIELDS)}")
        replicas = value["replicas"]
        profile = value["profile"]
        if not isinstance(replicas, int) or not 1 <= replicas <= 8:
            raise FleetError("defaults.replicas must be between 1 and 8")
        validate_name(profile, PROFILE_RE, "default profile")
        return value

    @classmethod
    def _profiles(cls, value):
        if not isinstance(value, dict) or not value:
            raise FleetError("profiles must be a non-empty object")
        profiles = {}
        for name, spec in value.items():
            validate_name(name, PROFILE_RE, "profile")
            if not isinstance(spec, dict) or set(spec) != cls.PROFILE_FIELDS:
                raise FleetError(
                    f"profile {name!r} fields must equal {sorted(cls.PROFILE_FIELDS)}"
                )
            labels = spec["labels"]
            if (
                not isinstance(labels, list)
                or not labels
                or not all(isinstance(item, str) and item for item in labels)
                or len(labels) != len(set(labels))
            ):
                raise FleetError(f"profile {name!r} labels must be unique strings")
            if "self-hosted" in labels or "ubuntu-latest" in labels:
                raise FleetError(f"profile {name!r} contains a reserved label")
            if not isinstance(spec["image"], str) or not IMAGE_RE.fullmatch(
                spec["image"]
            ):
                raise FleetError(
                    f"profile {name!r} image must be an approved GHCR digest"
                )
            if not isinstance(spec["memory"], str) or not spec["memory"]:
                raise FleetError(f"profile {name!r} memory is required")
            if not isinstance(spec["cpus"], str) or not spec["cpus"]:
                raise FleetError(f"profile {name!r} cpus is required")
            if not isinstance(spec["pids_limit"], int) or spec["pids_limit"] < 64:
                raise FleetError(f"profile {name!r} pids_limit must be at least 64")
            if not isinstance(spec["container_socket"], bool):
                raise FleetError(f"profile {name!r} container_socket must be boolean")
            profiles[name] = Profile(
                name=name,
                image=spec["image"],
                labels=tuple(labels),
                memory=spec["memory"],
                cpus=spec["cpus"],
                pids_limit=spec["pids_limit"],
                container_socket=spec["container_socket"],
            )
        return profiles

    def repository(self, full_name, org=DEFAULT_ORG):
        name = repository_name(full_name, org)
        try:
            raw = self.raw["repositories"][full_name]
        except KeyError as exc:
            raise FleetError(f"repository is not governed: {full_name}") from exc
        if not isinstance(raw, dict):
            raise FleetError(f"repository policy must be an object: {full_name}")
        runtime = raw.get("runner", {})
        if (
            not isinstance(runtime, dict)
            or set(runtime) - self.REPOSITORY_RUNTIME_FIELDS
        ):
            raise FleetError(f"invalid runner override for {full_name}")
        replicas = runtime.get("replicas", self.defaults["replicas"])
        if not isinstance(replicas, int) or not 1 <= replicas <= 8:
            raise FleetError(f"invalid replica count for {full_name}")
        profile_names = runtime.get("profiles", [self.defaults["profile"]])
        if (
            not isinstance(profile_names, list)
            or not profile_names
            or not all(isinstance(item, str) for item in profile_names)
            or len(profile_names) != len(set(profile_names))
        ):
            raise FleetError(f"invalid profiles for {full_name}")
        try:
            profiles = tuple(self.profiles[item] for item in profile_names)
        except KeyError as exc:
            raise FleetError(f"unknown profile for {full_name}: {exc.args[0]}") from exc
        account = f"gha-{name}"
        builder_account = f"ghb-{name}"
        if max(len(account), len(builder_account)) > 31:
            raise FleetError(
                f"repository name is too long for a service account: {name}"
            )
        return RepositorySpec(full_name, name, account, replicas, profiles)

    def governed(self):
        return tuple(sorted(self.raw["repositories"]))


class GitHubClient:
    def __init__(self, token, api_url="https://api.github.com", opener=None):
        if not token:
            raise FleetError("GitHub credential is empty")
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.opener = opener or urllib.request.urlopen

    def request(self, method, path, payload=None):
        body = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            self.api_url + path,
            data=body,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "f5-sales-demo-ephemeral-runner-controller",
            },
        )
        try:
            with self.opener(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            raise FleetError(f"GitHub API {method} {path} returned {exc.code}") from exc

    def registration_token(self, full_name):
        response = self.request(
            "POST", f"/repos/{full_name}/actions/runners/registration-token"
        )
        token = response.get("token")
        if not isinstance(token, str) or not token:
            raise FleetError("GitHub returned an empty registration token")
        return token

    def runners(self, full_name):
        response = self.request(
            "GET", f"/repos/{full_name}/actions/runners?per_page=100"
        )
        runners = response.get("runners")
        if not isinstance(runners, list):
            raise FleetError("GitHub returned a malformed runner inventory")
        return runners


class EphemeralController:
    def __init__(self, policy, github, base_dir=DEFAULT_BASE_DIR, command=run_command):
        self.policy = policy
        self.github = github
        self.base_dir = Path(base_dir)
        self.command = command
        self.stopping = False

    def state_dir(self, spec, profile, slot):
        path = self.base_dir / "diagnostics" / spec.name / profile.name / str(slot)
        base = self.base_dir.resolve()
        resolved = path.resolve()
        if base not in resolved.parents:
            raise FleetError("runner state path escapes base directory")
        return path

    @staticmethod
    def container_name(spec, profile, slot):
        return f"gha-{spec.name}-{profile.name}-{slot}"

    @staticmethod
    def expected_labels(spec, profile):
        return {"self-hosted", "Linux", "X64", spec.name, *profile.labels}

    @staticmethod
    def runtime_dir(spec, profile):
        if profile.container_socket:
            return Path("/run/f5-actions-podman") / spec.name
        return Path("/run/f5-actions-runner") / spec.account_for(profile)

    def prepare_account(self, spec, profile):
        account = spec.account_for(profile)
        runtime = self.runtime_dir(spec, profile)
        self.command(
            [
                "install",
                "-d",
                "-m",
                "0700",
                "-o",
                account,
                "-g",
                account,
                str(runtime),
            ]
        )
        return account, runtime

    def podman_prefix(self, account, runtime):
        validate_name(account, REPOSITORY_RE, "service account")
        return [
            "runuser",
            "--user",
            account,
            "--",
            "env",
            f"HOME=/data/actions-runners/users/{account}",
            f"XDG_RUNTIME_DIR={runtime}",
            "podman",
        ]

    def cleanup(self, spec, profile, slot):
        name = self.container_name(spec, profile, slot)
        account, runtime = self.prepare_account(spec, profile)
        prefix = self.podman_prefix(account, runtime)
        self.command([*prefix, "rm", "--force", "--ignore", name], check=False)

    def podman_command(self, spec, profile, slot):
        state = self.state_dir(spec, profile, slot)
        account, runtime = self.prepare_account(spec, profile)
        self.command(
            [
                "install",
                "-d",
                "-m",
                "0700",
                "-o",
                account,
                "-g",
                account,
                str(state),
            ]
        )
        name = self.container_name(spec, profile, slot)
        labels = ",".join(
            sorted(
                self.expected_labels(spec, profile) - {"self-hosted", "Linux", "X64"}
            )
        )
        command = [
            *self.podman_prefix(account, runtime),
            "run",
            "--interactive",
            "--pull=missing",
            "--userns=keep-id:uid=1001,gid=1001",
            "--stop-timeout",
            "300",
            "--rm",
            "--name",
            name,
            "--read-only",
            "--cap-drop=all",
            "--security-opt=no-new-privileges",
            "--pids-limit",
            str(profile.pids_limit),
            "--memory",
            profile.memory,
            "--cpus",
            profile.cpus,
            "--network",
            "slirp4netns:allow_host_loopback=false",
            "--tmpfs",
            "/tmp:rw,nosuid,nodev,size=2g",
            "--tmpfs",
            "/home/runner:rw,nosuid,nodev,size=4g",
            "--tmpfs",
            "/runner-runtime:rw,nosuid,nodev,size=20g",
            "--volume",
            f"{state}:/runner-runtime/_diag:rw",
            "--env",
            f"RUNNER_REPOSITORY={spec.full_name}",
            "--env",
            f"RUNNER_NAME={name}-{secrets.token_hex(4)}",
            "--env",
            f"RUNNER_LABELS={labels}",
            "--label",
            f"f5.runner.repository={spec.full_name}",
            "--label",
            f"f5.runner.profile={profile.name}",
        ]
        if profile.container_socket:
            socket = f"/run/f5-actions-podman/{spec.name}/podman.sock"
            command.extend(
                [
                    "--volume",
                    f"{socket}:/run/podman/podman.sock:rw",
                    "--env",
                    "DOCKER_HOST=unix:///run/podman/podman.sock",
                    "--env",
                    "CONTAINER_HOST=unix:///run/podman/podman.sock",
                    "--env",
                    "RUNNER_CONTAINER_TOOLS=1",
                ]
            )
        command.append(profile.image)
        return command

    def run_once(self, full_name, profile_name, slot=0):
        spec = self.policy.repository(full_name)
        profile = next(
            (item for item in spec.profiles if item.name == profile_name), None
        )
        if profile is None:
            raise FleetError(f"profile {profile_name!r} is not enabled for {full_name}")
        if not 0 <= slot < spec.replicas:
            raise FleetError(f"slot must be between 0 and {spec.replicas - 1}")
        self.cleanup(spec, profile, slot)
        token = self.github.registration_token(full_name)
        try:
            result = self.command(
                self.podman_command(spec, profile, slot),
                input_text=token + "\n",
                check=False,
                capture=False,
            )
            return result.returncode
        finally:
            token = ""  # Shorten the credential lifetime.
            self.cleanup(spec, profile, slot)

    def serve(self, full_name, profile_name, slot=0, backoff=5):
        def stop(_signum, _frame):
            self.stopping = True

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        while not self.stopping:
            try:
                code = self.run_once(full_name, profile_name, slot)
            except (FleetError, OSError, subprocess.SubprocessError) as exc:
                print(f"runner cycle failed: {exc}", file=sys.stderr, flush=True)
                code = 1
            if self.stopping:
                break
            if code != 0:
                time.sleep(backoff)
        return 0

    def audit(self, full_name):
        spec = self.policy.repository(full_name)
        errors = []
        actual = self.github.runners(full_name)
        expected_names = {
            self.container_name(spec, profile, slot)
            for profile in spec.profiles
            for slot in range(spec.replicas)
        }
        for runner in actual:
            name = runner.get("name")
            if not isinstance(name, str) or not name.startswith(f"gha-{spec.name}-"):
                continue
            base = name.rsplit("-", 1)[0]
            if base not in expected_names:
                errors.append(f"unexpected managed runner: {name}")
            labels = {item.get("name") for item in runner.get("labels", [])}
            if "ubuntu-latest" in labels:
                errors.append(f"reserved label on {name}: ubuntu-latest")
        return errors


def token_from_environment():
    path = os.environ.get("RUNNER_FLEET_GITHUB_TOKEN_FILE")
    if path:
        try:
            return Path(path).read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise FleetError(f"cannot read GitHub credential file: {exc}") from exc
    raise FleetError("set RUNNER_FLEET_GITHUB_TOKEN_FILE to a protected credential")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--base-dir", type=Path, default=DEFAULT_BASE_DIR)
    subparsers = parser.add_subparsers(dest="action", required=True)
    for action in ("once", "serve"):
        sub = subparsers.add_parser(action)
        sub.add_argument("repository")
        sub.add_argument("--profile", default="ubuntu-24.04")
        sub.add_argument("--slot", type=int, default=0)
    audit = subparsers.add_parser("audit")
    audit.add_argument("repository", nargs="?")
    args = parser.parse_args(argv)
    try:
        policy = FleetPolicy(args.policy)
        github = GitHubClient(token_from_environment())
        controller = EphemeralController(policy, github, args.base_dir)
        if args.action == "once":
            return controller.run_once(args.repository, args.profile, args.slot)
        if args.action == "serve":
            return controller.serve(args.repository, args.profile, args.slot)
        repositories = [args.repository] if args.repository else policy.governed()
        failed = False
        for repository in repositories:
            errors = controller.audit(repository)
            if errors:
                failed = True
                for error in errors:
                    print(f"[AUDIT ERROR] {repository}: {error}", file=sys.stderr)
            else:
                print(f"[OK] {repository}")
        return 1 if failed else 0
    except (FleetError, OSError, subprocess.SubprocessError) as exc:
        print(f"runner fleet failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
