#!/usr/bin/env python3
"""Redact common credential and PII forms from automation logs."""

from __future__ import annotations

import re
import sys

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
IPV4_RE = re.compile(r"(?<!\d)(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?!\d)")
PEM_BEGIN_RE = re.compile(r"-----BEGIN [A-Z0-9][A-Z0-9 ]*-----")
PEM_END_RE = re.compile(r"-----END [A-Z0-9][A-Z0-9 ]*-----")
CREDENTIAL_RE = re.compile(
    r"""
    (?P<key>
      ["']?
      (?:
        authorization|bearer|token|password|secret|api[-_]?key|
        access[-_]?key|private[-_]?key|gateway[-_]?(?:token|url)
      )
      ["']?
    )
    (?P<separator>[ \t]*(?::|=|[ \t])[ \t]*)
    (?:
      (?P<quote>["'])(?P<quoted>[^"'\r\n]*)(?P=quote)
      |
      (?P<bare>(?:(?:bearer|basic)[ \t]+)?[^,}\]\s]+)
    )
    """,
    re.IGNORECASE | re.VERBOSE,
)


def redact_line(line: str) -> str:
    """Replace credential, email, and IPv4 values in one log line."""

    def credential_replacement(match: re.Match[str]) -> str:
        quote = match.group("quote") or ""
        return (
            f"{match.group('key')}{match.group('separator')}"
            f"{quote}[REDACTED_CREDENTIAL]{quote}"
        )

    line = CREDENTIAL_RE.sub(credential_replacement, line)
    line = EMAIL_RE.sub("[REDACTED_EMAIL]", line)
    return IPV4_RE.sub("[REDACTED_IP]", line)


sys.stdin.reconfigure(encoding="utf-8", errors="replace")
in_pem_block = False
for input_line in sys.stdin:
    if in_pem_block:
        if PEM_END_RE.search(input_line):
            in_pem_block = False
        continue
    if PEM_BEGIN_RE.search(input_line):
        sys.stdout.write("[REDACTED_PEM_BLOCK]\n")
        in_pem_block = not PEM_END_RE.search(input_line)
        continue
    sys.stdout.write(redact_line(input_line))
