#!/usr/bin/env bash
# scripts/uninstall.sh — entfernt agent-stack Symlinks und restored optional aus Backup.
#
# Workflow:
#   1. Listet alle Symlinks, die dotbot angelegt hat, und entfernt sie
#   2. Sucht neuestes Backup unter ~/.config/agent-stack/backup-*
#   3. Fragt Nutzer, ob daraus restored werden soll
#
# MCP-Deregistrierung wird NICHT gemacht (kompliziert, pro CLI unterschiedlich;
# einfach zu lassen).

set -euo pipefail

readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
# shellcheck disable=SC2034  # reserved for future error-output styling (parität zu install.sh)
readonly C_RED=$'\033[31m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_DIM=$'\033[2m'

# Gleiche Liste wie in install.conf.yaml (die Targets der Symlinks).
SYMLINKS=(
    "${HOME}/.claude/CLAUDE.md"
    "${HOME}/.claude/settings.json"
    "${HOME}/.claude/hooks"
    "${HOME}/.claude/skills/code-review-expert"
    "${HOME}/.claude/skills/issue-pickup"
    "${HOME}/.claude/skills/pr-open"
    "${HOME}/.claude/skills/review-gate"
    "${HOME}/.cursor/AGENTS.md"
    "${HOME}/.cursor/rules/global.mdc"
    "${HOME}/.cursor/cli-config.json"
    "${HOME}/.cursor/skills/code-review-expert"
    "${HOME}/.cursor/skills/issue-pickup"
    "${HOME}/.cursor/skills/pr-open"
    "${HOME}/.cursor/skills/review-gate"
    "${HOME}/.gemini/GEMINI.md"
    "${HOME}/.gemini/settings.json"
    "${HOME}/.gemini/skills/code-review-expert"
    "${HOME}/.gemini/skills/issue-pickup"
    "${HOME}/.gemini/skills/pr-open"
    "${HOME}/.gemini/skills/review-gate"
    "${HOME}/.codex/AGENTS.md"
    "${HOME}/.codex/config.toml"
    "${HOME}/.codex/skills/code-review-expert"
    "${HOME}/.codex/skills/issue-pickup"
    "${HOME}/.codex/skills/pr-open"
    "${HOME}/.codex/skills/review-gate"
)

printf '%s%sagent-stack uninstall%s\n' "${C_BOLD}" "${C_YELLOW}" "${C_RESET}"
printf '%sThis removes symlinks created by install.sh. It does NOT touch real files.%s\n\n' \
    "${C_DIM}" "${C_RESET}"

# ---------------------------------------------------------------------------
# 1. Symlinks entfernen
# ---------------------------------------------------------------------------
REMOVED=0
for link in "${SYMLINKS[@]}"; do
    if [[ -L "${link}" ]]; then
        rm "${link}"
        printf '  %s✓%s removed symlink: %s\n' "${C_GREEN}" "${C_RESET}" "${link}"
        REMOVED=$((REMOVED + 1))
    elif [[ -e "${link}" ]]; then
        printf '  %s!%s not a symlink, skipped: %s\n' "${C_YELLOW}" "${C_RESET}" "${link}"
    fi
done

printf '\n  %s✓%s removed %d symlinks\n' "${C_GREEN}" "${C_RESET}" "${REMOVED}"

# ---------------------------------------------------------------------------
# 2. Neuestes Backup finden und optional restoren
# ---------------------------------------------------------------------------
BACKUP_ROOT="${HOME}/.config/agent-stack"
if [[ ! -d "${BACKUP_ROOT}" ]]; then
    printf '\n%sNo backup directory found at %s%s\n' "${C_DIM}" "${BACKUP_ROOT}" "${C_RESET}"
    exit 0
fi

# Alle Backup-Dirs (sortiert, neueste zuletzt)
mapfile -t BACKUPS < <(find "${BACKUP_ROOT}" -maxdepth 1 -type d -name 'backup-*' | sort)
if [[ "${#BACKUPS[@]}" -eq 0 ]]; then
    printf '\n%sNo backups found.%s\n' "${C_DIM}" "${C_RESET}"
    exit 0
fi

LATEST="${BACKUPS[-1]}"
printf '\n%sLatest backup:%s %s\n' "${C_DIM}" "${C_RESET}" "${LATEST}"
printf 'Restore from this backup? [y/N] '
read -r answer
if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
    printf '%sSkipping restore.%s\n' "${C_DIM}" "${C_RESET}"
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Restore: alle files aus Backup-Dir zurück in $HOME bewegen
# ---------------------------------------------------------------------------
RESTORED=0
while IFS= read -r -d '' src; do
    rel_path="${src#"${LATEST}/"}"
    if [[ "${rel_path}" == "RESTORE.md" ]]; then
        continue
    fi
    dest="${HOME}/${rel_path}"
    dest_dir="$(dirname "${dest}")"

    if [[ -e "${dest}" || -L "${dest}" ]]; then
        printf '  %s!%s skip (target exists): %s\n' "${C_YELLOW}" "${C_RESET}" "${dest}"
        continue
    fi

    mkdir -p "${dest_dir}"
    mv "${src}" "${dest}"
    printf '  %s✓%s restored: %s\n' "${C_GREEN}" "${C_RESET}" "${dest}"
    RESTORED=$((RESTORED + 1))
done < <(find "${LATEST}" -type f -not -name 'RESTORE.md' -print0)

printf '\n  %s✓%s restored %d files\n' "${C_GREEN}" "${C_RESET}" "${RESTORED}"
printf '%sYou may now delete the backup dir if satisfied:%s rm -rf %s\n' \
    "${C_DIM}" "${C_RESET}" "${LATEST}"
