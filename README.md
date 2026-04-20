# agent-stack

Multi-CLI Agent Standard + AI-Review-Pipeline-Hookup für Nicos
Developer-Setup. Globale Configs und Skills für Claude Code, Cursor CLI,
Gemini CLI und Codex CLI — aus einem Repo, ein Install-Script.

## Was macht das Ding

- **Eine `AGENTS.md`** (Engineering-Rules, TDD, Review-Charter, AC-Style) —
  per Symlink an alle vier CLIs ausgerollt unter dem jeweils erwarteten
  Dateinamen (`CLAUDE.md`, `GEMINI.md`, `~/.codex/AGENTS.md`,
  `~/.cursor/AGENTS.md`).
- **Skills nach Agent-Skills-Open-Standard** (`agentskills.io`) —
  ein `SKILL.md`, cross-tool symlinked.
- **MCP-Server** declarative in `mcp/servers.yaml`, per `register.sh` in
  allen CLIs registriert (Claude/Cursor JSON, Gemini JSON, Codex TOML).
- **Claude-Hooks** (block-dangerous, format-on-write, issue-link-check,
  stop-completion-gate, opt-in tdd-guard).
- **Templates** (Issue Forms mit Gherkin-AC, PR-Template mit Issue-Link-
  Pflicht, `.ai-review/config.yaml`) — ausrollbar in jedes Projekt via
  `scripts/ai-init-project.sh <project-dir>`.
- **dotbot** (git-submodule) als Symlink-Engine.

## Quick-Start

```bash
# 1. Clone
git clone --recursive https://github.com/EtroxTaran/agent-stack ~/projects/agent-stack
cd ~/projects/agent-stack

# 2. Env prüfen (Tokens in ~/.openclaw/.env)
cp .env.example ~/.openclaw/.env   # falls noch nicht vorhanden
$EDITOR ~/.openclaw/.env            # Werte eintragen

# 3. Bootstrap
./install.sh
```

Bei Fehlern: `scripts/preflight.sh` zeigt fehlende Tools.
Bei ungewünschten Änderungen: `scripts/uninstall.sh` restauriert aus
`~/.config/agent-stack/backup-<ts>/`.

## Idempotenz

`install.sh` ist safe to re-run. dotbot ist deklarativ
(Zielzustand in `install.conf.yaml`), `mcp/register.sh` entfernt Server vor
erneutem Registrieren, `scripts/backup-existing.sh` erkennt Symlinks und
bewegt nur reale Files.

## Repo-Struktur (Kurzform)

```
agent-stack/
├── AGENTS.md                    Single-SoT Engineering-Rules
├── install.sh                   Bootstrap-Entrypoint
├── install.conf.yaml            dotbot-Manifest
├── skills/*/SKILL.md            Cross-tool Skills (Agent-Skills-Spec)
├── mcp/servers.yaml             Declarative MCP-Server-Registry
├── mcp/register.sh              Multi-CLI MCP-Registrar
├── configs/                     Per-CLI-Configs + Claude-Hooks
├── templates/                   Issue/PR/Workflow-Templates für Projekte
├── scripts/                     preflight, backup, verify, uninstall, ai-init-project
├── tests/                       Bash-Validatoren (servers.yaml, Skills, Manifest)
├── ops/n8n/                     Messaging-Bridge (ops-n8n, Phase 3)
└── docs/                        Runbooks + Troubleshooting
```

## Voraussetzungen

- Linux oder macOS (Bash 4+), Ubuntu 22.04+/macOS 14+ getestet
- `git`, `gh` (authed), `node` (≥18), `npx`, `python3`, `yq` (v4, Mike
  Farah), `jq`, optional `docker`, optional `tailscale`
- Active OAuth-Sessions je CLI — werden vom preflight geprüft und bei
  Fehlen mit Login-Hinweis gemeldet (keine blockierende Fehlermeldung)

## Weiterführend

- Plan für die Implementierung: Phasen 1–5 in
  `~/.claude/plans/reports-projects-ai-portal-docs-v2-40-a-iridescent-flask.md`
- `ai-review-pipeline` — eigenes Repo (pip-Package + `gh ai-review`
  Extension), ab Phase 3
- OpenClaw Workspace — Nathan-Identität + Sub-Workspaces (parallel,
  referenziert von AGENTS.md)

## Lizenz

MIT.
