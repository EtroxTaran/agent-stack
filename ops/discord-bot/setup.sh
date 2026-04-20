#!/usr/bin/env bash
# setup.sh — One-Shot Setup: Discord Bot + ops-n8n + Tailscale Funnel
#
# Orchestriert:
#   1. Preflight Checks (Tools vorhanden?)
#   2. Discord Channels provisionieren (provision_channels.py)
#   3. ops-n8n Docker-Container starten
#   4. Warten bis ops-n8n healthy
#   5. n8n Workflows importieren
#   6. Tailscale Funnel für Discord Interactions Endpoint konfigurieren
#   7. Finale Anweisungen ausgeben
#
# Voraussetzung:
#   - ~/.openclaw/.env enthält DISCORD_BOT_TOKEN, DISCORD_GUILD_ID, N8N_API_KEY
#   - tailscale is installed and authenticated on r2d2
#   - docker + docker compose v2 installed

set -euo pipefail

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die() {
    log_error "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Pfade (relativ zum Repo-Root ermitteln)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPS_DIR="$REPO_ROOT/ops"
N8N_DIR="$OPS_DIR/n8n"
BOT_DIR="$OPS_DIR/discord-bot"
ENV_FILE="$HOME/.openclaw/.env"

# ---------------------------------------------------------------------------
# Schritt 0: Env-Datei laden
# ---------------------------------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
    die "~/.openclaw/.env nicht gefunden. Bitte anlegen (siehe register-bot.md)."
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# ---------------------------------------------------------------------------
# Schritt 1: Preflight — benötigte Tools prüfen
# ---------------------------------------------------------------------------

log_info "=== Schritt 1: Preflight Checks ==="

check_cmd() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Tool nicht gefunden: $cmd${hint:+ — $hint}"
        return 1
    fi
    log_ok "$cmd gefunden: $(command -v "$cmd")"
}

preflight_ok=true
check_cmd python3                   "apt install python3"         || preflight_ok=false
check_cmd curl                      "apt install curl"            || preflight_ok=false
check_cmd docker                    "siehe docs/docker-setup.md"  || preflight_ok=false
check_cmd tailscale                 "apt install tailscale"       || preflight_ok=false

# docker compose v2 check
if ! docker compose version &>/dev/null; then
    log_error "docker compose v2 nicht verfügbar (docker compose version fehlgeschlagen)"
    preflight_ok=false
else
    log_ok "docker compose v2 verfügbar"
fi

# pip3 / requests check für provision_channels.py
if ! python3 -c "import requests" 2>/dev/null; then
    log_warn "Python requests nicht installiert. Installiere via pip3..."
    pip3 install --user requests || die "pip3 install requests fehlgeschlagen"
fi

if [[ "$preflight_ok" != "true" ]]; then
    die "Preflight fehlgeschlagen. Bitte fehlende Tools installieren und erneut versuchen."
fi

# Pflicht-Env-Vars prüfen
for var in DISCORD_BOT_TOKEN DISCORD_GUILD_ID N8N_API_KEY; do
    if [[ -z "${!var:-}" ]]; then
        die "Env-Var $var nicht gesetzt in $ENV_FILE. Bitte register-bot.md befolgen."
    fi
done
log_ok "Alle Pflicht-Env-Vars gesetzt."

# ---------------------------------------------------------------------------
# Schritt 2: Discord Channels provisionieren
# ---------------------------------------------------------------------------

log_info "=== Schritt 2: Discord Channels provisionieren ==="

PROJECTS="ai-portal,nathan-cockpit,openclaw-office,research-workflow-n8n,ai-review-pipeline"

python3 "$BOT_DIR/provision_channels.py" \
    --guild-id "$DISCORD_GUILD_ID" \
    --projects "$PROJECTS" \
    || {
        log_warn "provision_channels.py hat mit nicht-0 Exit beendet (fehlgeschlagene Channels)."
        log_warn "Bitte Logs prüfen und ggf. fehlende Channels manuell anlegen."
        # Fail-Open: setup.sh läuft weiter
    }

log_ok "Channel-Provisioning abgeschlossen."

# ---------------------------------------------------------------------------
# Schritt 3: ops-n8n Docker-Container starten
# ---------------------------------------------------------------------------

log_info "=== Schritt 3: ops-n8n Container starten ==="

if [[ ! -f "$N8N_DIR/docker-compose.yml" ]]; then
    die "docker-compose.yml nicht gefunden: $N8N_DIR/docker-compose.yml"
fi

docker compose -f "$N8N_DIR/docker-compose.yml" up -d
log_ok "ops-n8n Container gestartet."

# ---------------------------------------------------------------------------
# Schritt 4: Warten bis ops-n8n healthy
# ---------------------------------------------------------------------------

log_info "=== Schritt 4: Warten auf ops-n8n Health ==="

N8N_HEALTH_URL="http://127.0.0.1:5678/healthz"
MAX_WAIT=60
WAITED=0
INTERVAL=3

log_info "Prüfe $N8N_HEALTH_URL (max ${MAX_WAIT}s) ..."

until curl -sf "$N8N_HEALTH_URL" &>/dev/null; do
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        die "ops-n8n ist nach ${MAX_WAIT}s noch nicht healthy. Prüfe: docker logs ops-n8n"
    fi
    echo -n "."
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
done
echo ""
log_ok "ops-n8n ist healthy (nach ${WAITED}s)."

# ---------------------------------------------------------------------------
# Schritt 5: Workflows importieren
# ---------------------------------------------------------------------------

log_info "=== Schritt 5: n8n Workflows importieren ==="

if [[ ! -f "$N8N_DIR/scripts/setup-ops-n8n.sh" ]]; then
    die "setup-ops-n8n.sh nicht gefunden: $N8N_DIR/scripts/setup-ops-n8n.sh"
fi

bash "$N8N_DIR/scripts/setup-ops-n8n.sh" --import-only
log_ok "Workflows importiert."

# ---------------------------------------------------------------------------
# Schritt 6: Tailscale Funnel für Discord Interactions Endpoint
# ---------------------------------------------------------------------------

log_info "=== Schritt 6: Tailscale Funnel konfigurieren ==="

log_info "Aktiviere Tailscale Funnel für /webhook/discord-interaction → localhost:5678 ..."
sudo tailscale funnel --bg --set-path /webhook/discord-interaction localhost:5678
log_ok "Tailscale Funnel aktiv."

# Tailscale-Hostname ermitteln
TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "r2d2.tail4fc6dd.ts.net")
INTERACTIONS_URL="https://${TAILSCALE_HOSTNAME}/webhook/discord-interaction"

# ---------------------------------------------------------------------------
# Schritt 7: Finale Anweisungen
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo -e "${GREEN}Setup abgeschlossen!${NC}"
echo "============================================================"
echo ""
echo "Letzter manueller Schritt:"
echo ""
echo "  Discord Developer Portal → Deine Application → General Information"
echo "  → 'Interactions Endpoint URL' setzen auf:"
echo ""
echo -e "    ${YELLOW}${INTERACTIONS_URL}${NC}"
echo ""
echo "  Dann 'Save Changes' klicken."
echo "  Discord verifiziert den Endpoint sofort."
echo ""
echo "------------------------------------------------------------"
echo "Kanäle erstellt für Projekte: $PROJECTS"
echo "ops-n8n läuft auf:            http://127.0.0.1:5678"
echo "n8n UI erreichbar via:        http://127.0.0.1:5678 (lokal)"
echo "Tailscale Funnel URL:         $INTERACTIONS_URL"
echo "------------------------------------------------------------"
echo ""
log_ok "Fertig. Viel Spass mit dem Discord Bot!"
