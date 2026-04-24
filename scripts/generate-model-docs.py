#!/usr/bin/env python3
"""Generiert die Modell-Sektionen in AGENTS.md + Wiki-Overview aus der committed Registry.

Ziel: AGENTS.md §8 (Reviewer-Modell-Defaults) + §11 (LLM-Modelle) UND die
"Die fünf Review-Stufen"-Tabelle in docs/wiki/00-ueberblick.md werden
NICHT manuell gepflegt — sondern aus ai-review-pipeline/registry/MODEL_REGISTRY.env
via Template-Replacement generiert. Das eliminiert Doc-Drift.

Mechanik:
- AGENTS.md-Sektion: zwischen `<!-- model-registry-start -->` / `<!-- model-registry-end -->`
- Wiki-Tabelle:      zwischen `<!-- wiki-review-stages-start -->` / `<!-- wiki-review-stages-end -->`
- Skript liest Registry, baut jeweils Markdown-Block, ersetzt alles dazwischen
- Pre-commit-Hook verhindert manuelle Edits zwischen den Markern

Usage:
  python3 scripts/generate-model-docs.py [--check] [--agents-md PATH] [--wiki-overview PATH]

  --check          Dry-Run, Exit 1 bei Drift (für pre-commit)
  --agents-md      Alternative AGENTS.md (für Tests)
  --wiki-overview  Alternative Wiki-Overview-Datei (für Tests)
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
DEFAULT_WIKI_OVERVIEW = REPO_ROOT / "docs" / "wiki" / "00-ueberblick.md"
DEFAULT_REGISTRY = (
    Path.home()
    / "projects"
    / "ai-review-pipeline"
    / "src"
    / "ai_review_pipeline"
    / "registry"
    / "MODEL_REGISTRY.env"
)

SECTION_START = "<!-- model-registry-start -->"
SECTION_END = "<!-- model-registry-end -->"

WIKI_SECTION_START = "<!-- wiki-review-stages-start -->"
WIKI_SECTION_END = "<!-- wiki-review-stages-end -->"


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
        result[key.strip()] = value.strip().strip("\"'")
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
- **OpenAI (Codex-CLI Main)**: `{_g("OPENAI_MAIN")}`
- **Gemini**: Pro `{_g("GEMINI_PRO")}` · Flash `{_g("GEMINI_FLASH")}`
- **CLI-Pins**: Codex `{_g("CODEX_CLI_VERSION")}` · Cursor-Agent `{_g("CURSOR_AGENT_CLI_VERSION")}`

Registry wird wöchentlich automatisch geprüft (Montag 08:00 UTC) via
[`.github/workflows/model-registry-drift-check.yml`](.github/workflows/model-registry-drift-check.yml).
Drift → auto-PR in [ai-review-pipeline](https://github.com/EtroxTaran/ai-review-pipeline).
Manuelle Overrides via `AI_REVIEW_MODEL_<ROLE>` Env-Var oder
`~/.openclaw/workspace/MODEL_REGISTRY.md` (Dev-Override).

{SECTION_END}"""


def render_wiki_review_stages(registry: dict[str, str]) -> str:
    """Baut die "Die fünf Review-Stufen"-Tabelle für docs/wiki/00-ueberblick.md."""
    today = datetime.now(timezone.utc).date().isoformat()

    def _g(key: str) -> str:
        return registry.get(key) or "(nicht gepinnt)"

    return f"""{WIKI_SECTION_START}
<!-- AUTO-GENERIERT aus ai-review-pipeline/registry/MODEL_REGISTRY.env -->
<!-- NICHT manuell editieren — Änderungen kommen aus dem Weekly-Drift-Check -->
<!-- Regeneriert: {today} -->

| Stufe | KI-Modell | Blickwinkel | Tool-Integration |
|---|---|---|---|
| **Code-Review** | Codex (`{_g("OPENAI_MAIN")}`) | Funktionale Korrektheit, TypeScript strict, TDD-Compliance | `ai-review stage code-review` |
| **Code-Cursor** | Cursor (composer-2) | Zweite Meinung mit anderem Modell | `ai-review stage cursor-review` |
| **Security** | Gemini (`{_g("GEMINI_PRO")}`) + `semgrep` | OWASP, Secret-Leaks, Injection-Risiken | `ai-review stage security` |
| **Design** | Claude (`{_g("CLAUDE_OPUS")}`) | UI/UX, Accessibility, Design-System-Konformität | `ai-review stage design` |
| **AC-Validation** | Codex primary + Claude second-opinion | 1:1-Mapping Acceptance-Criteria ↔ Test | `ai-review ac-validate` |
{WIKI_SECTION_END}"""


# ---------------------------------------------------------------------------
# File editing
# ---------------------------------------------------------------------------


def _replace_between(
    content: str, new_section: str, start_marker: str, end_marker: str, file_label: str
) -> str:
    """Ersetzt den Bereich zwischen spezifischen Markers. Wirft bei fehlenden Markers."""
    start_idx = content.find(start_marker)
    end_idx = content.find(end_marker)
    if start_idx == -1 or end_idx == -1:
        raise ValueError(
            f"{file_label} enthält die Marker '{start_marker}' / '{end_marker}' nicht. "
            f"Erster Setup: Füge die beiden Marker einmalig an der Stelle ein, wo "
            f"die Registry-Sektion leben soll."
        )
    if end_idx < start_idx:
        raise ValueError(
            f"{file_label}: end-Marker steht vor start-Marker. Datei ist korrupt."
        )

    end_idx += len(end_marker)
    return content[:start_idx] + new_section + content[end_idx:]


def replace_section(content: str, new_section: str) -> str:
    """Backward-kompatibler Wrapper: ersetzt den AGENTS.md-Block."""
    return _replace_between(
        content, new_section, SECTION_START, SECTION_END, "AGENTS.md"
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def _process_target(
    *,
    path: Path,
    render: callable,
    start_marker: str,
    end_marker: str,
    label: str,
    check_only: bool,
) -> tuple[int, bool]:
    """Verarbeitet ein Target-File. Return (exit_code, changed).

    exit_code: 0 ok, 1 drift im check-mode, 2 file-kaputt
    changed:   ob die Datei (potentiell) geschrieben wurde
    """
    if not path.is_file():
        print(f"❌ {label} nicht gefunden: {path}", file=sys.stderr)
        return 2, False

    before = path.read_text()
    new_section = render
    try:
        after = _replace_between(before, new_section, start_marker, end_marker, label)
    except ValueError as exc:
        print(f"❌ {exc}", file=sys.stderr)
        return 2, False

    if before == after:
        print(f"✅ {label} ist auf dem aktuellen Stand ({path}).")
        return 0, False

    if check_only:
        print(f"⚠️  {label} weicht von der Registry ab ({path}).", file=sys.stderr)
        print("   Führe aus: python3 scripts/generate-model-docs.py", file=sys.stderr)
        return 1, False

    path.write_text(after)
    print(f"📝 {label} regeneriert: {path}")
    return 0, True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--agents-md",
        type=Path,
        default=DEFAULT_AGENTS_MD,
        help="Pfad zur AGENTS.md (default: agent-stack/AGENTS.md)",
    )
    parser.add_argument(
        "--wiki-overview",
        type=Path,
        default=DEFAULT_WIKI_OVERVIEW,
        help="Pfad zur Wiki-Overview (default: agent-stack/docs/wiki/00-ueberblick.md)",
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

    registry = parse_registry(args.registry)

    worst_exit = 0
    # AGENTS.md
    rc, _ = _process_target(
        path=args.agents_md,
        render=render_registry_section(registry),
        start_marker=SECTION_START,
        end_marker=SECTION_END,
        label="AGENTS.md",
        check_only=args.check,
    )
    worst_exit = max(worst_exit, rc)

    # Wiki-Overview — skip wenn file nicht existiert (für Projekte ohne Wiki)
    if args.wiki_overview.is_file():
        rc, _ = _process_target(
            path=args.wiki_overview,
            render=render_wiki_review_stages(registry),
            start_marker=WIKI_SECTION_START,
            end_marker=WIKI_SECTION_END,
            label="Wiki-Overview",
            check_only=args.check,
        )
        worst_exit = max(worst_exit, rc)
    else:
        print(f"ℹ️  Wiki-Overview nicht gefunden — skip ({args.wiki_overview})")

    return worst_exit


if __name__ == "__main__":
    sys.exit(main())
