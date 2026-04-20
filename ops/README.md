# ops — Discord Bot + ops-n8n + Tailscale Funnel

Dieser Ordner enthält die vollständige Infrastructure-as-Code für den **Nathan Ops Discord Bot**:
der Messaging-Bus für die AI-Review-Pipeline.

---

## Übersicht

```
ops/
├── discord-bot/
│   ├── provision_channels.py   Discord Channel Provisioning (Python, idempotent)
│   ├── init-server.sh          Wrapper: provisioniert Default-Projekt-Liste in einem Aufruf
│   ├── register-bot.md         Schritt-für-Schritt Discord Dev Portal Setup
│   ├── setup.sh                One-Shot Orchestrations-Script (alles auf einmal)
│   └── .env.example            Alle benötigten Env-Vars (ohne Werte)
└── n8n/
    ├── docker-compose.yml      ops-n8n Container (Port 5679, Volume ops-n8n-data)
    ├── workflows/
    │   ├── ai-review-dispatcher.json   Webhook → Discord Components v2 + Inline-Buttons
    │   ├── ai-review-callback.json     Discord Interaction → Ed25519 Verify → GitHub API
    │   └── ai-review-escalation.json  Eskalation → Discord Alerts Channel
    └── scripts/
        ├── setup-ops-n8n.sh    Container starten + Workflows importieren
        └── backup-ops-n8n.sh   Wöchentliches Backup (cron-kompatibel)
```

**Trennung von ai-portal-n8n:**
- `ai-portal-n8n` (Port 5678): Business-Workflows (Finance, Research, Email). Bleibt unverändert.
- `ops-n8n` (Port 5679): Ausschließlich AI-Review Messaging-Bridge. Teil von `agent-stack`.

---

## Setup-Sequenz (10 Schritte)

### Manuelle Schritte (einmalig von Nico)

- [ ] **1.** Discord Developer Portal — Application "Nathan Ops Bot" anlegen
      → Anleitung: [discord-bot/register-bot.md](discord-bot/register-bot.md)

- [ ] **2.** Bot-Token kopieren → `DISCORD_BOT_TOKEN` in `~/.openclaw/.env`

- [ ] **3.** Application ID + Public Key kopieren → `DISCORD_APPLICATION_ID` + `DISCORD_PUBLIC_KEY` in `~/.openclaw/.env`

- [ ] **4.** OAuth2 URL generieren, Bot zum "Nathan Ops" Guild einladen

- [ ] **5.** Guild ID kopieren (Discord Dev Mode) → `DISCORD_GUILD_ID` in `~/.openclaw/.env`

### Automatisierte Schritte (via `setup.sh`)

- [ ] **6.** `setup.sh` ausführen:
  ```bash
  bash ops/discord-bot/setup.sh
  ```
  Dieser Schritt erledigt:
  - Channel-Provisioning für alle 5 Projekte (idempotent)
  - ops-n8n Container starten
  - Workflows importieren und aktivieren
  - Tailscale Funnel konfigurieren

- [ ] **7.** In n8n UI: API Key generieren (`Einstellungen → API → API Key erstellen`)
      → `N8N_API_KEY` in `~/.openclaw/.env` setzen, dann erneut ausführen:
  ```bash
  bash ops/n8n/scripts/setup-ops-n8n.sh --import-only
  ```

### Abschluss (einmalig manuell)

- [ ] **8.** Discord Dev Portal → General Information → "Interactions Endpoint URL":
  ```
  https://r2d2.tail4fc6dd.ts.net/webhook/discord-interaction
  ```
  "Save Changes" → Discord verifiziert Endpoint automatisch.

- [ ] **9.** Pro Projekt `DISCORD_CHANNEL_ID` in `.ai-review/config.yaml` eintragen
      (Channel-ID via Discord Dev Mode: Rechtsklick auf Channel → "Copy Channel ID")

- [ ] **10.** Smoke-Test: Test-PR erstellen → Pipeline sollte Discord-Nachricht senden

---

## Komponenten-Details

### discord-bot/provision_channels.py

Erstellt pro Projekt:
- `#ai-review-<project>` (Haupt-Review-Channel)
- `#ai-review-shadow-<project>` (Shadow-Mode-Channel, Phase 4)

Sowie einmalig:
- `#ai-review-alerts-global` (cross-projekt Eskalationen)

Alle in Category "AI Review".

```bash
# Dry-Run (keine API-Calls)
python provision_channels.py --guild-id $DISCORD_GUILD_ID --projects ai-portal --dry-run

# Live
python provision_channels.py --guild-id $DISCORD_GUILD_ID \
  --projects ai-portal,nathan-cockpit,openclaw-office,research-workflow-n8n,ai-review-pipeline
```

Tests: `tests/test_provision_channels.py` (12 Tests, TDD).

### n8n Workflows

| Workflow | Webhook-Pfad | Zweck |
|---|---|---|
| `ai-review-dispatcher.json` | `POST /webhook/ai-review-dispatch` | Empfängt Pipeline-Payload, rendert Discord Components v2 mit Buttons |
| `ai-review-callback.json` | `POST /webhook/discord-interaction` | Empfängt Button-Clicks, Ed25519-Verify, GitHub API Call |
| `ai-review-escalation.json` | `POST /webhook/ai-review-escalation` | Alert-Nachricht mit @here in Alerts-Channel |

**Discord Components v2 Buttons (in dispatcher):**

```
[Approve]   [Auto-Fix]   [Manual]
  PRIMARY   SECONDARY     DANGER
  custom_id: approve:{pr} | fix:{pr} | manual:{pr}
```

**Ed25519 Verify (in callback):**
- Pflicht für Discord Interactions (Plan §670)
- `DISCORD_PUBLIC_KEY` aus env
- Bei fehlgeschlagener Verify: HTTP 401
- Bei Discord PING (type:1): sofort `{type:1}` zurück

### ops-n8n docker-compose

- Image: `n8nio/n8n:latest` (kein Custom-Build)
- Port: `5679:5678` (host:container)
- Volume: `ops-n8n-data`
- Env: `~/.openclaw/.env`
- Execution Timeout: 600s

### Tailscale Funnel

Discord braucht einen öffentlichen HTTPS-Endpoint für Interactions (Button-Clicks).
Tailscale Funnel exposed `localhost:5679/webhook/discord-interaction` via:

```
https://r2d2.tail4fc6dd.ts.net/webhook/discord-interaction
```

```bash
# Starten (in setup.sh automatisiert)
sudo tailscale funnel --bg --set-path /webhook/discord-interaction localhost:5679

# Status prüfen
sudo tailscale funnel status
```

---

## Troubleshooting

| Problem | Diagnose | Lösung |
|---|---|---|
| Bot nicht im Guild | `curl ... /guilds/$DISCORD_GUILD_ID` → 401/403 | OAuth2 URL neu generieren, Bot erneut einladen |
| `provision_channels.py` → 403 | Bot fehlt "Manage Channels" Permission | Bot-Permissions im Dev Portal ergänzen, neu einladen |
| n8n nicht erreichbar | `curl http://127.0.0.1:5679/healthz` | `docker compose -f ops/n8n/docker-compose.yml up -d` |
| Workflow-Import schlägt fehl | `docker logs ops-n8n` | N8N_API_KEY prüfen, n8n UI öffnen |
| Discord Endpoint Verify fehlschlägt | Tailscale Funnel Status + Workflow aktiv? | `sudo tailscale funnel status`, Workflow in n8n aktivieren |
| Ed25519 Verify schlägt fehl | `DISCORD_PUBLIC_KEY` falsch? | Aus Dev Portal General Information neu kopieren |
| Button-Click ohne GitHub-Aktion | GitHub Token Scopes? | `GITHUB_TOKEN` braucht `repo` + `workflow` Scopes |

---

## Referenzen

- [register-bot.md](discord-bot/register-bot.md) — Discord Dev Portal Setup
- [Plan §269-399](../.claude/plans/) — n8n-Topologie + Discord-Architektur
- [Plan §748-760](../.claude/plans/) — R1 Tailscale Funnel Entscheidung
- [Discord API Docs](https://discord.com/developers/docs/interactions/message-components) — Components v2
- [ai-review-pipeline](https://github.com/EtroxTaran/ai-review-pipeline) — Pipeline-Code + discord_notify.py
