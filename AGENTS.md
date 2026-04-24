# AGENTS.md — Global Engineering Rules

> Single-Source-of-Truth. Wird per Symlink von allen 4 CLIs gelesen:
> `~/.claude/CLAUDE.md`, `~/.gemini/GEMINI.md`, `~/.codex/AGENTS.md`, `~/.cursor/AGENTS.md`.
> Projekt-spezifische Ergänzungen: `<project>/AGENTS.md` (ergänzt, überschreibt nicht).

---

## 1. Identität & Kontext

- **User**: Nico & Sabine Rimmele (Familie, 2-User-Use-Case).
- **Maintainer-Agent**: Nathan — Identity-Kern in `~/.openclaw/workspace/SOUL.md`
  ("direkt, proaktiv, kein Ja-Sager"). Hier bewusst NICHT dupliziert.
- **Primary-Dev-CLI**: Claude Code (Plan: Opus 4.7 · Implement: Sonnet 4.6 · Subagents/Commits: Haiku 4.5).
- **Reviewer-CLIs**: Codex, Cursor, Gemini, Claude — konkrete Modell-Pins in §8 (aus Registry).
- **OpenClaw-Koexistenz**: `~/.openclaw/workspace/AGENTS.md` hält Nathan-Identität + Sub-Workspaces
  (11 Agents, Fleet-Architektur, Ownership-Map). Diese Datei hier = Engineering-Infrastructure.
  Beide referenzieren sich, leben aber separat.

---

## 2. Nicht-Verhandelbare Kernregeln

### 🔴 Rule 0 — NO DE-SCOPING

Wenn Nico (oder Sabine) einen Auftrag gibt → **vollständig** abarbeiten. Ausnahmslos.

- ❌ Keine eigenständige Task-Streichung, kein stilles Reprioritisieren, kein "auf später".
- ❌ Keine Scope-Reduktion aus Bequemlichkeit, Zeitdruck oder Token-Budget.
- ✅ Dauert länger → dauert länger. Das ist OK.
- ✅ Echter Blocker (technische Unmöglichkeit, fehlende Credentials, externer Stopper) → **Nico FRAGEN**, nicht selbst entscheiden.

Gilt für ALLE Agents. Konsequenz bei Verstoß: sofortige Reflexion + Lessons Learned.

### 🔴 Rule 1 — Verify Before "Done"

Bevor etwas als erledigt gemeldet wird: mechanisch prüfen.

- Code: `bash scripts/completion-gate.sh "<dir>" "<feature>"`
- Recherche: `python3 scripts/research-quality-gate.py "<report>"`
- Status/Reports: echte Daten holen (`git log`, `gh pr list`, `curl API`) — **nie** aus Memory zitieren.
- Sub-Agent meldet "done" → selbst mechanisch verifizieren, nie nur trauen.

Exit 0 → melden. Sonst → fixen. Niemals Features eigenmächtig zurückstellen.

### 🔴 Rule 2 — Produktcode nur mit Nicos Freigabe

Kein Merge in `main`, kein Deploy, kein Release ohne **explizites** Go von Nico.
PR öffnen ist OK. Selbst mergen ist verboten.

### 🔴 Rule 3 — No Assumptions

Annahmen sind verboten. Immer klären, nie raten.

- Missing info → STOP → fragen, nicht erfinden.
- Unklarer Pfad/Config → `ls`/`cat`/`curl` zuerst, dann handeln.
- API/Tech-Verhalten → Docs prüfen (Context7, Ref), nicht aus Trainingsdaten annehmen.
- Unklarer Scope → Definition-of-Done VOR dem ersten Tool-Call klären.

❌ "This probably worked because no error appeared" · ❌ "I assume X is meant"
✅ "Bevor ich starte: meinst du A oder B?"

### 🔴 Rule 4 — Git-Checkpoint vor erstem Write

```bash
git add -A && git commit -m "checkpoint: vor [task-name]"
```

Kein Checkpoint = kein Start. Keine Ausnahmen. (`checkpoint:` ist Convention, nicht Conventional-Commit-Type — landet in History als Safety-Anker.)

### 🔴 Rule 5 — Blocker sofort melden

Kannst du nicht weiter? Unklarheit? → Nico **jetzt** informieren, nicht still umgehen.
**Deferral-Limit**: 1× vertagen ("morgen fixen") ist OK. Danach sofort lösen oder eskalieren.

---

## 3. Plan-First bei Tasks > 15 Minuten

Plan schreiben → OK abwarten → bauen. Format:

```
PLAN: [Was gebaut wird]
FILES: [Betroffene Dateien, absolute Pfade]
RISKS: [Risiken, Edge-Cases, Rollback-Pfad]
→ Warte auf Bestätigung
```

Ohne Bestätigung kein erster Write. Bei großen Tasks: Plan als `.claude/plans/<slug>.md` committen.

---

## 4. TDD — Test-Driven Development (PFLICHT)

Zweithöchste Regel nach Rule 0. Gilt für ALLE Agents, ALLE Features. Keine Ausnahmen.

### Zyklus: Red → Green → Refactor

1. **Red**: Test schreiben, der fehlschlägt (beweist Testwert).
2. **Green**: Minimaler Code, damit Test besteht. Nicht mehr.
3. **Refactor**: Aufräumen ohne Verhaltensänderung. Tests bleiben grün.

Nie überspringen, nie umkehren.

### Patterns

| Pattern | Einsatz |
|---|---|
| Arrange-Act-Assert (AAA) | Unit- & Integration-Tests |
| Given-When-Then | Playwright E2E, Gherkin-AC |
| Test Doubles (Mocks/Stubs/Fakes) | API-Calls, DB, n8n-Webhooks |
| Contract Testing | Backend↔Frontend API-Grenzen |
| Smoke-test Ladder | Nach jeder n8n-Workflow-Änderung |

**Playwright E2E**: `page.route()` für API-Mocking **zuerst** aufsetzen, bevor Feature-Logik entsteht.

### Verboten

- ❌ Implementierung zuerst, Tests danach — das ist KEIN TDD.
- ❌ "Tests später" — gibt es nicht.
- ❌ Feature als "fertig" ohne laufende Tests.
- ❌ Tests weglassen weil "zu einfach" oder "offensichtlich".

---

## 5. Research Before Build

Vor **jeder** Implementierung (Script, Skill, Feature, Config-Änderung):

1. **Problem definieren** — Was genau, für wen?
2. **Bestandsaufnahme** — Existiert Skill/Tool/MCP/Script/ADR/Tech-DB-Eintrag schon?
3. **Optionen evaluieren** — Mind. 2 Alternativen. Tool-Typ wählen:
   - Native Tool > MCP > CLI > Python-Script > Skill
   - MCP nur wenn vendor-maintained und besser als CLI-Alternative.
   - CLI bevorzugt wenn `gh`, `gog`, `surreal` etc. vorhanden.
4. **Tech-DB konsultieren** (OpenClaw) — `python3 scripts/tech-db.py recommend <use-case>`;
   bei Entscheidung `TECH_DB_REF: tech-…` oder `NO_TECH_DB_MATCH` + Follow-up.
5. **Docs aktuell** — Context7 / Ref MCP statt Trainingsdaten. `use context7` im Prompt.
6. **Zukunftssicherheit** — Kann es wiederverwendet werden? Skill > Script.
7. **Stress-Test** — Eigenen Plan challengen: was kann schiefgehen? Besserer Ansatz?
8. **Bei Unklarheit → eskalieren**, nicht raten.

"Der schnellste Weg" ist KEINE valide Begründung. "Der richtige Weg" ist es.

### Multi-Source-Research (Pflicht bei nicht-trivialen Fragen)

```bash
python3 ~/.openclaw/workspace/scripts/research.py "query"           # Brave + Perplexity + Grok + Tavily
python3 ~/.openclaw/workspace/scripts/research.py "query" --quick   # Brave + Perplexity
python3 ~/.openclaw/workspace/scripts/research.py "query" --images  # mit Bildern
```

`web_search` allein reicht nicht.

### Website-Analyse

```bash
python3 ~/.openclaw/workspace/scripts/web-analyze.py "https://example.com"
python3 ~/.openclaw/workspace/scripts/web-analyze.py "https://example.com" --compare  # Desktop vs Mobile
python3 ~/.openclaw/workspace/scripts/web-analyze.py /path/image.png --analyze-image
```

---

## 6. Strukturiert arbeiten — Tasks vor Aktionismus

Jeder nicht-triviale Auftrag (>1 Schritt):

1. **Verstehen** — Rückfragen bei Unklarheit (Rule 3).
2. **Zerlegen** — Konkrete, prüfbare Einzeltasks.
3. **Tracken** — `python3 scripts/task-tracker.py create "Titel" --agent <name> --project <p> --priority <prio>`
4. **Priorisieren** — Abhängigkeiten + kritischer Pfad.
5. **Research** (Rule 5) — Ist der Ansatz richtig?
6. **Abarbeiten** — Ein Task nach dem anderen, status `in_progress` → `complete`.
7. **PROGRESS.md** pflegen — Status + aktuelle Schritte + Blocker. Cockpit liest das.
8. **Abschluss** — `task-tracker.py complete <id>` + `status: done`.

Kein "einfach mal machen". Kein stilles Scheitern.

---

## 7. Code-Standards

- **TypeScript**: strict, kein `any`, explizite Return-Types.
- **Styling**: Tailwind only — kein raw CSS außer `@media print`.
- **Commits**: Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`).
  Safety-Checkpoints (Rule 4) dürfen `checkpoint:` als Ausnahme-Prefix verwenden.
- **Sprache**: Deutsche Kommentare, englischer Code.
- **Confidence Scoring (Debugging)**: vor Implementation Score 0–100% angeben.
  <70% → erst recherchieren (Context7, Docs, Multi-Source). ≥70% → implementieren, Score als Kommentar.
- **Playwright E2E**: `page.route()` vor Feature-Logik.
- **Deutsche Prose, englische Code-Identifier** — konsistent halten.

---

## 8. Review-Charter (AI-Review-Pipeline)

Details: `github.com/EtroxTaran/ai-review-pipeline`.

- **5 Stages**:
  1. Code-Review (Codex)
  2. Code-Cursor (Cursor)
  3. Security (Gemini + semgrep)
  4. Design (Claude)
  5. AC-Validation (Codex primary, Claude second-opinion)
- **Confidence-weighted Consensus**: Scoring 1–10, `avg ≥ 8` = success, 5–7 = soft (Nachfrage),
  `< 5` = failure.
- **Fail-Closed**: fehlende Stage = pending (nicht success).
- **Waiver mit Audit-Trail**: `/ai-review security-waiver <reason ≥30 chars>` bzw. `ac-waiver` —
  strukturiert, nie label-basiert.
- **Primary-Channel**: Discord (ein Guild "Nathan Ops", Channel pro Projekt). Kein Telegram mehr.

<!-- model-registry-start -->
<!-- AUTO-GENERIERT aus ai-review-pipeline/registry/MODEL_REGISTRY.env -->
<!-- NICHT manuell editieren — Änderungen kommen aus dem Weekly-Drift-Check -->
<!-- Regeneriert: 2026-04-24 -->

### Reviewer-Modell-Defaults (aus Registry)

| Rolle | Modell | Quelle |
|---|---|---|
| Code-Review (Codex) | CLI-Default | `CODEX_CLI_VERSION=latest` |
| Code-Cursor | CLI-Default | `CURSOR_AGENT_CLI_VERSION=latest` |
| Security (Gemini) | `gemini-3.1-pro-preview` | `GEMINI_PRO` |
| Design (Claude) | `claude-opus-4-7` | `CLAUDE_OPUS` |
| AC-Second-Opinion | `claude-opus-4-7` | `CLAUDE_OPUS` |
| Auto-Fix | `claude-sonnet-4-6` | `CLAUDE_SONNET` |
| Fix-Loop | `claude-sonnet-4-6` | `CLAUDE_SONNET` |

### LLM-Modell-Versionen (aus Registry)

- **Claude**: Opus `claude-opus-4-7` · Sonnet `claude-sonnet-4-6` · Haiku `claude-haiku-4-5`
- **OpenAI (Codex-CLI Main)**: `gpt-5.5`
- **Gemini**: Pro `gemini-3.1-pro-preview` · Flash `gemini-3.1-flash-live-preview`
- **CLI-Pins**: Codex `latest` · Cursor-Agent `latest`

Registry wird wöchentlich automatisch geprüft (Montag 08:00 UTC) via
[`.github/workflows/model-registry-drift-check.yml`](.github/workflows/model-registry-drift-check.yml).
Drift → auto-PR in [ai-review-pipeline](https://github.com/EtroxTaran/ai-review-pipeline).
Manuelle Overrides via `AI_REVIEW_MODEL_<ROLE>` Env-Var oder
`~/.openclaw/workspace/MODEL_REGISTRY.md` (Dev-Override).

<!-- model-registry-end -->

Override-Pfad pro Run: `AI_REVIEW_MODEL_<ROLE>` Env-Var · Dev-Override via
`~/.openclaw/workspace/MODEL_REGISTRY.md`. Registry-Source-of-Truth liegt in
[`ai-review-pipeline/registry/MODEL_REGISTRY.env`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/registry/MODEL_REGISTRY.env).

### Project-Setup-Step (automatisch bei Session-Start)

Jedes Projekt unter `github.com/EtroxTaran/*` MUSS die Review-Pipeline aktiviert haben.
Der SessionStart-Hook `~/.claude/hooks/project-setup-check.sh` prüft das bei jedem
Claude-Code-Start automatisch und printet — falls nicht konfiguriert — eine
handlungsbare Anleitung:

```
┌────────────────────────────────────────────────┐
│ ⚠️  AI-Review-Pipeline nicht aktiviert         │
│                                                │
│ Setup (~5 Min):                                │
│   gh ai-review install                         │
│   $EDITOR .ai-review/config.yaml               │
│   gh ai-review verify                          │
└────────────────────────────────────────────────┘
```

**Der Agent (Claude / Cursor / Gemini / Codex) liest diesen Output im Session-Start
und MUSS beim ersten nicht-trivialen User-Request:**

1. Den Nudge erwähnen (einmal pro Session, nicht wiederholen)
2. Anbieten, das Setup auszuführen (falls User-Intent = "neues Projekt aufsetzen")
3. Bei Ablehnung: respektieren, nicht drängen

**Bypass-Mechanismen** (wenn ein Repo bewusst ohne Pipeline läuft):
- `touch .ai-review/.noreview && git add … && git commit` im Repo
- `CLAUDE_SKIP_AI_REVIEW_SETUP=1` als Environment-Variable
- Fremd-Repos (nicht `EtroxTaran/*`): Hook feuert nicht

**Setup-Ablauf** (Details: `agent-stack/docs/wiki/40-setup/00-quickstart-neues-projekt.md`):
1. `gh ai-review install` — kopiert 10 Workflow-Templates + `.ai-review/config.yaml`
2. `$EDITOR .ai-review/config.yaml` — Discord-Channel-ID eintragen
3. `gh ai-review verify` — Sanity-Check (Templates da, Config-Schema valid, Secrets gesetzt)
4. `bash ~/projects/agent-stack/ops/discord-bot/init-server.sh --add-project <name>` — Channels anlegen
5. PR öffnen → Branch-Protection konfigurieren (`ai-review/consensus` als Required-Check)

**Warum als Hook und nicht als "bitte dran denken"**: Der Hook ist deterministisch,
der Mensch vergisst. Informationelle CLAUDE.md-Notizen werden vom Agent ignoriert
wenn der Session-Kontext voll ist — ein Bash-Output beim Session-Start ist
garantiert sichtbar.

---

## 9. Ticket ↔ PR Linkage (strikt)

- **Branch-Naming**: `feat/<slug>-issue-<N>` · `fix/<slug>-issue-<N>` · `chore/<slug>-issue-<N>`.
- **Jeder PR**: `Closes #N` oder `Refs #N` im Body. Fail-Closed.
  Einziger Ausweg: `/ai-review ac-waiver <reason ≥30 chars>`.
- **Acceptance Criteria in Gherkin** (Given-When-Then) im Issue-Body.
- **AC-Coverage**: 1:1 Mapping AC ↔ Test (Playwright-E2E oder Unit).
- Kein Label-Override, kein "fixing typo, no issue needed".

---

## 10. Security Guardrails

- OAuth-Scopes **nie** über `openid email profile` hinaus — Minimal-Prinzip.
- LLM-API-Keys **nur** in n8n-Credential-Store oder `~/.openclaw/.env`, **nie** im App-Container.
- `pull_request_target` in GitHub-Workflows **verboten** (Injection-Risiko).
- `nosemgrep`-Marker erfordern Justification-Comment (sonst Security-Stage fail).
- DB-Queries **parametrisiert**, nie String-Interpolation.
- Secrets nie committen. `.env` in `.gitignore`. `.env.example` listet nur Keys, keine Werte.
- Destructive Git-Commands (`reset --hard`, `push --force`, `branch -D`) nur mit expliziter User-Bitte.

---

## 11. Always Latest — Models & Frameworks

Niemals veraltete Versionen verwenden. Ältere Version im Code gefunden → STOPP → Nico informieren → Upgrade-Plan.

### LLM-Modelle

Aktuelle Pins siehe §8 Reviewer-Charter (auto-generiert aus
[`ai-review-pipeline/registry/MODEL_REGISTRY.env`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/registry/MODEL_REGISTRY.env)).
Weekly-Drift-Check [`.github/workflows/model-registry-drift-check.yml`](.github/workflows/model-registry-drift-check.yml)
prüft Montag 08:00 UTC automatisch und öffnet PR bei Drift.

Orientierungswerte (Stand 2026-04-24 — immer via Pre-Suggestion-Check unten verifizieren):

- **Claude**: `claude-opus-4-7` · `claude-sonnet-4-6` · `claude-haiku-4-5`
- **OpenAI**: `gpt-5.5` (released 2026-04-23 — inkl. `gpt-5.5-thinking`, `gpt-5.5-pro`). `gpt-5` ist Vor-Version, nicht deprecated aber nicht mehr Default.
- **Gemini**: `gemini-2.5-pro` ist möglicherweise veraltet (Hinweise auf Gemini 3.1 Pro) — **vor Nutzung verifizieren** via `python3 ~/.openclaw/workspace/scripts/research.py "latest Gemini Pro model 2026"`. `gemini-2.0-flash` weiterhin gültig.

### Embedding-Modelle (Stand 2026-04-24)

> Vor jeder Embedding-Empfehlung: Pre-Suggestion-Check unten durchführen. Diese Tabelle ist ein Ausgangspunkt, keine Garantie.

- **Gemini `gemini-embedding-2`** (GA 2026-04-22, 3072-dim, omnimodal: Text+Image+Video+Audio+PDF) — Default für Multi-Modal + Google-Stack-Alignment.
- **Voyage `voyage-4`** ($0.06/1M, 1024-dim, Text) — Anthropic-Partner, beste Preis/Leistung für Text-only.
- **Ollama `bge-m3`** (SOTA open-weight, 1024-dim, 100+ Sprachen inkl. DE+EN) — Default für Privacy-sensitive + Self-Hosted.
- **OpenAI `text-embedding-3-large`** (3072-dim) — noch gültig, kein Nachfolger gemerged.
- **Jina `jina-embeddings-v4`** (Preview), **Cohere `embed-v4`** — für Spezialfälle.

`gemini-embedding-001` ist abgelöst — nicht mehr empfehlen.

### Version-Check vor Build

1. Libraries: `use context7` im Prompt → aktuelle API-Docs.
2. `npm install <pkg>`: vorher `npm info <pkg> version`.
3. Modell-Auswahl: Registry ist SoT — siehe §8 + Weekly-Drift-Check.
4. MCP-Server via npx: immer `@latest`.

❌ `claude-opus-4-5` wenn `-4-7` existiert · ❌ `npm install react@18` ohne Check
✅ `@latest`, `use context7`

### 🔴 Pre-Suggestion-Check für Modell-Vorschläge (Rule-3-Verstärkung)

Bevor du **irgendein** konkretes Modell (LLM oder Embedding) namentlich empfiehlst oder in Code/Docs einträgst:

1. `python3 ~/.openclaw/workspace/scripts/research.py "latest <provider> <model-class> 2026"` ODER
2. Perplexity mit `recency: month` + Fachbegriffe, ODER
3. Context7 für offizielle Docs-Pages des Providers.

**Dann** erst Vorschlag. **Niemals** aus Trainingsdaten-Erinnerung. Auch nicht wenn du dir "sicher" bist.

*Failure-Pattern 2026-04-24*: Empfehlung `gemini-embedding-001` ohne Check, obwohl `gemini-embedding-2` zwei Tage vorher GA ging. Zwei-Tage-Stale-Knowledge ist normal, nicht Ausnahme.

Enforcement: Verletzung → Lessons-Learned-Eintrag + sofortige Korrektur + Memory-Update.

---

## 12. Tool-Stack

- **CLIs**: Claude Code (primary), Cursor, Gemini, Codex — alle via `agent-stack/install.sh`.
- **MCP-Server** (in `agent-stack/mcp/servers.yaml` deklarativ, pro CLI registriert):
  `github`, `filesystem`, `context7`, `brave-search`, `perplexity`, `sequential-thinking`,
  `knowledge-graph`, `playwright`, `n8n`, `Ref`, `docker`, `memory`.
- **Messaging-Bus**: Discord (ein Guild "Nathan Ops", ein Bot, Channel pro Projekt).
  Telegram komplett raus (Phase-5-Cutover).
- **Runner**: r2d2 Self-Hosted GitHub-Actions (ephemeral).
- **Messaging-Bridge**: `ops-n8n` auf r2d2:5679 (nicht die ai-portal-n8n auf :5678).
- **Quality-Gate**: Nach komplexen Outputs `gemini "Review für Korrektheit: $(git diff HEAD~1)"` triggern.

---

## 13. Context-Window-Hygiene

- `/context` laufend monitoren.
- **>70% Context** → neuen Task in frischer Session starten.
- Große Reads vermeiden — gezielte File-Reads statt ganzes Repo blind lesen.
- Kontextschwere Aufgaben (Research, Log-Analyse) → Subagents (OpenClaw Spock/Kaylee-Pattern).

---

## 14. Skills — Cross-Tool Standard

- **Format**: Agent Skills Open Standard (`SKILL.md` YAML-Frontmatter + Markdown).
  Eine Quelle in `agent-stack/skills/`, via dotbot symlinked in:
  - `~/.agents/skills/<name>` — **Primär-SoT**, nativ gelesen von **Codex** (offizielle Docs: [developers.openai.com/codex/skills](https://developers.openai.com/codex/skills)) und **Gemini** ([geminicli.com/docs/cli/skills](https://geminicli.com/docs/cli/skills/)).
  - `~/.claude/skills/<name>` — redundanter Symlink für Claude (erwartet seinen eigenen Pfad).
  - **Cursor** hat aktuell keinen nativen Skills-Support (Forum-Antwort Cursor-Mod, 2026-04). Plan: MCP-Bridge (Follow-up).
- **Tool-neutral**: Keine CLI-spezifischen Bash-Calls in Skills (`claude …`, `cursor-agent …`).
  Nur generische MCP-Tools + Standard-Bash.
- **Authoring-Workflow** (Anthropic Skill-Creator):
  1. Draft `SKILL.md` mit pushy-Description (Trigger-Phrases + "NOT for:")
  2. `evals/evals.json`: 5 Trigger + 3 No-Trigger + `expected_output`
  3. Eval-Loop: with-skill vs. without-skill Benchmark → iterate bis **≥80% Pass-Rate**
  4. Trigger-Tuning: `python ~/.openclaw/skills/skill-creator/scripts/improve_description.py`
  5. PR in `agent-stack`, CI validiert (`skills-ref validate` oder eigener Validator).
- **Zwei Typen**: Capability Uplift (kann obsolet werden) vs. Encoded Preference (durable, personalisiert).

---

## 15. Memory & Persistence

- **Auto-Memory** (Claude): `~/.claude/projects/<session>/memory/MEMORY.md`.
- **Knowledge-Graph**: shared Claude↔Cursor via `~/.cursor/memory/global.jsonl`.
- **Session-Plans**: `~/.claude/plans/*.md`.
- **NICHT persistieren**: Ephemere Task-Details, Debugging-Rezepte (gehören in Code + git log).
- **Lessons Learned**: `~/.openclaw/workspace/memory/lessons-learned.md`.

---

## 16. Agent-Delegation (OpenClaw Fleet)

Bei jeder Agent-zu-Agent-Delegation — Handoff-Format:

```
TASK: [Präzise Aufgabenbeschreibung]
CONTEXT: [Was bekannt ist, Dateien/Pfade, bisherige Ergebnisse]
DELIVERABLE: [Exakt was geliefert werden soll — Format, Ort, Qualitätskriterien]
ESCALATE_TO: [Agent-ID für Eskalation — default: nathan]
```

### Fleet-Tier (OpenClaw)

| Tier | Agents | Darf |
|---|---|---|
| Orchestrator | Nathan, Lisa | Alle Agents beauftragen, Fleet koordinieren |
| Autonomous | Spock, Kaylee | Sub-Agents spawnen für eigene Tasks |
| Leaf | Alle anderen | Tasks ausführen, **NICHT** selbst Agents spawnen |

Details: `~/.openclaw/workspace/AGENTS.md` §6 + `docs/extended-rules.md`.

---

## 17. Wichtige Pfade

- **Workspace (OpenClaw)**: `~/.openclaw/workspace/`
- **Skills (Cross-Tool-SoT)**: `~/projects/agent-stack/skills/` → symlinked in `~/.agents/skills/` (primär) + `~/.claude/skills/` (redundant für Claude-Pfad-Erwartung)
- **Scripts (OpenClaw)**: `~/.openclaw/workspace/scripts/`
- **Env (Secrets-SoT)**: `~/.openclaw/.env` — **NIE** im Repo committen
- **Projects**: `~/projects/`
- **agent-stack Repo**: `~/projects/agent-stack/`

---

## 18. Referenzen

- **OpenClaw AGENTS.md**: `~/.openclaw/workspace/AGENTS.md` (Rule 0, Fleet, Sub-Workspaces, Tech-DB, PROGRESS.md)
- **OpenClaw SOUL.md**: `~/.openclaw/workspace/SOUL.md` (Nathan-Persönlichkeit)
- **ai-review-pipeline**: `github.com/EtroxTaran/ai-review-pipeline`
- **agent-stack Repo**: `github.com/EtroxTaran/agent-stack` (diese Datei ist dessen `AGENTS.md`)
- **Skill-Creator**: `~/.openclaw/skills/skill-creator/SKILL.md`
- **Agent Skills Spec**: `agentskills.io/specification`
