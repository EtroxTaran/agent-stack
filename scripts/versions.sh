#!/usr/bin/env bash
# versions.sh — Report der vier CLI-Versionen (Claude, Cursor, Gemini, Codex).
# Exit-Code: 0 wenn alle vier gefunden, 1 wenn mindestens eine fehlt.
# Machine-parseable via `--json`.

set -euo pipefail

OUTPUT_JSON=false
if [[ "${1:-}" == "--json" ]]; then
    OUTPUT_JSON=true
fi

# Extrahiert die Version aus `<bin> --version`. Nimmt die erste Zeile,
# lässt Prefixes wie "codex-cli" oder Suffixes wie "(Claude Code)" stehen —
# dafür ist _first_version_token da, wenn ein sauberer Token gewünscht ist.
_get_version() {
    local bin="$1"
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "MISSING"
        return 1
    fi
    # Cursor-Agent kennt nur --version als Subcommand nicht; bleibt Standard.
    "$bin" --version 2>&1 | head -n1 | tr -d '\r'
}

_first_version_token() {
    # Pickt den ersten Token, der wie eine Version aussieht (x.y.z oder yyyy.mm.dd-hash).
    grep -oE '[0-9]+\.[0-9]+[.-][0-9A-Za-z.-]+' <<<"$1" | head -n1
}

declare -A VERSIONS
declare -A STATUS

for spec in "claude:claude" "cursor-agent:cursor" "gemini:gemini" "codex:codex"; do
    bin="${spec%%:*}"
    label="${spec##*:}"
    raw=$(_get_version "$bin" 2>&1 || true)
    if [[ "$raw" == "MISSING" ]]; then
        VERSIONS[$label]=""
        STATUS[$label]="missing"
    else
        token=$(_first_version_token "$raw")
        VERSIONS[$label]="${token:-$raw}"
        STATUS[$label]="ok"
    fi
done

MISSING_COUNT=0
for label in claude cursor gemini codex; do
    [[ "${STATUS[$label]}" == "missing" ]] && MISSING_COUNT=$((MISSING_COUNT + 1))
done

if $OUTPUT_JSON; then
    printf '{\n'
    printf '  "claude":  {"version": "%s", "status": "%s"},\n' "${VERSIONS[claude]}" "${STATUS[claude]}"
    printf '  "cursor":  {"version": "%s", "status": "%s"},\n' "${VERSIONS[cursor]}" "${STATUS[cursor]}"
    printf '  "gemini":  {"version": "%s", "status": "%s"},\n' "${VERSIONS[gemini]}" "${STATUS[gemini]}"
    printf '  "codex":   {"version": "%s", "status": "%s"}\n' "${VERSIONS[codex]}" "${STATUS[codex]}"
    printf '}\n'
else
    printf '%-12s %-25s %s\n' "CLI" "Version" "Status"
    printf '%-12s %-25s %s\n' "------------" "-------------------------" "------"
    for label in claude cursor gemini codex; do
        printf '%-12s %-25s %s\n' "$label" "${VERSIONS[$label]:-—}" "${STATUS[$label]}"
    done
fi

exit $([[ $MISSING_COUNT -eq 0 ]] && echo 0 || echo 1)
