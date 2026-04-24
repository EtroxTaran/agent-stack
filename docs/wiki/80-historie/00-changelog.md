# Changelog — Chronologie der Entwicklung

> **TL;DR:** Diese Seite listet die größeren Entwicklungsschritte der AI-Review-Toolchain in umgekehrter chronologischer Reihenfolge. Für Detail-Analyse einzelner Entscheidungen siehe [ADRs-Index](20-adrs-index.md); für die sich-daraus-ergebenden Lehren siehe [Lessons Learned](10-lessons-learned.md). Dieser Changelog fokussiert auf: Was wurde gebaut, wann, warum grob.

## 2026-04-24 (abends) — Docs-Drift-Bereinigung + Drift-Guard

**Was:** Nach Phase-5-Cutover und Registry-Migration waren Docs/Templates an mehreren Stellen stale. Bereinigt:
- Model-Pins in 10 Files auf Registry-SoT angeglichen (`gpt-5.5`, `gemini-3.1-pro-preview`, `claude-opus-4-7`).
- `templates/ai-review-config.yaml` auf kanonisches Schema (`reviewers.*`) migriert und Pin-frei gelassen — Modelle kommen aus Registry.
- `ai-portal-integration.md` komplett umgeschrieben auf aktuellen Phase-5-Produktionszustand (einzige Pipeline, `ai-review/consensus` required, Legacy v1 als historisch markiert).
- Cutover-Doc umbenannt (`40-cutover-phase-4-zu-5.md` → `40-shadow-zu-produktion-cutover.md`) und als generisches Playbook positioniert. Alle 10 Inbound-Links aktualisiert.
- Status von Phase-4-Referenzen in 9 weiteren Wiki-Seiten von "aktuell" auf "historisch bis 2026-04-24" umgestellt.
- Neuer Drift-Guard `scripts/check-docs-model-pins.sh` + `docs-pin-drift`-Job in `.github/workflows/model-registry-drift-check.yml` (läuft auf jedem Docs-PR + wöchentlich).

**Warum:** Neue User hätten veraltete Model-Pins (`gpt-5`, `gemini-2.5-pro`) via `ai-init-project.sh` in neue Projekte kopiert. Phase-4-Terminologie an mehreren Stellen passte nicht mehr zur Realität. <!-- pin-drift-ignore: Referenz auf abgelöste Modelle im Changelog -->

**Referenz:** Branch `docs/post-phase5-cutover-and-registry-drift-cleanup`.

## 2026-04-24 — Phase-5-Cutover im ai-portal (PR#44)

**Was:** v2 ai-review-pipeline wird die **einzige** Review-Pipeline im ai-portal. Shadow-Modus beendet, 5 v1-Legacy-Workflows gelöscht.
**Warum:** Die Toolchain wurde für Produktions-Einsatz gebaut; paralleler Shadow-Betrieb sollte nur Validierung sein, nicht Dauerzustand. Nico hat explizit Cutover sofort angeordnet.
**Die Schritte:**
1. `.ai-review/config.yaml`: alle 5 Stages `blocking: true`, Channel-ID auf `${DISCORD_CHANNEL_AI_PORTAL}`, `mention_role: "@here"`
2. `ai-review-v2-shadow.yml` → `ai-review.yml` (Rename via `git mv`)
3. `--status-context-prefix ai-review-v2`, `--discord-channel`, `--no-ping` Shadow-Flags entfernt
4. Metrics-Pfad `.ai-review/metrics-v2.jsonl` → `.ai-review/metrics.jsonl`
5. 5 Legacy-Workflows gelöscht: `ai-code-review.yml`, `ai-security-review.yml`, `ai-design-review.yml`, `ai-review-scope-check.yml`, `ai-review-consensus.yml`

**Branch-Protection:** `ai-review/consensus` war bereits als required-check konfiguriert — kein Gap beim Cutover.

**Referenz:** [ai-portal PR#44](https://github.com/EtroxTaran/ai-portal/pull/44).

## 2026-04-23 — Projekt-Setup-Hook (PR#9)

**Was:** SessionStart-Hook `project-setup-check.sh`, der bei jedem Claude-Code-Session-Start erkennt, ob das aktuelle Repo die AI-Review-Pipeline aktiviert hat.
**Warum:** Die Pipeline war bisher opt-in pro Projekt — man musste wissen, dass sie existiert, und sie manuell aktivieren. Bei neuen Projekten wurde das regelmäßig vergessen.
**Wie:** Der Hook printet bei unkonfigurierten `EtroxTaran/*`-Repos eine handlungsbare Setup-Anleitung in den Session-Output. Nicht-blockierend (exit 0), skippbar via `CLAUDE_SKIP_AI_REVIEW_SETUP=1` oder `.ai-review/.noreview`-File. AGENTS.md §8.3 definiert das zugehörige Agent-Verhalten.
**Referenz:** [`40-setup/50-project-setup-hook.md`](../40-setup/50-project-setup-hook.md).

## 2026-04-23 — Wiki-Einführung (PR#8)

**Was:** Dieses Wiki (`agent-stack/docs/wiki/`) wurde angelegt.
**Warum:** Infos waren über 3 Repos + 3 Plan-Dateien zerstreut; Junior-Devs hatten keinen Einstiegspunkt; Stakeholder (Nico, Sabine) brauchten verständliche TL;DR.
**Wie:** 46 Seiten nach Template, Deutsch mit englischen Code-Identifiern, Mermaid-Diagrammen überall, geschichteter Aufbau.
**Referenz:** Plan in `~/.claude/plans/snuggly-wiggling-moler.md`, Branch `docs/ai-review-wiki`.

## 2026-04-23 — Shadow-Pipeline PR-43 gemerged

**Was:** 4 Infrastruktur-Fixes für die v2-Shadow-Pipeline.
**Warum:** Shadow-Pipeline crashte auf echten PRs mit `FileNotFoundError`.
**Die 4 Fixes:**
1. `--force-reinstall --no-deps --no-cache-dir` vor jedem pip-Install (gegen skip-reinstall-Bug bei gleicher Version 0.1.0)
2. Runner pip-Half-Upgrade repariert (`rm -rf pip/ pip-*.dist-info` + `ensurepip`)
3. `submodules: false` + `.gitmodules`-Mapping für Orphan-Gitlink
4. `closingIssuesReferences` via GraphQL statt `gh pr view --json`

**Ergebnis:** Shadow-Run #24853468198 lief komplett grün — 6/6 Jobs + Consensus success.

## 2026-04-23 — Wheel-Packaging-Regression-Tests (PR#9)

**Was:** 2 neue Tests, die verhindern, dass `.md`-Prompt-Files aus dem Wheel fallen.
**Warum:** PR#8 hat einen Bug gefixt, aber keine Regressions-Absicherung — der gleiche Fehler hätte bei nächstem hatchling-Update wieder auftreten können.
**Tests:** `zipfile.namelist`-Check + Install-Integration-Check.
**Referenz:** [`tests/test_wheel_packaging.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/tests/test_wheel_packaging.py).

## 2026-04-23 — E2E-Validation-Script (agent-stack PR#7)

**Was:** Bash-Script `ai-review-e2e-validate.sh` das die komplette Toolchain in 25 Checks abklopft.
**Warum:** Bisher wurden die Gesundheitschecks ad-hoc mit `docker ps`, `curl`, `gh api` gemacht; nach Incidents war unklar, ob alles wieder sauber läuft.
**Referenz:** [`ops/n8n/tests/ai-review-e2e-validate.sh`](https://github.com/EtroxTaran/agent-stack/blob/main/ops/n8n/tests/ai-review-e2e-validate.sh).

## 2026-04-21 — Callback-Hardening (agent-stack PR#6)

**Was:** Der n8n-Callback-Workflow hat mehrere Härtungen bekommen.
**Warum:** Discord lehnte den Endpoint mehrfach ab ("could not be verified"), weil die Verify-Logik fehlerhaft war.
**Die Härtungen:**
- `webhookId: "discord-interaction"` explizit gesetzt (sonst registriert n8n unter nested Path)
- Raw-Body aus `$binary.data` statt aus `$json.body` (sonst falsche Bytes für Signatur)
- SPKI-Prefix-Ed25519-Verify via Node `crypto.verify` (statt unzuverlässigem `crypto.subtle`)
- Replay-Schutz mit ±300s Timestamp-Skew-Toleranz
- HTTP-Request-Retry + `neverError: true` (für 3s-Budget-Einhaltung)

**Referenz:** [`ops/n8n/workflows/ai-review-callback.json`](https://github.com/EtroxTaran/agent-stack/blob/main/ops/n8n/workflows/ai-review-callback.json).

## 2026-04-20 — Stage 5 (AC-Validation) Release

**Was:** Fünfte Stage "AC-Validation" zur Pipeline hinzugefügt — prüft 1:1-Mapping zwischen Gherkin-Acceptance-Criteria und Tests.
**Warum:** Vorherige 4 Stages waren alle Code-Qualität-fokussiert; nichts prüfte, ob das PR tatsächlich das liefert, was im Ticket versprochen wurde.
**Modelle:** Codex (primary) + Claude Opus 4.7 (second-opinion judge).
**Referenz:** [`src/ai_review_pipeline/stages/ac_validation.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/stages/ac_validation.py).

## 2026-04-20 — Prompts/-Dir-Bug + Fix (PR#8)

**Was:** Alle 4 Stage-Prompt-Markdown-Files wurden ins Repo committed und die hatchling-Config wurde korrigiert.
**Warum:** Die Prompts waren vorher als Doku in den Python-Files eingebettet; nach dem Extrakt in separate `.md`-Files fehlten sie im Wheel.
**Symptom:** `FileNotFoundError: stages/prompts/code_review.md` bei Stage-Run.
**Referenz:** [PR#8](https://github.com/EtroxTaran/ai-review-pipeline/pull/8).

## 2026-04-20 — handle-button-action.yml (PR#7)

**Was:** Das Target-Workflow für Discord-Button-Klicks. Nimmt `action`, `pr_number`, `user_id` als Inputs.
**Warum:** Ohne diesen Workflow würden Button-Klicks ins Leere zeigen.
**Phase:** Stub-Mode (loggt nur) — echte Aktionen kommen in Phase 5.
**Referenz:** [`ai-review-pipeline/.github/workflows/handle-button-action.yml`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/.github/workflows/handle-button-action.yml).

## 2026-04-20 — PR#42 erster Dogfood-PR (ai-portal)

**Was:** Der erste echte PR im ai-portal wurde durch beide Pipelines geschickt.
**Ergebnis:** v1 Legacy 2/2 Reviewers green → Auto-Merge. v2 Shadow crashte mit Prompt-Bug (führte zu PR#8-Fix).
**Lessons:** Beide Pipelines parallel laufen lassen ist wertvoll — v1 mergte erfolgreich, v2 zeigte einen Bug vor dem Blocking-Status.

## 2026-04-20 — env-Domain-Separation (PR#5)

**Was:** Umstellung von `~/.openclaw/.env` auf `~/.config/ai-workflows/env` für AI-Review-spezifische Variablen.
**Warum:** OpenClaw und AI-Review sind unabhängige Systeme; das versehentliche Überschreiben der OpenClaw-env durch AI-Review-Skripte war fast ein Desaster.
**Fix:** Strikt getrennte env-Dateien, jede mit ihrem eigenen Maintainer-Script.
**Referenz:** [agent-stack PR#5](https://github.com/EtroxTaran/agent-stack/pull/5).

## 2026-04-20 — Discord-Integration + Tailscale-Funnel

**Was:** Discord-Bot "Nathan Ops" mit Bot-Token, 11 Channels, Public-Key-Verify. Tailscale-Funnel öffnet genau einen Pfad (`/webhook/discord-interaction`) fürs Internet.
**Warum:** Email-basierte Review-Benachrichtigungen waren zu leise; man musste aktiv den Posteingang checken. Discord macht das ephemer und sichtbar.
**Referenz:** `ops/discord-bot/init-server.sh` + `ops/compose/n8n-ai-review.override.yml`.

## 2026-04 (früher) — Extraktion der Pipeline aus ai-portal

**Was:** Review-Logik aus ai-portal in eigenes Repo `ai-review-pipeline` als Python-Package extrahiert.
**Warum:** Die Pipeline sollte von mehreren Repos wiederverwendbar sein; eingebettet in ai-portal wäre sie für agent-stack nicht nutzbar gewesen.
**Ergebnis:** Python-Package mit 18 Modulen, 90% Coverage, `ai-review`-CLI.
**Referenz:** [ADR-018](https://github.com/EtroxTaran/ai-portal/blob/main/docs/v2/10-adr/ADR-018-cicd-deploy-pipeline.md) — die Entscheidung.

## Pre-2026-04 — v1 Legacy-Pipeline im ai-portal

**Was:** Erste Implementation mit 2 AI-Reviewern (Codex + Cursor), direkt als YAML-Workflows im Portal-Repo.
**Warum:** Minimaler Erst-Wurf um das Prinzip zu validieren.
**Limitationen:** Keine Security-Stage (nur semgrep im separaten Workflow), keine Design-Stage, keine AC-Validation, Logik hardcoded in YAML.
**Zustand heute:** Läuft weiter als blocking-Pipeline, bis Phase 5 Cutover.

## Verwandte Seiten

- [Lessons Learned](10-lessons-learned.md) — was wir aus diesen Entwicklungen gelernt haben
- [ADRs-Index](20-adrs-index.md) — Architecture-Decision-Records
- [Stolpersteine](../50-runbooks/60-stolpersteine.md) — aggregierte Gotchas
- [Shadow-vs-Cutover](../10-konzepte/20-shadow-vs-cutover.md) — Phasen-Modell

## Quelle der Wahrheit (SoT)

- [ai-review-pipeline Releases](https://github.com/EtroxTaran/ai-review-pipeline/releases)
- [agent-stack Commits](https://github.com/EtroxTaran/agent-stack/commits/main)
- [ai-portal ADR-018](https://github.com/EtroxTaran/ai-portal/blob/main/docs/v2/10-adr/ADR-018-cicd-deploy-pipeline.md)
