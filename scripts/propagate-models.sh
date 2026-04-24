#!/usr/bin/env bash
# propagate-models.sh — Schreibt MODEL_REGISTRY.md-Werte in die CLI-Configs.
#
# Liest ~/.openclaw/workspace/MODEL_REGISTRY.md und patcht:
#   - configs/codex/config.toml       top-level  model               ← OPENAI_MAIN
#   - configs/gemini/settings.json    .general.model                 ← GEMINI_PRO
#                                     .general.flashModel            ← GEMINI_FLASH
#
# Codex-Schema: top-level keys (model, sandbox_mode, approval_policy,
# model_reasoning_effort, project_doc_*) — keine TOML-Sections.
# Quelle: openai/codex → codex-rs/core/config.schema.json.
#
# Claude-Config nutzt Alias "opus" (vom SDK resolved) — nicht gepatcht.
# Cursor nutzt composer-2 (kein öffentliches Registry) — nicht gepatcht.

set -euo pipefail

# REPO_ROOT + REGISTRY überschreibbar für Tests (bats fake-Fixture-Dirs).
# Default: Skript-relativ (agent-stack/scripts/.. = Repo-Root).
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REGISTRY="${REGISTRY:-${HOME}/.openclaw/workspace/MODEL_REGISTRY.md}"

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

# ---- Codex: top-level `model` (außerhalb aller [sections]) ----
if [[ -n "$OPENAI_MAIN" ]]; then
    codex_cfg="${REPO_ROOT}/configs/codex/config.toml"
    if [[ -f "$codex_cfg" ]]; then
        tmp=$(mktemp)
        # Nur die erste `model = "..."`-Zeile vor dem ersten [section]-Header ersetzen.
        # Verhindert Kollision mit `model = ...` innerhalb von [profiles.<name>]-Blöcken.
        # Ersetze die erste `model = "..."` Zeile VOR dem ersten [section]-Header.
        # Nach dem ersten [section] wird `in_body=0` — verhindert Kollision mit
        # `model = ...` innerhalb von [profiles.<name>]- oder [mcp_servers.<n>]-Blöcken.
        awk -v val="$OPENAI_MAIN" '
            BEGIN { in_body=1 }
            /^[[:space:]]*\[/ { in_body=0 }
            !done && in_body && /^[[:space:]]*model[[:space:]]*=/ {
                print "model = \"" val "\""; done=1; next
            }
            { print }
        ' "$codex_cfg" > "$tmp"
        if ! cmp -s "$codex_cfg" "$tmp"; then
            mv "$tmp" "$codex_cfg"
            PATCHED+=("codex.model=${OPENAI_MAIN}")
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
