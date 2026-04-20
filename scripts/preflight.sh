#!/usr/bin/env bash
# scripts/preflight.sh — checkt Tools, Env-File, und warnt über fehlende OAuth-Blobs.
#
# Exit 0: alle Pflicht-Tools vorhanden (Warnungen ok).
# Exit 1: mindestens ein Pflicht-Tool fehlt ODER ~/.openclaw/.env fehlt.

set -euo pipefail

readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[31m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_DIM=$'\033[2m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MISSING=0
WARNINGS=0

_check_cmd() {
    # Prüft ein Binary und gibt Install-Hint aus wenn fehlt.
    local cmd="$1"
    local hint="$2"
    if command -v "${cmd}" >/dev/null 2>&1; then
        printf '  %s✓%s %-12s %s(%s)%s\n' "${C_GREEN}" "${C_RESET}" "${cmd}" "${C_DIM}" "$(command -v "${cmd}")" "${C_RESET}"
    else
        printf '  %s✗%s %-12s missing — install: %s\n' "${C_RED}" "${C_RESET}" "${cmd}" "${hint}" >&2
        MISSING=$((MISSING + 1))
    fi
}

_check_cmd_soft() {
    # Soft-Check: fehlt → Warnung, nicht Exit.
    local cmd="$1"
    local hint="$2"
    if command -v "${cmd}" >/dev/null 2>&1; then
        printf '  %s✓%s %-12s %s(%s)%s\n' "${C_GREEN}" "${C_RESET}" "${cmd}" "${C_DIM}" "$(command -v "${cmd}")" "${C_RESET}"
    else
        printf '  %s!%s %-12s missing (soft) — install: %s\n' "${C_YELLOW}" "${C_RESET}" "${cmd}" "${hint}"
        WARNINGS=$((WARNINGS + 1))
    fi
}

printf '%sChecking required tools...%s\n' "${C_DIM}" "${C_RESET}"
_check_cmd git        "apt install git | brew install git"
_check_cmd gh         "apt install gh | brew install gh"
_check_cmd node       "apt install nodejs | brew install node"
_check_cmd npx        "comes with node (npm install -g npm)"
_check_cmd python3    "apt install python3 | brew install python3"
_check_cmd yq         "snap install yq | brew install yq (v4+, mikefarah)"
_check_cmd jq         "apt install jq | brew install jq"

printf '\n%sChecking optional tools...%s\n' "${C_DIM}" "${C_RESET}"
_check_cmd_soft docker     "https://docs.docker.com/engine/install/"
_check_cmd_soft tailscale  "curl -fsSL https://tailscale.com/install.sh | sh"

# ---------------------------------------------------------------------------
# gh auth-Status
# ---------------------------------------------------------------------------
printf '\n%sChecking gh auth...%s\n' "${C_DIM}" "${C_RESET}"
if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
        printf '  %s✓%s gh is authenticated\n' "${C_GREEN}" "${C_RESET}"
    else
        printf '  %s!%s gh is not authenticated — run: gh auth login\n' "${C_YELLOW}" "${C_RESET}"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# ~/.openclaw/.env
# ---------------------------------------------------------------------------
printf '\n%sChecking env file...%s\n' "${C_DIM}" "${C_RESET}"
ENV_FILE="${HOME}/.openclaw/.env"
if [[ -f "${ENV_FILE}" ]]; then
    printf '  %s✓%s %s exists\n' "${C_GREEN}" "${C_RESET}" "${ENV_FILE}"
else
    printf '  %s✗%s %s is missing\n' "${C_RED}" "${C_RESET}" "${ENV_FILE}" >&2
    if [[ -f "${REPO_ROOT}/.env.example" ]]; then
        mkdir -p "${HOME}/.openclaw"
        cp "${REPO_ROOT}/.env.example" "${ENV_FILE}"
        printf '  %s→%s Copied .env.example → %s\n' "${C_YELLOW}" "${C_RESET}" "${ENV_FILE}" >&2
        printf '  %s→%s Fill in tokens, then re-run install.sh\n' "${C_YELLOW}" "${C_RESET}" >&2
    fi
    MISSING=$((MISSING + 1))
fi

# ---------------------------------------------------------------------------
# CLI-OAuth-Blobs (Warnungen, nicht Fehler)
# ---------------------------------------------------------------------------
printf '\n%sChecking CLI OAuth blobs...%s\n' "${C_DIM}" "${C_RESET}"
_check_oauth() {
    local cli="$1"
    local path="$2"
    local hint="$3"
    if [[ -f "${path}" ]]; then
        printf '  %s✓%s %-10s %s\n' "${C_GREEN}" "${C_RESET}" "${cli}" "${path}"
    else
        printf '  %s!%s %-10s missing — run: %s\n' "${C_YELLOW}" "${C_RESET}" "${cli}" "${hint}"
        WARNINGS=$((WARNINGS + 1))
    fi
}

_check_oauth "claude"  "${HOME}/.claude/.credentials.json"   "claude login"
_check_oauth "codex"   "${HOME}/.codex/auth.json"            "codex login"
_check_oauth "cursor"  "${HOME}/.cursor/cli-config.json"     "cursor-agent login"
_check_oauth "gemini"  "${HOME}/.gemini/oauth_creds.json"    "gemini auth"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
printf '\n%s─────────────────────────────────────────%s\n' "${C_DIM}" "${C_RESET}"
if [[ "${MISSING}" -gt 0 ]]; then
    printf '%s✗ preflight failed:%s %d required items missing, %d warnings\n' \
        "${C_RED}" "${C_RESET}" "${MISSING}" "${WARNINGS}" >&2
    exit 1
fi
printf '%s✓ preflight passed%s (%d warnings)\n' "${C_GREEN}" "${C_RESET}" "${WARNINGS}"
exit 0
