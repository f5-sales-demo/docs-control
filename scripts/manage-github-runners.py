#!/usr/bin/env python3
"""
Management script for self-hosted GitHub Actions runners in the f5-sales-demo ecosystem.

Directory structure:
  /data/actions-runners/f5-sales-demo/<repo-name>
  /data/actions-runners/f5-sales-demo/.cache

Authoritative list of governed repos is obtained from .claude/governance.json in docs-control.
"""

import argparse
import json
import os
import pathlib
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.request

DEFAULT_ORG = "f5-sales-demo"
DEFAULT_BASE_DIR = Path("/data/actions-runners/f5-sales-demo")
DEFAULT_USER = "robin"
DOCS_CONTROL_GOVERNANCE_PATH = Path(__file__).resolve().parent.parent / ".claude/governance.json"


def run_cmd(cmd, cwd=None, check=True, capture=True, sudo=False):
    if sudo and os.geteuid() != 0:
        cmd = ["sudo"] + cmd
    res = subprocess.run(
        cmd,
        cwd=cwd,
        check=check,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )
    return res


def get_latest_runner_version():
    try:
        res = run_cmd(["gh", "api", "repos/actions/runner/releases/latest", "--jq", ".tag_name"])
        tag = res.stdout.strip()
        if tag.startswith("v"):
            tag = tag[1:]
        if not tag:
            return "2.336.0"
        return tag
    except Exception as e:
        print(f"Warning: Failed to fetch latest runner tag via gh CLI: {e}. Falling back to 2.336.0")
        return "2.336.0"


def download_runner_tarball(version, cache_dir: Path):
    cache_dir.mkdir(parents=True, exist_ok=True)
    tarball_name = f"actions-runner-linux-x64-{version}.tar.gz"
    tarball_path = cache_dir / tarball_name

    if tarball_path.exists():
        print(f"[CACHE] Found cached runner tarball at {tarball_path}")
        return tarball_path

    tmp_path = cache_dir / f"{tarball_name}.tmp"
    url = f"https://github.com/actions/runner/releases/download/v{version}/{tarball_name}"
    print(f"[DOWNLOAD] Downloading runner v{version} from {url}...")
    urllib.request.urlretrieve(url, tmp_path)
    tmp_path.replace(tarball_path)
    print(f"[DOWNLOAD] Saved to {tarball_path}")
    return tarball_path


def get_registration_token(org, repo):
    res = run_cmd(["gh", "api", "-X", "POST", f"/repos/{org}/{repo}/actions/runners/registration-token", "--jq", ".token"])
    return res.stdout.strip()


def get_removal_token(org, repo):
    res = run_cmd(["gh", "api", "-X", "POST", f"/repos/{org}/{repo}/actions/runners/remove-token", "--jq", ".token"])
    return res.stdout.strip()


def load_governed_repos(gov_path: Path = DOCS_CONTROL_GOVERNANCE_PATH):
    if not gov_path.exists():
        raise FileNotFoundError(f"Governance manifest not found at {gov_path}")
    with open(gov_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    repos_dict = data.get("repo_classes", {}).get("repos", {})
    return sorted(list(repos_dict.keys()))


def setup_runner(org, repo, base_dir: Path, user):
    repo_dir = base_dir / repo
    cache_dir = base_dir / ".cache"

    print(f"\n==========================================")
    print(f"Setting up self-hosted runner for {org}/{repo}")
    print(f"Directory: {repo_dir}")
    print(f"==========================================")

    version = get_latest_runner_version()
    tarball = download_runner_tarball(version, cache_dir)

    if repo_dir.exists():
        svc_sh = repo_dir / "svc.sh"
        if svc_sh.exists():
            print(f"[CLEANUP] Stopping and uninstalling existing service in {repo_dir}...")
            try:
                run_cmd(["./svc.sh", "stop"], cwd=repo_dir, check=False, sudo=True)
                run_cmd(["./svc.sh", "uninstall"], cwd=repo_dir, check=False, sudo=True)
            except Exception as e:
                print(f"[CLEANUP WARNING] {e}")
        shutil.rmtree(repo_dir, ignore_errors=True)

    repo_dir.mkdir(parents=True, exist_ok=True)

    print(f"[EXTRACT] Extracting runner binary to {repo_dir}...")
    run_cmd(["tar", "-xzf", str(tarball), "-C", str(repo_dir)])

    print(f"[TOKEN] Requesting runner registration token for {org}/{repo}...")
    token = get_registration_token(org, repo)

    runner_name = f"runner-ubuntu-{repo}"
    labels = f"self-hosted,Linux,X64,ubuntu-latest,{repo},{org}"

    print(f"[CONFIG] Configuring runner '{runner_name}' with labels: {labels}")
    config_cmd = [
        "./config.sh",
        "--url", f"https://github.com/{org}/{repo}",
        "--token", token,
        "--name", runner_name,
        "--labels", labels,
        "--unattended",
        "--replace"
    ]
    run_cmd(config_cmd, cwd=repo_dir)

    print(f"[SERVICE] Installing systemd service as user '{user}'...")
    svc_pattern = f"actions.runner.{org}-{repo}.*.service"
    for unit in Path("/etc/systemd/system").glob(svc_pattern):
        print(f"[CLEANUP] Removing stale systemd unit file {unit}...")
        run_cmd(["systemctl", "stop", unit.name], check=False, sudo=True)
        run_cmd(["systemctl", "disable", unit.name], check=False, sudo=True)
        run_cmd(["rm", "-f", str(unit)], check=False, sudo=True)
        run_cmd(["systemctl", "daemon-reload"], check=False, sudo=True)

    run_cmd(["./svc.sh", "install", user], cwd=repo_dir, sudo=True)

    print(f"[SERVICE] Starting systemd service...")
    run_cmd(["./svc.sh", "start"], cwd=repo_dir, sudo=True)

    print(f"[SUCCESS] Runner for {org}/{repo} installed and started successfully!")


def status_runner(org, repo, base_dir: Path):
    repo_dir = base_dir / repo
    print(f"\n--- Status for {org}/{repo} ---")

    # GitHub API Status
    try:
        res = run_cmd(["gh", "api", f"/repos/{org}/{repo}/actions/runners"])
        data = json.loads(res.stdout)
        runners = data.get("runners", [])
        if not runners:
            print("  GitHub API: No runners registered for this repo.")
        else:
            for r in runners:
                print(f"  GitHub API Runner: ID={r.get('id')} Name={r.get('name')} Status={r.get('status')} Busy={r.get('busy')} OS={r.get('os')}")
    except Exception as e:
        print(f"  GitHub API Error: {e}")

    # Local Directory & Systemd Status
    if repo_dir.exists():
        svc_file = repo_dir / ".service"
        if svc_file.exists():
            service_name = svc_file.read_text().strip()
            print(f"  Service Name: {service_name}")
            try:
                res = run_cmd(["systemctl", "status", service_name], check=False)
                lines = res.stdout.splitlines()[:5]
                for line in lines:
                    print(f"    {line}")
            except Exception as e:
                print(f"  systemctl error: {e}")
        else:
            print("  Local Directory exists, but no .service file found.")
    else:
        print("  Local Directory does not exist.")


def restart_runner(org, repo, base_dir: Path):
    repo_dir = base_dir / repo
    if not repo_dir.exists():
        print(f"Error: {repo_dir} does not exist.")
        return
    print(f"Restarting runner service for {org}/{repo}...")
    run_cmd(["./svc.sh", "restart"], cwd=repo_dir, sudo=True)
    print("Done.")


def stop_runner(org, repo, base_dir: Path):
    repo_dir = base_dir / repo
    if not repo_dir.exists():
        print(f"Error: {repo_dir} does not exist.")
        return
    print(f"Stopping runner service for {org}/{repo}...")
    run_cmd(["./svc.sh", "stop"], cwd=repo_dir, sudo=True)
    print("Done.")


def remove_runner(org, repo, base_dir: Path):
    repo_dir = base_dir / repo
    if not repo_dir.exists():
        print(f"Directory {repo_dir} does not exist. Nothing to remove.")
        return

    print(f"\nRemoving runner for {org}/{repo}...")
    svc_sh = repo_dir / "svc.sh"
    if svc_sh.exists():
        print("Stopping service...")
        run_cmd(["./svc.sh", "stop"], cwd=repo_dir, check=False, sudo=True)
        print("Uninstalling service...")
        run_cmd(["./svc.sh", "uninstall"], cwd=repo_dir, check=False, sudo=True)

    try:
        print("Obtaining removal token...")
        remove_token = get_removal_token(org, repo)
        config_sh = repo_dir / "config.sh"
        if config_sh.exists():
            print("Unregistering runner from GitHub...")
            run_cmd(["./config.sh", "remove", "--token", remove_token], cwd=repo_dir, check=False)
    except Exception as e:
        print(f"Warning during unregistration: {e}")

    print(f"Removing directory {repo_dir}...")
    shutil.rmtree(repo_dir, ignore_errors=True)
    print(f"Successfully removed runner for {org}/{repo}.")


def setup_governed(org, base_dir: Path, user, auto_confirm=False, gov_path: Path = DOCS_CONTROL_GOVERNANCE_PATH):
    governed_repos = load_governed_repos(gov_path)
    print(f"Found {len(governed_repos)} governed repositories in docs-control governance.json:")
    for r in governed_repos:
        print(f"  - {r}")

    if not auto_confirm:
        input_val = input(f"\nProceed to setup runners for all {len(governed_repos)} governed repositories? [y/N] ").strip().lower()
        if input_val != 'y':
            print("Cancelled setup-governed.")
            return

    for idx, repo in enumerate(governed_repos, 1):
        print(f"\n[{idx}/{len(governed_repos)}] Processing governed repo: {repo}...")
        try:
            setup_runner(org, repo, base_dir, user)
        except Exception as e:
            print(f"ERROR setting up {repo}: {e}")


def clean_ungoverned(org, base_dir: Path, gov_path: Path = DOCS_CONTROL_GOVERNANCE_PATH):
    governed_set = set(load_governed_repos(gov_path))
    if not base_dir.exists():
        print("Base directory does not exist.")
        return

    print(f"Auditing runner directories in {base_dir} against governed repos list...")
    items = list(base_dir.iterdir())
    for item in items:
        if item.is_dir() and not item.name.startswith("."):
            repo_name = item.name
            if repo_name not in governed_set:
                print(f"⚠️ Found ungoverned runner directory: {repo_name}. Cleaning up...")
                remove_runner(org, repo_name, base_dir)


def health_check(org, base_dir: Path, gov_path: Path = DOCS_CONTROL_GOVERNANCE_PATH):
    governed_repos = load_governed_repos(gov_path)
    print(f"\n==========================================")
    print(f"Health Check for Governed {org} Runners ({len(governed_repos)} Repositories)")
    print(f"==========================================\n")

    summary = {"online": 0, "busy": 0, "idle": 0, "offline": 0, "unregistered": 0, "error": 0}

    for repo in governed_repos:
        try:
            res = run_cmd(["gh", "api", f"/repos/{org}/{repo}/actions/runners"], check=False)
            if res.returncode != 0:
                print(f"❌ {repo:30s} API Error")
                summary["error"] += 1
                continue

            data = json.loads(res.stdout)
            runners = data.get("runners", [])
            if not runners:
                print(f"⚠️ {repo:30s} Unregistered")
                summary["unregistered"] += 1
            else:
                r = runners[0]
                status = r.get("status", "unknown")
                busy = r.get("busy", False)
                busy_str = " (Busy)" if busy else " (Idle)"
                if status == "online":
                    print(f"✅ {repo:30s} Online{busy_str}")
                    summary["online"] += 1
                    if busy:
                        summary["busy"] += 1
                    else:
                        summary["idle"] += 1
                else:
                    print(f"❌ {repo:30s} Offline")
                    summary["offline"] += 1
        except Exception as e:
            print(f"❌ {repo:30s} Error: {e}")
            summary["error"] += 1

    print(f"\nSummary: {summary['online']} Online ({summary['busy']} Busy, {summary['idle']} Idle) | {summary['offline']} Offline | {summary['unregistered']} Unregistered | {summary['error']} Errors")


def main():
    parser = argparse.ArgumentParser(description="Manage repository-level GitHub Actions runners for f5-sales-demo governed repositories")
    parser.add_argument("--org", default=DEFAULT_ORG, help="GitHub Organization")
    parser.add_argument("--base-dir", default=str(DEFAULT_BASE_DIR), help="Base directory for runners")
    parser.add_argument("--user", default=DEFAULT_USER, help="System user for runner systemd service")
    parser.add_argument("--governance-path", default=str(DOCS_CONTROL_GOVERNANCE_PATH), help="Path to docs-control governance.json")

    subparsers = parser.add_subparsers(dest="command", required=True)

    # setup
    p_setup = subparsers.add_parser("setup", help="Provision and start runner for a repository")
    p_setup.add_argument("repo", help="Repository name")

    # status
    p_status = subparsers.add_parser("status", help="Check status of runner for a repository")
    p_status.add_argument("repo", nargs="?", help="Repository name (optional)")

    # restart
    p_restart = subparsers.add_parser("restart", help="Restart runner service for a repository")
    p_restart.add_argument("repo", help="Repository name")

    # stop
    p_stop = subparsers.add_parser("stop", help="Stop runner service for a repository")
    p_stop.add_argument("repo", help="Repository name")

    # remove
    p_remove = subparsers.add_parser("remove", help="Uninstall and unregister runner for a repository")
    p_remove.add_argument("repo", help="Repository name")

    # setup-governed / setup-all
    p_setup_gov = subparsers.add_parser("setup-governed", aliases=["setup-all"], help="Provision runners for all governed repositories declared in governance.json")
    p_setup_gov.add_argument("-y", "--yes", action="store_true", help="Auto confirm and run non-interactively")

    # clean-ungoverned
    subparsers.add_parser("clean-ungoverned", help="Remove runners for repositories not listed in governance.json")

    # health-check
    subparsers.add_parser("health-check", help="Check health of all governed runners across org")

    args = parser.parse_args()
    base_dir = Path(args.base_dir)
    gov_path = Path(args.governance_path)

    if args.command == "setup":
        setup_runner(args.org, args.repo, base_dir, args.user)
    elif args.command == "status":
        if args.repo:
            status_runner(args.org, args.repo, base_dir)
        else:
            health_check(args.org, base_dir, gov_path)
    elif args.command == "restart":
        restart_runner(args.org, args.repo, base_dir)
    elif args.command == "stop":
        stop_runner(args.org, args.repo, base_dir)
    elif args.command == "remove":
        remove_runner(args.org, args.repo, base_dir)
    elif args.command in ["setup-governed", "setup-all"]:
        setup_governed(args.org, base_dir, args.user, auto_confirm=args.yes, gov_path=gov_path)
    elif args.command == "clean-ungoverned":
        clean_ungoverned(args.org, base_dir, gov_path)
    elif args.command == "health-check":
        health_check(args.org, base_dir, gov_path)


if __name__ == "__main__":
    main()
