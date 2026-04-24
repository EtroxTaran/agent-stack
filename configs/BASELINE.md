# CLI Best-Practice Baseline

> **Single-Source-of-Truth** für die Settings der vier CLIs (Claude Code, Cursor Agent, Gemini, Codex).
> Wird von `scripts/audit-cli-settings.sh` als Drift-Referenz gelesen. Jeder Eintrag dokumentiert
> **was** gesetzt ist, **warum**, und seit welchem Datum.

Änderungen an dieser Baseline laufen als PR durch die AI-Review-Pipeline (siehe AGENTS.md §8).
`audit-cli-settings.sh` kann **nie** Settings ändern — es meldet nur Drift.

Die maschinenlesbaren Assertions stehen in `configs/BASELINE.assertions.json` direkt daneben.

---

## Claude Code (`configs/claude/settings.json`)

| Key | Soll-Wert | Warum |
|---|---|---|
| `model` | `opus` | AGENTS.md §1: Plan-Phase auf Opus 4.7 |
| `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `"1"` | TeamCreate/SendMessage für Fleet-Delegation aktiv |
| `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `"80"` | AGENTS.md §13: >70% Context = neue Session; 80% als harter Compact-Trigger |
| `env.CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `"32000"` | Default ist niedriger; 32k erlaubt längere Reports ohne Truncation |
| `env.ENABLE_TOOL_SEARCH` | `"1"` | Deferred-Tools via ToolSearch statt alle Schemas im Context |
| `permissions.defaultMode` | `"acceptEdits"` | Rule 0 kompatibel — Änderungen werden ohne Prompt akzeptiert, Denies fangen Gefährliches ab |
| `permissions.deny[]` | enthält `Bash(rm *)`, `Bash(sudo *)`, `Bash(git push --force*)`, `Read(**/.env)`, `Read(~/.ssh/**)` | Baseline-Deny verhindert Datenverlust + Secret-Leaks |
| `hooks.SessionStart` | `project-setup-check.sh` | AGENTS.md §8: AI-Review-Pipeline-Nudge |
| `hooks.PreToolUse[Bash]` | `block-dangerous.sh` | Zweite Verteidigungslinie jenseits der statischen Deny-Liste |
| `hooks.PreToolUse[Edit\|Write]` | `issue-link-check.sh` | AGENTS.md §9: Ticket↔PR-Linkage |
| `hooks.PostToolUse[Edit\|Write]` | `format-on-write.sh` | Format-Drift verhindern |
| `hooks.Stop` | `stop-completion-gate.sh` | Rule 1: Verify Before Done |

---

## Cursor Agent (`configs/cursor/cli-config.json`)

| Key | Soll-Wert | Warum |
|---|---|---|
| `model.modelId` | `composer-2` | AGENTS.md §1: Reviewer-Default |
| `approvalMode` | `"allowlist"` | Nur explizit erlaubte Shell-Patterns laufen ohne Nachfrage |
| `permissions.allow[]` | enthält `Bash(git:*)`, `Bash(gh:*)`, `Bash(pnpm:*)`, `Read(**/*)` | Minimale Arbeits-Allowlist; andere Operationen prompten |
| `sandbox.mode` | `"disabled"` | Trusted local (2-User-System); keine Container-Sandbox nötig |
| `attribution.attributeCommitsToAgent` | `true` | Git-History kennt Autor-Source |
| `attribution.attributePRsToAgent` | `true` | PR-Metadata kennt Autor-Source |

---

## Gemini (`configs/gemini/settings.json`)

| Key | Soll-Wert | Warum |
|---|---|---|
| `security.auth.selectedType` | `"oauth-personal"` | AGENTS.md §10: Minimal-Scope OAuth, keine API-Keys im Container |
| `tools.autoAccept` | `true` | Rule 0 kompatibel |
| `tools.toolOutputMasking.enabled` | `true` | Secret-Redaction in Logs |
| `general.previewFeatures` | `true` | Neue Flags früh sichtbar |
| `general.model` | siehe `MODEL_REGISTRY.md` Pro-Modell | Audit vergleicht gegen Registry |
| `general.flashModel` | siehe `MODEL_REGISTRY.md` Flash-Modell | Audit vergleicht gegen Registry |
| `general.sessionRetention.enabled` | `true` | 30-Tage Sessions für Cross-Day-Continuity |
| `experimental.plan` | `true` | Plan-Mode verfügbar (AGENTS.md §3) |
| `experimental.enableAgents` | `true` | Sub-Agent-Delegation |
| `experimental.checkpointing.enabled` | `true` | Rule 4: automatische Safety-Checkpoints |
| `context.fileName[]` | enthält `GEMINI.md`, `AGENTS.md` | Cross-CLI-AGENTS.md-Konvention |

---

## Codex (`configs/codex/config.toml`)

> **Schema-Hinweis**: Codex-`config.toml` nutzt **top-level Keys**, keine TOML-Sections.
> Referenz: [`openai/codex → codex-rs/core/config.schema.json`](https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json).
> `[model]` / `[sandbox]`-Sections laden **nicht** (`invalid type: map, expected a string`).

| Key | Soll-Wert | Warum |
|---|---|---|
| `model` | siehe `MODEL_REGISTRY.md` `OPENAI_MAIN` (aktuell `gpt-5.5`, künftig höher) | AGENTS.md §11; GPT-5-Familie integriert Reasoning via `model_reasoning_effort` |
| `model_reasoning_effort` | `"medium"` | Balance Latency↔Qualität; Review-Tasks brauchen kein `"high"` (enum: none/minimal/low/medium/high/xhigh) |
| `sandbox_mode` | `"workspace-write"` | Codex darf im Projekt schreiben, nichts außerhalb (enum: read-only/workspace-write/danger-full-access) |
| `approval_policy` | `"never"` | Rule 0 kompatibel; Sandbox-Boundary schützt (enum: untrusted/on-failure/on-request/never/object) |
| `project_doc_max_bytes` | `65536` | Reicht für AGENTS.md + projektspezifische Ergänzung |
| `project_doc_fallback_filenames` | enthält `AGENTS.md`, `CODEX.md` | AGENTS.md als Cross-CLI-Konvention |

---

---

## Modell-Registry Cross-Check

`audit-cli-settings.sh` vergleicht beim Lauf die CLI-Config-Modelle gegen `~/.openclaw/workspace/MODEL_REGISTRY.md` (gepflegt von `model-version-check.py`, der jeden Morgen vor dem Audit frisch läuft).

**Gemappte Paare** (siehe `BASELINE.assertions.json → model_registry.mappings`):

| CLI | Config-Key | Registry-Key |
|---|---|---|
| Gemini | `general.model` | `GEMINI_PRO` |
| Gemini | `general.flashModel` | `GEMINI_FLASH` |
| Codex | `model` | `OPENAI_MAIN` |

**Nicht gemappt** (bewusst):
- **Claude**: Config nutzt Alias `opus` — Claude Code resolved das selbst zur aktuellen Opus-Version (aktuell 4.7).
- **Cursor**: kein öffentliches Modell-Registry — `composer-2` ist Cursor-intern.

**Alert-Logik**:
- Registry älter als 14 Tage → `⚠ warn` (Registry veraltet, `--apply` läuft nicht)
- Config-Wert ≠ Registry-Wert → `⚠ warn` (Modell-Drift)
- Config ist Prefix des Registry-Werts (z.B. `gpt-5` vs. `gpt-5.3-codex`) → `⚠ warn` mit Hinweis "Alias — spezifischer Wert empfohlen" <!-- pin-drift-ignore: Alias-Check-Beispiel, keine echten Pins -->

---

## Änderungshistorie

| Datum | Change | Grund |
|---|---|---|
| 2026-04-24 | Initial-Version | Auto-Update/Audit-System aufgesetzt |
