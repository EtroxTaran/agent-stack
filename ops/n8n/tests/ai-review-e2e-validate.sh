#!/usr/bin/env bash
# ai-review-e2e-validate.sh
#
# Durchläuft das gesamte AI-Review-Pipeline-System und validiert jede Komponente
# gegen den tatsächlichen Zustand (kein Memory, keine Annahmen). Pflicht-Suite
# nach jeder Infrastruktur-Änderung.
#
# Prüft:
#   1. n8n-Container lebt + healthz
#   2. 3 ai-review-Workflows aktiv (dispatcher, callback, escalation)
#   3. Callback-Workflow-Code im Repo enthält Hardening (webhookId,
#      Replay-Schutz, SPKI-Ed25519)
#   4. Unit-Tests callback-logic.test.js → 13/13 pass
#   5. Live-Probe lokal → 3/3 pass
#   6. Live-Probe public Funnel → 3/3 pass
#   7. Env-Variablen im Container (Bot-Token, Public-Key, GitHub-Token)
#   8. Tailscale-Funnel :443 mit Pfad-Passthrough
#   9. Dispatcher-Webhook E2E (sendet Test-Message nach Discord)
#  10. Escalation-Webhook E2E (sendet Alert nach Discord)
#  11. handle-button-action.yml auf ai-review-pipeline main
#  12. Self-hosted Runner online
#
# Usage:
#   ./ai-review-e2e-validate.sh
#   ./ai-review-e2e-validate.sh --skip-discord     # kein Test-Post nach Discord
#   ./ai-review-e2e-validate.sh --verbose          # alle Outputs
#
# Exit 0 = alle Checks grün; >0 = mindestens einer fehlgeschlagen.

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────
readonly N8N_HOST="${N8N_HOST:-127.0.0.1}"
readonly N8N_PORT="${N8N_PORT:-5678}"
readonly N8N_CONTAINER="${N8N_CONTAINER:-ai-portal-n8n-portal-1}"
readonly FUNNEL_URL="${FUNNEL_URL:-https://r2d2.tail4fc6dd.ts.net}"
readonly ALERTS_CHANNEL_ID="${DISCORD_ALERTS_CHANNEL_ID:-1495821862910038117}"
readonly AGENT_STACK_DIR="${AGENT_STACK_DIR:-${HOME}/projects/agent-stack}"
readonly AI_REVIEW_PIPELINE_DIR="${AI_REVIEW_PIPELINE_DIR:-${HOME}/projects/ai-review-pipeline}"

SKIP_DISCORD=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --skip-discord) SKIP_DISCORD=1 ;;
        --verbose|-v) VERBOSE=1 ;;
        --help|-h)
            sed -n '3,25p' "$0"
            exit 0
            ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILURES

pass() { printf '  \033[32m[PASS]\033[0m %s\n' "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*" >&2; FAIL_COUNT=$((FAIL_COUNT+1)); FAILURES+=("$*"); }
info() { [ "$VERBOSE" = "1" ] && printf '  [info] %s\n' "$*"; true; }
step() { printf '\n\033[1m[%s] %s\033[0m\n' "$1" "$2"; }

# ── 1. n8n-Container health ───────────────────────────────────────────────
step "1/12" "n8n container health"
if docker inspect -f '{{.State.Running}}' "$N8N_CONTAINER" 2>/dev/null | grep -q true; then
    uptime="$(docker ps --filter "name=$N8N_CONTAINER" --format '{{.Status}}')"
    pass "container $N8N_CONTAINER is running ($uptime)"
else
    fail "container $N8N_CONTAINER is NOT running"
fi

if curl -sf "http://${N8N_HOST}:${N8N_PORT}/healthz" >/dev/null; then
    pass "n8n healthz → ok"
else
    fail "n8n healthz unreachable at http://${N8N_HOST}:${N8N_PORT}/healthz"
fi

# ── 2. Workflows aktiv ───────────────────────────────────────────────────
step "2/12" "ai-review workflows active"
workflows_output="$(docker exec "$N8N_CONTAINER" n8n list:workflow 2>/dev/null | grep -E '^ai-review-(escalation|callback|dispatcher)' || true)"
for wid in ai-review-escalation ai-review-callback ai-review-dispatcher; do
    if echo "$workflows_output" | grep -q "^${wid}|"; then
        pass "workflow $wid listed"
    else
        fail "workflow $wid NOT listed"
    fi
done

# ── 3. Callback-Workflow Repo-Stand ist hardened ─────────────────────────
step "3/12" "callback workflow JSON has hardening"
callback_json="${AGENT_STACK_DIR}/ops/n8n/workflows/ai-review-callback.json"
if [ -f "$callback_json" ]; then
    if grep -q '"webhookId": "discord-interaction"' "$callback_json"; then
        pass "webhookId: discord-interaction gesetzt"
    else fail "webhookId fehlt in callback JSON"; fi

    if grep -q "MAX_TIMESTAMP_SKEW_SEC" "$callback_json"; then
        pass "Replay-Schutz MAX_TIMESTAMP_SKEW_SEC vorhanden"
    else fail "Replay-Schutz fehlt in callback JSON"; fi

    if grep -q "302a300506032b6570032100" "$callback_json"; then
        pass "SPKI-prefix Ed25519 crypto.verify"
    else fail "SPKI-prefix fehlt — crypto.verify-Code nicht deterministisch"; fi

    if grep -q '"rawBody": true' "$callback_json"; then
        pass "webhook rawBody:true (raw bytes aus \$binary)"
    else fail "rawBody:true fehlt in webhook-Node options"; fi
else
    fail "$callback_json nicht gefunden"
fi

# ── 4. Unit-Tests ────────────────────────────────────────────────────────
step "4/12" "callback-logic unit tests"
unit_test="${AGENT_STACK_DIR}/ops/n8n/tests/callback-logic.test.js"
if [ -f "$unit_test" ]; then
    test_out="$(node "$unit_test" 2>&1)"
    pass_line="$(echo "$test_out" | grep -E '[0-9]+/[0-9]+ tests passed' | tail -1)"
    if echo "$pass_line" | grep -qE '^([0-9]+)/\1 tests passed'; then
        pass "$pass_line"
    else
        fail "unit-tests failed: $pass_line"
        [ "$VERBOSE" = "1" ] && echo "$test_out"
    fi
else
    fail "unit test file not found: $unit_test"
fi

# ── 5. Live-Probe lokal ──────────────────────────────────────────────────
step "5/12" "live-probe localhost:${N8N_PORT}"
probe_script="${AGENT_STACK_DIR}/ops/n8n/tests/callback-live-probe.sh"
if [ -x "$probe_script" ]; then
    if BASE_URL="http://${N8N_HOST}:${N8N_PORT}" bash "$probe_script" >/tmp/probe-local.out 2>&1; then
        pass "lokale Webhook rejects bad requests korrekt (unsigned/bogus/replay)"
    else
        fail "live-probe lokal fehlgeschlagen"
        [ "$VERBOSE" = "1" ] && cat /tmp/probe-local.out
    fi
else
    fail "probe script nicht executable: $probe_script"
fi

# ── 6. Live-Probe public Funnel ──────────────────────────────────────────
step "6/12" "live-probe public Funnel ${FUNNEL_URL}"
if [ -x "$probe_script" ]; then
    if BASE_URL="$FUNNEL_URL" bash "$probe_script" >/tmp/probe-funnel.out 2>&1; then
        pass "Funnel Webhook rejects bad requests korrekt"
    else
        fail "live-probe Funnel fehlgeschlagen"
        [ "$VERBOSE" = "1" ] && cat /tmp/probe-funnel.out
    fi
fi

# ── 7. Env-Variablen ─────────────────────────────────────────────────────
step "7/12" "container environment variables"
env_out="$(docker exec "$N8N_CONTAINER" sh -c 'echo BOT=${#DISCORD_BOT_TOKEN} PUB=${#DISCORD_PUBLIC_KEY} TOK=${#GITHUB_TOKEN} REPO=$GITHUB_REPO TGT=$GITHUB_TARGET_REPO APP=$DISCORD_APPLICATION_ID')"
info "$env_out"

check_env() {
    local var="$1" op="$2" expected="$3" desc="$4"
    local val
    val="$(echo "$env_out" | grep -oE "${var}=[^ ]+" | cut -d= -f2)"
    case "$op" in
        ge) [ "${val:-0}" -ge "$expected" ] && pass "$desc ($val)" || fail "$desc (got $val, expected >= $expected)" ;;
        eq) [ "$val" = "$expected" ] && pass "$desc" || fail "$desc (got '$val', expected '$expected')" ;;
    esac
}

check_env BOT  ge 40 "DISCORD_BOT_TOKEN length"
check_env PUB  eq 64 "DISCORD_PUBLIC_KEY length (64 hex chars)"
check_env TOK  ge 40 "GITHUB_TOKEN length"
check_env REPO eq "EtroxTaran/ai-review-pipeline" "GITHUB_REPO set"
check_env TGT  eq "EtroxTaran/ai-portal" "GITHUB_TARGET_REPO set"

# ── 8. Tailscale-Funnel ──────────────────────────────────────────────────
step "8/12" "tailscale funnel routing"
funnel_out="$(tailscale funnel status 2>&1)"
if echo "$funnel_out" | grep -qE 'Funnel on'; then
    pass "funnel is ON"
else
    fail "funnel nicht aktiv"
fi

if echo "$funnel_out" | grep -q "/webhook/discord-interaction proxy http://localhost:${N8N_PORT}/webhook/discord-interaction"; then
    pass "Pfad-Passthrough /webhook/discord-interaction → :${N8N_PORT}"
else
    fail "Funnel-Pfad-Passthrough fehlt oder falsch"
fi

# ── 9. Dispatcher-Webhook E2E ────────────────────────────────────────────
step "9/12" "dispatcher webhook → Discord message"
if [ "$SKIP_DISCORD" = "1" ]; then
    info "skipped (--skip-discord)"
else
    disp_payload="$(cat <<EOF
{
  "channel_id": "${ALERTS_CHANNEL_ID}",
  "pr_number": 1999,
  "pr_url": "https://github.com/EtroxTaran/ai-portal/pull/1999",
  "pr_title": "E2E Validate: smoke test (automated)",
  "pr_author": "e2e-validator",
  "scores": {"code":7,"cursor":8,"security":9,"design":7,"ac":8},
  "consensus": "soft",
  "project": "ai-portal"
}
EOF
)"
    disp_resp="$(curl -sS -X POST "http://${N8N_HOST}:${N8N_PORT}/webhook/ai-review-dispatch" -H 'Content-Type: application/json' -d "$disp_payload" -w "\n%{http_code}")"
    disp_code="$(echo "$disp_resp" | tail -1)"
    disp_body="$(echo "$disp_resp" | head -n -1)"
    if [ "$disp_code" = "200" ] && echo "$disp_body" | grep -q '"ok":true'; then
        msg_id="$(echo "$disp_body" | grep -oE '"message_id":"[0-9]+"' | cut -d'"' -f4)"
        pass "dispatcher posted message (id=$msg_id)"
    else
        fail "dispatcher failed (HTTP $disp_code): $disp_body"
    fi
fi

# ── 10. Escalation-Webhook E2E ───────────────────────────────────────────
step "10/12" "escalation webhook → Discord alert"
if [ "$SKIP_DISCORD" = "1" ]; then
    info "skipped (--skip-discord)"
else
    esc_payload='{"project":"ai-portal","pr_number":1999,"reason":"e2e-validate smoke test","severity":"low"}'
    esc_resp="$(curl -sS -X POST "http://${N8N_HOST}:${N8N_PORT}/webhook/ai-review-escalation" -H 'Content-Type: application/json' -d "$esc_payload" -w "\n%{http_code}")"
    esc_code="$(echo "$esc_resp" | tail -1)"
    esc_body="$(echo "$esc_resp" | head -n -1)"
    if [ "$esc_code" = "200" ] && echo "$esc_body" | grep -q '"ok":true'; then
        pass "escalation webhook delivered"
    else
        fail "escalation failed (HTTP $esc_code): $esc_body"
    fi
fi

# ── 11. handle-button-action.yml auf main ────────────────────────────────
step "11/12" "handle-button-action.yml on ai-review-pipeline main"
hba_path="${AI_REVIEW_PIPELINE_DIR}/.github/workflows/handle-button-action.yml"
if [ -f "$hba_path" ]; then
    pass "handle-button-action.yml liegt lokal ($hba_path)"
    if grep -q 'workflow_dispatch' "$hba_path" && grep -q 'pr_number' "$hba_path" && grep -q 'action' "$hba_path"; then
        pass "workflow_dispatch + pr_number + action inputs vorhanden"
    else
        fail "handle-button-action.yml struktur unvollständig"
    fi
else
    fail "handle-button-action.yml NICHT gefunden — PR#7 nicht gemergt oder Repo nicht geklont"
fi

# Optional remote-Check — nur wenn gh CLI vorhanden
if command -v gh >/dev/null; then
    remote_check="$(gh api "repos/EtroxTaran/ai-review-pipeline/contents/.github/workflows/handle-button-action.yml?ref=main" --jq '.name // "MISSING"' 2>/dev/null || echo "MISSING")"
    if [ "$remote_check" = "handle-button-action.yml" ]; then
        pass "handle-button-action.yml exists on remote main"
    else
        fail "handle-button-action.yml nicht auf remote main"
    fi
fi

# ── 12. Self-hosted Runner online ────────────────────────────────────────
step "12/12" "self-hosted runner online"
if command -v gh >/dev/null; then
    runner_state="$(gh api "repos/EtroxTaran/ai-review-pipeline/actions/runners" --jq '.runners[] | select(.name | test("r2d2")) | .status' 2>/dev/null | head -1)"
    if [ "$runner_state" = "online" ]; then
        pass "runner r2d2 is online"
    else
        fail "runner nicht online (state='$runner_state')"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "========================================================================="
echo "  Result: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================================================="
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    echo "Failures:"
    for f in "${FAILURES[@]}"; do echo "  • $f"; done
    exit 1
fi

echo ""
echo "  ✅ AI-Review-Pipeline ist vollständig grün."
