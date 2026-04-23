# CLI-Commands — `ai-review` Subcommand-Referenz

> **TL;DR:** Die Pipeline wird über ein einziges Kommandozeilen-Programm `ai-review` gesteuert. Es kennt sieben Subcommands — einen pro Verantwortungsbereich: einzelne Stage ausführen, Consensus aggregieren, AC validieren, Auto-Fix triggern, Fix-Loop orchestrieren, Metriken abfragen, Nachfrage-Commands abarbeiten. Diese Seite listet alle Subcommands mit ihren Flags, realen Beispielen und typischen Exit-Codes.

## Wie es funktioniert

`ai-review` ist ein argparse-basiertes Python-CLI, installiert via `pip install git+https://github.com/EtroxTaran/ai-review-pipeline.git@main`. Die Subcommand-Struktur ist klassisches Unix:

```
ai-review <subcommand> [--flag value] [--flag2 value2]
```

Jeder Subcommand mappt auf ein Python-Modul im Package. Die Flags sind pro Subcommand unterschiedlich, aber einige **Shadow-Flags** (`--status-context-prefix`, `--discord-channel`, `--no-ping`) sind global verfügbar.

## Subcommands im Detail

### `ai-review stage`

**Zweck:** Eine einzelne Review-Stage gegen einen PR ausführen.

**Flags:**

| Flag | Typ | Pflicht | Default | Bedeutung |
|---|---|---|---|---|
| `<stage-name>` | positional | ja | — | `code-review`, `cursor-review`, `security`, `design` |
| `--pr` | int | ja | — | PR-Nummer |
| `--max-iterations` | int | nein | 2 | Wie oft der Fix-Loop laufen darf |
| `--skip-fix-loop` | bool | nein | false | Keine Auto-Fixes, nur Report |
| `--status-context-prefix` | str | nein | `ai-review` | Für Shadow-Mode: `ai-review-v2` |

**Beispiel:**

```bash
ai-review stage code-review \
  --pr 42 \
  --max-iterations 2 \
  --status-context-prefix ai-review-v2
```

**Exit-Codes:**
- `0` — Stage erfolgreich (Status `success` geschrieben)
- `1` — Stage fehlgeschlagen (findings mit Severity blocker oder crash)
- `2` — Konfigurationsfehler (fehlende ENV, unbekannte Stage)

### `ai-review consensus`

**Zweck:** Status aller Stages aggregieren und den Consensus-Status schreiben.

**Flags:**

| Flag | Typ | Pflicht | Default | Bedeutung |
|---|---|---|---|---|
| `--sha` | str | ja | — | PR-HEAD-SHA |
| `--pr` | int | ja | — | PR-Nummer |
| `--target-url` | str | nein | Run-URL | URL für Status-Context-Target |
| `--status-context` | str | nein | `ai-review/consensus` | Override Consensus-Status-Name |
| `--status-context-prefix` | str | nein | `ai-review` | Prefix für die Stage-Status-Filter |
| `--discord-channel` | str | nein | aus Config | Override Discord-Channel-ID |
| `--no-ping` | bool | nein | false | Unterdrückt `@here`-Mention |

**Beispiel:**

```bash
ai-review consensus \
  --sha abc123... \
  --pr 42 \
  --target-url https://github.com/.../actions/runs/123 \
  --status-context ai-review-v2/consensus \
  --discord-channel $DISCORD_CHANNEL_AI_PORTAL_SHADOW \
  --no-ping
```

**Exit-Codes:**
- `0` — Consensus-Status geschrieben (success, soft/pending, oder failure)
- `1` — Consensus-Timeout (Stages nie terminal)
- `2` — Konfigurationsfehler

### `ai-review ac-validate`

**Zweck:** Stage 5 — Acceptance-Criteria gegen Tests im PR validieren.

**Flags:**

| Flag | Typ | Pflicht | Bedeutung |
|---|---|---|---|
| `--pr-body-file` | Pfad | ja | Datei mit PR-Body-Text |
| `--linked-issues-file` | Pfad | ja | JSON-Datei mit `{issue_num: issue_body}` |
| `--changed-files` | str | ja | CSV-Liste der geänderten Dateien |
| `--diff-file` | Pfad | nein | Datei mit PR-Diff (Kontext für Judge) |
| `--judge-model` | str | nein | Override des Primary-Judge-Modells |
| `--second-opinion-model` | str | nein | Override des Second-Opinion-Modells |
| `--min-coverage` | float | nein | Coverage-Schwelle (0.0–1.0) |

**Beispiel:**

```bash
# Aus einem Workflow-Step:
gh pr view $PR --json body,files > /tmp/pr_meta.json
jq -r '.body' /tmp/pr_meta.json > /tmp/pr_body.txt
jq -r '[.files[].path] | join(",")' /tmp/pr_meta.json > /tmp/changed.txt

ai-review ac-validate \
  --pr-body-file /tmp/pr_body.txt \
  --linked-issues-file /tmp/linked_issues.json \
  --changed-files "$(cat /tmp/changed.txt)" \
  --diff-file /tmp/pr_diff.txt
```

**Output (stdout):**

```
✅ AC-Validation: score=10/10, confidence=1.0, waived=False
Coverage: 3/3 ACs mapped to tests:
  - "given empty array, return []" → tests/test_queue.py:42
  - "given full queue, emit backpressure" → tests/test_queue.py:58
  - "given invalid type, raise ValueError" → tests/test_queue.py:77
```

### `ai-review auto-fix`

**Zweck:** Einen Auto-Fix-Pass auf einen PR anwenden (manual trigger).

**Flags:**

| Flag | Typ | Pflicht | Bedeutung |
|---|---|---|---|
| `--pr` | int | ja | PR-Nummer |
| `--stage` | str | ja | Welche Stage-Findings (code-review, design) |
| `--reason` | str | nein | Kontext für den Commit-Body |
| `--max-files` | int | nein | Max geänderte Dateien, default 10 |
| `--findings-file` | Pfad | nein | Vorgefertigte Findings-JSON, sonst neu fetchen |

**Beispiel:**

```bash
ai-review auto-fix \
  --pr 42 \
  --stage code-review \
  --reason "post-hoc cleanup after manual review"
```

**Exit-Codes:**
- `0` — Fix commited + gepushed
- `1` — Kein Fix möglich (LLM antwortet "keine Lösung")
- `2` — Patch zu groß (mehr als max-files)
- `3` — Git-Konflict beim Push

### `ai-review fix-loop`

**Zweck:** Iterative Schleife Stage → Fix → Stage, bis success oder max-iterations erreicht.

**Flags:**

| Flag | Typ | Pflicht | Bedeutung |
|---|---|---|---|
| `--stage` | str | ja | Welche Stage |
| `--pr` | int | ja | PR-Nummer |
| `--max-iterations` | int | nein | Default 2 |

**Beispiel:**

```bash
ai-review fix-loop \
  --stage code-review \
  --pr 42 \
  --max-iterations 2
```

**Exit-Codes:**
- `0` — Nach ≤N Iterationen success
- `1` — Max Iterations erreicht, immer noch failure → needs_human
- `2` — Auto-Fix scheiterte (nicht möglich zu fixen)

### `ai-review metrics`

**Zweck:** Metriken aus `metrics.jsonl` abfragen + aggregieren.

**Flags:**

| Flag | Typ | Pflicht | Bedeutung |
|---|---|---|---|
| `--since` | YYYY-MM-DD | nein | Nur Events nach diesem Datum |
| `--until` | YYYY-MM-DD | nein | Nur Events vor diesem Datum |
| `--filter` | key=value | nein | Event-Filter (kann mehrfach) |
| `--format` | str | nein | `json`, `table`, `summary` (default) |

**Beispiele:**

```bash
# Gesamt-Summary seit April
ai-review metrics --since 2026-04-01
# Output: "42 PRs reviewed, avg consensus score 8.7, 12 auto-fixes applied"

# Nur Waivers
ai-review metrics --since 2026-04-01 --filter type=waiver
# Output: Liste aller Waivers mit Autor + Reason

# Detail-Export für Report
ai-review metrics --since 2026-04-01 --format json > /tmp/metrics.json
```

### `ai-review nachfrage`

**Zweck:** Soft-Consensus-Command (`/ai-review approve` etc.) aus PR-Kommentar verarbeiten.

**Flags:**

| Flag | Typ | Pflicht | Bedeutung |
|---|---|---|---|
| `--pr-number` | int | ja | PR-Nummer |
| `--comment-body` | str | ja | Body des PR-Kommentars |
| `--author` | str | ja | GitHub-Username des Autors |

**Beispiel (nur aus Workflow getriggert):**

```bash
ai-review nachfrage \
  --pr-number 42 \
  --comment-body "/ai-review approve" \
  --author "NicoR"
```

**Wirkung:** Je nach Command:
- `/ai-review approve` → Consensus-Status auf `success` setzen, Merge freigeben
- `/ai-review retry` → Stages neu triggern
- `/ai-review security-waiver <reason>` → Security-Status waived=true, Audit-Eintrag
- `/ai-review ac-waiver <reason>` → AC-Status waived=true, Audit-Eintrag

### `ai-review --version`

```bash
ai-review --version
# Output: ai-review 0.1.0
```

### `ai-review --help`

```bash
ai-review --help
# Zeigt alle Subcommands + Top-Level-Flags

ai-review stage --help
# Zeigt Flags für `stage`-Subcommand
```

## Shadow-Flags im Überblick

Drei Flags machen die Shadow-Mode-Orchestrierung möglich (Stand PR#2):

- `--status-context-prefix <prefix>`: Schreibt Status mit `<prefix>/<stage>` statt default `ai-review/<stage>`
- `--status-context <full-name>` (nur `consensus`): Override des Consensus-Status-Namens
- `--discord-channel <id>`: Override der Discord-Channel-ID aus Config
- `--no-ping`: Unterdrückt `@here`-Mention

**Typische Shadow-Nutzung:**

```bash
ai-review stage code-review --pr 42 \
  --status-context-prefix ai-review-v2

ai-review consensus --sha $SHA --pr 42 \
  --status-context ai-review-v2/consensus \
  --discord-channel $DISCORD_CHANNEL_AI_PORTAL_SHADOW \
  --no-ping
```

## Verwandte Seiten

- [AI-Review-Pipeline Repo](../20-komponenten/10-ai-review-pipeline-repo.md) — Implementations-Details
- [Workflow-Templates](../40-setup/30-workflow-templates.md) — wo die Commands in YAML gebraucht werden
- [.ai-review/config.yaml](../40-setup/20-ai-review-config-schema.md) — Config-Defaults

## Quelle der Wahrheit (SoT)

- [`src/ai_review_pipeline/cli.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/cli.py) — argparse-Setup
- `ai-review --help` — Live-Referenz
