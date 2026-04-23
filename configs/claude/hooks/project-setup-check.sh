#!/bin/bash
# project-setup-check.sh — SessionStart-Hook
#
# Feuert bei jedem neuen Claude-Code-Session-Start via ~/.claude/settings.json
# `hooks.SessionStart`. Erkennt Projekte die die AI-Review-Pipeline nutzen
# könnten aber noch nicht konfiguriert sind, und printet eine klar handlungs-
# bare Anleitung in den Session-Start-Output.
#
# Design-Ziele:
#   - Kein Noise in Non-Git-Ordnern oder bereits-konfigurierten Repos
#   - Zeigt nur Info (exit 0), blockt den Session-Start nicht
#   - Skippbar via CLAUDE_SKIP_AI_REVIEW_SETUP=1 (für CI, temp-Dirs etc.)
#   - Idempotent und absichtsicher — läuft auch ohne gh-Extension sauber durch

set -euo pipefail

# ── Abbruch-Bedingungen ─────────────────────────────────────────────────

# Explizit-Skip (z.B. CI, Temp-Dirs, experimentelle Ordner)
if [ "${CLAUDE_SKIP_AI_REVIEW_SETUP:-0}" = "1" ]; then
    exit 0
fi

# Nicht in einem Git-Repo → nichts zu tun
if [ ! -d ".git" ] && ! git rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

# Pipeline bereits konfiguriert → nichts zu tun
if [ -f ".ai-review/config.yaml" ] && \
   [ -f ".github/workflows/ai-code-review.yml" ]; then
    exit 0
fi

# Repo ist explizit als "kein AI-Review"-Repo markiert
if [ -f ".ai-review/.noreview" ] || \
   [ -f ".noaireview" ]; then
    exit 0
fi

# ── Repo-Typ erkennen ───────────────────────────────────────────────────
# Nur Repos auf dem User-Account interessieren; fremde Forks ignorieren
readonly EXPECTED_OWNER="${AI_REVIEW_EXPECTED_OWNER:-EtroxTaran}"

REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
if [ -z "$REMOTE_URL" ]; then
    # Lokales Repo ohne Remote — kein Setup-Nudge
    exit 0
fi

if ! echo "$REMOTE_URL" | grep -qE "[/:]${EXPECTED_OWNER}/"; then
    # Fremdes Repo (nicht EtroxTaran) → kein Setup-Nudge
    exit 0
fi

# ── Setup-Fähigkeit prüfen ──────────────────────────────────────────────

# gh-CLI verfügbar?
if ! command -v gh >/dev/null 2>&1; then
    cat <<'EOF'

ℹ️  AI-Review-Pipeline ist für dieses Repo noch nicht konfiguriert.
   Installation braucht `gh` CLI — siehe agent-stack/docs/wiki/40-setup/
EOF
    exit 0
fi

# gh ai-review Extension installiert?
if ! gh ai-review --help >/dev/null 2>&1; then
    cat <<'EOF'

ℹ️  AI-Review-Pipeline ist für dieses Repo noch nicht konfiguriert.
   Voraussetzung: `gh extension install EtroxTaran/gh-ai-review`

   Danach: `gh ai-review install` im Repo-Root.

   Details: agent-stack/docs/wiki/40-setup/00-quickstart-neues-projekt.md
EOF
    exit 0
fi

# ── Nudge ausgeben ──────────────────────────────────────────────────────
REPO_NAME=$(basename "$(pwd)")

cat <<EOF

┌─────────────────────────────────────────────────────────────────┐
│  ⚠️  AI-Review-Pipeline nicht aktiviert in '$REPO_NAME'
├─────────────────────────────────────────────────────────────────┤
│  Jedes Projekt unter $EXPECTED_OWNER sollte die Review-Pipeline
│  haben (5 Stages + Consensus + Discord-Notifications).
│
│  Setup (~5 Min):
│    gh ai-review install
│    $EDITOR .ai-review/config.yaml    # Discord-Channel eintragen
│    gh ai-review verify               # Sanity-Check
│
│  Skip (für dieses Repo dauerhaft):
│    touch .ai-review/.noreview && git add … && git commit …
│
│  Details: agent-stack/docs/wiki/40-setup/00-quickstart-neues-projekt.md
└─────────────────────────────────────────────────────────────────┘

EOF

# Exit 0 = informativ, non-blocking
exit 0
