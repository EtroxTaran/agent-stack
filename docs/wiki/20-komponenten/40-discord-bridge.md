# Discord-Bridge — Guild, Bot, Channels

> **TL;DR:** Discord ist der primäre Benachrichtigungs-Kanal für die Review-Pipeline. Ein Discord-Bot namens "Nathan Ops" postet pro Projekt Nachrichten in dedizierte Kanäle — einen regulären für Produktion und einen Shadow-Kanal für nicht-blockierende Tests. Die Nachrichten enthalten interaktive Buttons (Freigeben, Nochmal prüfen, Manuell übernehmen), die per Klick direkt GitHub-Actions triggern. Der Bot hat ausschließlich die minimal nötigen Rechte (Messages posten, Buttons rendern, Interactions empfangen) — keine Admin-Funktionen, keine Member-Manipulation.

## Wie es funktioniert

```mermaid
graph TB
    subgraph "Discord"
        BOT[Nathan Ops Bot]
        G[Guild 'Nathan Ops']
        CH_PORT[#ai-review-ai-portal]
        CH_PORTS[#ai-review-shadow-ai-portal]
        CH_PIPE[#ai-review-ai-review-pipeline]
        CH_PIPES[#ai-review-shadow-ai-review-pipeline]
        CH_STACK[#ai-review-agent-stack]
        CH_STACKS[#ai-review-shadow-agent-stack]
        CH_ALERTS[#alerts]
    end

    subgraph "r2d2"
        N8N[n8n Dispatcher]
    end

    N8N -->|Bot-Token| BOT
    BOT -->|post message| CH_PORT
    BOT -->|post message| CH_PORTS
    BOT -->|post message| CH_PIPE
    BOT -->|post message| CH_PIPES
    BOT -->|post message| CH_STACK
    BOT -->|post message| CH_STACKS
    BOT -->|@here alert| CH_ALERTS

    classDef bot fill:#1e88e5,color:#fff
    classDef chan fill:#43a047,color:#fff
    classDef shadow fill:#757575,color:#fff
    classDef alert fill:#e53935,color:#fff
    class BOT bot
    class CH_PORT,CH_PIPE,CH_STACK chan
    class CH_PORTS,CH_PIPES,CH_STACKS shadow
    class CH_ALERTS alert
```

Die Discord-Struktur folgt einer einfachen Regel: **ein Channel pro Repo pro Phase**. Jedes Repo hat einen regulären Kanal (für Produktions-Reviews) und einen Shadow-Kanal (für Tests, nicht-blockierend). Dazu kommt ein gemeinsamer Alerts-Kanal, wohin Eskalationen mit `@here`-Mention landen.

Die Trennung Shadow/regulär sorgt dafür, dass der reguläre Kanal **wirklich ernst genommen** wird — dort landen nur Nachrichten, die eine Entscheidung brauchen oder eine erfolgreiche Freigabe melden. Der Shadow-Kanal ist das Experimentier-Feld, in dem auch kaputte Runs und halbgare Urteile landen, ohne Aufmerksamkeit zu verschwenden.

## Technische Details

### Der Bot

- **Name:** Nathan Ops
- **Application-ID:** `1472703891371069511` (öffentlich, nicht sensitiv)
- **Public Key:** 64 hex chars (siehe `DISCORD_PUBLIC_KEY` env-var) — wird zur Signatur-Verifikation der Interactions genutzt
- **Bot-Token:** 72 chars (siehe `DISCORD_BOT_TOKEN`) — **sensitiv**, rotierbar im Discord-Developer-Portal
- **Scopes:** `bot applications.commands`
- **Bot-Permissions:** Send Messages, Read Message History, Use Application Commands

Das Bot-Token ist im n8n-Container als Env-Var verfügbar, nicht in GitHub-Secrets — es gehört nicht in die Cloud.

### Die Guild

- **Name:** Nathan Ops
- **Guild-ID:** 19 chars (siehe `DISCORD_GUILD_ID`)
- **Mitglieder:** Nico + Sabine (Family-Use-Case, keine öffentliche Community)

Die Guild ist bewusst klein — es ist keine Support-Community, sondern der private Benachrichtigungs-Raum für Reviews und Alerts.

### Die 11 Channels

Alle Channel-IDs liegen als Env-Vars im Runner-Env `~/.config/ai-workflows/env`. Das Mapping:

| Env-Var | Zweck |
|---|---|
| `DISCORD_ALERTS_CHANNEL_ID` | Gemeinsamer Alerts-Kanal, empfängt `@here`-Mentions bei Eskalationen |
| `DISCORD_CHANNEL_AI_PORTAL` | Regulärer Review-Kanal für ai-portal-PRs |
| `DISCORD_CHANNEL_AI_PORTAL_SHADOW` | Shadow-Kanal für ai-portal (historisch; Phase 4 bis 2026-04-24). Bleibt für künftige Experimente. |
| `DISCORD_CHANNEL_AI_REVIEW_PIPELINE` | Regulärer Review-Kanal für ai-review-pipeline-PRs (Dogfood) |
| `DISCORD_CHANNEL_AI_REVIEW_PIPELINE_SHADOW` | Shadow-Kanal für ai-review-pipeline |
| `DISCORD_CHANNEL_AGENT_STACK` | Regulärer Review-Kanal für agent-stack-PRs |
| `DISCORD_CHANNEL_AGENT_STACK_SHADOW` | Shadow-Kanal für agent-stack |

Die restlichen 4 Slots sind für zukünftige Projekte reserviert. Vollständige Liste mit Zwecken: [`70-reference/30-channel-mapping.md`](../70-reference/30-channel-mapping.md).

### Interactions Endpoint

Discord braucht eine öffentlich erreichbare URL, wohin Button-Klicks geschickt werden. Im Developer-Portal unter "Interactions Endpoint URL" eingetragen:

```
https://r2d2.tail4fc6dd.ts.net/webhook/discord-interaction
```

Diese URL zeigt auf den Tailscale-Funnel, der die Anfrage an die lokale n8n-Instanz weiterleitet. Details: [`50-tailscale-funnel.md`](50-tailscale-funnel.md) und [`30-n8n-workflows.md`](30-n8n-workflows.md).

Beim "Save" im Developer-Portal schickt Discord einen PING (`type: 1`), auf den der Endpoint mit `{type: 1}` antworten muss. Ohne diesen Handshake speichert Discord die URL nicht. Der Callback-Workflow ist dafür vorbereitet.

### Das Message-Format

Pipeline-Nachrichten nutzen **Components V1** (Action-Row mit Buttons), NICHT `flags: 32768` (das ist V2 und führt zu `MESSAGE_CANNOT_USE_LEGACY_FIELDS_WITH_COMPONENTS_V2`-Fehlern bei gleichzeitigem `content`):

```json
{
  "content": "PR #42 — Soft-Consensus: 2/5 green, avg 7.2\n\nScores:\n  code: 8 …",
  "components": [
    {
      "type": 1,
      "components": [
        {"type": 2, "style": 3, "label": "✅ Freigeben", "custom_id": "approve:42"},
        {"type": 2, "style": 1, "label": "🔄 Nochmal prüfen", "custom_id": "fix:42"},
        {"type": 2, "style": 2, "label": "👤 Manuell übernehmen", "custom_id": "manual:42"}
      ]
    }
  ]
}
```

Die `custom_id`-Konvention ist `action:pr_number` — der Callback-Workflow parst sie zurück zu `{action: "approve", pr_number: 42}`.

### Sticky Messages

Statt bei jedem Status-Update eine neue Nachricht zu posten, aktualisiert der Dispatcher eine existierende Nachricht per `PATCH /channels/{id}/messages/{id}`. Das macht den Channel übersichtlich: pro PR gibt es **eine** Nachricht, die sich im Laufe der Review aktualisiert.

Die `message_id` wird in den n8n-Workflow-State gespeichert (keyed by PR-Number + Repo). Details: [`src/ai_review_pipeline/discord_notify.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/discord_notify.py).

### Token-Rotation

Bot-Token und Interactions-Public-Key rotieren unabhängig:

**Bot-Token rotieren** (Discord Developer Portal → Bot → "Reset Token"):
1. Neuen Token kopieren
2. `DISCORD_BOT_TOKEN` in `~/.config/ai-workflows/env` updaten
3. Container recreate: `bash ~/projects/agent-stack/ops/scripts/restart-n8n-with-ai-review.sh`

**Public Key rotieren** (Discord Developer Portal → General Information → "Reset Public Key"):
1. Neuen Public Key kopieren
2. `DISCORD_PUBLIC_KEY` in env updaten
3. Container recreate

Details: [`50-runbooks/50-token-rotation.md`](../50-runbooks/50-token-rotation.md).

### Guild-Setup

Das initiale Anlegen der Channels ist skriptiert via [`ops/discord-bot/init-server.sh`](https://github.com/EtroxTaran/agent-stack/blob/main/ops/discord-bot/init-server.sh) — es erstellt Channels idempotent und schreibt die IDs zurück in die env-Datei.

Beim Hinzufügen eines neuen Projekts: Das Script ergänzt die Channel-IDs automatisch, wenn `PROJECT_NAMES` in den env-Vars erweitert wird.

## Verwandte Seiten

- [n8n Workflows](30-n8n-workflows.md) — wie die Bridge technisch läuft
- [Tailscale-Funnel](50-tailscale-funnel.md) — der öffentliche Endpoint für Interactions
- [Button-Click-Callback](../30-workflows/10-button-click-callback.md) — der Flow beim Klick
- [Channel-Mapping](../70-reference/30-channel-mapping.md) — Detail-Übersicht aller Channels
- [Token-Rotation-Runbook](../50-runbooks/50-token-rotation.md) — wie man Bot-Token/Public-Key wechselt
- [Soft-Consensus & Nachfrage](../10-konzepte/40-nachfrage-soft-consensus.md) — wann welche Nachricht gepostet wird

## Quelle der Wahrheit (SoT)

- [Discord Developer Portal für Nathan Ops](https://discord.com/developers/applications/1472703891371069511) — Application-Settings + Token-Rotation
- [`ops/n8n/workflows/ai-review-dispatcher.json`](https://github.com/EtroxTaran/agent-stack/blob/main/ops/n8n/workflows/ai-review-dispatcher.json) — Outbound-Workflow
- [`ops/discord-bot/init-server.sh`](https://github.com/EtroxTaran/agent-stack/blob/main/ops/discord-bot/init-server.sh) — Guild-Setup-Skript
