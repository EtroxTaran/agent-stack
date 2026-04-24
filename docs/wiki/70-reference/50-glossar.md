# Glossar — Fachbegriffe von A bis Z

> **TL;DR:** Nachschlagewerk für die wichtigsten Fachbegriffe, die in diesem Wiki vorkommen. Pro Eintrag: Ein-Satz-Definition plus Link zu der Seite, wo der Begriff in Kontext erklärt wird. Wenn ein Junior-Dev über ein Wort stolpert, reicht meistens ein Blick hierher um weiterzukommen.

## A

**AC (Acceptance Criteria)**
Die prüfbaren Kriterien, die ein Ticket oder Issue erfüllen muss, damit es als "done" gilt. Im Gherkin-Format mit Given-When-Then formuliert. Siehe [`10-konzepte/00-ai-review-pipeline.md`](../10-konzepte/00-ai-review-pipeline.md) zur Stage-5-Validierung.

**AC-Coverage**
Ratio zwischen Anzahl AC und Anzahl Tests, die sie abdecken. Eine Coverage von 1.0 heißt: jede AC hat mindestens einen dazugehörigen Test. Die AC-Validation-Stage (Stage 5) prüft das.

**AC-Waiver**
Formeller Kommentar-Override für die AC-Validation-Stage, wenn die Pipeline eine AC nicht erkennt oder nicht greift (z.B. bei Docs-PRs). Kommando: `/ai-review ac-waiver <reason ≥30 chars>`. Siehe [`10-konzepte/30-waiver-system.md`](../10-konzepte/30-waiver-system.md).

**agent-stack**
Das zentrale Infrastruktur-Repo dieser Toolchain: enthält Skills, MCP-Registry, Workflow-Templates, Install-Skripte. Symlinked zu allen vier CLI-Homes. Siehe [`20-komponenten/00-agent-stack.md`](../20-komponenten/00-agent-stack.md).

**ai-review (CLI)**
Das Python-Kommandozeilen-Programm, das die Pipeline lokal ausführt. Sieben Subcommands. Siehe [`70-reference/00-cli-commands.md`](00-cli-commands.md).

**ai-review-pipeline**
Das Python-Package, das die Pipeline-Logik enthält. Installiert via `pip install git+…`. Siehe [`20-komponenten/10-ai-review-pipeline-repo.md`](../20-komponenten/10-ai-review-pipeline-repo.md).

**Auto-Fix**
Automatisches Patching von Findings durch einen LLM-Agent. Single-Pass. Siehe [`30-workflows/30-auto-fix-loop.md`](../30-workflows/30-auto-fix-loop.md).

**Auto-Merge**
GitHub-Feature, das einen PR automatisch mergt sobald alle Required-Checks grün sind. Aktiviert via `gh pr merge --auto`.

## B

**Blocking vs. Non-Blocking**
Konfigurations-Switch pro Stage. Blocking heißt Fail-Closed (Stage-Ausfall → Consensus-Failure). Non-Blocking (Shadow-Modus) heißt informativ.

**Bot-Token**
Discord-Bot-Credential. 72 Zeichen, rotierbar via Dev-Portal. `DISCORD_BOT_TOKEN` Env-Var. Siehe [`20-komponenten/40-discord-bridge.md`](../20-komponenten/40-discord-bridge.md).

**Branch-Protection**
GitHub-Feature, das Merge-Regeln pro Branch definiert. Listet Required-Status-Checks. Siehe [`70-reference/20-status-contexts.md`](20-status-contexts.md).

## C

**Callback-Workflow**
Der n8n-Workflow, der Discord-Button-Klicks empfängt, verifiziert und an GitHub-API weitergibt. Siehe [`20-komponenten/30-n8n-workflows.md`](../20-komponenten/30-n8n-workflows.md).

**CI (Continuous Integration)**
Automatisches Ausführen von Tests + Checks bei jedem Commit / PR. Hier synonym mit den GitHub-Actions-Workflows.

**Codex**
OpenAI's Code-Review-Modell (GPT-5-basiert). Modell für Stage 1 + AC-Primary-Judge.

**Components V1 (Discord)**
Discord-Nachrichten-Format mit Action-Rows + Buttons. **NICHT** `flags: 32768` (das wäre V2 und kollidiert mit `content`).

**Consensus**
Das aggregierte Gesamturteil der fünf Review-Stages. Skala: `success` (avg ≥ 8), `soft` (5–7), `failure` (< 5). Siehe [`10-konzepte/10-consensus-scoring.md`](../10-konzepte/10-consensus-scoring.md).

**Confidence-Weighting**
Aggregations-Methode, bei der jeder Stage-Score mit dessen Confidence-Wert gewichtet wird. Formel: `avg = Σ(score × conf) / Σ(conf)`.

**Conventional Commits**
Commit-Message-Format `type(scope): description`. Types: feat/fix/chore/docs/refactor/test. `checkpoint:` als Safety-Ausnahme erlaubt.

**Context-Name / Context-Prefix**
Der Name eines GitHub-Commit-Status, z.B. `ai-review/consensus`. Seit Phase 5 nur noch `ai-review/*` aktiv; der Shadow-Präfix `ai-review-v2/*` ist historisch. Siehe [`20-status-contexts.md`](20-status-contexts.md).

**Cursor (composer-2)**
Cursor's Code-Review-Modell für Stage 1b. Cursor-intern, nicht in der zentralen MODEL_REGISTRY.env.

**Model Registry**
Single-Source-of-Truth für LLM-Modell-Pins: [`ai-review-pipeline/src/ai_review_pipeline/registry/MODEL_REGISTRY.env`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/registry/MODEL_REGISTRY.env). Wöchentlicher Drift-Check montags 08:00 UTC.

**Cutover**
Der Wechsel von Shadow- zur Produktions-Pipeline. Für ai-portal am 2026-04-24 abgeschlossen; Playbook für künftige Projekte: [`30-workflows/40-shadow-zu-produktion-cutover.md`](../30-workflows/40-shadow-zu-produktion-cutover.md).

## D

**Dispatcher-Workflow**
Der n8n-Workflow, der Review-Ergebnisse von der Pipeline nimmt und als Discord-Nachricht postet. Inbound-Webhook `/webhook/ai-review-dispatch`.

**dotbot**
Symlink-Engine für das agent-stack-Install-Skript. Liest `install.conf.yaml`. [github.com/anishathalye/dotbot](https://github.com/anishathalye/dotbot).

## E

**Ed25519**
Asymmetrischer Signatur-Algorithmus, den Discord für Interactions-Verifikation verwendet. SPKI-Prefix + 32-byte-Key. Siehe [`30-workflows/10-button-click-callback.md`](../30-workflows/10-button-click-callback.md).

**Escalation**
30-Min-Timeout-Mechanismus: Wenn auf eine Soft-Consensus-Nachfrage keine Reaktion kommt, wird ein lauterer Alert im Alerts-Channel gepostet. Siehe [`30-workflows/20-escalation-30-min.md`](../30-workflows/20-escalation-30-min.md).

## F

**Fail-Closed**
Sicherheits-Pattern: Bei unklarem oder ausbleibendem Signal wird "failure" angenommen, nicht "success". Verhindert, dass ein kaputter Reviewer die Qualitätsprüfung umgeht.

**Fix-Loop**
Iterative Schleife aus Stage → Auto-Fix → Stage, max N Iterationen. Siehe [`30-auto-fix-loop.md`](../30-workflows/30-auto-fix-loop.md).

**Fine-grained PAT**
GitHub Personal-Access-Token mit Repo-Scoping (Prefix `github_pat_`). Sicherer als Classic PAT, aber aktuell nicht genutzt (Entscheidung User 2026-04-21).

**Funnel (Tailscale)**
Tailscales Feature für öffentliche Exposure einzelner Pfade. Siehe [`20-komponenten/50-tailscale-funnel.md`](../20-komponenten/50-tailscale-funnel.md).

## G

**Gemini 2.5 Pro**
Google's Security-Review-Modell für Stage 2.

**gh-ai-review (Extension)**
GitHub-CLI-Extension für Template-Install. Siehe [`40-setup/40-gh-extension.md`](../40-setup/40-gh-extension.md).

**Gherkin**
Given-When-Then-Syntax für Acceptance-Criteria. Standard in BDD (Behavior-Driven-Development).

**gitleaks**
Secret-Scanner im CI-Workflow. Prüft jeden Commit auf bekannte Token-Patterns.

**Guild (Discord)**
Synonym für "Discord-Server". Unsere ist "Nathan Ops".

## H

**hatchling**
Python-Build-Backend, das das ai-review-pipeline-Wheel erzeugt. Siehe [`20-komponenten/10-ai-review-pipeline-repo.md`](../20-komponenten/10-ai-review-pipeline-repo.md).

## I

**Interaction (Discord)**
Ein User-Event in Discord (Button-Klick, Slash-Command, Modal-Submit). Kommt per signierten POST an `/webhook/discord-interaction`.

## L

**Legacy-Pipeline (v1)**
Die alte Review-Pipeline direkt im ai-portal-Repo, vor der Extraction. Siehe [`10-konzepte/20-shadow-vs-cutover.md`](../10-konzepte/20-shadow-vs-cutover.md).

## M

**MCP (Model Context Protocol)**
Offener Standard für Tool-Schnittstellen zwischen Agent und External-Systems. Siehe [`20-komponenten/70-skills-mcp.md`](../20-komponenten/70-skills-mcp.md).

**Mermaid**
Diagramm-Syntax in Markdown-Blöcken. Konventionen: [`70-reference/40-mermaid-conventions.md`](40-mermaid-conventions.md).

## N

**Nachfrage**
Deutscher Begriff für den Soft-Consensus-Human-ACK-Flow. Siehe [`10-konzepte/40-nachfrage-soft-consensus.md`](../10-konzepte/40-nachfrage-soft-consensus.md).

**n8n**
Workflow-Engine, die die Integration zwischen Pipeline und Discord abbildet. Siehe [`20-komponenten/30-n8n-workflows.md`](../20-komponenten/30-n8n-workflows.md).

## O

**OAuth-Credentials**
Lokale Login-State-Dateien für Codex/Cursor/Gemini, gespeichert in `~/.codex/`, `~/.cursor/`, `~/.gemini/`.

**ops/**
Unterordner in agent-stack mit Operations-Infrastructure (n8n-Workflows, Compose-Override, Scripts).

## P

**PAT (Personal Access Token)**
GitHub-Credential für API-Calls. `ghp_…` = classic, `github_pat_…` = fine-grained.

**Phase 4 / Phase 5**
Shadow-Modus (Phase 4, abgeschlossen für ai-portal am 2026-04-24) vs. produktive Pipeline (Phase 5, aktuell). Siehe [Shadow-vs-Cutover](../10-konzepte/20-shadow-vs-cutover.md).

**pip install git+URL**
Installation eines Python-Packages direkt aus einem Git-Repo. Vorsicht bei gleichbleibender Version — siehe [`50-runbooks/30-pip-install-bricht.md`](../50-runbooks/30-pip-install-bricht.md).

**PING (Discord Type 1)**
Handshake-Request von Discord, wenn die Interactions-Endpoint-URL im Dev-Portal gesaved wird. Muss mit `{type: 1}` beantwortet werden.

**Prompts (Stage-Prompts)**
Markdown-Dateien mit Stage-spezifischen LLM-Prompts. In `src/ai_review_pipeline/stages/prompts/`. Müssen im gebauten Wheel enthalten sein — siehe [`60-tests/20-wheel-packaging-regression.md`](../60-tests/20-wheel-packaging-regression.md).

## R

**Raw-Body**
Die Original-Bytes einer HTTP-Request vor JSON-Parsing. Kritisch für Signatur-Verifikation, weil der Hash auf genau diesen Bytes beruht.

**Replay-Attacke**
Angriff, bei dem ein abgefangener gültiger Request wiederverwendet wird. Gegenmaßnahme: Timestamp-Skew-Check (±300s).

**r2d2**
Name des Home-Servers, auf dem n8n, Runner, Tailscale-Funnel laufen.

**Review-Charter**
Formale Definition der Review-Pipeline in `CLAUDE.md §8`. Die SoT für die Stages.

**Runner (Self-hosted)**
GitHub-Actions-Runner-Prozess auf r2d2, der Pipeline-Jobs ausführt. Siehe [`20-komponenten/60-self-hosted-runner.md`](../20-komponenten/60-self-hosted-runner.md).

## S

**SAST (Static Application Security Testing)**
Statische Code-Analyse, hier `semgrep` in Stage 2.

**Security-Waiver**
Override für Security-Stage-Findings. Kommando: `/ai-review security-waiver <reason ≥30 chars>`.

**SessionStart-Hook**
Ein Claude-Code-Hook-Event, das bei jedem Session-Start automatisch ausgeführt wird, bevor der Agent den ersten User-Input bekommt. Genutzt für den Projekt-Setup-Check (`project-setup-check.sh`). Siehe [`40-setup/50-project-setup-hook.md`](../40-setup/50-project-setup-hook.md).

**Setup-Hook**
Kurzform für den `project-setup-check.sh`-SessionStart-Hook, der unkonfigurierte `EtroxTaran/*`-Repos erkennt und einen Setup-Nudge zeigt.

**semgrep**
SAST-Tool mit Rule-basiertem Code-Scanning. Teil der Stage 2.

**Shadow-Mode**
Phase 4 der Pipeline: v2 läuft parallel, aber nicht-blockierend. Für ai-portal historisch (20.–24. April 2026); als Strategie für künftige Projekte weiterhin gültig. Siehe [`10-konzepte/20-shadow-vs-cutover.md`](../10-konzepte/20-shadow-vs-cutover.md).

**Skill (Agent-Skill)**
Spezialisierte Prompt-Definition in `skills/<name>/SKILL.md`. Agentskills.io-Standard. Siehe [`20-komponenten/70-skills-mcp.md`](../20-komponenten/70-skills-mcp.md).

**Soft-Consensus**
Consensus-Urteil mit avg 5–7 — nicht klar success, nicht klar failure. Triggert Nachfrage-Flow.

**SoT (Source of Truth)**
Canonische Quelle für eine Information. Das Wiki verlinkt zu SoTs, dupliziert sie nicht.

**SPKI-Prefix**
Ed25519-spezifischer ASN.1-DER-Header (`302a300506032b6570032100`). Nötig für Node's `crypto.verify`.

**Sticky Message**
Eine Discord-Message, die per `PATCH` geupdatet wird statt neue Posts. Hält pro PR genau eine Nachricht.

**Status-Context**
Ein Name-Value-Paar auf einem GitHub-Commit. Typisches Beispiel: `ai-review/consensus = success`.

## T

**Tailscale**
Privates VPN auf Wireguard-Basis. Nutzen wir für SSH + Funnel. Siehe [`20-komponenten/50-tailscale-funnel.md`](../20-komponenten/50-tailscale-funnel.md).

**TDD (Test-Driven Development)**
Red-Green-Refactor-Zyklus. Pflicht im Nexus-Portal. Enforced durch `tdd-guard`-Skill + Test-Gate.

**Tool-Cache**
Runner-Verzeichnis `_work/_tool/Python/3.12.13/x64/` mit vorinstalliertem Python + pip. Von `actions/setup-python@v5` managed.

## V

**v1 / v2 Pipeline**
v1 = Legacy, direkt im ai-portal-Repo. v2 = neue, als `ai-review-pipeline`-Package extrahiert.

## W

**Waiver**
Formeller Override eines Stage-Findings mit Audit-Trail. Siehe [`10-konzepte/30-waiver-system.md`](../10-konzepte/30-waiver-system.md).

**WAL (Write-Ahead-Log)**
SQLite-Feature für Concurrent-Writes. Kann bei direkter DB-Manipulation inkonsistent werden. Siehe [`50-runbooks/10-n8n-db-korruption.md`](../50-runbooks/10-n8n-db-korruption.md).

**webhookId**
Attribut am n8n-Webhook-Node, das die Route-Registrierung beeinflusst. **Zwingend erforderlich**, sonst nested Path. Siehe [Stolpersteine #2](../50-runbooks/60-stolpersteine.md).

**workflow_dispatch**
GitHub-Actions-Trigger-Event für manuelles oder API-getriggertes Workflow-Starten.

## Y

**yq**
YAML-Parser-CLI. Für MCP-Server-Registry genutzt.

## Z

**Zod**
TypeScript-Library für Runtime-Type-Validation. Standard in ai-portal für API-Contract-Tests.

## Verwandte Seiten

- [Überblick](../00-ueberblick.md) — Big-Picture-Kontext
- [Style-Guide](../99-meta/10-style-guide.md) — Wiki-Konventionen
- [Stolpersteine](../50-runbooks/60-stolpersteine.md) — aggregierte Gotchas
