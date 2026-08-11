# mypy: ignore-errors
# pylint: disable=too-many-arguments,too-many-instance-attributes,too-many-public-methods,consider-using-with,protected-access
"""Hermetic procfs/systemd/recovery tests for managed GitHub runners."""

import contextlib
import importlib.util
import io
import shutil
import signal
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts/manage-github-runners.py"
SPEC = importlib.util.spec_from_file_location("manage_github_runners", SCRIPT)
runner_module = importlib.util.module_from_spec(SPEC)
sys.modules["manage_github_runners"] = runner_module
SPEC.loader.exec_module(runner_module)


class Result:
    def __init__(self, stdout="", returncode=0):
        self.stdout = stdout
        self.stderr = ""
        self.returncode = returncode


class FakeGitHub:
    def __init__(self, runners):
        self.items = runners

    def runners(self, _org, _repo):
        return self.items


class Clock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        self.value += 1.0
        return self.value


class RunnerManagerTests(unittest.TestCase):
    org = "f5-sales-demo"
    repo = "terraform-provider-xcsh"
    user = "robin"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.base = self.root / "runners"
        self.proc = self.root / "proc"
        self.systemd = self.root / "systemd"
        self.repo_dir = self.base / self.repo
        self.archive = self.root / "runner.tar.gz"
        self.archive.write_text("fixture", encoding="utf-8")
        self.base.mkdir()
        self.proc.mkdir()
        self.systemd.mkdir()
        self.fake_bash = self.root / "bin/bash"
        self.fake_node = self.root / "bin/node"
        self.fake_bash.parent.mkdir()
        self.fake_bash.touch()
        self.fake_node.touch()
        self.unit = runner_module.RunnerManager.unit_name(self.org, self.repo)
        self.control_group = f"/system.slice/{self.unit}"
        self.load_state = "loaded"
        self.active = True
        self.metadata_overrides = {}
        self.fail = set()
        self.calls = []
        self.signals = []
        self.removed = []
        self.runner = self.runner_record()
        self.github = FakeGitHub([self.runner])
        self.create_installation(self.repo_dir)
        self.start_processes(self.repo_dir)
        self.manager = self.make_manager()

    def tearDown(self):
        self.temp.cleanup()

    def runner_record(self, **changes):
        record = {
            "name": f"runner-ubuntu-{self.repo}",
            "status": "online",
            "busy": False,
            "labels": [
                {"name": label}
                for label in [
                    "self-hosted",
                    "Linux",
                    "X64",
                    self.repo,
                    self.org,
                ]
            ],
        }
        record.update(changes)
        return record

    def create_installation(self, path):
        path.mkdir(parents=True, exist_ok=True)
        (path / "bin").mkdir(exist_ok=True)
        for relative in (
            "bin/Runner.Listener",
            "bin/Runner.Worker",
            "bin/RunnerService.js",
            "runsvc.sh",
            "svc.sh",
            "config.sh",
        ):
            (path / relative).touch()
        (path / ".service").write_text(self.unit, encoding="utf-8")
        (self.systemd / self.unit).write_text("[Service]\n", encoding="utf-8")

    def add_process(
        self,
        pid,
        executable,
        cwd,
        command_line,
        cgroup=None,
        start_time=9001,
        parent_pid=1,
    ):
        process = self.proc / str(pid)
        process.mkdir(parents=True, exist_ok=True)
        executable = Path(executable)
        if not executable.is_absolute():
            executable = Path(cwd) / executable
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.touch(exist_ok=True)
        (process / "exe").symlink_to(executable)
        (process / "cwd").symlink_to(cwd)
        fields = ["S", str(parent_pid), *(["0"] * 17), str(start_time), "0"]
        (process / "stat").write_text(
            f"{pid} (runner fixture) " + " ".join(fields), encoding="utf-8"
        )
        (process / "cgroup").write_text(
            f"0::{cgroup or self.control_group}\n", encoding="utf-8"
        )
        (process / "cmdline").write_bytes(
            b"\0".join(str(item).encode() for item in command_line) + b"\0"
        )

    def delete_process(self, pid):
        path = self.proc / str(pid)
        if path.exists():
            shutil.rmtree(path)

    def clear_processes(self):
        for child in list(self.proc.iterdir()):
            if child.is_dir():
                shutil.rmtree(child)

    def start_processes(self, path):
        self.clear_processes()
        self.add_process(
            77,
            self.fake_bash,
            path,
            [str(path / "runsvc.sh")],
            start_time=9077,
        )
        self.add_process(
            101,
            path / "bin/Runner.Listener",
            path,
            [str(path / "bin/Runner.Listener"), "run", "--startuptype", "service"],
            parent_pid=77,
        )

    def command(self, command, cwd=None, check=True, sudo=False, **_kwargs):
        self.calls.append((list(command), Path(cwd) if cwd else None, sudo))
        token = next((item for item in self.fail if item in command), None)
        if token and check:
            raise runner_module.subprocess.CalledProcessError(1, command)
        returncode = 1 if token else 0
        if command[:2] == ["systemctl", "show"]:
            if "--property=SubState" not in command:
                return Result(
                    f"LoadState={self.load_state}\n"
                    f"ActiveState={'active' if self.active else 'inactive'}\n"
                )
            values = {
                "LoadState": self.load_state,
                "ActiveState": "active" if self.active else "inactive",
                "SubState": "running" if self.active else "dead",
                "MainPID": "77" if self.active else "0",
                "FragmentPath": str(self.systemd / self.unit),
                "ExecStart": "{ path="
                + str(self.repo_dir / "runsvc.sh")
                + " ; argv[]=x ; }",
                "User": self.user,
                "ControlGroup": self.control_group,
            }
            values.update(
                {key: str(value) for key, value in self.metadata_overrides.items()}
            )
            return Result(
                "\n".join(f"{key}={value}" for key, value in values.items()) + "\n"
            )
        if command[:2] == ["./svc.sh", "stop"] or command[:2] == ["systemctl", "stop"]:
            if "stop" not in self.fail:
                self.active = False
                self.clear_processes()
            return Result(returncode=returncode)
        if command[:2] == ["./svc.sh", "uninstall"]:
            if "uninstall" not in self.fail:
                self.load_state = "not-found"
                (self.systemd / self.unit).unlink(missing_ok=True)
            return Result(returncode=returncode)
        if command[:1] == ["unlink"]:
            Path(command[1]).unlink()
        if command[:2] == ["tar", "-xzf"]:
            destination = Path(command[command.index("-C") + 1])
            self.create_installation(destination)
        if command[:2] == ["./config.sh", "--url"]:
            self.github.items = [self.runner_record()]
            self.runner = self.github.items[0]
        if command[:2] == ["./svc.sh", "install"]:
            self.load_state = "loaded"
            self.active = False
            (self.systemd / self.unit).write_text("[Service]\n", encoding="utf-8")
            (Path(cwd) / ".service").write_text(self.unit, encoding="utf-8")
        if command[:2] in (["./svc.sh", "start"], ["./svc.sh", "restart"]):
            self.active = True
            self.load_state = "loaded"
            self.start_processes(Path(cwd))
        return Result(returncode=returncode)

    def remove_tree(self, path):
        path = Path(path)
        self.removed.append(path)
        if path.exists():
            shutil.rmtree(path)

    def signal_process(self, pid, sig):
        self.signals.append((pid, sig))
        self.delete_process(pid)

    def make_manager(self, **overrides):
        options = {
            "base_dir": self.base,
            "proc_root": self.proc,
            "systemd_root": self.systemd,
            "command": self.command,
            "github": self.github,
            "sleep": lambda _seconds: None,
            "monotonic": Clock(),
            "signal_process": self.signal_process,
            "remove_tree": self.remove_tree,
            "downloader": lambda _version, _cache: self.archive,
            "latest_version": lambda: "2.336.0",
            "registration_token": lambda _org, _repo: "registration-secret",
            "removal_token": lambda _org, _repo: "removal-secret",
            "user": self.user,
        }
        options.update(overrides)
        return runner_module.RunnerManager(**options)

    def assert_audit_contains(self, text, require_idle=False):
        errors = self.make_manager().audit(self.org, self.repo, require_idle)
        self.assertTrue(any(text in error for error in errors), errors)

    def test_healthy_listener_worker_and_unrelated_spoof(self):
        self.add_process(
            102,
            self.repo_dir / "bin/Runner.Worker",
            self.repo_dir,
            [str(self.repo_dir / "bin/Runner.Worker")],
            parent_pid=101,
        )
        outside = self.root / "outside"
        outside.mkdir()
        spoof = outside / "Runner.Listener"
        spoof.touch()
        self.add_process(103, spoof, outside, [str(spoof)])
        self.assertEqual(self.manager.audit(self.org, self.repo), [])

    def test_missing_directory_and_service_marker_fail(self):
        shutil.rmtree(self.repo_dir)
        self.assert_audit_contains("missing")
        self.create_installation(self.repo_dir)
        (self.repo_dir / ".service").unlink()
        self.assert_audit_contains("missing")

    def test_inactive_service_zero_and_duplicate_listeners_fail(self):
        self.active = False
        self.assert_audit_contains("ActiveState")
        self.active = True
        self.delete_process(101)
        self.assert_audit_contains("found 0")
        self.start_processes(self.repo_dir)
        self.add_process(
            102,
            self.repo_dir / "bin/Runner.Listener",
            self.repo_dir,
            [str(self.repo_dir / "bin/Runner.Listener")],
            parent_pid=77,
        )
        self.assert_audit_contains("found 2")

    def test_mainpid_and_listener_cgroup_must_align(self):
        self.delete_process(77)
        self.assert_audit_contains("MainPID process identity")
        self.start_processes(self.repo_dir)
        (self.proc / "101/cgroup").write_text(
            "0::/system.slice/other.service\n", encoding="utf-8"
        )
        self.assert_audit_contains("outside")

    def test_service_metadata_is_exact(self):
        cases = {
            "FragmentPath": self.systemd / "other.service",
            "ExecStart": self.repo_dir / "wrong.sh",
            "User": "wrong",
            "ControlGroup": "relative",
            "LoadState": "error",
        }
        for field, value in cases.items():
            with self.subTest(field=field):
                self.metadata_overrides = {field: value}
                self.assertTrue(self.make_manager().audit(self.org, self.repo))
        self.metadata_overrides = {}

    def test_github_absent_offline_busy_and_label_drift_fail(self):
        self.github.items = []
        self.assert_audit_contains("found 0")
        self.github.items = [self.runner_record(status="offline")]
        self.assert_audit_contains("not online")
        self.github.items = [self.runner_record(busy=True)]
        self.assertEqual(self.make_manager().audit(self.org, self.repo), [])
        self.assert_audit_contains("busy", require_idle=True)
        for labels in (
            ["self-hosted"],
            ["self-hosted", "Linux", "X64", self.repo, self.org, "extra"],
            ["self-hosted", "Linux", "X64", "ubuntu-latest", self.repo, self.org],
        ):
            self.github.items = [
                self.runner_record(labels=[{"name": label} for label in labels])
            ]
            self.assert_audit_contains("label mismatch")

    def test_sigterm_then_sigkill_and_pid_reuse_are_safe(self):
        identity = self.manager.listeners(self.repo_dir)[0]
        self.assertTrue(self.manager.terminate_identity(identity, 1, 1))
        self.assertEqual(self.signals, [(101, signal.SIGTERM)])

        self.start_processes(self.repo_dir)
        identity = self.manager.listeners(self.repo_dir)[0]
        signals = []

        def kill_only_on_sigkill(pid, sig):
            signals.append(sig)
            if sig == signal.SIGKILL:
                self.delete_process(pid)

        manager = self.make_manager(
            signal_process=kill_only_on_sigkill,
            monotonic=Clock(),
        )
        self.assertTrue(manager.terminate_identity(identity, 1, 1))
        self.assertEqual(signals, [signal.SIGTERM, signal.SIGKILL])

        self.start_processes(self.repo_dir)
        identity = self.manager.listeners(self.repo_dir)[0]
        signals = []

        def reuse_pid(_pid, sig):
            signals.append(sig)
            if sig == signal.SIGTERM:
                stat = self.proc / "101/stat"
                text = stat.read_text(encoding="utf-8").replace("9001", "9999")
                stat.write_text(text, encoding="utf-8")

        manager = self.make_manager(signal_process=reuse_pid, monotonic=Clock())
        self.assertTrue(manager.terminate_identity(identity, 1, 1))
        self.assertEqual(signals, [signal.SIGTERM])

    def test_cleanup_stops_uninstalls_before_removal(self):
        self.manager.cleanup_installation(self.org, self.repo)
        commands = [call[0] for call in self.calls]
        self.assertLess(
            commands.index(["./svc.sh", "stop"]),
            commands.index(["./svc.sh", "uninstall"]),
        )
        self.assertFalse(self.repo_dir.exists())
        self.assertIn(self.repo_dir, self.removed)

    def test_cleanup_failure_never_removes_directory(self):
        self.fail.add("stop")
        with self.assertRaises(RuntimeError):
            self.manager.cleanup_installation(self.org, self.repo)
        self.assertTrue(self.repo_dir.exists())
        self.assertNotIn(self.repo_dir, self.removed)

    def test_stale_unit_without_runner_directory_is_removed(self):
        shutil.rmtree(self.repo_dir)
        self.clear_processes()
        self.active = False
        self.manager.cleanup_installation(self.org, self.repo, remove_directory=False)
        self.assertFalse((self.systemd / self.unit).exists())
        self.assertIn(["systemctl", "daemon-reload"], [call[0] for call in self.calls])
        unlink_call = next(call for call in self.calls if call[0][:1] == ["unlink"])
        self.assertTrue(unlink_call[2])

    def test_stale_unit_symlink_removal_never_deletes_target(self):
        shutil.rmtree(self.repo_dir)
        self.clear_processes()
        self.active = False
        unit_path = self.systemd / self.unit
        unit_path.unlink()
        target = self.root / "must-survive.service"
        target.write_text("sentinel\n", encoding="utf-8")
        unit_path.symlink_to(target)
        self.manager.cleanup_installation(self.org, self.repo, remove_directory=False)
        self.assertFalse(unit_path.exists())
        self.assertEqual(target.read_text(encoding="utf-8"), "sentinel\n")

    def test_stale_unit_disable_failure_is_fatal(self):
        shutil.rmtree(self.repo_dir)
        self.clear_processes()
        self.active = False
        self.fail.add("disable")
        with self.assertRaisesRegex(RuntimeError, "disable failed"):
            self.manager.cleanup_installation(
                self.org, self.repo, remove_directory=False
            )
        self.assertTrue((self.systemd / self.unit).exists())

    def test_unrelated_process_is_never_signaled(self):
        self.clear_processes()
        outside = self.root / "outside"
        outside.mkdir()
        spoof = outside / "Runner.Listener"
        spoof.touch()
        self.add_process(301, spoof, outside, [str(spoof)])
        self.manager.cleanup_installation(self.org, self.repo)
        self.assertEqual(self.signals, [])

    def test_setup_refuses_busy_or_duplicate_registration(self):
        self.github.items = [self.runner_record(busy=True)]
        with self.assertRaisesRegex(RuntimeError, "busy"):
            self.make_manager().setup(self.org, self.repo)
        self.github.items = [self.runner_record(), self.runner_record()]
        with self.assertRaisesRegex(RuntimeError, "duplicate"):
            self.make_manager().setup(self.org, self.repo)

    def test_complete_setup_recovers_and_audits_exact_labels(self):
        marker = self.repo_dir / "old-marker"
        marker.touch()
        self.manager.setup(self.org, self.repo)
        self.assertFalse(marker.exists())
        self.assertFalse(
            self.repo_dir.with_name(self.repo + ".recovery-backup").exists()
        )
        self.assertEqual(self.manager.audit(self.org, self.repo), [])
        commands = [call[0] for call in self.calls]
        config = next(
            command for command in commands if command[:2] == ["./config.sh", "--url"]
        )
        labels = config[config.index("--labels") + 1]
        self.assertEqual(labels, f"{self.repo},{self.org}")
        self.assertNotIn("ubuntu-latest", labels)
        self.assertEqual(commands.count(["./svc.sh", "install", self.user]), 1)
        self.assertEqual(commands.count(["./svc.sh", "start"]), 1)
        backup = self.repo_dir.with_name(self.repo + ".recovery-backup")
        chown = next(command for command in commands if command[:1] == ["chown"])
        self.assertEqual(
            chown,
            [
                "chown",
                "--recursive",
                "--no-dereference",
                "--",
                f"{self.user}:{self.user}",
                str(backup),
            ],
        )

    def test_runner_tree_removal_rejects_arbitrary_path_and_symlink(self):
        outside = self.root / "must-survive"
        outside.mkdir()
        with self.assertRaisesRegex(RuntimeError, "unrecognized"):
            self.manager._remove_runner_tree(self.repo, outside)
        self.assertTrue(outside.exists())

        backup = self.repo_dir.with_name(self.repo + ".recovery-backup")
        backup.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            self.manager._remove_runner_tree(self.repo, backup)
        self.assertTrue(outside.exists())
        self.assertFalse(any(call[0][:1] == ["chown"] for call in self.calls))

        shutil.rmtree(self.repo_dir)
        self.repo_dir.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "must not be a symlink"):
            self.manager.repo_dir(self.repo)

    def test_setup_rejects_dangling_recovery_backup_symlink(self):
        backup = self.repo_dir.with_name(self.repo + ".recovery-backup")
        backup.symlink_to(self.root / "missing", target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "recovery backup already exists"):
            self.manager.setup(self.org, self.repo)

    def test_cleanup_backup_requires_healthy_runner_then_removes_exact_tree(self):
        backup = self.repo_dir.with_name(self.repo + ".recovery-backup")
        backup.mkdir()
        (backup / "root-owned-fixture").touch()
        self.runner["status"] = "offline"
        with self.assertRaisesRegex(RuntimeError, "runner audit fails"):
            self.manager.cleanup_backup(self.org, self.repo)
        self.assertTrue(backup.exists())
        self.runner["status"] = "online"
        self.manager.cleanup_backup(self.org, self.repo)
        self.assertFalse(backup.exists())
        chown_call = next(call for call in self.calls if call[0][:1] == ["chown"])
        self.assertTrue(chown_call[2])
        self.assertEqual(chown_call[0][-1], str(backup))

    def test_failed_ownership_repair_preserves_recovery_backup(self):
        backup = self.repo_dir.with_name(self.repo + ".recovery-backup")
        backup.mkdir()
        self.fail.add("chown")
        with self.assertRaises(runner_module.subprocess.CalledProcessError):
            self.manager.cleanup_backup(self.org, self.repo)
        self.assertTrue(backup.exists())
        self.assertNotIn(backup, self.removed)

    def test_post_setup_failure_restores_old_directory_stopped(self):
        marker = self.repo_dir / "preserve-me"
        marker.touch()
        manager = self.make_manager(
            github=FakeGitHub([self.runner_record(status="offline")])
        )
        with self.assertRaisesRegex(RuntimeError, "post-setup audit"):
            manager.setup(self.org, self.repo)
        self.assertTrue((self.repo_dir / "preserve-me").exists())
        self.assertFalse(self.active)

    def test_remove_unregisters_only_after_local_stop(self):
        self.manager.remove(self.org, self.repo)
        commands = [call[0] for call in self.calls]
        stop_index = commands.index(["./svc.sh", "stop"])
        remove_index = next(
            index
            for index, command in enumerate(commands)
            if command[:2] == ["./config.sh", "remove"]
        )
        self.assertLess(stop_index, remove_index)
        self.assertFalse(self.repo_dir.exists())

    def test_cli_exposes_legacy_and_audit_commands(self):
        for command in (
            "setup",
            "audit",
            "status",
            "restart",
            "stop",
            "remove",
            "cleanup-backup",
            "setup-governed",
            "setup-all",
            "clean-ungoverned",
            "health-check",
        ):
            with (
                self.subTest(command=command),
                self.assertRaises(SystemExit) as raised,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                runner_module.main([command, "--help"])
            self.assertEqual(raised.exception.code, 0)


if __name__ == "__main__":
    unittest.main()
