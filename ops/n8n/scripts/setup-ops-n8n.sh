#!/usr/bin/env bash
# setup-ops-n8n.sh — ops-n8n Container starten + Workflows importieren
#
# Verwendung:
#   bash ops/n8n/scripts/setup-ops-n8n.sh           # start + import
#   bash ops/n8n/scripts/setup-ops-n8n.sh --import-only  # nur import (Container läuft schon)
#
# Benötigt:
#   - docker + docker compose v2
#   - N8N_API_KEY in ~/.openclaw/.env (nach erstem Start in n8n UI generieren)
#   - WORKFLOWS_DIR: ops/n8n/workflows/ mit den 3 JSON-Files

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N8N_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$N8N_DIR/docker-compose.yml"
WORKFLOWS_DIR="$N8N_DIR/workflows"
ENV_FILE="$HOME/.openclaw/.env"

# Flags
IMPORT_ONLY=false
for arg in "$@"; do
    [[ "$arg" == "--import-only" ]] && IMPORT_ONLY=true
done

# Env laden
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# --- Schritt 1: Container starten (wenn nicht --import-only) ---
if [[ "$IMPORT_ONLY" == "false" ]]; then
    log_info "Starte ops-n8n Container ..."
    docker compose -f "$COMPOSE_FILE" up -d
    log_ok "Container gestartet."

    # Auf Health warten
    log_info "Warte auf ops-n8n Health (http://127.0.0.1:5679/healthz) ..."
    MAX_WAIT=90
    WAITED=0
    until curl -sf "http://127.0.0.1:5679/healthz" &>/dev/null; do
        [[ $WAITED -ge $MAX_WAIT ]] && die "ops-n8n nicht healthy nach ${MAX_WAIT}s. docker logs ops-n8n"
        echo -n "."
        sleep 3
        WAITED=$((WAITED + 3))
    done
    echo ""
    log_ok "ops-n8n healthy (nach ${WAITED}s)."
fi

# --- Schritt 2: Workflows importieren via n8n REST API ---
N8N_API_BASE="http://127.0.0.1:5679/api/v1"
N8N_API_KEY="${N8N_API_KEY:-}"

if [[ -z "$N8N_API_KEY" ]]; then
    log_warn "N8N_API_KEY nicht gesetzt."
    log_warn "Bitte in n8n UI generieren: Einstellungen → API → API Key erstellen"
    log_warn "Dann N8N_API_KEY in ~/.openclaw/.env setzen und erneut ausführen."
    log_warn "Workflows werden NICHT importiert."
    exit 0
fi

log_info "Importiere Workflows aus $WORKFLOWS_DIR ..."

IMPORTED=0
FAILED=0

for wf_file in "$WORKFLOWS_DIR"/*.json; do
    [[ -f "$wf_file" ]] || continue
    wf_name="$(basename "$wf_file")"

    log_info "  Importiere: $wf_name ..."

    HTTP_STATUS=$(curl -s -o /tmp/n8n-import-response.json -w "%{http_code}" \
        -X POST \
        -H "X-N8N-API-KEY: $N8N_API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$wf_file" \
        "$N8N_API_BASE/workflows" 2>/dev/null)

    if [[ "$HTTP_STATUS" == "200" ]] || [[ "$HTTP_STATUS" == "201" ]]; then
        WF_ID=$(python3 -c "import json,sys; d=json.load(open('/tmp/n8n-import-response.json')); print(d.get('id','?'))" 2>/dev/null || echo "?")
        log_ok "    $wf_name → id=$WF_ID (HTTP $HTTP_STATUS)"
        IMPORTED=$((IMPORTED + 1))

        # Workflow aktivieren
        if [[ "$WF_ID" != "?" ]]; then
            if curl -s -o /dev/null \
                -X PATCH \
                -H "X-N8N-API-KEY: $N8N_API_KEY" \
                -H "Content-Type: application/json" \
                -d '{"active": true}' \
                "$N8N_API_BASE/workflows/$WF_ID" 2>/dev/null; then
                log_ok "    $wf_name aktiviert."
            else
                log_warn "    $wf_name konnte nicht aktiviert werden (Aktivierung separat in n8n UI nötig)."
            fi
        fi
    else
        log_error "    $wf_name fehlgeschlagen (HTTP $HTTP_STATUS)"
        python3 -m json.tool < /tmp/n8n-import-response.json 2>/dev/null || true
        FAILED=$((FAILED + 1))
    fi
done

log_info "Import abgeschlossen: $IMPORTED importiert, $FAILED fehlgeschlagen."

[[ $FAILED -gt 0 ]] && log_warn "Einige Workflows konnten nicht importiert werden. Bitte n8n UI prüfen."

log_ok "setup-ops-n8n.sh fertig."
