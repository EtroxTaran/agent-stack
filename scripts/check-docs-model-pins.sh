#!/usr/bin/env bash
# scripts/check-docs-model-pins.sh
#
# Prüft docs/wiki/, AGENTS.md, templates/, configs/BASELINE.md auf
# LLM-Modell-Pins, die nicht im Registry-SoT (MODEL_REGISTRY.env) stehen.
# Läuft als Job "docs-pin-drift" im Weekly-Drift-Check.
#
# Exit-Codes:
#   0 = keine Drift
#   1 = mind. ein Pin nicht in Registry
#   2 = Registry nicht erreichbar / Setup-Fehler

set -euo pipefail

REGISTRY_URL="${REGISTRY_URL:-https://raw.githubusercontent.com/EtroxTaran/ai-review-pipeline/main/src/ai_review_pipeline/registry/MODEL_REGISTRY.env}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Registry laden ─────────────────────────────────────────────────────────
REGISTRY="$(curl -sfL "$REGISTRY_URL" || true)"
if [[ -z "$REGISTRY" ]]; then
    echo "::error::Konnte Registry nicht laden: $REGISTRY_URL" >&2
    exit 2
fi

# Alle Werte rechts vom "=" extrahieren (das sind die erlaubten Pins).
mapfile -t ALLOWED < <(echo "$REGISTRY" \
    | grep -E '^[A-Z_]+=' \
    | cut -d= -f2 \
    | tr -d '"' \
    | sort -u)

# Ein Pin ist erlaubt, wenn er:
#   (a) exakt in $ALLOWED vorkommt, ODER
#   (b) ein bekannter vendor-interner Identifier ist (Cursor composer-*),
#       der nicht in der zentralen Registry getrackt wird.
IGNORE_LITERALS=(
    "composer-2"             # Cursor-intern, kein Registry-Entry
)

# ─── Muster für pinbare Modelle ─────────────────────────────────────────────
# Erfasst: gpt-5, gpt-5.5, gpt-5.5-thinking, gemini-3.1-pro-preview,
# gemini-2.5-pro, claude-opus-4-7, claude-sonnet-4-6, grok-4.20, composer-2
PATTERN='(gpt-[0-9]+([.-][a-z0-9-]+)*|gemini-[0-9]+([.-][a-z0-9-]+)*|claude-(opus|sonnet|haiku)-[0-9]+-[0-9]+|grok-[0-9]+([.-][0-9]+)?|composer-[0-9]+)'

# ─── Scan-Ziele ─────────────────────────────────────────────────────────────
SCAN_TARGETS=(
    "$REPO_ROOT/docs/wiki"
    "$REPO_ROOT/AGENTS.md"
    "$REPO_ROOT/templates"
    "$REPO_ROOT/configs/BASELINE.md"
)

cd "$REPO_ROOT"

fail=0

# Hilfsfunktion: ist $1 ein erlaubter Pin?
is_allowed() {
    local pin="$1"
    # Ignore-Literals
    for lit in "${IGNORE_LITERALS[@]}"; do
        [[ "$pin" == "$lit" ]] && return 0
    done
    # In Registry?
    printf '%s\n' "${ALLOWED[@]}" | grep -qxF "$pin"
}

# ─── Scan ────────────────────────────────────────────────────────────────────
while IFS= read -r line; do
    # Format: path:linenum:content
    file="${line%%:*}"
    rest="${line#*:}"
    linenum="${rest%%:*}"
    content="${rest#*:}"

    # Zeilen mit explizitem Ignore-Marker überspringen.
    # Unterstützt Markdown (<!-- pin-drift-ignore -->), Bash/YAML (# …), TOML (# …).
    if echo "$content" | grep -qE 'pin-drift-ignore'; then
        continue
    fi

    # Alle Pin-Matches der Zeile extrahieren und einzeln prüfen
    while IFS= read -r pin; do
        [[ -z "$pin" ]] && continue
        if ! is_allowed "$pin"; then
            echo "::warning file=${file#"$REPO_ROOT/"},line=$linenum::outdated model pin '$pin' — not in MODEL_REGISTRY.env"
            fail=1
        fi
    done < <(echo "$content" | grep -oE "$PATTERN" | sort -u)
done < <(grep -rnE "$PATTERN" "${SCAN_TARGETS[@]}" 2>/dev/null || true)

if [[ $fail -eq 0 ]]; then
    echo "OK — alle Model-Pins in Docs/Templates/Configs stehen im Registry."
else
    echo "" >&2
    echo "Drift erkannt. Fix: Pins auf aktuelle Registry-Werte bringen oder" >&2
    echo "mit '# pin-drift-ignore' als legitimes Historisch-Beispiel markieren." >&2
fi

exit $fail
