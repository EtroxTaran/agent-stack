#!/usr/bin/env bash
# init-server.sh — Initial Discord-Server-Setup für Nathan-Ops Guild.
#
# Erstellt (idempotent):
#   - Category "AI Review"
#   - Pro Projekt: #ai-review-<project> + #ai-review-shadow-<project>
#   - #ai-review-alerts-global (cross-projekt Escalations)
#
# Projekt-Liste ist die Nathan-Ops Default-Liste. Für weitere Projekte:
# Entweder DISCORD_PROJECTS env-var überschreiben, oder provision_channels.py
# direkt mit eigenen --projects aufrufen.
#
# Required env (Secrets-SoT: ~/.config/ai-workflows/env, chmod 600):
#   DISCORD_BOT_TOKEN  — Bot-Token aus Discord Dev Portal
#   DISCORD_GUILD_ID   — Server-ID aus Discord Dev-Mode
#
# Optional:
#   DISCORD_PROJECTS    — CSV-Liste (Default: siehe PROJECTS_DEFAULT unten)
#   DRY_RUN             — "1" für Preview ohne API-Writes
#   AI_WORKFLOWS_ENV    — Pfad-Override (Default: ~/.config/ai-workflows/env)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PROVISION_PY="${SCRIPT_DIR}/provision_channels.py"
readonly ENV_FILE="${AI_WORKFLOWS_ENV:-${HOME}/.config/ai-workflows/env}"

readonly PROJECTS_DEFAULT="ai-portal,ai-review-pipeline,agent-stack,nathan-cockpit,openclaw-office,research-workflow-n8n"

die() { printf 'init-server: %s\n' "$*" >&2; exit 1; }

# --- Env laden ------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# --- Preflight ------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 nicht gefunden"
[[ -f "$PROVISION_PY" ]] || die "provision_channels.py fehlt: $PROVISION_PY"
python3 -c "import requests" 2>/dev/null || die "python requests fehlt — 'pip install --user requests' oder venv aktivieren"

: "${DISCORD_BOT_TOKEN:?DISCORD_BOT_TOKEN nicht gesetzt — siehe ops/discord-bot/register-bot.md}"
: "${DISCORD_GUILD_ID:?DISCORD_GUILD_ID nicht gesetzt — siehe ops/discord-bot/register-bot.md}"

readonly PROJECTS="${DISCORD_PROJECTS:-$PROJECTS_DEFAULT}"

# --- Provisioning ---------------------------------------------------------
echo ">>> Initial Discord-Setup startet"
echo "    Guild:    ${DISCORD_GUILD_ID}"
echo "    Projekte: ${PROJECTS}"
echo "    Modus:    $([[ "${DRY_RUN:-0}" == "1" ]] && echo 'DRY-RUN' || echo 'LIVE')"
echo ""

extra_args=()
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    extra_args+=("--dry-run")
fi

# Kategorie-Name ist „AI Review" per default, via Env überschreibbar
if [[ -n "${DISCORD_CATEGORY_NAME:-}" ]]; then
    extra_args+=("--category" "$DISCORD_CATEGORY_NAME")
fi

DISCORD_BOT_TOKEN="$DISCORD_BOT_TOKEN" \
python3 "$PROVISION_PY" \
    --guild-id "$DISCORD_GUILD_ID" \
    --projects "$PROJECTS" \
    "${extra_args[@]}"

echo ""
echo ">>> Fertig. Channel-IDs via Discord Dev-Mode → Rechtsklick → 'ID kopieren'."
echo "    Pro Projekt die ID in <projekt>/.ai-review/config.yaml → notifications.discord.channel_id eintragen."
