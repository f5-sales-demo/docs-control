#!/usr/bin/env python3
"""
Real-time process monitor for GitHub Self-Hosted Runners in f5-sales-demo.

Displays:
 - Disk space on /data and /
 - Fleet summary (Online, Busy, Idle, Offline)
 - Live process statistics (PID, CPU %, Memory MB, Repo, Status, Current Job)
 - Interactive mode or single-shot output mode (--once)
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

DEFAULT_BASE_DIR = Path("/data/actions-runners/f5-sales-demo")
GOVERNANCE_PATH = Path(__file__).resolve().parent.parent / ".claude/governance.json"


def get_disk_info(mount_point):
    try:
        st = os.statvfs(mount_point)
        total = (st.f_blocks * st.f_frsize) / (1024 ** 3)
        free = (st.f_bavail * st.f_frsize) / (1024 ** 3)
        used = total - free
        pct = (used / total) * 100 if total > 0 else 0
        return f"{used:.1f}G/{total:.1f}G ({pct:.0f}%)"
    except Exception:
        return "N/A"


def get_governed_repos():
    if not GOVERNANCE_PATH.exists():
        return []
    try:
        with open(GOVERNANCE_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        return sorted(list(data.get("repo_classes", {}).get("repos", {}).keys()))
    except Exception:
        return []


def get_running_processes():
    """
    Parse ps aux for Runner.Listener, Runner.Worker, and runsvc.sh processes.
    """
    procs = []
    try:
        res = subprocess.run(
            ["ps", "aux"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True
        )
        lines = res.stdout.splitlines()
        header = lines[0].split()
        for line in lines[1:]:
            parts = line.split(None, 10)
            if len(parts) < 11:
                continue
            user, pid, cpu, mem, vsz, rss, tty, stat, start, time_str, cmd = parts
            if "actions-runners/f5-sales-demo" in cmd:
                # Extract repo name from path
                # e.g., /data/actions-runners/f5-sales-demo/<repo>/...
                repo = "unknown"
                if "/f5-sales-demo/" in cmd:
                    after_org = cmd.split("/f5-sales-demo/")[1]
                    repo = after_org.split("/")[0]

                p_type = "Listener"
                if "Runner.Worker" in cmd:
                    p_type = "Worker"
                elif "runsvc.sh" in cmd:
                    p_type = "Service"

                mem_mb = float(rss) / 1024.0 if rss.isdigit() else 0.0

                procs.append({
                    "pid": pid,
                    "user": user,
                    "cpu": float(cpu) if cpu.replace('.', '', 1).isdigit() else 0.0,
                    "mem_mb": mem_mb,
                    "repo": repo,
                    "type": p_type,
                    "cmd": cmd
                })
    except Exception:
        pass
    return procs


def fetch_gh_runner_statuses(org="f5-sales-demo"):
    """
    Query GitHub API for runner statuses across repos or list via systemctl
    """
    repos = get_governed_repos()
    statuses = {}
    for repo in repos:
        repo_dir = DEFAULT_BASE_DIR / repo
        statuses[repo] = {"status": "offline", "busy": False, "pid": "-", "cpu": 0.0, "mem_mb": 0.0}

    # Aggregate process stats per repo
    procs = get_running_processes()
    repo_procs = {}
    for p in procs:
        r = p["repo"]
        if r not in repo_procs:
            repo_procs[r] = []
        repo_procs[r].append(p)

    for r, plist in repo_procs.items():
        total_cpu = sum(p["cpu"] for p in plist)
        total_mem = sum(p["mem_mb"] for p in plist)
        main_pid = plist[0]["pid"] if plist else "-"
        is_worker_active = any(p["type"] == "Worker" for p in plist)
        statuses[r] = {
            "status": "online",
            "busy": is_worker_active,
            "pid": main_pid,
            "cpu": total_cpu,
            "mem_mb": total_mem
        }

    return statuses


def render_top_view(statuses, once=False):
    total = len(statuses)
    online = sum(1 for s in statuses.values() if s["status"] == "online")
    busy = sum(1 for s in statuses.values() if s["busy"])
    idle = online - busy
    offline = total - online

    disk_data = get_disk_info("/data")
    disk_root = get_disk_info("/")

    if not once:
        # Clear screen and move cursor to top
        sys.stdout.write("\033[2J\033[H")

    header = f"""
================================================================================
  f5-sales-demo Self-Hosted Runner Monitor  [{time.strftime('%Y-%m-%d %H:%M:%S')}]
================================================================================
  Disk /data: {disk_data:<20} Disk /: {disk_root:<20}
  Fleet: {total} Total | \033[32m{online} Online\033[0m (\033[33m{busy} Busy\033[0m, \033[36m{idle} Idle\033[0m) | \033[31m{offline} Offline\033[0m
================================================================================
  {"REPO NAME":<30} {"STATUS":<12} {"PID":<8} {"CPU %":<8} {"MEM (MB)":<10}
--------------------------------------------------------------------------------"""
    print(header)

    for repo, data in sorted(statuses.items()):
        st = data["status"]
        if st == "online":
            if data["busy"]:
                st_str = "\033[33mONLINE (BUSY)\033[0m"
            else:
                st_str = "\033[32mONLINE (IDLE)\033[0m"
        else:
            st_str = "\033[31mOFFLINE\033[0m"

        pid_str = str(data["pid"])
        cpu_str = f"{data['cpu']:.1f}%" if data['status'] == 'online' else "-"
        mem_str = f"{data['mem_mb']:.1f} MB" if data['status'] == 'online' else "-"

        print(f"  {repo:<30} {st_str:<23} {pid_str:<8} {cpu_str:<8} {mem_str:<10}")

    print("================================================================================")
    if not once:
        print("Press Ctrl+C to exit monitor.")


def main():
    parser = argparse.ArgumentParser(description="Real-time process monitor for GitHub Self-Hosted Runners")
    parser.add_argument("--once", action="store_true", help="Print stats once and exit")
    parser.add_argument("--interval", type=int, default=3, help="Refresh interval in seconds (default: 3)")
    args = parser.parse_args()

    try:
        while True:
            statuses = fetch_gh_runner_statuses()
            render_top_view(statuses, once=args.once)
            if args.once:
                break
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nExiting runner monitor.")
        sys.exit(0)


if __name__ == "__main__":
    main()
