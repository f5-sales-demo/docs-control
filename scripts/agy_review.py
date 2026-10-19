#!/usr/bin/env python3
"""Trusted review supervisor. Provider text is private until validated and redacted."""

from __future__ import annotations

# pylint: disable=too-many-return-statements,too-many-locals,too-many-branches,too-many-statements,consider-using-with,unidiomatic-typecheck
# Argument arrays are intentional; strict validators use explicit early failure returns.
# ruff: noqa: S603, S607, PLR0911, PLR2004, TRY301
import argparse
import contextlib
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import cast

from redact_automation_log import redact_line

TOOLS = Path(__file__).resolve().parent
ATTEMPT_CAP = 720
OVERALL_BUDGET = 2700
ACTIVE_GROUPS: set[int] = set()
MODEL_RE = re.compile(r"^gemini-(\d+(?:\.\d+)*)(?:-[a-z0-9]+)*-high$")
TRANSIENT = re.compile(
    r"timeout|timed out|network|connection|rate.?limit|429|service (unavailable|error)|temporar",
    re.IGNORECASE,
)
UNAVAILABLE = re.compile(
    r"model.*(?:unavailable|not found|not supported)|unknown model", re.IGNORECASE
)


def digest(*parts: str) -> str:
    """Hash newline-delimited receipt components."""
    return hashlib.sha256(("\n".join(parts) + "\n").encode()).hexdigest()


def git(root: Path, *args: str) -> str:
    """Read Git data with an argument array and no shell."""
    return (
        subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL)
        .decode()
        .strip()
    )


def stop_group(pid: int) -> None:
    """Terminate the provider group, including inherited descriptor holders."""
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    # Do not let a provider trap delay cleanup beyond the deadline.
    with contextlib.suppress(ProcessLookupError):
        os.killpg(pid, signal.SIGKILL)


def interrupted(signum: int, _frame: object) -> None:
    """Propagate cancellation to every active provider group."""
    for pid in tuple(ACTIVE_GROUPS):
        stop_group(pid)
    raise SystemExit(124 if signum == signal.SIGALRM else 128 + signum)


for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGALRM):
    signal.signal(sig, interrupted)


def bounded(
    command: list[str],
    cwd: Path,
    work: Path,
    name: str,
    seconds: float,
    env: dict[str, str] | None = None,
) -> tuple[int, str, str, int]:
    """Regular private files avoid inherited FIFO descriptors blocking completion."""
    if seconds <= 0:
        return 124, "", "", 0
    started = time.monotonic()
    heartbeat = started
    stdout = work / f"{name}.stream"
    stderr = work / f"{name}.stderr"
    with stdout.open("wb") as out, stderr.open("wb") as err:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdout=out,
            stderr=err,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        ACTIVE_GROUPS.add(process.pid)
        try:
            while process.poll() is None:
                if time.monotonic() - heartbeat >= 30:
                    print(
                        f"[review] {name} running elapsed_seconds={int(time.monotonic() - started)}",
                        file=sys.stderr,
                    )
                    heartbeat = time.monotonic()
                if time.monotonic() - started >= seconds:
                    stop_group(process.pid)
                    process.wait(timeout=5)
                    return (
                        124,
                        stdout.read_text(errors="replace"),
                        stderr.read_text(errors="replace"),
                        int(time.monotonic() - started),
                    )
                time.sleep(min(0.1, max(0.01, seconds)))
            # Kill descendants even if the direct provider exited successfully.
            stop_group(process.pid)
            return (
                process.returncode,
                stdout.read_text(errors="replace"),
                stderr.read_text(errors="replace"),
                int(time.monotonic() - started),
            )
        finally:
            stop_group(process.pid)
            process.wait(timeout=5)
            ACTIVE_GROUPS.discard(process.pid)


def redact(value: object) -> object:
    """Sanitize diagnostic and structured string values before publication."""
    if isinstance(value, str):
        # Drop PEM blocks before line redaction; never publish their contents.
        value = re.sub(
            r"-----BEGIN [A-Z0-9 ]+-----.*?(?:-----END [A-Z0-9 ]+-----|\Z)",
            "[REDACTED_PEM_BLOCK]",
            value,
            flags=re.DOTALL,
        )
        return redact_line(value)
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, dict):
        return {key: redact(item) for key, item in value.items()}
    return value


def atomic_json(path: Path, value: object) -> None:
    """Replace a report only after flushing a complete private temporary file."""
    path = path.absolute()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        Path(temporary).replace(path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def valid_result(result: object, receipt: str, required: list[str]) -> bool:
    """Validate every schema field and required coverage path."""
    if not isinstance(result, dict) or set(result) != {
        "verdict",
        "summary",
        "findings",
        "next_steps",
        "review_target_receipt",
        "coverage",
    }:
        return False
    if (
        result["verdict"] not in ("approve", "needs-attention")
        or not isinstance(result["summary"], str)
        or not result["summary"]
    ):
        return False
    if (
        result["review_target_receipt"] != receipt
        or not isinstance(result["next_steps"], list)
        or not all(isinstance(x, str) and x for x in result["next_steps"])
    ):
        return False
    coverage = result["coverage"]
    if not isinstance(coverage, dict) or set(coverage) != {
        "status",
        "read_files",
        "denied_reads",
    }:
        return False
    if (
        coverage["status"] != "complete"
        or coverage["denied_reads"] != []
        or not isinstance(coverage["read_files"], list)
    ):
        return False
    if (
        not all(isinstance(x, str) and x for x in coverage["read_files"])
        or len(set(coverage["read_files"])) != len(coverage["read_files"])
        or not set(required).issubset(coverage["read_files"])
    ):
        return False
    if not isinstance(result["findings"], list):
        return False
    for finding in result["findings"]:
        if not isinstance(finding, dict) or set(finding) != {
            "severity",
            "title",
            "body",
            "file",
            "line_start",
            "line_end",
            "confidence",
            "recommendation",
        }:
            return False
        if finding["severity"] not in ("critical", "high", "medium", "low"):
            return False
        if not all(
            isinstance(finding[x], str) and finding[x]
            for x in ("title", "body", "file")
        ) or not isinstance(finding["recommendation"], str):
            return False
        if (
            not all(
                type(finding[x]) is int and finding[x] >= 1
                for x in ("line_start", "line_end")
            )
            or finding["line_end"] < finding["line_start"]
        ):
            return False
        if (
            type(finding["confidence"]) not in (float, int)
            or not 0 <= finding["confidence"] <= 1
        ):
            return False
    return True


def failure(receipt: str, reason: str) -> dict:
    """Return a fixed non-approving result without provider text."""
    return {
        "verdict": "needs-attention",
        "summary": f"Review execution failed ({reason}); no approval granted.",
        "findings": [],
        "next_steps": ["Repair execution and rerun both passes."],
        "review_target_receipt": receipt,
        "coverage": {"status": "incomplete", "read_files": [], "denied_reads": []},
    }


def stream_result(
    stream: str, model: str, receipt: str, required: list[str]
) -> tuple[dict, dict]:
    """Bind successful structured output to stream model and conversation metadata."""
    rows = [json.loads(line) for line in stream.splitlines() if line.strip()]
    init = [row for row in rows if row.get("event") == "init"]
    results = [row for row in rows if row.get("event") == "result"]
    if len(init) != 1 or len(results) != 1:
        msg = "missing or duplicate init/result"
        raise ValueError(msg)
    first, last = init[0], results[0]["result"]
    conversation = first.get("conversation_id")
    if (
        not isinstance(conversation, str)
        or not conversation
        or conversation != last.get("conversation_id")
    ):
        msg = "invalid conversation identity"
        raise ValueError(msg)
    if first.get("init", {}).get("model") != model or last.get("status") != "SUCCESS":
        msg = "invalid model/status"
        raise ValueError(msg)
    for row in rows:
        if row.get("event") != "result" and re.search(
            r"permission denied|read denied|access denied|requires? approval",
            json.dumps(row),
            re.IGNORECASE,
        ):
            msg = "denied required read"
            raise ValueError(msg)
    result = last.get("structured_output")
    if not valid_result(result, receipt, required):
        msg = "invalid receipt/coverage/schema"
        raise ValueError(msg)
    return result, {
        "conversation_id": conversation,
        "actual_model": first["init"]["model"],
        "effort": "high",
        "effort_evidence": "explicit-cli-argument",
    }


def eligible_catalog(text: str) -> str:
    """Select the sole newest stable flagship High catalog identifier."""
    candidates: dict[tuple[int, ...], list[str]] = {}
    for line in text.splitlines():
        token = line.split()[0] if line.split() else ""
        match = MODEL_RE.fullmatch(token)
        if not match or re.search(
            r"flash|lite|preview|experimental|beta", token, re.IGNORECASE
        ):
            continue
        version = tuple(int(part) for part in match[1].split("."))
        candidates.setdefault(version, []).append(token)
    if not candidates or len(set(candidates[max(candidates)])) != 1:
        msg = "catalog-failure-or-ambiguous"
        raise ValueError(msg)
    return candidates[max(candidates)][0]


def snapshot(root: Path, excluded: set[Path]) -> str:
    # Bind relevant source to actual filesystem bytes, including untracked documents.
    """Hash repository source bytes and reject externally resolving symlinks."""
    paths = (
        subprocess.check_output(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=root,
        )
        .decode()
        .split("\0")
    )
    h = hashlib.sha256()
    for name in sorted(set(paths) - {""}):
        path = root / name
        if path in excluded or any(
            parent.name.startswith(".agy-review.")
            for parent in path.relative_to(root).parents
        ):
            continue
        h.update(name.encode())
        if path.is_symlink():
            resolved = path.resolve()
            if not resolved.is_relative_to(root):
                msg = "external source symlink"
                raise ValueError(msg)
            h.update(str(path.readlink()).encode())
        if path.is_file():
            h.update(path.read_bytes())
        elif path.is_dir():
            h.update(b"directory")
        else:
            h.update(b"missing")
    h.update(git(root, "rev-parse", "HEAD").encode())
    return h.hexdigest()


def main() -> int:
    """Resolve the target and require two independent verified approvals."""
    if os.environ.get("AGY_REVIEW_ACTIVE") == "1":
        msg = "nested review refused"
        raise ValueError(msg)
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("code", "document"))
    parser.add_argument("--base")
    parser.add_argument("--kind", choices=("spec", "plan"))
    parser.add_argument("--file")
    args = parser.parse_args()
    signal.setitimer(signal.ITIMER_REAL, OVERALL_BUDGET)
    invocation = Path.cwd()
    root = Path(git(invocation, "rev-parse", "--show-toplevel")).resolve()
    document = (invocation / args.file).resolve() if args.file else None
    report_path = (
        Path(os.environ["AGY_REVIEW_REPORT_FILE"]).absolute()
        if os.environ.get("AGY_REVIEW_REPORT_FILE")
        else None
    )
    os.umask(0o077)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix=".agy-review.", dir=root) as directory:
        work = Path(directory)
        env = {
            k: v
            for k, v in os.environ.items()
            if k
            not in {
                "GH_TOKEN",
                "GITHUB_TOKEN",
                "REPO_SETTINGS_TOKEN",
                "REPO_SYNC_TOKEN",
                "GATEWAY_TOKEN",
                "GATEWAY_URL",
                "ANTIGRAVITY_TOKEN",
            }
        }
        env["AGY_REVIEW_ACTIVE"] = "1"
        head = git(root, "rev-parse", "HEAD")
        if args.mode == "code":
            if not args.base or args.kind or args.file:
                parser.error("code requires --base and no document options")
            if git(root, "status", "--porcelain"):
                msg = "commit or stash changes before code review"
                raise ValueError(msg)
            base = git(root, "rev-parse", "--verify", f"{args.base}^{{commit}}")
            merge_base = git(root, "merge-base", base, head)
            target = {
                "version": 2,
                "mode": "code",
                "base_sha": base,
                "merge_base_sha": merge_base,
                "head_sha": head,
            }
            receipt = digest("agy-review-target-v2", "code", base, merge_base, head)
            changed = (
                subprocess.check_output(
                    ["git", "diff", "--name-only", "-z", f"{merge_base}...{head}"],
                    cwd=root,
                )
                .decode()
                .split("\0")
            )
            required = sorted(set(changed) - {""})
            if not required:
                print("[review] no branch diff to review")
                return 0
            data = (
                git(root, "log", "--format=commit %H%n%B", f"{merge_base}..{head}")
                + "\n"
                + git(
                    root,
                    "diff",
                    "--no-ext-diff",
                    "--no-color",
                    f"{merge_base}...{head}",
                )
            )
            target_file = work / "code-review-target.txt"
            target_file.write_text(data)
            required.append(str(target_file.relative_to(root)))
            instructions = f"Read {target_file.relative_to(root)} completely, including deleted-file content. Inspect changed files and relevant source/tests read-only. Do not run terminal commands."
            description = (
                f"committed branch {merge_base}...{head}, supplied base {base}"
            )
        else:
            if not args.kind or not document or args.base:
                parser.error("document requires --kind and --file and no --base")
            if not document.is_relative_to(root) or not document.is_file():
                msg = "document must resolve to a regular file inside repository"
                raise ValueError(msg)
            file_hash = hashlib.sha256(document.read_bytes()).hexdigest()
            relative = str(document.relative_to(root))
            target = {
                "version": 2,
                "mode": "document",
                "kind": args.kind,
                "file": relative,
                "document_sha256": file_hash,
                "head_sha": head,
            }
            receipt = digest(
                "agy-review-target-v2", "document", args.kind, relative, file_hash, head
            )
            frozen = work / "document-review-target.txt"
            frozen.write_bytes(document.read_bytes())
            required = [relative, str(frozen.relative_to(root))]
            instructions = f"Read frozen document {frozen.relative_to(root)} completely and verify material claims against repository source."
            description = f"{args.kind} document {relative}"
        target["receipt"] = receipt
        target["required_paths"] = required
        excluded = {report_path} if report_path else set()
        before = snapshot(root, excluded)
        if (
            args.mode == "code"
            and os.environ.get("AGY_REVIEW_SKIP_LOCAL_PII") != "1"
            and (root / "scripts/check-pii.sh").is_file()
        ):
            rc, _, _, _ = bounded(
                [
                    "bash",
                    str(TOOLS / "run-with-progress.sh"),
                    "--phase",
                    "pii-preflight",
                    "--",
                    "bash",
                    str(TOOLS / "check-pii.sh"),
                    "--scope",
                    "changed",
                    "--base",
                    base,
                    "--mode",
                    "enforce",
                ],
                root,
                work,
                "pii",
                min(ATTEMPT_CAP, OVERALL_BUDGET - (time.monotonic() - started)),
                env,
            )
            if rc:
                msg = "PII preflight failed"
                raise ValueError(msg)
        diagnostics = Path(
            os.environ.get("AGY_REVIEW_DIAGNOSTIC_DIR", str(work / "diagnostics"))
        )
        diagnostics.mkdir(parents=True, exist_ok=True)
        attempts: list[dict] = []
        policy = json.loads((TOOLS / "agy-model-policy.json").read_text())
        fallback = (
            policy.get("last_verified_model") if policy.get("qualification") else None
        )
        model: str | None
        requested = None
        reason = None
        rc, catalog, catalog_stderr, _ = bounded(
            ["agy", "models"],
            root,
            work,
            "catalog",
            min(60, OVERALL_BUDGET - (time.monotonic() - started)),
            env,
        )
        try:
            if rc:
                msg = "catalog-unavailable"
                raise ValueError(msg)
            requested = eligible_catalog(catalog)
            model = requested
        except ValueError:
            for suffix, text in (("stdout", catalog), ("stderr", catalog_stderr)):
                (diagnostics / f"catalog.{suffix}.txt").write_text(
                    str(redact(text))[:4096]
                )
            model = fallback
            reason = "catalog-unavailable-or-ambiguous"
        results = {
            phase: failure(receipt, "model-unqualified")
            for phase in ("reviewer", "verifier")
        }
        sessions: dict[str, dict] = {}
        pair = 0
        while model:
            pair += 1
            sessions = {}
            results = {
                phase: failure(receipt, "not-executed")
                for phase in ("reviewer", "verifier")
            }
            restart = False
            for phase in ("reviewer", "verifier"):
                prompt = (
                    (TOOLS / "agy-review-policy.txt")
                    .read_text()
                    .format(
                        description=description,
                        instructions=instructions,
                        receipt=receipt,
                    )
                )
                prompt += (
                    "\nRequired coverage paths: "
                    + json.dumps(required)
                    + "\nRead every required input fully. Return coverage.status complete only when all required reads succeeded; record read_files and denied_reads. Denied reads and incomplete coverage cannot approve.\n"
                )
                if phase == "verifier":
                    previous = work / "reviewer.json"
                    atomic_json(previous, results["reviewer"])
                    prompt += f"Independently verify the first review in {previous.relative_to(root)} and look for material omissions.\n"
                for count in range(1, 4):
                    remaining = OVERALL_BUDGET - (time.monotonic() - started)
                    reserve = ATTEMPT_CAP * (2 if phase == "reviewer" else 1)
                    if remaining < reserve:
                        results[phase] = failure(receipt, "budget-exhausted")
                        break
                    command = [
                        "agy",
                        "--new-project",
                        "--sandbox",
                        "--mode",
                        "plan",
                        "--disable-slash-commands",
                        "--model",
                        model,
                        "--effort",
                        "high",
                        "--output-format",
                        "stream-json",
                        "--json-schema",
                        str(TOOLS / "agy-review-output.schema.json"),
                        "--print-timeout",
                        "12m",
                        "--print",
                        prompt,
                    ]
                    rc, stream, stderr, elapsed = bounded(
                        command,
                        root,
                        work,
                        f"{phase}-{pair}-{count}",
                        min(ATTEMPT_CAP, remaining),
                        env,
                    )
                    classification = "deterministic-cli-failure"
                    if rc == 0:
                        try:
                            result, session = stream_result(
                                stream, model, receipt, required
                            )
                            if (
                                phase == "verifier"
                                and session["conversation_id"]
                                == sessions["reviewer"]["conversation_id"]
                            ):
                                msg = "sessions not independent"
                                raise ValueError(msg)
                            results[phase], sessions[phase] = result, session
                            classification = "success"
                        except (ValueError, KeyError, TypeError, AttributeError):
                            classification = "invalid-review-receipt"
                    else:
                        diagnostics_only = []
                        for line in stream.splitlines():
                            try:
                                row = json.loads(line)
                            except ValueError:
                                diagnostics_only.append(line)
                                continue
                            if isinstance(row, dict) and row.get("event") == "result":
                                diagnostics_only.append(
                                    str(row.get("result", {}).get("error", ""))
                                )
                            else:
                                diagnostics_only.append(line)
                        nonresult = "\n".join(diagnostics_only)
                        if (
                            UNAVAILABLE.search(stderr + nonresult)
                            and fallback
                            and model != fallback
                            and reason is None
                        ):
                            classification = "model-unavailable"
                            model, reason, restart = (
                                fallback,
                                "requested-model-unavailable",
                                True,
                            )
                        elif rc == 124 or TRANSIENT.search(stderr + nonresult):
                            classification = "transient-cli-failure"
                    attempts.append(
                        {
                            "phase": phase,
                            "count": count,
                            "class": classification,
                            "exit_status": rc,
                            "elapsed_seconds": elapsed,
                            "pair": pair,
                        }
                    )
                    if classification == "success":
                        print(
                            f"[review] {phase} completed; validated structured output",
                            file=sys.stderr,
                        )
                        break
                    for suffix, text in (
                        ("summary", stream),
                        ("stderr-summary", stderr),
                    ):
                        (
                            diagnostics
                            / f"{phase}-pair-{pair}-attempt-{count}.{suffix}.txt"
                        ).write_text(str(redact(text))[:4096])
                    results[phase] = failure(receipt, classification)
                    if (
                        restart
                        or classification != "transient-cli-failure"
                        or count == 3
                    ):
                        break
                    backoff = 5 if count == 1 else 15
                    if (
                        OVERALL_BUDGET - (time.monotonic() - started)
                        < reserve + backoff
                    ):
                        results[phase] = failure(receipt, "budget-exhausted")
                        break
                    time.sleep(backoff)
                if restart or phase not in sessions:
                    break
            if restart:
                continue
            break
        stable = before == snapshot(root, excluded)
        if document:
            stable = (
                stable
                and document.is_file()
                and hashlib.sha256(document.read_bytes()).hexdigest()
                == target["document_sha256"]
                and (invocation / args.file).resolve() == document
            )
        approved = (
            stable
            and len(sessions) == 2
            and all(
                result["verdict"] == "approve"
                and not any(
                    f["severity"] in ("critical", "high") for f in result["findings"]
                )
                for result in results.values()
            )
        )
        report = {
            "report_version": 2,
            "target": target,
            "source_stable": stable,
            "model": {
                "requested_model": requested,
                "actual_model": model if sessions else None,
                "effort": "high",
                "fallback_reason": reason,
                "latest_model_accepted": approved and reason is None,
                "fallback_qualification": policy.get("qualification")
                if reason
                else None,
            },
            "sessions": sessions,
            **results,
            "attempt_metadata": attempts,
        }
        report = cast("dict", redact(report))
        if report_path:
            atomic_json(report_path, report)
        print(json.dumps(report, indent=2))
        print(
            "[review] Antigravity gate "
            + (
                "passed: two explicit approvals"
                if approved
                else "blocked: approval, coverage, identity or stable input requirement failed"
            ),
            file=sys.stderr,
        )
        return 0 if approved else 3


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Exception details can contain target data; public diagnostics use a fixed message.
        print(
            f"[review] execution refused ({type(error).__name__}); no approval granted",
            file=sys.stderr,
        )
        sys.exit(1)
