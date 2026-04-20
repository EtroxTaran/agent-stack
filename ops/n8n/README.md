# ops-n8n — Optionaler separater n8n-Container

**Aktuelles Deployment**: AI-Review läuft konsolidiert in der bestehenden
`ai-portal-n8n` (Port 5678) — siehe [../README.md](../README.md) "CONSOLIDATED" Banner
und [../scripts/restart-n8n-with-ai-review.sh](../scripts/restart-n8n-with-ai-review.sh).

Dieses Verzeichnis bleibt als **Fallback** für den Fall dass Container-Trennung
später nötig wird (Blast-Radius, Rate-Limit-Isolation, Upgrade-Unabhängigkeit).

## Bei Aktivierung

- Port 5679 (5678 bleibt ai-portal-n8n für Business-Workflows)
- Image: `n8nio/n8n:latest` (kein Custom-Build)
- Env-File: `~/.config/ai-workflows/env` (chmod 600, AI-Workflows-Domain —
  **nicht** `~/.openclaw/.env`; OpenClaw ist eigenständiges Agent-System)
- Volume: `ops-n8n-data`

## Inhalt

- `docker-compose.yml` (optional-fallback, zweite n8n-Instanz auf Port 5679)
- `workflows/` — 3 JSON-Files (bereits in ai-portal-n8n importiert + aktiv):
  - `ai-review-dispatcher.json` (Discord Message + Inline-Buttons)
  - `ai-review-callback.json` (Discord Interaction → GitHub API, Ed25519 Verify)
  - `ai-review-escalation.json` (Alert → Channel pro Projekt)
- `scripts/setup-ops-n8n.sh` — optional: Container starten + Workflows importieren
- `scripts/backup-ops-n8n.sh` — wöchentliches Backup (cron-kompatibel)
