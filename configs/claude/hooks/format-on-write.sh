#!/usr/bin/env bash
# format-on-write.sh — PostToolUse hook for Edit|Write
# Formatiert die geschriebene Datei mit dem passenden Tool.
# Silent-skip wenn Formatter nicht installiert.
# Exit 0 immer (darf nie den Fluss unterbrechen).

set -u  # bewusst kein -e: Formatter-Fehler dürfen nicht propagieren

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

FILE_PATH="$(printf '%s' "${INPUT}" | jq -r '.tool_input.file_path // empty')"

if [[ -z "${FILE_PATH}" ]] || [[ ! -f "${FILE_PATH}" ]]; then
  exit 0
fi

# Extension extrahieren
EXT="${FILE_PATH##*.}"

run_if_available() {
  local bin="$1"
  shift
  if command -v "${bin}" >/dev/null 2>&1; then
    "${bin}" "$@" >/dev/null 2>&1 || true
  fi
}

case "${EXT}" in
  ts|tsx|js|jsx|mjs|cjs)
    run_if_available prettier --write "${FILE_PATH}"
    ;;
  json|md|yaml|yml|css|scss|html)
    run_if_available prettier --write "${FILE_PATH}"
    ;;
  py)
    if command -v ruff >/dev/null 2>&1; then
      ruff format "${FILE_PATH}" >/dev/null 2>&1 || true
    elif command -v black >/dev/null 2>&1; then
      black --quiet "${FILE_PATH}" >/dev/null 2>&1 || true
    fi
    ;;
  go)
    run_if_available gofmt -w "${FILE_PATH}"
    ;;
  rs)
    run_if_available rustfmt "${FILE_PATH}"
    ;;
  sh|bash)
    run_if_available shfmt -w "${FILE_PATH}"
    ;;
  *)
    : # nichts tun
    ;;
esac

exit 0
