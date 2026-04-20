# ops-n8n

Messaging-Bridge für die AI-Review-Pipeline. Getrennt von ai-portal-n8n,
damit Maintenance unabhängig läuft.

- Port 5679 (5678 bleibt ai-portal-n8n für Business-Workflows)
- Image: `n8nio/n8n:latest` (kein Custom-Build)
- Env-File: `~/.openclaw/.env`
- Volume: `ops-n8n-data`

Wird in **Phase 3** (Plan) implementiert — aktuell leer.

Geplant:
- `docker-compose.yml`
- `workflows/ai-review-dispatcher.json` (Discord Components v2, Inline-Buttons)
- `workflows/ai-review-callback.json` (Discord Interaction → GitHub API)
- `workflows/ai-review-escalation.json` (Alert → Channel pro Projekt)
- `scripts/setup-ops-n8n.sh`
- `scripts/backup-ops-n8n.sh`
