#!/usr/bin/env bash
# scripts/ai-init-project.sh — bootstrap agent-stack-Konventionen in einem Projekt.
#
# Kopiert (kein symlink, damit Projekt self-contained und committable ist):
#   · templates/ISSUE_TEMPLATE/*.yml  → <project>/.github/ISSUE_TEMPLATE/
#   · templates/PULL_REQUEST_TEMPLATE.md → <project>/.github/
#   · templates/ai-review-config.yaml → <project>/.ai-review/config.yaml
# Erzeugt:
#   · <project>/AGENTS.md (dünner Wrapper, inklu. Include-Hint auf globale AGENTS.md)
#
# Usage: ai-init-project.sh <project-dir>

set -euo pipefail

readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_DIM=$'\033[2m'

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <project-dir>\n' "$(basename "$0")" >&2
    exit 2
fi

PROJECT_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ ! -d "${PROJECT_DIR}" ]]; then
    printf 'Error: project-dir does not exist: %s\n' "${PROJECT_DIR}" >&2
    exit 1
fi

PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"
PROJECT_NAME="$(basename "${PROJECT_DIR}")"

printf '%s%sBootstrapping project:%s %s\n' "${C_BOLD}" "${C_GREEN}" "${C_RESET}" "${PROJECT_NAME}"
printf '%sPath:%s %s\n\n' "${C_DIM}" "${C_RESET}" "${PROJECT_DIR}"

# ---------------------------------------------------------------------------
# Helper: Copy mit -n (no clobber), Report
# ---------------------------------------------------------------------------
_copy_if_missing() {
    local src="$1"
    local dest="$2"
    local dest_dir
    dest_dir="$(dirname "${dest}")"

    if [[ -e "${dest}" ]]; then
        printf '  %s·%s exists (skip): %s\n' "${C_DIM}" "${C_RESET}" "${dest#"${PROJECT_DIR}/"}"
        return 0
    fi
    if [[ ! -e "${src}" ]]; then
        printf '  %s!%s src missing (skip): %s\n' "${C_YELLOW}" "${C_RESET}" "${src}"
        return 0
    fi

    mkdir -p "${dest_dir}"
    cp "${src}" "${dest}"
    printf '  %s✓%s copied:  %s\n' "${C_GREEN}" "${C_RESET}" "${dest#"${PROJECT_DIR}/"}"
}

_copy_dir_contents() {
    # Kopiert alle files aus src_dir nach dest_dir (non-recursive).
    local src_dir="$1"
    local dest_dir="$2"
    if [[ ! -d "${src_dir}" ]]; then
        printf '  %s!%s template dir missing: %s\n' "${C_YELLOW}" "${C_RESET}" "${src_dir}"
        return 0
    fi
    mkdir -p "${dest_dir}"
    local src
    # Verwende nullglob, damit leere dirs nicht als "/*" interpretiert werden
    shopt -s nullglob
    for src in "${src_dir}"/*; do
        if [[ -f "${src}" ]]; then
            _copy_if_missing "${src}" "${dest_dir}/$(basename "${src}")"
        fi
    done
    shopt -u nullglob
}

# ---------------------------------------------------------------------------
# 1. Issue-Templates
# ---------------------------------------------------------------------------
printf '%s1. Issue templates%s\n' "${C_DIM}" "${C_RESET}"
_copy_dir_contents "${REPO_ROOT}/templates/ISSUE_TEMPLATE" "${PROJECT_DIR}/.github/ISSUE_TEMPLATE"

# ---------------------------------------------------------------------------
# 2. PR-Template
# ---------------------------------------------------------------------------
printf '\n%s2. PR template%s\n' "${C_DIM}" "${C_RESET}"
_copy_if_missing \
    "${REPO_ROOT}/templates/PULL_REQUEST_TEMPLATE.md" \
    "${PROJECT_DIR}/.github/PULL_REQUEST_TEMPLATE.md"

# ---------------------------------------------------------------------------
# 3. .ai-review/config.yaml
# ---------------------------------------------------------------------------
printf '\n%s3. .ai-review config%s\n' "${C_DIM}" "${C_RESET}"
_copy_if_missing \
    "${REPO_ROOT}/templates/ai-review-config.yaml" \
    "${PROJECT_DIR}/.ai-review/config.yaml"

# ---------------------------------------------------------------------------
# 4. AGENTS.md Wrapper
# ---------------------------------------------------------------------------
printf '\n%s4. AGENTS.md project wrapper%s\n' "${C_DIM}" "${C_RESET}"
AGENTS_FILE="${PROJECT_DIR}/AGENTS.md"
if [[ -e "${AGENTS_FILE}" ]]; then
    printf '  %s·%s AGENTS.md already exists (skip)\n' "${C_DIM}" "${C_RESET}"
else
    cat > "${AGENTS_FILE}" <<WRAPPER_EOF
# AGENTS.md — ${PROJECT_NAME}

> Global engineering rules live in ~/agent-stack/AGENTS.md and are loaded
> automatically by Claude Code (via ~/.claude/CLAUDE.md), Codex CLI, Cursor CLI,
> and Gemini CLI through their respective symlinks. This file only documents
> project-specific additions.

## Project scope

Describe the project's purpose in 2-3 sentences here.

## Project-specific rules

- (Add project-specific coding conventions, infra quirks, etc.)

## Tool stack (project-specific)

- (e.g., Next.js 15, Prisma 6, shadcn/ui v2)

## Contacts

- Owner: (your name)
WRAPPER_EOF
    printf '  %s✓%s wrote: AGENTS.md\n' "${C_GREEN}" "${C_RESET}"
fi

# ---------------------------------------------------------------------------
# 5. Final checklist
# ---------------------------------------------------------------------------
printf '\n%s%s✓ project bootstrap complete%s\n\n' "${C_BOLD}" "${C_GREEN}" "${C_RESET}"
printf '%sManual follow-ups (not automated on purpose):%s\n' "${C_BOLD}" "${C_RESET}"
cat <<CHECKLIST
  1. Set GitHub Secrets for this repo:
       gh secret set DISCORD_CHANNEL_ID --body "<channel-id>"
       gh secret set DISCORD_BOT_TOKEN  --body "\$(grep DISCORD_BOT_TOKEN  ~/.openclaw/.env | cut -d= -f2)"
       gh secret set GITHUB_PAT         --body "\$(grep GITHUB_TOKEN       ~/.openclaw/.env | cut -d= -f2)"

  2. Configure branch-protection on default branch:
       · Require PRs to merge
       · Require status checks: ai-review/consensus (or ai-review-v2/consensus)
       · Require branches up-to-date

  3. Review & customise:
       · AGENTS.md (project-specific rules)
       · .ai-review/config.yaml (notification channel, reviewer settings)

  4. Commit the bootstrap:
       git add .github/ .ai-review/ AGENTS.md
       git commit -m "chore: bootstrap agent-stack conventions"
CHECKLIST
