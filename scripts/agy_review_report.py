#!/usr/bin/env python3
"""Shared exact-target producer/consumer validation; no model claims from prompts."""

# Receipt field-by-field early returns keep the fail-closed contract inspectable.
# ruff: noqa: PLR0911, PLR2004, TRY300

import argparse
import json
import re
from pathlib import Path

from agy_review import digest, valid_result


def validate(
    report: dict,
    *,
    repository: str,
    base: str,
    head: str,
    workflow: str,
    version: str,
    tools: str,
    merge_base: str,
) -> bool:
    """Validate the report envelope and exact producer provenance."""
    try:
        receipt = report["receipt"]
        target = report["target"]
        expected = digest("agy-review-target-v2", "code", base, merge_base, head)
        required = target.get("required_paths")
        if (
            not isinstance(required, list)
            or not required
            or not all(isinstance(path, str) and path for path in required)
        ):
            return False
        if report["report_version"] != 2 or target != {
            "version": 2,
            "mode": "code",
            "base_sha": base,
            "merge_base_sha": merge_base,
            "head_sha": head,
            "receipt": expected,
            "required_paths": required,
        }:
            return False
        if any(
            receipt[key] != value
            for key, value in {
                "repository": repository,
                "base_sha": base,
                "head_sha": head,
                "workflow_sha": workflow,
                "agy_version": version,
                "tools_sha": tools,
            }.items()
        ):
            return False
        if (
            type(receipt["tool_status"]) is not int
            or not 0 <= receipt["tool_status"] <= 255
        ):
            return False
        attempts = report["attempt_metadata"]
        if not isinstance(attempts, list) or len(attempts) > 12:
            return False
        for attempt in attempts:
            if set(attempt) != {
                "phase",
                "count",
                "class",
                "exit_status",
                "elapsed_seconds",
                "pair",
            }:
                return False
            if (
                attempt["phase"] not in ("reviewer", "verifier")
                or attempt["count"] not in (1, 2, 3)
                or attempt["pair"] not in (1, 2)
            ):
                return False
            if not isinstance(attempt["class"], str) or not re.fullmatch(
                r"[a-z-]{1,64}", attempt["class"]
            ):
                return False
            if (
                type(attempt["exit_status"]) is not int
                or not 0 <= attempt["exit_status"] <= 255
                or type(attempt["elapsed_seconds"]) is not int
                or not 0 <= attempt["elapsed_seconds"] <= 725
            ):
                return False
        if receipt["tool_status"] == 0:
            return gate(report)
        # Failed runs can publish only a bounded failure report, never approval.
        return all(
            isinstance(report[phase], dict)
            and report[phase]["review_target_receipt"] == expected
            and report[phase]["verdict"] in ("approve", "needs-attention")
            for phase in ("reviewer", "verifier")
        )
    except (KeyError, TypeError, ValueError):
        return False


def gate(report: dict) -> bool:
    """Validate the report approval, session and completeness contract."""
    try:
        if report["receipt"]["tool_status"] != 0 or report["source_stable"] is not True:
            return False
        model = report["model"]
        if not isinstance(model["actual_model"], str) or model["effort"] != "high":
            return False
        if model["fallback_reason"] is None:
            if (
                model["requested_model"] != model["actual_model"]
                or model["latest_model_accepted"] is not True
            ):
                return False
        elif (
            not model["fallback_qualification"]
            or model["latest_model_accepted"] is not False
        ):
            return False
        sessions = report["sessions"]
        if (
            set(sessions) != {"reviewer", "verifier"}
            or sessions["reviewer"]["conversation_id"]
            == sessions["verifier"]["conversation_id"]
        ):
            return False
        for phase in ("reviewer", "verifier"):
            session = sessions[phase]
            result = report[phase]
            if (
                not session["conversation_id"]
                or session["actual_model"] != model["actual_model"]
                or session["effort"] != "high"
            ):
                return False
            if (
                not valid_result(
                    result,
                    report["target"]["receipt"],
                    report["target"]["required_paths"],
                )
                or result["verdict"] != "approve"
            ):
                return False
            if any(
                finding["severity"] in ("high", "critical")
                for finding in result["findings"]
            ):
                return False
        return True
    except (KeyError, TypeError, ValueError):
        return False


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--gate", action="store_true")
    for option in (
        "repository",
        "base",
        "head",
        "workflow",
        "version",
        "tools",
        "merge-base",
    ):
        parser.add_argument("--" + option)
    args = parser.parse_args()
    value = json.loads(args.report.read_text())
    ok = (
        gate(value)
        if args.gate
        else validate(
            value,
            repository=args.repository,
            base=args.base,
            head=args.head,
            workflow=args.workflow,
            version=args.version,
            tools=args.tools,
            merge_base=args.merge_base,
        )
    )
    raise SystemExit(0 if ok else 1)
