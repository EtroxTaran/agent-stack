#!/usr/bin/env bash
# scripts/backup-existing.sh — bewegt reale (nicht-symlink) Config-Files nach Backup-Dir.
#
# Idempotent: bei Re-Run sind alle targets bereits Symlinks → nichts zu tun.
# Backup-Dir: ~/.config/agent-stack/backup-<timestamp>/
#
# Exit 0 immer (Backup ist best-effort, keine kritischen Fehler erwartet).

set -euo pipefail

readonly C_RESET=$'\033[0m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_DIM=$'\033[2m'

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/.config/agent-stack/backup-${TS}"

# Zu sichernde Pfade (relativ zu $HOME). Nur reale Files, keine Symlinks.
BACKUP_TARGETS=(
    ".claude/CLAUDE.md"
    ".claude/settings.json"
    ".cursor/AGENTS.md"
    ".cursor/rules/global.mdc"
    ".cursor/cli-config.json"
    ".gemini/GEMINI.md"
    ".gemini/settings.json"
    ".codex/AGENTS.md"
    ".codex/config.toml"
)

MOVED_COUNT=0
SKIPPED_COUNT=0

# Helper: Move nur wenn reales File, nicht Symlink, nicht leer.
_maybe_backup() {
    local rel_path="$1"
    local src="${HOME}/${rel_path}"
    local dest="${BACKUP_DIR}/${rel_path}"
    local dest_dir
    dest_dir="$(dirname "${dest}")"

    if [[ ! -e "${src}" ]]; then
        # Existiert gar nicht — nichts zu tun
        printf '  %s·%s %-40s (not present)\n' "${C_DIM}" "${C_RESET}" "${rel_path}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 0
    fi

    if [[ -L "${src}" ]]; then
        # Bereits Symlink — skip (idempotent path)
        printf '  %s·%s %-40s (already symlink)\n' "${C_DIM}" "${C_RESET}" "${rel_path}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 0
    fi

    # Reales File → in Backup-Dir bewegen
    mkdir -p "${dest_dir}"
    mv "${src}" "${dest}"
    printf '  %s→%s %-40s moved to backup\n' "${C_YELLOW}" "${C_RESET}" "${rel_path}"
    MOVED_COUNT=$((MOVED_COUNT + 1))
}

for t in "${BACKUP_TARGETS[@]}"; do
    _maybe_backup "${t}"
done

# ---------------------------------------------------------------------------
# RESTORE.md nur schreiben, wenn tatsächlich etwas bewegt wurde
# ---------------------------------------------------------------------------
if [[ "${MOVED_COUNT}" -gt 0 ]]; then
    mkdir -p "${BACKUP_DIR}"
    cat > "${BACKUP_DIR}/RESTORE.md" <<'RESTORE_EOF'
# Backup Restore Instructions

This directory contains config files that were replaced by agent-stack symlinks.

## To restore manually

For each file listed below, remove the current symlink and move the backup back:

```bash
# Example for ~/.claude/CLAUDE.md
rm "$HOME/.claude/CLAUDE.md"
mv "<this-backup-dir>/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
```

## Automated restore

Run:

```bash
~/projects/agent-stack/scripts/uninstall.sh
```

It will prompt you to choose a backup directory and restore files interactively.

## Inventory

Files backed up in this snapshot:
RESTORE_EOF

    # Inventory-Liste anhängen
    (
        cd "${BACKUP_DIR}"
        find . -type f -not -name 'RESTORE.md' | sort | sed 's|^\./|  - |'
    ) >> "${BACKUP_DIR}/RESTORE.md"

    printf '\n  %s✓%s Backup written to %s (%d files)\n' \
        "${C_GREEN}" "${C_RESET}" "${BACKUP_DIR}" "${MOVED_COUNT}"
else
    printf '\n  %s·%s Nothing to back up (%d items skipped)\n' \
        "${C_DIM}" "${C_RESET}" "${SKIPPED_COUNT}"
fi

exit 0
