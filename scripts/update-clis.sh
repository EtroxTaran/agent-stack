#!/usr/bin/env bash
# update-clis.sh — Täglicher Auto-Updater für die vier CLIs.
#
# Läuft per Cron um 04:00. Aktualisiert Claude Code, Cursor Agent, Gemini CLI, Codex CLI
# und triggert am Ende den Config-Audit. Sendet einen Discord-Report nur wenn sich was
# geändert hat oder ein Update fehlschlug.
#
# Usage:
#   update-clis.sh             # Echter Lauf
#   update-clis.sh --dry-run   # Zeigt was passieren würde, ohne Änderungen
#   update-clis.sh --no-notify # Kein Discord-Ping (z.B. für interaktives Debugging)
#   update-clis.sh --verbose   # Volle Ausgabe auf stderr
#
# Exit-Code:
#   0  alles ok (keine Änderungen oder alle Updates erfolgreich)
#   1  mindestens ein Update fehlgeschlagen
#   2  Setup-Fehler (fehlendes jq/npm/Scripts)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${HOME}/.openclaw/logs"
LOG_FILE="${LOG_DIR}/cli-updates.log"
AI_WORKFLOWS_ENV="${HOME}/.config/ai-workflows/env"

DRY_RUN=false
NOTIFY=true
VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --no-notify) NOTIFY=false ;;
        --verbose) VERBOSE=true ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    esac
done

mkdir -p "$LOG_DIR"

_log() {
    local level="$1"; shift
    local msg="$*"
    printf '[%s] [%s] %s\n' "$(date -Is)" "$level" "$msg" | tee -a "$LOG_FILE"
}

_verbose() {
    $VERBOSE && _log DEBUG "$@" || echo "[DEBUG] $*" >>"$LOG_FILE"
}

# ---- Preflight ----
for tool in jq npm curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        _log ERROR "Fehlt: $tool — kann nicht laufen."
        exit 2
    fi
done

# ---- Version-Snapshot VORHER ----
BEFORE_JSON=$("${REPO_ROOT}/scripts/versions.sh" --json)
_verbose "Vorher: ${BEFORE_JSON}"

_before_version() {
    local cli="$1"
    jq -r ".${cli}.version" <<<"$BEFORE_JSON"
}

# ---- Update-Funktionen (jede trappt eigene Fehler, läuft weiter) ----
declare -A RESULTS     # RESULTS[cli]=ok|failed|skipped
declare -A NEW_VERSION

_run_update() {
    local cli="$1"
    shift
    local cmd=("$@")
    _log INFO "Update ${cli}: ${cmd[*]}"
    if $DRY_RUN; then
        _log INFO "  [dry-run] würde ausführen: ${cmd[*]}"
        RESULTS[$cli]="skipped"
        return 0
    fi
    if "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
        RESULTS[$cli]="ok"
    else
        local rc=$?
        _log ERROR "${cli} update exit=${rc}"
        RESULTS[$cli]="failed"
    fi
}

# Claude Code: `claude update` — native updater, behält vorherige Version in versions/-Dir
_update_claude() {
    _run_update claude claude update
}

# Cursor Agent: `cursor-agent update`
_update_cursor() {
    _run_update cursor cursor-agent update
}

# Gemini CLI: npm global
_update_gemini() {
    _run_update gemini npm install -g @google/gemini-cli@latest --silent
}

# Codex CLI: npm global
_update_codex() {
    _run_update codex npm install -g @openai/codex@latest --silent
}

_update_claude
_update_cursor
_update_gemini
_update_codex

# ---- Version-Snapshot NACHHER ----
AFTER_JSON=$("${REPO_ROOT}/scripts/versions.sh" --json)
_verbose "Nachher: ${AFTER_JSON}"

_after_version() {
    local cli="$1"
    jq -r ".${cli}.version" <<<"$AFTER_JSON"
}

# ---- Sanity-Check: jede CLI muss nach Update startbar sein ----
SANITY_FAILED=()
for cli in claude cursor gemini codex; do
    status=$(jq -r ".${cli}.status" <<<"$AFTER_JSON")
    if [[ "$status" != "ok" ]]; then
        SANITY_FAILED+=("$cli")
        RESULTS[$cli]="failed"
        _log ERROR "Sanity-Check: ${cli} --version liefert 'missing'"
    fi
done

# ---- Change-Report bauen ----
CHANGES=()
for cli in claude cursor gemini codex; do
    before=$(_before_version "$cli")
    after=$(_after_version "$cli")
    result="${RESULTS[$cli]:-unknown}"
    if [[ "$before" != "$after" && "$result" == "ok" ]]; then
        CHANGES+=("✓ ${cli}: ${before} → ${after}")
    elif [[ "$result" == "failed" ]]; then
        CHANGES+=("✗ ${cli}: update FAILED (war ${before})")
    fi
done

# ---- Modell-Registry aktualisieren ----
MODEL_CHECK_SCRIPT="${HOME}/.openclaw/workspace/scripts/model-version-check.py"
MODEL_CHECK_OUTPUT=""
if $DRY_RUN; then
    _log INFO "Model-Registry-Check übersprungen (dry-run)"
elif [[ -x "$MODEL_CHECK_SCRIPT" ]] || [[ -f "$MODEL_CHECK_SCRIPT" ]]; then
    MODEL_CHECK_OUTPUT=$(python3 "$MODEL_CHECK_SCRIPT" --apply 2>&1 || true)
    _log INFO "Model-Registry-Check fertig"
    printf '%s\n' "$MODEL_CHECK_OUTPUT" >>"$LOG_FILE"
else
    _log WARN "model-version-check.py fehlt — skip Registry-Refresh"
fi

# ---- Audit triggern ----
AUDIT_OUTPUT=""
AUDIT_EXIT=0
if $DRY_RUN; then
    _log INFO "Audit übersprungen (dry-run)"
else
    AUDIT_OUTPUT=$("${REPO_ROOT}/scripts/audit-cli-settings.sh" --release-notes 2>&1) || AUDIT_EXIT=$?
    _log INFO "Audit exit=${AUDIT_EXIT}"
    printf '%s\n' "$AUDIT_OUTPUT" >>"$LOG_FILE"
fi

# ---- Discord-Notify (nur wenn was zu sagen ist) ----
_notify_discord() {
    local msg="$1"
    if ! $NOTIFY; then
        _log INFO "Notification übersprungen (--no-notify)"
        return 0
    fi
    if [[ ! -f "$AI_WORKFLOWS_ENV" ]]; then
        _log WARN "Kein ${AI_WORKFLOWS_ENV} — skip Discord-Notify"
        return 0
    fi
    # shellcheck disable=SC1090
    local token channel
    token=$(grep -E '^DISCORD_BOT_TOKEN=' "$AI_WORKFLOWS_ENV" | cut -d= -f2- | tr -d '"')
    channel=$(grep -E '^DISCORD_ALERTS_CHANNEL_ID=' "$AI_WORKFLOWS_ENV" | cut -d= -f2- | tr -d '"')
    if [[ -z "$token" || -z "$channel" ]]; then
        _log WARN "DISCORD_BOT_TOKEN/CHANNEL_ID leer — skip Discord-Notify"
        return 0
    fi
    # Discord content limit = 2000 Zeichen
    local payload
    payload=$(jq -n --arg c "$(printf '%s' "$msg" | head -c 1900)" '{content: $c}')
    local http_code
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
        -X POST "https://discord.com/api/v10/channels/${channel}/messages" \
        -H "Authorization: Bot ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload") || true
    if [[ "$http_code" =~ ^2 ]]; then
        _log INFO "Discord: HTTP ${http_code}"
    else
        _log WARN "Discord-Notify fehlgeschlagen: HTTP ${http_code}"
    fi
}

# ---- Summary ----
HAS_CHANGES=$([[ ${#CHANGES[@]} -gt 0 ]] && echo true || echo false)
HAS_FAILURES=false
for cli in claude cursor gemini codex; do
    [[ "${RESULTS[$cli]:-}" == "failed" ]] && HAS_FAILURES=true
done

SUMMARY="**CLI Update-Report** ($(date +%Y-%m-%d))"$'\n'
if $DRY_RUN; then
    SUMMARY+=$'\n'"_DRY-RUN — keine Änderungen vorgenommen_"$'\n'
fi
if $HAS_CHANGES; then
    SUMMARY+=$'\n'"Änderungen:"$'\n'
    for c in "${CHANGES[@]}"; do SUMMARY+="  $c"$'\n'; done
else
    SUMMARY+=$'\n'"Keine Versions-Änderungen."$'\n'
fi
if [[ -n "$MODEL_CHECK_OUTPUT" ]] && echo "$MODEL_CHECK_OUTPUT" | grep -qE "UPDATE|🆙"; then
    # Nur bei tatsächlichen Updates in den Report aufnehmen
    SUMMARY+=$'\n'"Model-Registry:"$'\n'
    SUMMARY+="$(echo "$MODEL_CHECK_OUTPUT" | grep -E "UPDATE|🆙" | head -5)"$'\n'
fi
if [[ $AUDIT_EXIT -ne 0 && -n "$AUDIT_OUTPUT" ]]; then
    SUMMARY+=$'\n'"Audit:"$'\n'"$AUDIT_OUTPUT"$'\n'
elif ! $DRY_RUN; then
    SUMMARY+=$'\n'"Audit: ✓ Keine Drift."$'\n'
fi

printf '%s\n' "$SUMMARY"
printf '%s\n' "$SUMMARY" >>"$LOG_FILE"

# Notify nur bei Änderungen, Failures oder Audit-Drift
if $HAS_CHANGES || $HAS_FAILURES || [[ $AUDIT_EXIT -ne 0 ]]; then
    _notify_discord "$SUMMARY"
fi

$HAS_FAILURES && exit 1 || exit 0
