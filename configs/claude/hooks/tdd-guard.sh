#!/usr/bin/env bash
# tdd-guard.sh — PreToolUse hook for Edit|Write (OPT-IN)
# Aktiv nur wenn AI_TDD_GUARD=strict gesetzt ist.
# Blockt Writes in src/**, app/**, plugins/**, wenn keine Test-Datei daneben existiert.
# Siehe hooks/README.md für Details.

set -euo pipefail

# Opt-in-Gate: ohne strict → sofort durchwinken
if [[ "${AI_TDD_GUARD:-off}" != "strict" ]]; then
  exit 0
fi

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

FILE_PATH="$(printf '%s' "${INPUT}" | jq -r '.tool_input.file_path // empty')"

if [[ -z "${FILE_PATH}" ]]; then
  exit 0
fi

deny() {
  local reason="$1"
  jq -nc --arg r "${reason}" '{permissionDecision:"deny", reason:$r}'
  exit 2
}

# Relevant nur für Produktcode-Verzeichnisse
if [[ ! "${FILE_PATH}" =~ /(src|app|plugins)/ ]]; then
  exit 0
fi

# Test-Dateien selbst sind erlaubt
BASE="$(basename "${FILE_PATH}")"
if [[ "${BASE}" =~ \.(test|spec)\. ]] || [[ "${BASE}" =~ _test\. ]]; then
  exit 0
fi

# Existiert eine Test-Datei im selben Verzeichnis?
DIR="$(dirname "${FILE_PATH}")"
STEM="${BASE%.*}"
EXT="${BASE##*.}"

FOUND=0
for variant in \
  "${DIR}/${STEM}.test.${EXT}" \
  "${DIR}/${STEM}.spec.${EXT}" \
  "${DIR}/${STEM}_test.${EXT}" \
  "${DIR}/__tests__/${STEM}.test.${EXT}" \
  "${DIR}/__tests__/${STEM}.spec.${EXT}"; do
  if [[ -f "${variant}" ]]; then
    FOUND=1
    break
  fi
done

if [[ "${FOUND}" -eq 0 ]]; then
  deny "TDD violation: write failing test first for ${FILE_PATH}"
fi

exit 0
