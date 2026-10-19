#!/usr/bin/env python3
"""Produce a bounded, non-approving envelope if the wrapper cannot write one."""

import sys
from pathlib import Path

from agy_review import atomic_json, digest, failure

output, base, merge_base, head = sys.argv[1:]
receipt = digest("agy-review-target-v2", "code", base, merge_base, head)
atomic_json(
    Path(output),
    {
        "report_version": 2,
        "target": {
            "version": 2,
            "mode": "code",
            "base_sha": base,
            "merge_base_sha": merge_base,
            "head_sha": head,
            "receipt": receipt,
            "required_paths": ["unavailable"],
        },
        "source_stable": False,
        "model": {
            "requested_model": None,
            "actual_model": None,
            "effort": "high",
            "fallback_reason": "wrapper-catastrophe",
            "latest_model_accepted": False,
            "fallback_qualification": None,
        },
        "sessions": {},
        "reviewer": failure(receipt, "wrapper-catastrophe"),
        "verifier": failure(receipt, "wrapper-catastrophe"),
        "attempt_metadata": [],
    },
)
