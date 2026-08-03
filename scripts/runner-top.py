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


def get_governed_repos(gov_path=GOVERNANCE_PATH):
    if not gov_path.exists():
        return []
    try:
        with open(gov_path, "r", encoding="utf-8") as f:
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

                p_type = None
                if "Runner.Listener" in cmd:
                    p_type = "Listener"
                elif "Runner.Worker" in cmd:
                    p_type = "Worker"
                elif "runsvc.sh" in cmd:
                    p_type = "Service"
                else:
                    continue

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


def fetch_gh_runner_statuses(gov_path=GOVERNANCE_PATH, base_dir=DEFAULT_BASE_DIR):
    """
    Aggregate local runner process status across governed repositories.
    """
    repos = get_governed_repos(gov_path)
    statuses = {}
    for repo in repos:
        repo_dir = base_dir / repo
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
        if r in statuses:
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
  {"REPO NAME":<30} {"STATUS":<15} {"PID":<8} {"CPU %":<8} {"MEM (MB)":<10}
--------------------------------------------------------------------------------"""
    print(header)

    for repo, data in sorted(statuses.items()):
        st = data["status"]
        if st == "online":
            if data["busy"]:
                raw_st = "ONLINE (BUSY)"
                st_str = f"\033[33m{raw_st:<15}\033[0m"
            else:
                raw_st = "ONLINE (IDLE)"
                st_str = f"\033[32m{raw_st:<15}\033[0m"
        else:
            raw_st = "OFFLINE"
            st_str = f"\033[31m{raw_st:<15}\033[0m"

        pid_str = str(data["pid"])
        cpu_str = f"{data['cpu']:.1f}%" if data['status'] == 'online' else "-"
        mem_str = f"{data['mem_mb']:.1f} MB" if data['status'] == 'online' else "-"

        print(f"  {repo:<30} {st_str} {pid_str:<8} {cpu_str:<8} {mem_str:<10}")

    print("================================================================================")
    if not once:
        print("Press Ctrl+C to exit monitor.")


def main():
    parser = argparse.ArgumentParser(description="Real-time process monitor for GitHub Self-Hosted Runners")
    parser.add_argument("--once", action="store_true", help="Print stats once and exit")
    parser.add_argument("--interval", type=int, default=3, help="Refresh interval in seconds (default: 3)")
    parser.add_argument("--base-dir", type=Path, default=DEFAULT_BASE_DIR, help="Base directory for runners")
    parser.add_argument("--governance-path", type=Path, default=GOVERNANCE_PATH, help="Path to docs-control governance.json")
    args = parser.parse_args()

    try:
        while True:
            statuses = fetch_gh_runner_statuses(gov_path=args.governance_path, base_dir=args.base_dir)
            render_top_view(statuses, once=args.once)
            if args.once:
                break
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nExiting runner monitor.")
        sys.exit(0)


if __name__ == "__main__":
    main()
