#!/usr/bin/env python3
"""Generiert die Modell-Sektionen in AGENTS.md aus der committed Registry.

Ziel: CLAUDE.md §8 (Reviewer-Modell-Defaults) und §11 (LLM-Modelle) werden
NICHT manuell gepflegt — sondern aus ai-review-pipeline/registry/MODEL_REGISTRY.env
via Template-Replacement generiert. Das eliminiert Doc-Drift.

Mechanik:
- Sektionen sind zwischen `<!-- model-registry-start -->` und
  `<!-- model-registry-end -->` markiert
- Skript liest Registry, baut Markdown-Block, ersetzt alles dazwischen
- Pre-commit-Hook verhindert manuelle Edits zwischen den Markern

Usage:
  python3 scripts/generate-model-docs.py [--check] [--agents-md PATH]

  --check      Dry-Run, Exit 1 bei Drift (für pre-commit)
  --agents-md  Alternative AGENTS.md (für Tests)
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_AGENTS_MD = REPO_ROOT / "AGENTS.md"
DEFAULT_REGISTRY = (
    Path.home() / "projects" / "ai-review-pipeline" /
    "src" / "ai_review_pipeline" / "registry" / "MODEL_REGISTRY.env"
)

SECTION_START = "<!-- model-registry-start -->"
SECTION_END = "<!-- model-registry-end -->"


# ---------------------------------------------------------------------------
# Registry parser (keep in sync with model-registry-drift-check.py)
# ---------------------------------------------------------------------------


def parse_registry(path: Path) -> dict[str, str]:
    """Minimal env-file parser — stdlib-only."""
    result: dict[str, str] = {}
    if not path.is_file():
        return result
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        result[key.strip()] = value.strip().strip('"\'')
    return result


# ---------------------------------------------------------------------------
# Template
# ---------------------------------------------------------------------------


def render_registry_section(registry: dict[str, str]) -> str:
    """Baut Markdown-Block für AGENTS.md (zwischen den start/end-Markern)."""
    today = datetime.now(timezone.utc).date().isoformat()
    # Safe-get: fehlende Keys werden als "(nicht gepinnt)" gerendert
    def _g(key: str) -> str:
        return registry.get(key) or "(nicht gepinnt)"

    return f"""{SECTION_START}
<!-- AUTO-GENERIERT aus ai-review-pipeline/registry/MODEL_REGISTRY.env -->
<!-- NICHT manuell editieren — Änderungen kommen aus dem Weekly-Drift-Check -->
<!-- Regeneriert: {today} -->

### Reviewer-Modell-Defaults (aus Registry)

| Rolle | Modell | Quelle |
|---|---|---|
| Code-Review (Codex) | CLI-Default | `CODEX_CLI_VERSION={_g("CODEX_CLI_VERSION")}` |
| Code-Cursor | CLI-Default | `CURSOR_AGENT_CLI_VERSION={_g("CURSOR_AGENT_CLI_VERSION")}` |
| Security (Gemini) | `{_g("GEMINI_PRO")}` | `GEMINI_PRO` |
| Design (Claude) | `{_g("CLAUDE_OPUS")}` | `CLAUDE_OPUS` |
| AC-Second-Opinion | `{_g("CLAUDE_OPUS")}` | `CLAUDE_OPUS` |
| Auto-Fix | `{_g("CLAUDE_SONNET")}` | `CLAUDE_SONNET` |
| Fix-Loop | `{_g("CLAUDE_SONNET")}` | `CLAUDE_SONNET` |

### LLM-Modell-Versionen (aus Registry)

- **Claude**: Opus `{_g("CLAUDE_OPUS")}` · Sonnet `{_g("CLAUDE_SONNET")}` · Haiku `{_g("CLAUDE_HAIKU")}`
- **OpenAI**: Coding `{_g("OPENAI_CODING")}`
- **Gemini**: Pro `{_g("GEMINI_PRO")}` · Flash `{_g("GEMINI_FLASH")}`
- **CLI-Pins**: Codex `{_g("CODEX_CLI_VERSION")}` · Cursor-Agent `{_g("CURSOR_AGENT_CLI_VERSION")}`

Registry wird wöchentlich automatisch geprüft (Montag 08:00 UTC) via
[`.github/workflows/model-registry-drift-check.yml`](.github/workflows/model-registry-drift-check.yml).
Drift → auto-PR in [ai-review-pipeline](https://github.com/EtroxTaran/ai-review-pipeline).
Manuelle Overrides via `AI_REVIEW_MODEL_<ROLE>` Env-Var oder
`~/.openclaw/workspace/MODEL_REGISTRY.md` (Dev-Override).

{SECTION_END}"""


# ---------------------------------------------------------------------------
# AGENTS.md editing
# ---------------------------------------------------------------------------


def replace_section(content: str, new_section: str) -> str:
    """Ersetzt den Bereich zwischen den Markers. Wirft bei fehlenden Markers."""
    start_idx = content.find(SECTION_START)
    end_idx = content.find(SECTION_END)
    if start_idx == -1 or end_idx == -1:
        raise ValueError(
            f"AGENTS.md enthält die Marker '{SECTION_START}' / '{SECTION_END}' nicht. "
            f"Erster Setup: Füge die beiden Marker einmalig an der Stelle ein, wo "
            f"die Registry-Sektion leben soll."
        )
    if end_idx < start_idx:
        raise ValueError(
            "AGENTS.md: end-Marker steht vor start-Marker. Datei ist korrupt."
        )

    end_idx += len(SECTION_END)
    return content[:start_idx] + new_section + content[end_idx:]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--agents-md",
        type=Path,
        default=DEFAULT_AGENTS_MD,
        help="Pfad zur AGENTS.md (default: agent-stack/AGENTS.md)",
    )
    parser.add_argument(
        "--registry",
        type=Path,
        default=DEFAULT_REGISTRY,
        help="Pfad zur MODEL_REGISTRY.env",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Dry-Run; Exit 1 bei Drift (für pre-commit)",
    )
    args = parser.parse_args(argv)

    if not args.registry.is_file():
        print(f"❌ Registry nicht gefunden: {args.registry}", file=sys.stderr)
        return 2
    if not args.agents_md.is_file():
        print(f"❌ AGENTS.md nicht gefunden: {args.agents_md}", file=sys.stderr)
        return 2

    registry = parse_registry(args.registry)
    new_section = render_registry_section(registry)

    before = args.agents_md.read_text()
    after = replace_section(before, new_section)

    if before == after:
        print("✅ AGENTS.md ist auf dem aktuellen Stand.")
        return 0

    if args.check:
        print("⚠️  AGENTS.md weicht von der Registry ab.", file=sys.stderr)
        print("   Führe aus: python3 scripts/generate-model-docs.py", file=sys.stderr)
        return 1

    args.agents_md.write_text(after)
    print(f"📝 AGENTS.md regeneriert: {args.agents_md}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
