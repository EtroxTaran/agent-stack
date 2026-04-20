#!/usr/bin/env python3
"""find_ac_tests.py - Heuristic mapping of Gherkin ACs to test files.

Reads a Gherkin-block (stdin or file) + a repo root, scans test files
for keywords from each Scenario's Then-clause, and emits one line per
AC:

    AC-1: covered by tests/foo.test.ts
    AC-2: partial  tests/bar.spec.ts (then-keywords unmatched)
    AC-3: uncovered

Exit codes:
    0  all ACs at least "partial"
    1  one or more "uncovered"
    2  malformed input / no Gherkin

Deutscher Kommentar: reine stdlib, keine pip-deps - muss in jeder CLI
laufen ohne venv-Setup.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

GHERKIN_FENCE = re.compile(
    r"```gherkin\s*\n(.*?)\n```",
    re.DOTALL | re.IGNORECASE,
)
SCENARIO_BLOCK = re.compile(
    r"^\s*Scenario(?:\s+Outline)?:\s*(.+?)\s*$(.*?)(?=^\s*Scenario(?:\s+Outline)?:|\Z)",
    re.MULTILINE | re.DOTALL,
)
THEN_LINE = re.compile(
    r"^\s*(?:Then|And|But)\s+(.+?)\s*$",
    re.MULTILINE | re.IGNORECASE,
)
WORD = re.compile(r"[A-Za-z][A-Za-z0-9_]{2,}")
SLUG_CLEAN = re.compile(r"[^a-z0-9]+")

TEST_GLOBS = (
    "**/*.test.ts",
    "**/*.test.tsx",
    "**/*.test.js",
    "**/*.spec.ts",
    "**/*.spec.tsx",
    "**/*.spec.js",
    "**/test_*.py",
    "**/*_test.py",
    "**/*_test.go",
    "**/*.feature",
)

# stop-words: extremely common English verbs that produce false positives
STOP = {
    "the", "and", "for", "with", "from", "that", "this", "then", "when",
    "should", "must", "will", "have", "has", "can", "not", "are", "was",
    "were", "user", "users", "page", "show", "shows", "see", "seen",
    "system", "feature", "scenario",
}


@dataclass
class AC:
    idx: int
    title: str
    then_keywords: list[str]

    @property
    def slug(self) -> str:
        return SLUG_CLEAN.sub("-", self.title.lower()).strip("-")[:60]


def parse_gherkin(body: str) -> list[AC]:
    acs: list[AC] = []
    for block in GHERKIN_FENCE.findall(body):
        for i, (title, rest) in enumerate(SCENARIO_BLOCK.findall(block), start=1):
            kws: list[str] = []
            for m in THEN_LINE.finditer(rest):
                clause = m.group(1)
                kws.extend(
                    w.lower() for w in WORD.findall(clause)
                    if w.lower() not in STOP
                )
            # dedupe preserving order
            seen = set()
            kws = [k for k in kws if not (k in seen or seen.add(k))]
            acs.append(AC(idx=len(acs) + 1, title=title.strip(), then_keywords=kws))
    return acs


def find_test_files(root: Path) -> list[Path]:
    files: set[Path] = set()
    for pat in TEST_GLOBS:
        for p in root.glob(pat):
            # skip common noise dirs
            if any(part in {"node_modules", "dist", "build", ".next", ".turbo"}
                   for part in p.parts):
                continue
            files.add(p)
    return sorted(files)


def score_file(text: str, ac: AC) -> tuple[int, int]:
    """Return (matches, required). AC 'covered' if matches >= ceil(required/2)."""
    lower = text.lower()
    slug_hit = ac.slug and ac.slug in lower
    title_words = [
        w.lower() for w in WORD.findall(ac.title) if w.lower() not in STOP
    ]
    # required set: AC slug OR >=2 title words AND >=2 Then-keywords
    kw_hits = sum(1 for k in ac.then_keywords if k in lower)
    title_hits = sum(1 for w in title_words if w in lower)
    required = max(2, min(4, len(ac.then_keywords)))
    matches = kw_hits + (1 if slug_hit else 0) + (title_hits // 2)
    return matches, required


def evaluate(acs: list[AC], files: list[Path]) -> list[tuple[AC, str, Path | None]]:
    out: list[tuple[AC, str, Path | None]] = []
    for ac in acs:
        best: tuple[int, int, Path | None] = (0, 1, None)
        for f in files:
            try:
                text = f.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            m, r = score_file(text, ac)
            if m > best[0]:
                best = (m, r, f)
        matches, required, file = best
        if file is None or matches == 0:
            status = "uncovered"
        elif matches >= required:
            status = "covered"
        else:
            status = "partial"
        out.append((ac, status, file))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--body", help="File with issue body (omit for stdin)")
    ap.add_argument("--root", default=".", help="Repo root to scan (default: cwd)")
    ap.add_argument("--json", action="store_true", help="Emit JSON instead of text")
    args = ap.parse_args()

    if args.body:
        body = Path(args.body).read_text(encoding="utf-8")
    else:
        body = sys.stdin.read()

    if not body.strip():
        print("find_ac_tests: empty input", file=sys.stderr)
        return 2

    acs = parse_gherkin(body)
    if not acs:
        print("find_ac_tests: no ```gherkin``` block with Scenarios found",
              file=sys.stderr)
        return 2

    files = find_test_files(Path(args.root).resolve())
    results = evaluate(acs, files)

    uncovered = 0
    if args.json:
        import json
        out = [
            {
                "ac": f"AC-{ac.idx}",
                "title": ac.title,
                "slug": ac.slug,
                "status": status,
                "file": str(file) if file else None,
            }
            for ac, status, file in results
        ]
        print(json.dumps(out, indent=2))
    else:
        for ac, status, file in results:
            suffix = f" {file}" if file else ""
            print(f"AC-{ac.idx}: {status}{suffix}  - {ac.title}")
    uncovered = sum(1 for _, s, _ in results if s == "uncovered")
    return 0 if uncovered == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
