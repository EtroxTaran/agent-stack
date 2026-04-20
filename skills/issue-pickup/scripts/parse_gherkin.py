#!/usr/bin/env python3
"""parse_gherkin.py - Extract AC slugs from a GitHub Issue body.

Reads Markdown (stdin or file arg) and emits one line per Gherkin
Scenario found inside a ```gherkin ... ``` fenced block:

    AC-1: <kebab-slug of scenario title>
    AC-2: <kebab-slug of scenario title>

Exit codes:
    0  at least one Scenario found
    1  no gherkin block or no scenarios (caller should stop)
    2  malformed input

Deutscher Kommentar: bewusst reines Python 3 stdlib, damit Skill in
jeder CLI ohne pip install laeuft.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

GHERKIN_FENCE = re.compile(
    r"```gherkin\s*\n(.*?)\n```",
    re.DOTALL | re.IGNORECASE,
)
SCENARIO_LINE = re.compile(
    r"^\s*Scenario(?:\s+Outline)?:\s*(.+?)\s*$",
    re.MULTILINE,
)
SLUG_CLEAN = re.compile(r"[^a-z0-9]+")


def slugify(title: str, max_len: int = 60) -> str:
    lower = title.lower()
    slug = SLUG_CLEAN.sub("-", lower).strip("-")
    return slug[:max_len].rstrip("-")


def extract(body: str) -> list[str]:
    scenarios: list[str] = []
    for block in GHERKIN_FENCE.findall(body):
        for match in SCENARIO_LINE.finditer(block):
            scenarios.append(match.group(1).strip())
    return scenarios


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        path = Path(argv[1])
        if not path.exists():
            print(f"parse_gherkin: file not found: {path}", file=sys.stderr)
            return 2
        body = path.read_text(encoding="utf-8")
    else:
        body = sys.stdin.read()

    if not body.strip():
        print("parse_gherkin: empty input", file=sys.stderr)
        return 2

    scenarios = extract(body)
    if not scenarios:
        print(
            "parse_gherkin: no ```gherkin``` block with Scenario found",
            file=sys.stderr,
        )
        return 1

    for idx, title in enumerate(scenarios, start=1):
        print(f"AC-{idx}: {slugify(title)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
