# AI-Workflows Secrets Source-of-Truth

**Location:** `~/.config/ai-workflows/env` (chmod 600)

Alle Secrets für AI-Workflow-Systeme (ai-review-pipeline + ai-portal-Workflows die mit
AI-Review interagieren) leben hier. **Separat von `~/.openclaw/.env`** (OpenClaw-Agent-Domain).

## Warum getrennt?

- **OpenClaw-Agent** ist ein eigenständiges Assistant-System (Nathan, Fleet, Sub-Workspaces)
- **AI-Workflows** sind Coding/Review-Infrastructure
- Cross-Domain-Secrets-Sharing = unsauber (OpenClaw-Rotation beeinflusst AI-Review-Uptime
  und umgekehrt, Blast-Radius größer, Audit-Trail verschwimmt)

Plan-Original (§207-212) hatte `~/.openclaw/.env` als globale Secrets-SoT definiert —
das war Design-Fehler. Diese Separation korrigiert das.

## Template

```bash
# AI-Workflows Secrets-SoT (ai-review-pipeline + ai-portal Workflows)
# NICHT mit ~/.openclaw/.env mischen — separate Domain.

# Discord (Nathan-Ops-Guild — AI-Review-Bridge)
DISCORD_BOT_TOKEN=<bot-token>
DISCORD_GUILD_ID=<guild-id>
DISCORD_APPLICATION_ID=<app-id>
DISCORD_PUBLIC_KEY=<ed25519-public-key>

# Discord Channel-IDs (aus provision_channels.py Live-Setup)
DISCORD_ALERTS_CHANNEL_ID=<alerts-channel-id>
DISCORD_CHANNEL_AI_PORTAL=<channel-id>
DISCORD_CHANNEL_AI_PORTAL_SHADOW=<channel-id>
# ... weitere pro Projekt

# GitHub (für n8n-Callback-Workflow → PR-Comments schreiben)
GITHUB_REPO=<owner/repo-default>
GITHUB_TOKEN=<pat-with-repo-workflow-scope>
```

## Zugriff vom n8n-Container

Via docker-compose override (Plan §290 — nicht invasiv):
- `ops/compose/n8n-ai-review.override.yml` fügt einen ZWEITEN `env_file` Mount hinzu
- Startet mit: `ops/scripts/restart-n8n-with-ai-review.sh` (wrapper um `docker compose`)

Die bestehende `ai-portal/docker-compose.yml` bleibt unverändert — `~/.openclaw/.env` wird
weiter für bestehende Business-Workflow-Credentials genutzt. Unsere neue Datei wird ERGÄNZEND
gelesen.

## Permission

```bash
chmod 600 ~/.config/ai-workflows/env
```

Das Restart-Script warnt bei falschen Perms.

## Rotation

Bot-Token:
1. Discord Dev Portal → Bot → Reset Token
2. Neuen Token in `~/.config/ai-workflows/env` eintragen
3. `./ops/scripts/restart-n8n-with-ai-review.sh` ausführen

GitHub-Token:
1. GitHub Settings → Developer settings → PAT rotieren
2. Neuen Token in `~/.config/ai-workflows/env` eintragen
3. Container restart wie oben
