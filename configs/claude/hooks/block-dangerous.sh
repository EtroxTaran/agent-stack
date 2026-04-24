#!/usr/bin/env bash
# block-dangerous.sh — PreToolUse hook for Bash
# Blockiert gefährliche Shell-Kommandos bevor Claude sie ausführt.
# Input: JSON via stdin mit tool_input.command
# Output bei Block: exit 2 + JSON {"permissionDecision":"deny","reason":"..."}
# Sonst: exit 0

set -euo pipefail

# --- Input lesen ---------------------------------------------------------
INPUT="$(cat)"

# jq fehlt? → silent allow (nicht blocken, wenn Setup unvollständig)
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

CMD="$(printf '%s' "${INPUT}" | jq -r '.tool_input.command // empty')"

if [[ -z "${CMD}" ]]; then
  exit 0
fi

# --- Hilfsfunktion: Deny-Response --------------------------------------
deny() {
  local reason="$1"
  jq -nc --arg r "${reason}" '{permissionDecision:"deny", reason:$r}'
  exit 2
}

# --- Gefährliche Muster --------------------------------------------------

# rm -rf / (auch rm -rf /* oder mit Leerzeichen)
if [[ "${CMD}" =~ rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f?[[:space:]]+/[[:space:]]*$ ]] \
  || [[ "${CMD}" =~ rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f?[[:space:]]+/([[:space:]]|\*) ]]; then
  deny "Refusing: rm -rf on root filesystem"
fi

# git reset --hard origin*
if [[ "${CMD}" =~ git[[:space:]]+reset[[:space:]]+--hard[[:space:]]+origin ]]; then
  deny "Refusing: git reset --hard origin destroys local work"
fi

# force-push OHNE --force-with-lease
if [[ "${CMD}" =~ git[[:space:]]+push ]] \
  && { [[ "${CMD}" =~ --force([[:space:]]|$) ]] || [[ "${CMD}" =~ [[:space:]]-f([[:space:]]|$) ]]; } \
  && [[ ! "${CMD}" =~ --force-with-lease ]]; then
  deny "Refusing: force-push without --force-with-lease"
fi

# curl ... | bash / curl ... | sh (Pipe-to-shell remote exec)
if [[ "${CMD}" =~ curl[[:space:]].*\|[[:space:]]*(bash|sh)([[:space:]]|$) ]]; then
  deny "Refusing: curl | bash pattern (remote code execution)"
fi

# wget ... | bash / wget ... | sh
if [[ "${CMD}" =~ wget[[:space:]].*\|[[:space:]]*(bash|sh)([[:space:]]|$) ]]; then
  deny "Refusing: wget | bash pattern (remote code execution)"
fi

# sudo rm ...
if [[ "${CMD}" =~ sudo[[:space:]]+rm([[:space:]]|$) ]]; then
  deny "Refusing: sudo rm requires explicit approval"
fi

# >> /etc/ (privilegierter Schreibzugriff auf Systemconfig)
if [[ "${CMD}" =~ \>\>?[[:space:]]*/etc/ ]]; then
  deny "Refusing: redirect into /etc/ without review"
fi

# --- Alles ok ------------------------------------------------------------
exit 0
