# ADRs-Index — Architecture Decision Records

> **TL;DR:** Wichtige Architektur-Entscheidungen werden in ADR-Dateien festgehalten — kurze Dokumente mit Kontext, Decision, Alternativen und Konsequenzen. Sie liegen im jeweiligen Projekt-Repo (ai-portal hat 18, ai-review-pipeline hat einige). Diese Seite ist ein Index aller ADRs, die für die AI-Review-Toolchain relevant sind, mit Ein-Zeilen-Zusammenfassung pro Entscheidung.

## Wie es funktioniert

ADRs (Architecture Decision Records) sind ein Standard für Software-Architekturen, dokumentiert in der "MADR"-Spezifikation (Markdown Architectural Decision Records). Jede ADR hat ein einheitliches Template:

- **Status:** proposed / accepted / deprecated / superseded by ADR-xxx
- **Context:** was ist die Ausgangslage, welches Problem lösen wir
- **Decision:** was wurde entschieden
- **Consequences:** positive + negative Folgen
- **Alternatives Considered:** was wurde gegeneinander abgewogen

Ein Projekt ohne ADRs landet bei "warum ist das so? — weiß keiner mehr". ADRs sind Institutional-Memory.

## ADRs im ai-portal

Verzeichnis: [`ai-portal/docs/v2/10-adr/`](https://github.com/EtroxTaran/ai-portal/tree/main/docs/v2/10-adr) (insgesamt 18 ADRs, hier nur die AI-Review-relevanten).

| ADR | Status | Titel | Relevanz für Toolchain |
|---|---|---|---|
| [ADR-001](https://github.com/EtroxTaran/ai-portal/blob/main/docs/v2/10-adr/ADR-001-monorepo.md) | accepted | Monorepo (pnpm + Nx) | — |
| [ADR-011](https://github.com/EtroxTaran/ai-portal/blob/main/docs/v2/10-adr/ADR-011-n8n-workflow-engine.md) | accepted | n8n als Workflow-Engine | Basis für Dispatcher/Callback/Escalation |
| [ADR-013](https://github.com/EtroxTaran/ai-portal/blob/main/docs/v2/10-adr/ADR-013-rest-vs-mcp.md) | accepted | REST + OpenAPI statt MCP | Erklärt, warum Portal-Agent via HTTP, nicht MCP |
| [ADR-015](https://github.com/EtroxTaran/ai-portal/blob/main/docs/v2/10-adr/ADR-015-docker-compose-deployment.md) | accepted | Docker-Compose auf r2d2 | Deployment-Basis für n8n + Portal |
| [ADR-018](https://github.com/EtroxTaran/ai-portal/blob/main/docs/v2/10-adr/ADR-018-cicd-deploy-pipeline.md) | accepted | CI/CD-Pipeline: AI-Review + Auto-Deploy | **Kern-ADR für die Toolchain** |

### ADR-018 im Detail

**Datum:** 2026-04-16
**Status:** accepted
**Context:** Ursprünglich Husky-pre-push + broken `ai-review.yml` (OPENAI_API_KEY fehlte, ungültige Modell-ID) + lokaler `scripts/ai-review.py` + kein Auto-Deploy.
**Decision:** PR → 5 parallele Quality-Gates → Auto-Merge → Auto-Deploy r2d2 → Post-Deploy E2E → Auto-Rollback.

**Quality-Gates (blocking):**
1. `ci.yml` — typecheck + lint + unit + audit + E2E
2. `design-system-check.yml`
3. `security.yml` (gitleaks + semgrep + trivy)
4. `ai-code-review.yml` + `ai-security-review.yml` (Codex + Gemini multi-model consensus)
5. Post-Deploy E2E (Playwright via Tailscale)

**Kern-Entscheidungen:**
- **Auto-Merge via PAT**, nicht `GITHUB_TOKEN` (weil Push-Events von `GITHUB_TOKEN` keine neuen Workflows triggern)
- **Deploy via SSH-Tunnel über Tailscale**
- **Rollback via Image-Snapshot + `docker-compose.rollback.yml`**

Das ist der Ur-Entwurf, aus dem die heutige 5-Stage-Pipeline + v2 Shadow entstanden ist. Details: [`10-konzepte/20-shadow-vs-cutover.md`](../10-konzepte/20-shadow-vs-cutover.md).

## ADRs im ai-review-pipeline

Verzeichnis noch nicht formal angelegt — stattdessen leben Entscheidungen im `CHANGELOG.md` + PR-Bodies. Geplant: ADRs rückwirkend anlegen für:

| Geplante ADR | Thema |
|---|---|
| ADR-001 | Extraktion der Pipeline aus ai-portal als Python-Package |
| ADR-002 | hatchling als Build-Backend (statt setuptools/poetry) |
| ADR-003 | Confidence-weighted Consensus-Aggregation (Formel + Schwellen) |
| ADR-004 | Fail-Closed-Verhalten bei missing Stages |
| ADR-005 | Separate Discord-Channels für Shadow- vs. Produktions-Mode |
| ADR-006 | Status-Context-Prefix `ai-review/` vs. `ai-review-v2/` |

Das Anlegen dieser ADRs ist ein offener Task für die nächsten Wochen.

## ADRs in agent-stack

Noch nicht formal, aber Entscheidungen sind dokumentiert in:

- [`AGENTS.md`](https://github.com/EtroxTaran/agent-stack/blob/main/AGENTS.md) — die 18 Sektionen sind teilweise ADR-ähnlich
- [`README.md`](https://github.com/EtroxTaran/agent-stack/blob/main/README.md) — Design-Rationale für Multi-CLI-Uniformity
- Plan-Dateien unter `~/.claude/plans/` — Entwurfs-Logs für größere Änderungen

Formale ADRs für:
- ADR-001: `AGENTS.md`-Symlink-Pattern für alle 4 CLIs
- ADR-002: `mcp/servers.yaml` als declarativer Single-Source für MCP-Server
- ADR-003: dotbot + backup-existing als idempotenter Install-Flow

…werden bei Bedarf angelegt.

## Globale Entscheidungen (nicht repo-spezifisch)

Manche Entscheidungen betreffen die gesamte Toolchain und sind in `CLAUDE.md` verankert:

- **[Rule 0 — No De-Scoping](https://github.com/EtroxTaran/agent-stack/blob/main/AGENTS.md)** — nicht-verhandelbare Regel für alle Agents
- **[§8 Review-Charter](https://github.com/EtroxTaran/agent-stack/blob/main/AGENTS.md)** — die 5 Stages + Consensus-Thresholds
- **[§10 Security Guardrails](https://github.com/EtroxTaran/agent-stack/blob/main/AGENTS.md)** — OAuth-Scopes, LLM-Keys in n8n, keine `pull_request_target`
- **[§11 Always Latest](https://github.com/EtroxTaran/agent-stack/blob/main/AGENTS.md)** — aktuelle Modell-IDs

## Wie man ein neues ADR anlegt

1. Nächste freie Nummer im jeweiligen Projekt wählen (z.B. `ADR-019-xyz.md`)
2. Template aus [`docs/v2/10-adr/`](https://github.com/EtroxTaran/ai-portal/tree/main/docs/v2/10-adr) kopieren
3. Sektionen ausfüllen: Context + Decision + Alternatives + Consequences
4. Als PR einreichen — muss durch die Review-Pipeline laufen
5. Nach Merge: hier im Wiki verlinken + in Changelog erwähnen

## Verwandte Seiten

- [Changelog](00-changelog.md) — chronologische Ereignis-Liste
- [Lessons Learned](10-lessons-learned.md) — reflektive Retrospektiven
- [AGENTS.md](https://github.com/EtroxTaran/agent-stack/blob/main/AGENTS.md) — globale Regeln

## Quelle der Wahrheit (SoT)

- [`ai-portal/docs/v2/10-adr/`](https://github.com/EtroxTaran/ai-portal/tree/main/docs/v2/10-adr) — alle ai-portal-ADRs
- [MADR-Spec](https://adr.github.io/madr/) — Template-Standard
