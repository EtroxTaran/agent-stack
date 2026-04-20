#!/usr/bin/env bash
# agent-stack — Bootstrap Entrypoint
#
# Idempotent, safe to re-run. Läuft durch alle Bootstrap-Phasen:
#   1. preflight  — prüft Tools und Credentials
#   2. backup     — bewegt reale Config-Files beiseite
#   3. dotbot     — legt alle Symlinks an
#   4. mcp        — registriert MCP-Server pro CLI
#   5. gh-ext     — installiert ai-review gh extension (optional)
#   5b. ai-review-pipeline  — installiert pip-Paket (nur mit --with-ai-review)
#   6. verify     — Post-Install Sanity-Check
#
# Usage: ./install.sh [--with-ai-review] [--help]

set -euo pipefail

# ----------------------------------------------------------------------------
# Farbcodes (ANSI)
# ----------------------------------------------------------------------------
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_DIM=$'\033[2m'
readonly C_RED=$'\033[31m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_BLUE=$'\033[34m'
readonly C_CYAN=$'\033[36m'

# ----------------------------------------------------------------------------
# Helper
# ----------------------------------------------------------------------------
_section() {
    # Druckt einen Step-Header mit Farbe
    local step_num="$1"
    local step_name="$2"
    printf '\n%s%s╭─ Step %s: %s %s\n' "${C_BOLD}" "${C_BLUE}" "${step_num}" "${step_name}" "${C_RESET}"
    printf '%s╰─────────────────────────────────────────%s\n' "${C_BLUE}" "${C_RESET}"
}

_ok() {
    printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"
}

_warn() {
    printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"
}

_err() {
    printf '  %s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1" >&2
}

# Fehler-Trap: sagt klar welcher Step versagte und wie zu fixen
_on_error() {
    local exit_code="$?"
    local line_no="$1"
    local cmd="$2"
    printf '\n%s%s✗ INSTALL FAILED%s\n' "${C_BOLD}" "${C_RED}" "${C_RESET}" >&2
    printf '%s  Exit code:%s %d\n' "${C_DIM}" "${C_RESET}" "${exit_code}" >&2
    printf '%s  Line:     %s %d\n' "${C_DIM}" "${C_RESET}" "${line_no}" >&2
    printf '%s  Command:  %s %s\n' "${C_DIM}" "${C_RESET}" "${cmd}" >&2
    printf '%s  Current step:%s %s\n' "${C_DIM}" "${C_RESET}" "${CURRENT_STEP:-unknown}" >&2
    printf '\n  %sFix hints:%s\n' "${C_YELLOW}" "${C_RESET}" >&2
    case "${CURRENT_STEP:-}" in
        preflight)
            printf '    Install missing binaries per hints above, then re-run.\n' >&2
            ;;
        backup)
            printf '    Check permissions of ~/.config/agent-stack/ — ensure writable.\n' >&2
            ;;
        dotbot)
            printf '    Inspect install.conf.yaml syntax (yq eval install.conf.yaml).\n' >&2
            printf '    Remove conflicting files or run scripts/uninstall.sh to reset.\n' >&2
            ;;
        mcp)
            printf '    Verify MCP CLI subcommands: claude mcp list · gemini --version\n' >&2
            printf '    Check ~/.openclaw/.env has required API keys.\n' >&2
            ;;
        verify)
            printf '    Run scripts/verify.sh directly for detailed report.\n' >&2
            ;;
        ai-review-pipeline)
            printf '    Run scripts/install-ai-review-pipeline.sh directly for detailed output.\n' >&2
            printf '    Ensure pip/pip3 is installed and ~/projects/ai-review-pipeline exists (dev fallback).\n' >&2
            ;;
        *)
            printf '    Re-run with: bash -x ./install.sh  (for verbose trace)\n' >&2
            ;;
    esac
    exit "${exit_code}"
}
trap '_on_error "${LINENO}" "${BASH_COMMAND}"' ERR

# ----------------------------------------------------------------------------
# Argument Parsing
# ----------------------------------------------------------------------------
WITH_AI_REVIEW=false

_usage() {
    printf 'Usage: %s [OPTIONS]\n\n' "$(basename "$0")"
    printf 'Bootstrap agent-stack: symlinks, MCP-Server, gh extensions, optional integrations.\n\n'
    printf 'Options:\n'
    printf '  --with-ai-review   Installiert ai-review-pipeline als pip-Paket nach dem\n'
    printf '                     gh-Extension-Schritt. Versucht zuerst PyPI-Install;\n'
    printf '                     Fallback auf ~/projects/ai-review-pipeline (Dev-Repo).\n'
    printf '                     Smoke-test: ai-review --version muss Exit 0 liefern.\n'
    printf '  --help, -h         Zeigt diese Hilfe an.\n'
    exit 0
}

for arg in "$@"; do
    case "${arg}" in
        --with-ai-review)
            WITH_AI_REVIEW=true
            ;;
        --help|-h)
            _usage
            ;;
        *)
            printf 'Unknown option: %s\n' "${arg}" >&2
            printf 'Run with --help for usage.\n' >&2
            exit 2
            ;;
    esac
done

# ----------------------------------------------------------------------------
# Working dir == repo root
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

printf '%s%s┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\n' "${C_BOLD}" "${C_CYAN}"
printf '┃  agent-stack bootstrap                   ┃\n'
printf '┃  %sidempotent · safe to re-run%s%s           ┃\n' "${C_DIM}" "${C_RESET}" "${C_BOLD}${C_CYAN}"
printf '┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛%s\n' "${C_RESET}"
printf '%sRepo:%s %s\n' "${C_DIM}" "${C_RESET}" "${SCRIPT_DIR}"
if [[ "${WITH_AI_REVIEW}" == "true" ]]; then
    printf '%sMode:%s --with-ai-review (ai-review-pipeline pip-Install aktiviert)\n' "${C_DIM}" "${C_RESET}"
fi

# ----------------------------------------------------------------------------
# 1. Preflight
# ----------------------------------------------------------------------------
CURRENT_STEP="preflight"
_section "1" "Preflight — Tool & Credential Check"
bash "${SCRIPT_DIR}/scripts/preflight.sh"
_ok "preflight passed"

# ----------------------------------------------------------------------------
# 2. Backup existing real files
# ----------------------------------------------------------------------------
CURRENT_STEP="backup"
_section "2" "Backup — Move real config files aside"
bash "${SCRIPT_DIR}/scripts/backup-existing.sh"
_ok "backup complete"

# ----------------------------------------------------------------------------
# 3. dotbot — create symlinks per install.conf.yaml
# ----------------------------------------------------------------------------
CURRENT_STEP="dotbot"
_section "3" "Dotbot — Create symlinks"
if [[ ! -x "${SCRIPT_DIR}/dotbot/bin/dotbot" ]]; then
    _err "dotbot binary not found at ${SCRIPT_DIR}/dotbot/bin/dotbot"
    _err "Did you run: git submodule update --init --recursive ?"
    exit 1
fi
"${SCRIPT_DIR}/dotbot/bin/dotbot" -c "${SCRIPT_DIR}/install.conf.yaml"
_ok "symlinks created"

# ----------------------------------------------------------------------------
# 4. Register MCP servers per CLI
# ----------------------------------------------------------------------------
CURRENT_STEP="mcp"
_section "4" "MCP — Register servers across all CLIs"

# ~/.openclaw/.env sourcen (Tokens wie GITHUB_PERSONAL_ACCESS_TOKEN)
if [[ -f "${HOME}/.openclaw/.env" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "${HOME}/.openclaw/.env"
    set +a
    _ok "sourced ~/.openclaw/.env"
else
    # shellcheck disable=SC2088  # tilde ist hier nur display-text, nicht path-expansion
    _warn "~/.openclaw/.env not found — MCP registration may fail for some servers"
fi

if [[ -x "${SCRIPT_DIR}/mcp/register.sh" ]]; then
    bash "${SCRIPT_DIR}/mcp/register.sh"
    _ok "MCP servers registered"
else
    _warn "mcp/register.sh not found or not executable — skipping"
fi

# ----------------------------------------------------------------------------
# 5. Install gh-ai-review extension (optional, failure non-fatal)
# ----------------------------------------------------------------------------
CURRENT_STEP="gh-ext"
_section "5" "gh extension — ai-review (optional)"
if command -v gh >/dev/null 2>&1; then
    if gh extension list 2>/dev/null | grep -q "EtroxTaran/gh-ai-review"; then
        _ok "gh-ai-review already installed"
    else
        if gh extension install EtroxTaran/gh-ai-review 2>/dev/null; then
            _ok "gh-ai-review installed"
        else
            _warn "gh-ai-review install failed (repo may not exist yet) — continuing"
        fi
    fi
else
    _warn "gh CLI not available — skipping extension install"
fi

# ----------------------------------------------------------------------------
# 5b. Install ai-review-pipeline pip package (optional, nur mit --with-ai-review)
# ----------------------------------------------------------------------------
CURRENT_STEP="ai-review-pipeline"
if [[ "${WITH_AI_REVIEW}" == "true" ]]; then
    _section "5b" "ai-review-pipeline — pip install (optional)"
    bash "${SCRIPT_DIR}/scripts/install-ai-review-pipeline.sh"
    _ok "ai-review-pipeline installed"
fi

# ----------------------------------------------------------------------------
# 6. Verify
# ----------------------------------------------------------------------------
CURRENT_STEP="verify"
_section "6" "Verify — Post-install sanity"
bash "${SCRIPT_DIR}/scripts/verify.sh"

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
printf '\n%s%s✓ agent-stack bootstrap complete%s\n' "${C_BOLD}" "${C_GREEN}" "${C_RESET}"
printf '%sNext:%s\n' "${C_DIM}" "${C_RESET}"
printf '  · Re-run this script anytime; it is idempotent.\n'
printf '  · Bootstrap a project:  scripts/ai-init-project.sh <path>\n'
printf '  · Restore from backup:  scripts/uninstall.sh\n'
