#!/usr/bin/env python3
# pylint: disable=invalid-name,too-many-lines
"""Run repository-scoped GitHub Actions runners in one-job Docker sandboxes."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

DEFAULT_ORG = "f5-sales-demo"
HOST_ENTRYPOINT = Path("/opt/f5-actions-runner/runner-entrypoint.sh")
HOST_TOOL_CACHE_INITIALIZER = Path(
    "/opt/f5-actions-runner/prepare-runner-tool-cache.sh"
)
DEFAULT_BASE_DIR = Path("/data/actions-runners/f5-sales-demo-ephemeral")
DEFAULT_POLICY = (
    Path(__file__).resolve().parent.parent
    / ".github/config/self-hosted-runner-policy.json"
)
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_.-]+")
PROFILE_RE = re.compile(r"[a-z0-9][a-z0-9.-]*")
IMAGE_RE = re.compile(r"ghcr\.io/f5-sales-demo/[a-z0-9._-]+@sha256:[0-9a-f]{64}")
MEMORY_RE = re.compile(r"[1-9][0-9]*[KMGTPEkmgtpe]")
CPU_RE = re.compile(r"[1-9][0-9]*(?:\.[0-9]+)?")
VERSION_RE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
CONTAINER_ID_RE = re.compile(r"[0-9a-f]{64}")
HOST_DOCKER_SOCKET = "/run/f5-actions-runner/container-build/docker.sock"
RUNNER_DOCKER_SOCKET = "/run/docker.sock"
ROOTLESS_DOCKER_DATA_ROOT = "/data/actions-runners/container-build-docker"
ROOTLESS_DOCKER_CACHE_MAX = "20g"
CONTAINER_BUILD_SLICE = "f5-actions-container-build.slice"
MINIMUM_DOCKER_VERSION = "29.2.1"
TARGET_DOCKER_VERSION = "29.7.2"
TRANSIENT_INSPECT_ATTEMPTS = 8
TRANSIENT_INSPECT_INITIAL_DELAY_SECONDS = 0.1
TRANSIENT_INSPECT_MAX_DELAY_SECONDS = 2.0
TRANSIENT_INSPECT_MAX_TOTAL_SECONDS = 8.0
DOCKER_COMMAND_TIMEOUT_SECONDS = 60
REGISTRATION_RATE_LIMIT_FALLBACK_SECONDS = 300
REGISTRATION_RECOVERY_JITTER_SECONDS = 120


DOCS_ARC_COHORT = frozenset(
    f"f5-sales-demo/{name}"
    for name in (
        "docs",
        "docs-builder",
        "docs-icons",
        "docs-theme",
        "i18n-core",
        "starlight-llms-txt",
    )
)
MANAGED_ARC_COHORT = frozenset(
    f"f5-sales-demo/{name}"
    for name in (
        "administration",
        "api-protection",
        "api-specs",
        "apt-repo",
        "bot-advanced",
        "bot-standard",
        "cdn",
        "cdn-simulator",
        "console",
        "csd",
        "ddos",
        "demo-resource-template",
        "demo-resources",
        "devcontainer",
        "dns",
        "docs-control",
        "marketplace",
        "marketplace-claude-code",
        "mcn",
        "nginx",
        "observability",
        "origin-server",
        "starlight-mega-menu",
        "traffic-generator",
        "vscode-xcsh",
        "waf",
        "was",
        "webapp-api-protection",
        "xcsh-action",
        "xcsh-chrome-extension",
    )
)
ARC_SHARED_CONTRACTS = (
    (
        DOCS_ARC_COHORT,
        {
            "socketless": {
                "label": "docs-socketless",
                "profile": "ubuntu-24.04",
            },
            "container-build": {
                "label": "docs-container-build",
                "profile": "container-build",
            },
        },
    ),
    (
        MANAGED_ARC_COHORT,
        {
            "socketless": {
                "label": "managed-socketless",
                "profile": "ubuntu-24.04",
            },
            "container-build": {
                "label": "managed-container-build",
                "profile": "container-build",
            },
        },
    ),
    (
        frozenset({"f5-sales-demo/api-specs-enriched"}),
        {
            "socketless": {
                "label": "managed-socketless",
                "profile": "ubuntu-24.04",
            },
            "container-build": {
                "label": "managed-container-build",
                "profile": "container-build",
            },
            "compute": {
                "label": "api-specs-enriched-compute",
                "profile": "ubuntu-24.04",
            },
        },
    ),
    (
        frozenset({"f5-sales-demo/terraform-provider-xcsh"}),
        {
            "socketless": {
                "label": "managed-socketless",
                "profile": "ubuntu-24.04",
            },
            "container-build": {
                "label": "managed-container-build",
                "profile": "container-build",
            },
            "compute": {
                "label": "terraform-provider-xcsh-compute",
                "profile": "ubuntu-24.04",
            },
        },
    ),
    (
        frozenset({"f5-sales-demo/xcsh"}),
        {
            "socketless": {
                "label": "xcsh-socketless",
                "profile": "ubuntu-24.04",
            },
            "container-build": {
                "label": "xcsh-container-build",
                "profile": "container-build",
            },
            "compute": {
                "label": "xcsh-compute",
                "profile": "ubuntu-24.04",
            },
        },
    ),
)
RESERVED_ARC_LABELS = frozenset(
    {
        "api-specs-enriched-compute",
        "docs-container-build",
        "docs-socketless",
        "managed-container-build",
        "managed-socketless",
        "terraform-provider-xcsh-compute",
        "xcsh-container-build",
        "xcsh-compute",
        "xcsh-socketless",
    }
)


def expected_arc_scale_sets(repository):
    """Return the exact shared-label contract for a governed ARC cohort."""
    for cohort, contract in ARC_SHARED_CONTRACTS:
        if repository in cohort:
            return contract
    return None


class FleetError(RuntimeError):
    """A fail-closed runner fleet error."""


class GitHubRateLimitError(FleetError):
    """A GitHub API rate-limit response with its earliest safe retry time."""

    def __init__(self, kind, retry_at):
        self.kind = kind
        self.retry_at = retry_at
        super().__init__(f"GitHub {kind} rate limit until {retry_at}")


class StopRequestedError(Exception):
    """Interrupt a blocking runner cycle for prompt systemd shutdown."""


def run_command(command, *, input_text=None, check=True, capture=True):
    """Run an argv-only command without a shell."""
    timeout = DOCKER_COMMAND_TIMEOUT_SECONDS if command[:1] == ["docker"] else None
    return subprocess.run(  # noqa: S603 - every caller passes an argv list
        command,
        check=check,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        timeout=timeout,
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


def version_tuple(value):
    if not isinstance(value, str):
        raise FleetError(f"invalid Docker version: {value!r}")
    match = VERSION_RE.fullmatch(value.strip())
    if not match:
        raise FleetError(f"invalid Docker version: {value!r}")
    return tuple(int(component) for component in match.groups())


def memory_bytes(value):
    multipliers = {
        "k": 1024,
        "m": 1024**2,
        "g": 1024**3,
        "t": 1024**4,
        "p": 1024**5,
        "e": 1024**6,
    }
    if not isinstance(value, str) or not MEMORY_RE.fullmatch(value):
        raise FleetError(f"invalid memory limit: {value!r}")
    return int(value[:-1]) * multipliers[value[-1].lower()]


@dataclass(frozen=True)
class Profile:
    name: str
    image: str
    labels: tuple[str, ...]
    memory: str
    cpus: str
    pids_limit: int
    stop_timeout: int
    network: str
    docker_socket: bool


@dataclass(frozen=True)
class DockerPolicy:
    host_socket: str
    runner_socket: str
    data_root: str
    cache_max: str
    cgroup_parent: str
    minimum_version: str
    target_version: str


@dataclass(frozen=True)
class DispatcherPolicy:
    repositories: tuple[str, ...]
    memory: str
    cpus: str
    standard_runners: int
    container_build_runners: int
    request_budget: int


@dataclass(frozen=True)
class RepositorySpec:
    full_name: str
    name: str
    replicas: int
    profiles: tuple[Profile, ...]

    standby_profiles: tuple[Profile, ...]


class FleetPolicy:
    """Strict schema-v4 fleet policy consumed by runtime and workflow audits."""

    TOP_LEVEL = {
        "schema_version",
        "docker",
        "dispatcher",
        "defaults",
        "profiles",
        "hosted_exceptions",
        "repositories",
    }
    DEFAULT_FIELDS = {"replicas", "profile", "standby_profiles"}
    DOCKER_FIELDS = {
        "host_socket",
        "runner_socket",
        "data_root",
        "cache_max",
        "cgroup_parent",
        "minimum_version",
        "target_version",
    }
    DISPATCHER_FIELDS = {
        "repositories",
        "memory",
        "cpus",
        "standard_runners",
        "container_build_runners",
        "request_budget",
    }
    PROFILE_FIELDS = {
        "image",
        "labels",
        "memory",
        "cpus",
        "pids_limit",
        "stop_timeout",
        "network",
        "docker_socket",
    }
    REPOSITORY_RUNTIME_FIELDS = {"replicas", "profiles", "arc_scale_sets"}
    ARC_SCALE_SET_FIELDS = {"label", "profile"}

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
        if raw["schema_version"] != 4:
            raise FleetError("runner fleet requires policy schema_version 4")
        self.raw = raw
        self.docker = self._docker(raw["docker"])
        self.dispatcher = self._dispatcher(raw["dispatcher"])
        self.defaults = self._defaults(raw["defaults"])
        self.profiles = self._profiles(raw["profiles"])
        default_profile = self.profiles.get(self.defaults["profile"])
        builder_profile = self.profiles.get("container-build")
        if default_profile is None or default_profile.docker_socket:
            raise FleetError("the default runner profile must exist and be socketless")
        if (
            builder_profile is None
            or not builder_profile.docker_socket
            or builder_profile.labels != ("container-build",)
        ):
            raise FleetError("container-build must be the exact Docker socket profile")
        if any(
            profile.docker_socket and profile.name != "container-build"
            for profile in self.profiles.values()
        ):
            raise FleetError("only container-build may receive the Docker socket")
        if not isinstance(raw["hosted_exceptions"], dict):
            raise FleetError("hosted_exceptions must be an object")
        if not isinstance(raw["repositories"], dict) or not raw["repositories"]:
            raise FleetError("repositories must be a non-empty object")
        self.arc_scale_sets = {}
        for repository in raw["repositories"]:
            arc_scale_sets = self._repository_arc_scale_sets(repository)
            if arc_scale_sets is not None:
                self.arc_scale_sets[repository] = arc_scale_sets
                if repository in self.dispatcher.repositories:
                    raise FleetError(
                        f"ARC repository cannot use legacy dispatcher: {repository}"
                    )
                continue
            enabled = {profile.name for profile in self.repository(repository).profiles}
            if "container-build" not in enabled:
                raise FleetError(
                    f"container-build is required for governed repository {repository}"
                )
        if any(
            repository not in raw["repositories"]
            for repository in self.dispatcher.repositories
        ):
            raise FleetError("dispatcher repositories must be governed")

    @classmethod
    def _docker(cls, value):
        if not isinstance(value, dict) or set(value) != cls.DOCKER_FIELDS:
            raise FleetError(f"docker fields must equal {sorted(cls.DOCKER_FIELDS)}")
        expected = {
            "host_socket": HOST_DOCKER_SOCKET,
            "runner_socket": RUNNER_DOCKER_SOCKET,
            "data_root": ROOTLESS_DOCKER_DATA_ROOT,
            "cache_max": ROOTLESS_DOCKER_CACHE_MAX,
            "cgroup_parent": CONTAINER_BUILD_SLICE,
            "minimum_version": MINIMUM_DOCKER_VERSION,
            "target_version": TARGET_DOCKER_VERSION,
        }
        if value != expected:
            raise FleetError(f"docker policy must equal {expected!r}")
        return DockerPolicy(**value)

    @classmethod
    def _dispatcher(cls, value):
        if not isinstance(value, dict) or set(value) != cls.DISPATCHER_FIELDS:
            raise FleetError(
                f"dispatcher fields must equal {sorted(cls.DISPATCHER_FIELDS)}"
            )
        repositories = value["repositories"]
        if (
            not isinstance(repositories, list)
            or not all(
                isinstance(repository, str) and repository
                for repository in repositories
            )
            or repositories != sorted(set(repositories))
        ):
            raise FleetError("dispatcher repositories must be sorted unique names")
        if (
            value["memory"] != "48g"
            or value["cpus"] != "18"
            or value["standard_runners"] != 3
            or value["container_build_runners"] != 1
            or value["request_budget"] != 80
        ):
            raise FleetError("dispatcher capacity contract is invalid")
        return DispatcherPolicy(
            repositories=tuple(repositories),
            memory=value["memory"],
            cpus=value["cpus"],
            standard_runners=value["standard_runners"],
            container_build_runners=value["container_build_runners"],
            request_budget=value["request_budget"],
        )

    @classmethod
    def _defaults(cls, value):
        if not isinstance(value, dict) or set(value) != cls.DEFAULT_FIELDS:
            raise FleetError(f"defaults fields must equal {sorted(cls.DEFAULT_FIELDS)}")
        replicas = value["replicas"]
        profile = value["profile"]
        standby_profiles = value["standby_profiles"]
        if not isinstance(replicas, int) or not 1 <= replicas <= 8:
            raise FleetError("defaults.replicas must be between 1 and 8")
        validate_name(profile, PROFILE_RE, "default profile")
        if (
            not isinstance(standby_profiles, list)
            or not standby_profiles
            or not all(isinstance(item, str) for item in standby_profiles)
            or len(standby_profiles) != len(set(standby_profiles))
        ):
            raise FleetError("defaults.standby_profiles must be unique profile names")
        for standby_profile in standby_profiles:
            validate_name(standby_profile, PROFILE_RE, "standby profile")
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
            if not isinstance(spec["memory"], str) or not MEMORY_RE.fullmatch(
                spec["memory"]
            ):
                raise FleetError(f"profile {name!r} memory limit is invalid")
            if not isinstance(spec["cpus"], str) or not CPU_RE.fullmatch(spec["cpus"]):
                raise FleetError(f"profile {name!r} CPU limit is invalid")
            if not isinstance(spec["pids_limit"], int) or spec["pids_limit"] < 64:
                raise FleetError(f"profile {name!r} pids_limit must be at least 64")
            if (
                not isinstance(spec["stop_timeout"], int)
                or not 1 <= spec["stop_timeout"] <= 600
            ):
                raise FleetError(
                    f"profile {name!r} stop_timeout must be between 1 and 600"
                )
            if spec["network"] != "bridge":
                raise FleetError(f"profile {name!r} network must be bridge")
            if not isinstance(spec["docker_socket"], bool):
                raise FleetError(f"profile {name!r} docker_socket must be boolean")
            profiles[name] = Profile(
                name=name,
                image=spec["image"],
                labels=tuple(labels),
                memory=spec["memory"],
                cpus=spec["cpus"],
                pids_limit=spec["pids_limit"],
                stop_timeout=spec["stop_timeout"],
                network=spec["network"],
                docker_socket=spec["docker_socket"],
            )
        return profiles

    def _repository_arc_scale_sets(self, full_name):
        repository_name(full_name)
        try:
            repository_policy = self.raw["repositories"][full_name]
        except KeyError as exc:
            raise FleetError(f"repository is not governed: {full_name}") from exc
        if not isinstance(repository_policy, dict):
            raise FleetError(f"repository policy must be an object: {full_name}")
        runtime = repository_policy.get("runner", {})
        if (
            not isinstance(runtime, dict)
            or set(runtime) - self.REPOSITORY_RUNTIME_FIELDS
        ):
            raise FleetError(f"invalid runner override for {full_name}")
        scale_sets = runtime.get("arc_scale_sets")
        if scale_sets is None:
            return None
        if "replicas" in runtime or "profiles" in runtime:
            raise FleetError(
                f"ARC runner override cannot include legacy fields for {full_name}"
            )
        if not isinstance(scale_sets, dict) or not scale_sets:
            raise FleetError(
                f"ARC scale sets must be a non-empty object for {full_name}"
            )
        parsed = {}
        labels = set()
        for name, spec in scale_sets.items():
            validate_name(name, PROFILE_RE, "ARC scale-set route")
            if not isinstance(spec, dict) or set(spec) != self.ARC_SCALE_SET_FIELDS:
                raise FleetError(
                    f"ARC scale set {name!r} fields must equal "
                    f"{sorted(self.ARC_SCALE_SET_FIELDS)}"
                )
            label = validate_name(spec["label"], PROFILE_RE, "ARC scale-set label")
            profile_name = validate_name(
                spec["profile"], PROFILE_RE, "ARC scale-set profile"
            )
            if label in labels:
                raise FleetError(
                    f"duplicate ARC scale-set label for {full_name}: {label}"
                )
            if profile_name not in self.profiles:
                raise FleetError(
                    f"unknown ARC scale-set profile for {full_name}: {profile_name}"
                )
            labels.add(label)
            parsed[name] = {"label": label, "profile": profile_name}
        expected = expected_arc_scale_sets(full_name)
        if expected is not None and parsed != expected:
            raise FleetError(f"{full_name} ARC scale-set contract is invalid")
        if expected is None:
            leaked = labels & RESERVED_ARC_LABELS
            if leaked:
                message = "reserved ARC scale-set label escaped its cohort"
                raise FleetError(f"{message}: {sorted(leaked)}")
        return parsed

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
        if "arc_scale_sets" in runtime:
            self._repository_arc_scale_sets(full_name)
            raise FleetError(
                f"repository is managed by ARC, not the legacy fleet: {full_name}"
            )
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
        try:
            standby_profiles = tuple(
                self.profiles[item] for item in self.defaults["standby_profiles"]
            )
        except KeyError as exc:
            raise FleetError(f"unknown standby profile: {exc.args[0]}") from exc
        if any(profile not in profiles for profile in standby_profiles):
            raise FleetError(f"standby profile is not enabled for {full_name}")
        if any(profile.docker_socket for profile in standby_profiles):
            raise FleetError("standby profiles must be socketless")
        return RepositorySpec(full_name, name, replicas, profiles, standby_profiles)

    def governed(self):
        return tuple(sorted(self.raw["repositories"]))


class GitHubClient:
    def __init__(self, token, api_url="https://api.github.com", opener=None):
        if not token:
            raise FleetError("GitHub credential is empty")
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.opener = opener or urllib.request.urlopen

    @staticmethod
    def rate_limit_error(exc):
        headers = exc.headers or {}
        message = ""
        try:
            body = exc.read(4096)
            if isinstance(body, bytes):
                message = body.decode("utf-8", errors="replace")
        except OSError:
            pass
        lower = message.lower()
        now = int(time.time())
        remaining = headers.get("X-RateLimit-Remaining")
        reset = headers.get("X-RateLimit-Reset")
        retry_after = headers.get("Retry-After")
        try:
            reset_at = int(reset) if reset is not None else 0
        except ValueError:
            reset_at = 0
        try:
            retry_after_seconds = int(retry_after) if retry_after is not None else 0
        except ValueError:
            retry_after_seconds = 0
        primary = remaining == "0" or "api rate limit exceeded" in lower
        secondary = "secondary rate limit" in lower or retry_after_seconds > 0
        if primary:
            return GitHubRateLimitError(
                "primary",
                max(reset_at, now + REGISTRATION_RATE_LIMIT_FALLBACK_SECONDS),
            )
        if secondary:
            return GitHubRateLimitError(
                "secondary",
                now
                + max(retry_after_seconds, REGISTRATION_RATE_LIMIT_FALLBACK_SECONDS),
            )
        return None

    def request(self, method, path, payload=None, headers=None, include_headers=False):
        body = None if payload is None else json.dumps(payload).encode()
        request_headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "f5-sales-demo-ephemeral-runner-controller",
        }
        if headers:
            request_headers.update(headers)
        request = urllib.request.Request(
            self.api_url + path,
            data=body,
            method=method,
            headers=request_headers,
        )
        try:
            with self.opener(request, timeout=30) as response:
                response_body = response.read()
                parsed = json.loads(response_body) if response_body else {}
                if include_headers:
                    return parsed, dict(response.headers.items())
                return parsed
        except urllib.error.HTTPError as exc:
            if exc.code == 304 and include_headers:
                return None, dict((exc.headers or {}).items())
            rate_limit = self.rate_limit_error(exc)
            if rate_limit is not None:
                raise rate_limit from exc
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

    def delete_runner(self, full_name, runner_id):
        self.request("DELETE", f"/repos/{full_name}/actions/runners/{runner_id}")


class EphemeralController:  # pylint: disable=too-many-public-methods
    def __init__(
        self,
        policy,
        github,
        base_dir=DEFAULT_BASE_DIR,
        command=run_command,
        popen=None,
    ):
        self.policy = policy
        self.github = github
        self.base_dir = Path(base_dir)
        self.command = command
        self.popen = (
            popen
            if popen is not None
            else subprocess.Popen
            if command is run_command
            else None
        )
        self.stopping = False

    def request_stop(self, _signum, _frame):
        """Interrupt the blocking outer runner once so cleanup can finish."""
        if self.stopping:
            return
        self.stopping = True
        raise StopRequestedError

    @property
    def registration_cooldown_path(self):
        return self.base_dir / ".registration-rate-limit.json"

    @property
    def registration_cooldown_lock_path(self):
        return self.base_dir / ".registration-rate-limit.lock"

    @contextlib.contextmanager
    def registration_cooldown_lock(self):
        self.base_dir.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(
            self.registration_cooldown_lock_path,
            os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
            0o600,
        )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def read_registration_cooldown(self):
        try:
            payload = json.loads(
                self.registration_cooldown_path.read_text(encoding="utf-8")
            )
        except FileNotFoundError:
            return 0
        except OSError as exc:
            raise FleetError(f"cannot read registration cooldown: {exc}") from exc
        except ValueError:
            print(
                "runner registration cooldown is malformed; ignoring it",
                file=sys.stderr,
            )
            return 0
        retry_at = payload.get("retry_at") if isinstance(payload, dict) else None
        if not isinstance(retry_at, int) or retry_at < 0:
            print(
                "runner registration cooldown is malformed; ignoring it",
                file=sys.stderr,
            )
            return 0
        return retry_at

    def record_registration_cooldown(self, retry_at):
        if not isinstance(retry_at, int) or retry_at <= 0:
            raise FleetError("registration cooldown deadline is invalid")
        with self.registration_cooldown_lock():
            effective_retry_at = max(retry_at, self.read_registration_cooldown())
            temporary = self.registration_cooldown_path.with_name(
                self.registration_cooldown_path.name + ".tmp"
            )
            descriptor = os.open(
                temporary,
                os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW,
                0o600,
            )
            try:
                os.write(
                    descriptor,
                    json.dumps({"retry_at": effective_retry_at}).encode("utf-8"),
                )
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            temporary.replace(self.registration_cooldown_path)
        return effective_retry_at

    def registration_cooldown_delay(self, full_name, profile_name, slot):
        with self.registration_cooldown_lock():
            retry_at = self.read_registration_cooldown()
        now = int(time.time())
        if retry_at <= now:
            return 0
        identity = f"{full_name}:{profile_name}:{slot}".encode()
        jitter = int.from_bytes(hashlib.sha256(identity).digest()[:2], "big") % (
            REGISTRATION_RECOVERY_JITTER_SECONDS + 1
        )
        return retry_at - now + jitter

    def state_dir(self, spec, profile, slot):
        path = self.base_dir / "diagnostics" / spec.name / profile.name / str(slot)
        base = self.base_dir.resolve()
        resolved = path.resolve()
        if base not in resolved.parents:
            raise FleetError("runner state path escapes base directory")
        return path

    def runtime_workspace(self, spec, profile, slot):
        """Return the host-visible action workspace for one ephemeral runner."""
        return self.base_dir / "workspaces" / spec.name / profile.name / str(slot)

    def cleanup_lock_path(self, spec, profile, slot):
        """Return the lock dedicated to one runner's container cleanup.

        Container inventory is global, but every cleanup action below is scoped to
        the exact repository/profile/slot workspace.  A fleet-wide lock therefore
        turns one slow workspace into head-of-line blocking for unrelated runners.
        The validated identifiers make this filename safe beneath ``base_dir``.
        """
        return self.base_dir / f".cleanup-{spec.name}-{profile.name}-{slot}.lock"

    @property
    def nested_container_inventory_lock_path(self):
        """Return the lock for the Docker-wide nested-container inventory."""
        return self.base_dir / ".nested-container-inventory.lock"

    @contextlib.contextmanager
    def nested_container_inventory_lock(self):
        """Serialize global Docker inventory without serializing exact cleanup."""
        lock_path = self.nested_container_inventory_lock_path
        try:
            self.base_dir.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(
                lock_path,
                os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
            )
        except OSError as exc:
            raise FleetError(
                f"cannot open nested container inventory lock: {exc}"
            ) from exc
        try:
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600
            ):
                raise FleetError("nested container inventory lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        except OSError as exc:
            raise FleetError(
                f"cannot use nested container inventory lock: {exc}"
            ) from exc
        finally:
            os.close(descriptor)

    @staticmethod
    def container_name(spec, profile, slot):
        return f"gha-{spec.name}-{profile.name}-{slot}"

    @staticmethod
    def expected_labels(spec, profile):
        return {"self-hosted", "Linux", "X64", spec.name, *profile.labels}

    def docker_cli(self, dedicated=False):
        if dedicated:
            return ["docker", "--host", f"unix://{self.policy.docker.host_socket}"]
        return ["docker"]

    def verify_engine(self, dedicated=False):
        result = self.command(
            [*self.docker_cli(dedicated), "version", "--format", "{{.Server.Version}}"],
            check=False,
        )
        if result.returncode != 0:
            engine = "dedicated rootless" if dedicated else "host"
            raise FleetError(f"cannot query the {engine} Docker Engine")
        actual = version_tuple(result.stdout.strip())
        if actual < version_tuple(self.policy.docker.minimum_version):
            raise FleetError(
                f"Docker Engine {result.stdout.strip()} is below required "
                f"{self.policy.docker.minimum_version}"
            )
        return result.stdout.strip()

    def docker_socket_group(self):
        path = self.policy.docker.host_socket
        try:
            metadata = Path(path).stat(follow_symlinks=False)
        except OSError as exc:
            raise FleetError(f"cannot inspect Docker socket {path}: {exc}") from exc
        if not stat.S_ISSOCK(metadata.st_mode):
            raise FleetError(f"Docker socket is not a Unix socket: {path}")
        if metadata.st_uid != 1001 or stat.S_IMODE(metadata.st_mode) != 0o660:
            raise FleetError("dedicated Docker socket must be UID 1001 with mode 0660")
        return metadata.st_gid

    @staticmethod
    def _container_ids(output, context):
        ids = output.splitlines()
        if any(not CONTAINER_ID_RE.fullmatch(item) for item in ids):
            raise FleetError(f"malformed Docker {context} inventory")
        if len(ids) != len(set(ids)):
            raise FleetError(f"duplicate Docker {context} inventory")
        return ids

    def _inspect_container(
        self, container_id, *, allow_disappeared=False, dedicated=False
    ):
        attempts = TRANSIENT_INSPECT_ATTEMPTS if allow_disappeared else 1
        docker = self.docker_cli(dedicated)
        for attempt in range(attempts):
            result = self.command(
                [*docker, "container", "inspect", container_id], check=False
            )
            if result.returncode == 0:
                break
            if not allow_disappeared:
                raise FleetError(f"cannot inspect Docker container {container_id}")
            inventory = self.command(
                [
                    *docker,
                    "container",
                    "ls",
                    "--all",
                    "--quiet",
                    "--no-trunc",
                    "--filter",
                    f"id={container_id}",
                ],
                check=False,
            )
            if inventory.returncode != 0:
                raise FleetError(
                    f"cannot confirm disappeared Docker container {container_id}"
                )
            ids = self._container_ids(inventory.stdout, "exact disappeared container")
            if not ids:
                return None
            if ids != [container_id]:
                raise FleetError(
                    f"unexpected Docker exact container inventory for {container_id}"
                )
            if attempt + 1 == attempts:
                raise FleetError(f"cannot inspect Docker container {container_id}")
            delay = min(
                TRANSIENT_INSPECT_INITIAL_DELAY_SECONDS * (2**attempt),
                TRANSIENT_INSPECT_MAX_DELAY_SECONDS,
            )
            time.sleep(delay)
        try:
            payload = json.loads(result.stdout)
        except (TypeError, ValueError) as exc:
            raise FleetError(f"malformed Docker inspection for {container_id}") from exc
        if isinstance(payload, list) and len(payload) == 1:
            payload = payload[0]
        if not isinstance(payload, dict) or payload.get("Id") != container_id:
            raise FleetError(f"malformed Docker inspection for {container_id}")
        name = payload.get("Name")
        config = payload.get("Config")
        if not isinstance(config, dict):
            raise FleetError(f"malformed Docker inspection for {container_id}")
        labels = config.get("Labels")
        valid_name = isinstance(name, str) and name.startswith("/")
        valid_labels = labels is None or isinstance(labels, dict)
        if not all(
            (
                valid_name,
                valid_labels,
                isinstance(payload.get("Mounts"), list),
            )
        ):
            raise FleetError(f"malformed Docker inspection for {container_id}")
        if labels is None:
            config["Labels"] = {}
        return payload

    def _exact_outer_id(self, spec, profile, slot):
        name = self.container_name(spec, profile, slot)
        result = self.command(
            [
                "docker",
                "container",
                "ls",
                "--all",
                "--quiet",
                "--no-trunc",
                "--filter",
                f"name=^/{name}$",
            ],
            check=False,
        )
        if result.returncode != 0:
            raise FleetError(f"cannot inventory exact runner container {name}")
        ids = self._container_ids(result.stdout, "outer runner")
        if len(ids) > 1:
            raise FleetError(f"multiple exact runner containers matched {name}")
        if not ids:
            return None
        container_id = ids[0]
        inspected = self._inspect_container(container_id)
        expected_labels = {
            "f5.runner.managed": "true",
            "f5.runner.repository": spec.full_name,
            "f5.runner.profile": profile.name,
            "f5.runner.slot": str(slot),
        }
        labels = inspected["Config"]["Labels"]
        if inspected["Name"] != f"/{name}" or any(
            labels.get(key) != value for key, value in expected_labels.items()
        ):
            raise FleetError(f"exact runner container identity mismatch: {name}")
        return container_id

    def outer_image(self, spec, profile, slot):
        # Return the exact managed container image for one runner slot.
        container_id = self._exact_outer_id(spec, profile, slot)
        if container_id is None:
            return None
        image = self._inspect_container(container_id)["Config"].get("Image")
        if not isinstance(image, str):
            raise FleetError(
                f"runner image metadata is malformed: {self.container_name(spec, profile, slot)}"
            )
        return image

    def _request_outer_stop(self, spec, profile, slot):
        name = self.container_name(spec, profile, slot)
        container_id = self._exact_outer_id(spec, profile, slot)
        if container_id is None:
            return None
        stopped = self.command(
            [
                "docker",
                "container",
                "stop",
                "--time",
                str(profile.stop_timeout),
                container_id,
            ],
            check=False,
        )
        if stopped.returncode != 0:
            raise FleetError(f"cannot stop exact runner container {name}")
        return container_id

    def _stop_outer(self, spec, profile, slot):
        name = self.container_name(spec, profile, slot)
        container_id = self._request_outer_stop(spec, profile, slot)
        if container_id is None:
            return
        removed = self.command(
            ["docker", "container", "rm", "--force", container_id], check=False
        )
        if removed.returncode != 0:
            raise FleetError(f"cannot remove exact runner container {name}")

    def _remove_nested_containers(self, spec, profile, slot):
        """Remove builder children through its dedicated rootless daemon."""
        with self.nested_container_inventory_lock():
            self._remove_nested_containers_locked(spec, profile, slot)

    def _remove_nested_containers_locked(self, spec, profile, slot):
        workspace = self.runtime_workspace(spec, profile, slot)
        try:
            workspace_root = workspace.resolve(strict=True)
        except FileNotFoundError:
            return
        except OSError as exc:
            raise FleetError(f"cannot resolve exact runner workspace: {exc}") from exc
        dedicated = profile.docker_socket
        docker = self.docker_cli(dedicated=dedicated)
        result = self.command(
            [*docker, "container", "ls", "--all", "--quiet", "--no-trunc"],
            check=False,
        )
        if result.returncode != 0:
            raise FleetError("cannot inventory nested Docker containers")
        for container_id in self._container_ids(result.stdout, "nested container"):
            inspected = self._inspect_container(
                container_id, allow_disappeared=True, dedicated=dedicated
            )
            if inspected is None:
                continue
            beneath = []
            for mount in inspected["Mounts"]:
                if not isinstance(mount, dict) or not isinstance(
                    mount.get("Type"), str
                ):
                    raise FleetError(
                        f"malformed Docker mount inspection for {container_id}"
                    )
                if mount["Type"] != "bind":
                    continue
                source = mount.get("Source")
                if not isinstance(source, str) or not source.startswith("/"):
                    raise FleetError(
                        f"malformed Docker bind mount inspection for {container_id}"
                    )
                source_path = Path(source)
                lexical_match = (
                    source_path == workspace or workspace in source_path.parents
                )
                if not lexical_match:
                    beneath.append(False)
                    continue
                try:
                    # Docker retains bind-source paths after a job removes the
                    # final component.  Resolve existing ancestors and append
                    # missing descendants so cleanup remains recoverable while
                    # still rejecting surviving symlink escapes.
                    resolved = source_path.resolve(strict=False)
                except OSError as exc:
                    raise FleetError(
                        f"cannot validate Docker bind mount for {container_id}"
                    ) from exc
                if (
                    resolved != workspace_root
                    and workspace_root not in resolved.parents
                ):
                    raise FleetError(
                        f"Docker bind mount escapes exact workspace: {container_id}"
                    )
                beneath.append(True)
            if not any(beneath):
                continue
            if not all(beneath):
                raise FleetError(
                    f"nested Docker container has a bind outside its workspace: {container_id}"
                )
            removed = self.command(
                [*docker, "container", "rm", "--force", container_id], check=False
            )
            if removed.returncode != 0:
                raise FleetError(
                    f"cannot remove nested Docker container {container_id}"
                )

    def cleanup(self, spec, profile, slot):
        lock_path = self.cleanup_lock_path(spec, profile, slot)
        try:
            descriptor = os.open(
                lock_path,
                os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
            )
        except OSError as exc:
            raise FleetError(f"cannot open runner cleanup lock: {exc}") from exc
        try:
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600
            ):
                raise FleetError("runner cleanup lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            self._stop_outer(spec, profile, slot)
            self._remove_nested_containers(spec, profile, slot)
        except OSError as exc:
            raise FleetError(f"cannot use runner cleanup lock: {exc}") from exc
        finally:
            os.close(descriptor)

    def prepare_workspace(self, spec, profile, slot):
        """Create the exact host-visible workspace owned by runner UID/GID 1001."""
        workspace = self.runtime_workspace(spec, profile, slot)
        try:
            relative = workspace.relative_to(self.base_dir)
            descriptor = os.open(
                self.base_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            )
        except OSError as exc:
            raise FleetError(f"cannot open runner workspace base: {exc}") from exc
        try:
            for component in relative.parts:
                with contextlib.suppress(FileExistsError):
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                next_descriptor = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=descriptor,
                )
                os.close(descriptor)
                descriptor = next_descriptor
                if component != relative.parts[-1]:
                    os.fchmod(descriptor, 0o711)
            os.fchmod(descriptor, 0o700)
            os.fchown(descriptor, 1001, 1001)
        except OSError as exc:
            raise FleetError(f"cannot prepare runner workspace: {exc}") from exc
        finally:
            os.close(descriptor)
        return workspace

    def reset_workspace(self, spec, profile, slot):
        """Remove stale state only after the exact runner container is stopped."""
        workspace = self.runtime_workspace(spec, profile, slot)
        if workspace.is_symlink():
            raise FleetError("runner workspace is unsafe")
        if not workspace.exists():
            return
        if not workspace.is_dir():
            raise FleetError("runner workspace is unsafe")
        for child in workspace.iterdir():
            if child.is_symlink():
                child.unlink()
                continue
            try:
                if child.is_dir():
                    cast("Any", shutil.rmtree)(child, onexc=self.remove_read_only)
                else:
                    child.unlink()
            except OSError as exc:
                raise FleetError(f"cannot reset runner workspace: {exc}") from exc

    @staticmethod
    def remove_read_only(function, path, error):
        """Retry a removal without following untrusted links in the workspace."""
        if not isinstance(error, PermissionError):
            raise error
        target = Path(path)
        if target.is_symlink():
            target.unlink()
            return
        directory = (
            target if function in (os.open, os.scandir, os.listdir) else target.parent
        )
        try:
            descriptor = os.open(directory, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError as exc:
            raise FleetError(
                f"cannot safely reset read-only workspace path: {exc}"
            ) from exc
        try:
            Path(f"/proc/self/fd/{descriptor}").chmod(stat.S_IRWXU)
        finally:
            os.close(descriptor)
        if function is os.open:
            cast("Any", shutil.rmtree)(
                target, onexc=EphemeralController.remove_read_only
            )
            return
        function(path)

    def remove_registration(self, spec, profile, slot):
        """Remove registrations left behind when an idle runner is stopped."""
        prefix = self.container_name(spec, profile, slot) + "-"
        for runner in self.github.runners(spec.full_name):
            name = runner.get("name")
            runner_id = runner.get("id")
            if isinstance(name, str) and name.startswith(prefix):
                if not isinstance(runner_id, int) or runner_id <= 0:
                    raise FleetError(f"managed runner has an invalid id: {name}")
                self.github.delete_runner(spec.full_name, runner_id)

    def docker_command(self, spec, profile, slot):
        state = self.state_dir(spec, profile, slot)
        workspace = self.runtime_workspace(spec, profile, slot)
        self.command(
            [
                "install",
                "-d",
                "-m",
                "0700",
                "-o",
                "1001",
                "-g",
                "1001",
                str(state),
            ]
        )
        # Preserve diagnostic history across ephemeral runner cycles while
        # migrating files created by the retired per-repository host accounts.
        # GNU chown with --no-dereference changes symlink ownership only and
        # never follows a diagnostic symlink outside this validated state path.
        self.command(
            [
                "chown",
                "--recursive",
                "--no-dereference",
                "1001:1001",
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
            "docker",
            "run",
            "--interactive",
            "--pull",
            "missing",
            "--user",
            "1001:1001",
            "--stop-timeout",
            str(profile.stop_timeout),
            "--name",
            name,
            "--read-only",
            "--cap-drop=all",
            "--security-opt=no-new-privileges=true",
            "--network",
            profile.network,
            "--memory",
            profile.memory,
            "--cpus",
            profile.cpus,
            "--pids-limit",
            str(profile.pids_limit),
            "--tmpfs",
            "/tmp:rw,nosuid,nodev,exec,size=2g",
            "--volume",
            f"{workspace}:{workspace}:rw",
            "--volume",
            f"{state}:{workspace}/_diag:rw",
            "--volume",
            f"{HOST_ENTRYPOINT}:/usr/local/bin/runner-entrypoint:ro",
            "--volume",
            f"{HOST_TOOL_CACHE_INITIALIZER}:/usr/local/libexec/prepare-runner-tool-cache:ro",
            "--env",
            f"HOME={workspace}/home",
            "--env",
            f"RUNNER_RUNTIME_DIR={workspace}",
            "--env",
            f"RUNNER_TOOL_CACHE={workspace}/_tool",
            "--env",
            "RUNNER_EPHEMERAL=1",
            "--env",
            "RUNNER_MANUALLY_TRAP_SIG=1",
            "--env",
            f"RUNNER_REPOSITORY={spec.full_name}",
            "--env",
            f"RUNNER_NAME={name}-{secrets.token_hex(4)}",
            "--env",
            f"RUNNER_LABELS={labels}",
            "--label",
            "f5.runner.managed=true",
            "--label",
            f"f5.runner.repository={spec.full_name}",
            "--label",
            f"f5.runner.profile={profile.name}",
            "--label",
            f"f5.runner.slot={slot}",
        ]
        if profile.docker_socket:
            host_socket = self.policy.docker.host_socket
            runner_socket = self.policy.docker.runner_socket
            command.extend(
                [
                    "--cgroup-parent",
                    self.policy.docker.cgroup_parent,
                    "--volume",
                    f"{host_socket}:{runner_socket}:rw",
                    "--group-add",
                    str(self.docker_socket_group()),
                    "--env",
                    f"DOCKER_HOST=unix://{runner_socket}",
                    "--env",
                    "RUNNER_CONTAINER_TOOLS=1",
                ]
            )
        command.append(profile.image)
        return command

    def _run_outer(self, spec, profile, slot, command, token):
        if self.popen is None:
            return self.command(
                command,
                input_text=token + "\n",
                check=False,
                capture=False,
            )
        process = self.popen(
            command,
            stdin=subprocess.PIPE,
            text=True,
        )
        try:
            process.communicate(token + "\n")
        except StopRequestedError:
            container_id = self._request_outer_stop(spec, profile, slot)
            if container_id is None and process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
        return subprocess.CompletedProcess(command, process.returncode)

    def run_once(self, full_name, profile_name, slot=0):
        spec = self.policy.repository(full_name)
        profile = next(
            (item for item in spec.profiles if item.name == profile_name), None
        )
        if profile is None:
            raise FleetError(f"profile {profile_name!r} is not enabled for {full_name}")
        maximum_slots = spec.replicas + int(profile in spec.standby_profiles)
        if not 0 <= slot < maximum_slots:
            raise FleetError(f"slot is invalid for profile {profile_name!r}")
        self.verify_engine()
        if profile.docker_socket:
            self.verify_engine(dedicated=True)
        token = ""
        try:
            self.cleanup(spec, profile, slot)
            self.prepare_workspace(spec, profile, slot)
            self.reset_workspace(spec, profile, slot)
            token = self.github.registration_token(full_name)
            result = self._run_outer(
                spec,
                profile,
                slot,
                self.docker_command(spec, profile, slot),
                token,
            )
            return result.returncode
        finally:
            token = ""  # Shorten the credential lifetime.
            self.cleanup(spec, profile, slot)
            self.reset_workspace(spec, profile, slot)
            self.remove_registration(spec, profile, slot)

    def audit_containers(self, full_name):  # pylint: disable=too-many-locals
        spec = self.policy.repository(full_name)
        errors = []
        expected = {
            self.container_name(spec, profile, slot): (profile, slot)
            for profile in spec.profiles
            for slot in range(spec.replicas + int(profile in spec.standby_profiles))
        }
        result = self.command(
            [
                "docker",
                "container",
                "ls",
                "--all",
                "--quiet",
                "--no-trunc",
                "--filter",
                "label=f5.runner.managed=true",
            ],
            check=False,
        )
        if result.returncode != 0:
            return ["cannot inventory managed Docker containers"]
        try:
            container_ids = self._container_ids(result.stdout, "managed runner")
        except FleetError as exc:
            return [str(exc)]
        for container_id in container_ids:
            try:
                inspected = self._inspect_container(container_id)
            except FleetError as exc:
                errors.append(str(exc))
                continue
            labels = inspected["Config"]["Labels"]
            if labels.get("f5.runner.repository") != full_name:
                continue
            name = inspected["Name"].removeprefix("/")
            if name not in expected:
                errors.append(f"unexpected managed Docker container: {name}")
                continue
            profile, slot = expected[name]
            required_labels = {
                "f5.runner.managed": "true",
                "f5.runner.repository": full_name,
                "f5.runner.profile": profile.name,
                "f5.runner.slot": str(slot),
            }
            if any(labels.get(key) != value for key, value in required_labels.items()):
                errors.append(f"managed Docker labels mismatch: {name}")
            host = inspected.get("HostConfig")
            config = inspected["Config"]
            if not isinstance(host, dict):
                errors.append(f"managed Docker HostConfig is malformed: {name}")
                continue
            expected_host = {
                "Memory": memory_bytes(profile.memory),
                "NanoCpus": int(float(profile.cpus) * 1_000_000_000),
                "PidsLimit": profile.pids_limit,
                "NetworkMode": profile.network,
                "ReadonlyRootfs": True,
            }
            for field, value in expected_host.items():
                if host.get(field) != value:
                    errors.append(
                        f"managed Docker resource mismatch: {name} {field}={host.get(field)!r}"
                    )
            cap_drop = host.get("CapDrop")
            if not isinstance(cap_drop, list) or {
                item.lower() for item in cap_drop
            } != {"all"}:
                errors.append(f"managed Docker capabilities mismatch: {name}")
            security = host.get("SecurityOpt")
            if not isinstance(security, list) or not any(
                item in {"no-new-privileges", "no-new-privileges=true"}
                for item in security
            ):
                errors.append(f"managed Docker security options mismatch: {name}")
            if config.get("StopTimeout") != profile.stop_timeout:
                errors.append(f"managed Docker stop timeout mismatch: {name}")
            socket_mounts = [
                mount
                for mount in inspected["Mounts"]
                if isinstance(mount, dict)
                and mount.get("Source") == self.policy.docker.host_socket
                and mount.get("Destination") == self.policy.docker.runner_socket
            ]
            if bool(socket_mounts) != profile.docker_socket:
                errors.append(f"managed Docker socket isolation mismatch: {name}")
            expected_parent = (
                self.policy.docker.cgroup_parent if profile.docker_socket else ""
            )
            if host.get("CgroupParent", "") != expected_parent:
                errors.append(f"managed Docker cgroup parent mismatch: {name}")
        return errors

    def audit(self, full_name):
        spec = self.policy.repository(full_name)
        errors = []
        actual = self.github.runners(full_name)
        expected_names = {
            self.container_name(spec, profile, slot)
            for profile in spec.profiles
            for slot in range(spec.replicas + int(profile in spec.standby_profiles))
        }
        for runner in actual:
            name = runner.get("name")
            if not isinstance(name, str) or not name.startswith(f"gha-{spec.name}-"):
                continue
            base = name.rsplit("-", 1)[0]
            if base not in expected_names:
                errors.append(f"unexpected managed runner: {name}")
            raw_labels = runner.get("labels")
            if not isinstance(raw_labels, list) or any(
                not isinstance(item, dict)
                or not isinstance(item.get("name"), str)
                or not item["name"]
                for item in raw_labels
            ):
                errors.append(f"managed runner labels are malformed on {name}")
                continue
            labels = {item["name"] for item in raw_labels}
            if "ubuntu-latest" in labels:
                errors.append(f"reserved label on {name}: ubuntu-latest")
            if base in expected_names:
                profile = next(
                    item
                    for item in spec.profiles
                    if any(
                        base == self.container_name(spec, item, slot)
                        for slot in range(
                            spec.replicas + int(item in spec.standby_profiles)
                        )
                    )
                )
                expected_labels = self.expected_labels(spec, profile)
                if labels != expected_labels:
                    errors.append(
                        f"managed runner labels mismatch on {name}: {sorted(labels)}"
                    )
        errors.extend(self.audit_containers(full_name))
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
    for action in ("once",):
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
            previous_handler = signal.signal(signal.SIGTERM, controller.request_stop)
            try:
                return controller.run_once(args.repository, args.profile, args.slot)
            except StopRequestedError:
                return 0
            finally:
                signal.signal(signal.SIGTERM, previous_handler)
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
