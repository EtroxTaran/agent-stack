#!/usr/bin/env bash
# backup-ops-n8n.sh — Wöchentliches Backup der ops-n8n Workflows + Credential-IDs
#
# Cron-kompatibel (wöchentlich):
#   0 3 * * 0 /home/clawd/projects/agent-stack/ops/n8n/scripts/backup-ops-n8n.sh
#
# Exportiert:
#   - Alle Workflows als JSON (via n8n REST API)
#   - Credential-IDs als Liste (keine Werte — Security!)
#   - Paketiert als tarball in ~/.openclaw/backups/ops-n8n/
#
# Benötigt:
#   - N8N_API_KEY in ~/.openclaw/.env
#   - ops-n8n Container läuft (http://127.0.0.1:5679 erreichbar)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# Env laden
ENV_FILE="$HOME/.openclaw/.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

N8N_API_KEY="${N8N_API_KEY:-}"
N8N_API_BASE="http://127.0.0.1:5679/api/v1"
BACKUP_BASE="$HOME/.openclaw/backups/ops-n8n"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_BASE/$TIMESTAMP"

mkdir -p "$BACKUP_DIR"

# Erreichbarkeit prüfen
if ! curl -sf "http://127.0.0.1:5679/healthz" &>/dev/null; then
    die "ops-n8n nicht erreichbar (http://127.0.0.1:5679/healthz). Container läuft?"
fi

if [[ -z "$N8N_API_KEY" ]]; then
    die "N8N_API_KEY nicht gesetzt in $ENV_FILE. Backup nicht möglich."
fi

log_info "Backup gestartet: $BACKUP_DIR"

# --- Workflows exportieren ---
log_info "Exportiere Workflows ..."

WORKFLOWS_RESPONSE=$(curl -s \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "$N8N_API_BASE/workflows" 2>/dev/null)

if [[ -z "$WORKFLOWS_RESPONSE" ]]; then
    die "Keine Antwort von n8n API. API-Key korrekt?"
fi

# Alle Workflows als einzelne JSONs + Gesamtliste
echo "$WORKFLOWS_RESPONSE" > "$BACKUP_DIR/workflows-all.json"

# Pro Workflow einzelne Datei
WF_COUNT=$(echo "$WORKFLOWS_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
workflows = data if isinstance(data, list) else data.get('data', [])
for wf in workflows:
    name = wf.get('name','unknown').replace(' ', '-').replace('/', '-')
    wf_id = wf.get('id', 'unknown')
    safe_name = ''.join(c for c in name if c.isalnum() or c in '-_')
    filename = f'{safe_name}-{wf_id}.json'
    with open('${BACKUP_DIR}/' + filename, 'w') as f:
        json.dump(wf, f, indent=2)
print(len(workflows))
" 2>/dev/null || echo "0")

log_ok "Workflows exportiert: $WF_COUNT Files."

# --- Credential-IDs exportieren (keine Werte!) ---
log_info "Exportiere Credential-IDs (keine Werte) ..."

CREDS_RESPONSE=$(curl -s \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "$N8N_API_BASE/credentials" 2>/dev/null)

if [[ -n "$CREDS_RESPONSE" ]]; then
    echo "$CREDS_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
creds = data if isinstance(data, list) else data.get('data', [])
# Nur IDs + Namen exportieren, KEINE Werte
safe_creds = [{'id': c.get('id'), 'name': c.get('name'), 'type': c.get('type')} for c in creds]
print(json.dumps(safe_creds, indent=2))
" > "$BACKUP_DIR/credential-ids.json" 2>/dev/null || echo "[]" > "$BACKUP_DIR/credential-ids.json"
    log_ok "Credential-IDs exportiert."
else
    log_warn "Keine Credentials gefunden oder API-Fehler."
    echo "[]" > "$BACKUP_DIR/credential-ids.json"
fi

# --- Tarball erstellen ---
log_info "Erstelle Tarball ..."
TARBALL="$BACKUP_BASE/ops-n8n-backup-$TIMESTAMP.tar.gz"
tar -czf "$TARBALL" -C "$BACKUP_BASE" "$TIMESTAMP"
log_ok "Tarball: $TARBALL"

# Backup-Verzeichnis aufräumen (nur Tarball behalten)
rm -rf "$BACKUP_DIR"

# --- Alte Backups bereinigen (älter als 30 Tage) ---
find "$BACKUP_BASE" -name "ops-n8n-backup-*.tar.gz" -mtime +30 -delete 2>/dev/null \
    && log_info "Alte Backups (>30 Tage) bereinigt." \
    || true

log_ok "Backup abgeschlossen: $TARBALL"
log_info "Inhalt: $WF_COUNT Workflows, Credential-IDs (ohne Werte)"
