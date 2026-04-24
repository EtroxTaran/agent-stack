# Model-Tier Policy — Opus vs. Sonnet vs. Haiku

> **Wann welches Claude-Modell?** Dieses Dokument gibt konkrete Regeln, statt pauschal Opus für alles zu nutzen.

## Kurzfassung

| Tier | Default-Einsatz | Relative Kosten | Relative Latenz |
|---|---|---|---|
| **Opus 4.7** | Planning, Architektur, Review, komplexes Reasoning | 5× Haiku | 3× Haiku |
| **Sonnet 4.6** | Implementation, Coding, Multi-Step-Tasks | 3× Haiku | 1.5× Haiku |
| **Haiku 4.5** | Commits, Extraktion, Summaries, Bulk-Operationen, Explore-Subagents | 1× (Referenz) | 1× (Referenz) |

`agent-stack` startet Claude Code mit `"model": "opus"` (siehe `configs/claude/settings.json` + BASELINE). Delegation auf Sonnet/Haiku erfolgt **gezielt pro Task**, nicht pauschal.

---

## Konfigurations-Ebenen

Claude Code erlaubt Model-Auswahl auf sechs Ebenen — höhere Ebenen überschreiben niedrigere:

1. **Default in `~/.claude/settings.json`** — `"model": "opus"` (Session-Fallback).
2. **Env-Variable** — `ANTHROPIC_MODEL=sonnet` beim Session-Start.
3. **Startup-Flag** — `claude --model sonnet`.
4. **Session-Switch** — `/model opus|sonnet|haiku|opusplan` während laufender Session.
5. **Subagent-Frontmatter** — `model: haiku` im YAML-Header eines Agents unter `~/.claude/agents/*.md`.
6. **Task-Tool-Override** — beim `Task(subagent_type: "Explore", model: "haiku")`-Aufruf.

**`opusplan`**: Spezial-Alias, der Plan-Phase auf Opus laufen lässt und anschließend automatisch auf Sonnet für die Ausführung wechselt. Guter Default für gemischte Planning+Coding-Sessions.

---

## Delegation-Patterns

### Tiefes Reasoning / Planning → Opus

**Wann**: Architektur-Entscheidungen, komplexe Refactoring-Pläne, Security-Reviews, Multi-Repo-Koordination, Root-Cause-Analyse bei nicht-trivialen Bugs.

**Wie**: Default ist bereits Opus. Oder `/model opus` in einer Session, die auf Sonnet läuft.

### Implementation / Coding → Sonnet

**Wann**: Feature-Implementation mit klarer Spec, Refactoring innerhalb einer Datei, Test-Schreiben, Doc-Updates mit konkretem Scope, Library-Migration nach vorgegebenem Plan.

**Wie**:

- Session-Switch: `/model sonnet` nach der Plan-Phase.
- Oder: `opusplan`-Alias nutzen (wechselt automatisch).
- Oder: Implementation an einen Subagent delegieren, der `model: sonnet` im Frontmatter setzt.

### Commits / Extraktion / Bulk → Haiku

**Wann**: Conventional-Commit-Messages generieren, Docs parsen, JSON extrahieren, einfache Linter-Fixes, PR-Body-Formatting, Status-Zusammenfassungen, Explore-Agent-Scans über viele Files.

**Wie**:

- `Task(subagent_type: "Explore")` nutzt intern Haiku für den Fan-out.
- `/model haiku` für dedizierte Commit-/Cleanup-Sessions.
- Subagents für repetitive Tasks: `model: haiku` im Frontmatter.

### Hybrid: Plan-in-Opus-Execute-in-Sonnet

`/model opusplan` aktivieren — Claude Code entscheidet selbst, wann gewechselt wird. Empfohlener Default für typische Feature-Arbeit.

---

## Entscheidungs-Flussdiagramm

```
Ist die Aufgabe klar spezifiziert und der Weg offensichtlich?
├─ Ja → Wie viele Iterationen / wie viel Context?
│   ├─ Wenige, fokussiert, Single-File → Sonnet
│   └─ Bulk, repetitiv, Extraktion → Haiku
└─ Nein → Braucht es tiefes Reasoning oder Architektur-Entscheidungen?
    ├─ Ja → Opus
    └─ Nein (Research/Exploration) → Opus (mit Haiku-Subagents für Fan-out)
```

---

## Konkrete Beispiele aus `agent-stack`

| Task | Modell | Warum |
|---|---|---|
| Review einer PR in der AI-Review-Pipeline | Opus | Security- + AC-Validation braucht tiefes Reasoning |
| Implementation eines neuen Skills nach SKILL.md-Draft | Sonnet | Spec ist klar, Scope begrenzt |
| Commit-Message für Bulk-Dep-Update | Haiku | Triviale Conventional-Commit-Formulierung |
| Explore-Agent für "finde alle Refs auf X in docs/wiki/" | Haiku | Grep + Summary, keine Bewertung |
| Architektur-Plan für neuen MCP-Server | Opus | Multi-File-Impact, Trade-offs zu wägen |
| Auto-Fix-Vorschlag nach E2E-Fail | Sonnet | Code-Change mit Test-Kontext |
| Agent-Commit (Automated) | Haiku | Standardisiert, keine Kreativität nötig |

---

## Kosten/Latenz-Tradeoffs

**Faustregel**: Starte mit **Sonnet** für typische Feature-Arbeit, **escalate zu Opus** bei Architektur-Fragen oder unklaren Specs, **fall back zu Haiku** für bulkige oder deterministische Aufgaben.

Bei `"model": "opus"`-Default (agent-stack) ist die Regel invertiert: **Delegiere aktiv nach unten** für Sonnet/Haiku-würdige Arbeit, sonst zahlst du Opus-Preise für Haiku-Tasks.

---

## Referenzen

- AGENTS.md §1 (Primary-Dev-CLI Tier-Zuweisung)
- AGENTS.md §8 (Review-Charter mit konkreten Modell-Pins)
- `configs/BASELINE.md` (Claude Code-Keys inkl. `effortLevel`)
- [code.claude.com/docs/en/model-config](https://code.claude.com/docs/en/model-config) — offizielle Model-Konfiguration + `opusplan`
- [claude.com/resources/tutorials/choosing-the-right-claude-model](https://claude.com/resources/tutorials/choosing-the-right-claude-model) — Anthropic-Rationale
- `ai-review-pipeline/registry/MODEL_REGISTRY.env` — Single-Source-of-Truth für aktuelle Modell-Pins
