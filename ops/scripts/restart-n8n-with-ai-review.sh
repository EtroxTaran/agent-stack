#!/usr/bin/env bash
# restart-n8n-with-ai-review.sh
#
# Startet/Recreated ai-portal-n8n Container mit dem AI-Review-Override,
# damit die Discord-Secrets aus ~/.config/ai-workflows/env verfügbar werden.
#
# Der bestehende ai-portal-n8n-portal-1 Container wird mit --force-recreate
# neu erstellt (nötig weil env_file nur bei create gelesen wird).

set -euo pipefail

readonly AI_PORTAL_COMPOSE="${AI_PORTAL_COMPOSE:-${HOME}/projects/ai-portal/docker-compose.yml}"
readonly AI_REVIEW_OVERRIDE="${AI_REVIEW_OVERRIDE:-${HOME}/projects/agent-stack/ops/compose/n8n-ai-review.override.yml}"
readonly AI_WORKFLOWS_ENV="${AI_WORKFLOWS_ENV:-${HOME}/.config/ai-workflows/env}"

die() { printf 'restart-n8n: %s\n' "$*" >&2; exit 1; }

[[ -f "$AI_PORTAL_COMPOSE" ]]   || die "ai-portal docker-compose nicht gefunden: $AI_PORTAL_COMPOSE"
[[ -f "$AI_REVIEW_OVERRIDE" ]]  || die "override fehlt: $AI_REVIEW_OVERRIDE"
[[ -f "$AI_WORKFLOWS_ENV" ]]    || die "env-file fehlt: $AI_WORKFLOWS_ENV (chmod 600 + DISCORD_BOT_TOKEN nötig)"

# chmod-Check: env-file muss 600 sein (Leak-Prevention)
env_mode="$(stat -c %a "$AI_WORKFLOWS_ENV" 2>/dev/null || stat -f %A "$AI_WORKFLOWS_ENV")"
if [[ "$env_mode" != "600" ]]; then
    printf 'WARN: %s hat mode %s, empfohlen 600\n' "$AI_WORKFLOWS_ENV" "$env_mode" >&2
fi

echo ">>> Recreating n8n-portal mit AI-Review-Override ..."
docker compose \
    -f "$AI_PORTAL_COMPOSE" \
    -f "$AI_REVIEW_OVERRIDE" \
    up -d --force-recreate n8n-portal

echo ""
echo ">>> Warte auf Container-Start ..."
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if curl -sf http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
        echo "healthz OK"
        break
    fi
    sleep 2
done

echo ""
echo ">>> Env-Verify (DISCORD_BOT_TOKEN present?):"
if docker exec ai-portal-n8n-portal-1 printenv DISCORD_BOT_TOKEN >/dev/null 2>&1; then
    echo "  ✅ DISCORD_BOT_TOKEN im Container sichtbar"
else
    die "DISCORD_BOT_TOKEN nicht im Container — env_file mount prüfen"
fi

echo ""
echo ">>> AI-Review Workflows aktiv?"
docker exec ai-portal-n8n-portal-1 n8n list:workflow 2>/dev/null | grep -E "AI-Review" || echo "WARN: keine AI-Review-Workflows gefunden"

echo ""
echo ">>> DONE. n8n-portal recreated. Webhook-Endpoints:"
echo "   POST http://127.0.0.1:5678/webhook/ai-review-dispatch"
echo "   POST http://127.0.0.1:5678/webhook/discord-interaction"
echo "   POST http://127.0.0.1:5678/webhook/ai-review-escalation"
