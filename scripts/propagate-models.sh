#!/usr/bin/env bash
# propagate-models.sh — Schreibt MODEL_REGISTRY.md-Werte in die CLI-Configs.
#
# Liest ~/.openclaw/workspace/MODEL_REGISTRY.md und patcht:
#   - configs/codex/config.toml       [model].name  ← OPENAI_MAIN
#   - configs/gemini/settings.json    .general.model      ← GEMINI_PRO
#                                     .general.flashModel ← GEMINI_FLASH
#
# Claude-Config nutzt Alias "opus" (vom SDK resolved) — nicht gepatcht.
# Cursor nutzt composer-2 (kein öffentliches Registry) — nicht gepatcht.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="${HOME}/.openclaw/workspace/MODEL_REGISTRY.md"

if [[ ! -f "$REGISTRY" ]]; then
    echo "ERROR: Registry fehlt unter ${REGISTRY}" >&2
    exit 2
fi

_get() {
    grep -E "^$1=" "$REGISTRY" | head -n1 | cut -d= -f2- | tr -d '"'
}

OPENAI_MAIN=$(_get OPENAI_MAIN)
GEMINI_PRO=$(_get GEMINI_PRO)
GEMINI_FLASH=$(_get GEMINI_FLASH)

PATCHED=()

# ---- Codex: [model].name ----
if [[ -n "$OPENAI_MAIN" ]]; then
    codex_cfg="${REPO_ROOT}/configs/codex/config.toml"
    if [[ -f "$codex_cfg" ]]; then
        tmp=$(mktemp)
        # Nur im [model]-Block das name-Feld ersetzen.
        awk -v val="$OPENAI_MAIN" '
            /^\[model\]/    { inmodel=1; print; next }
            /^\[[^]]+\]/    { inmodel=0; print; next }
            inmodel && /^[[:space:]]*name[[:space:]]*=/ {
                print "name = \"" val "\""; next
            }
            { print }
        ' "$codex_cfg" > "$tmp"
        if ! cmp -s "$codex_cfg" "$tmp"; then
            mv "$tmp" "$codex_cfg"
            PATCHED+=("codex[model].name=${OPENAI_MAIN}")
        else
            rm -f "$tmp"
        fi
    fi
fi

# ---- Gemini: .general.model + .general.flashModel ----
gemini_cfg="${REPO_ROOT}/configs/gemini/settings.json"
if [[ -f "$gemini_cfg" && ( -n "$GEMINI_PRO" || -n "$GEMINI_FLASH" ) ]]; then
    tmp=$(mktemp)
    jq --arg pro "$GEMINI_PRO" --arg flash "$GEMINI_FLASH" '
        if $pro != "" then .general.model = $pro else . end
        | if $flash != "" then .general.flashModel = $flash else . end
    ' "$gemini_cfg" > "$tmp"
    if ! cmp -s "$gemini_cfg" "$tmp"; then
        mv "$tmp" "$gemini_cfg"
        PATCHED+=("gemini.general.model=${GEMINI_PRO}")
        PATCHED+=("gemini.general.flashModel=${GEMINI_FLASH}")
    else
        rm -f "$tmp"
    fi
fi

if [[ ${#PATCHED[@]} -eq 0 ]]; then
    echo "Propagation: keine Änderungen (Configs sind synchron)."
else
    echo "Propagation angewendet:"
    for p in "${PATCHED[@]}"; do echo "  ✓ $p"; done
fi
