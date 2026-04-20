#!/usr/bin/env bash
# ===========================================================================
# test_mcp_servers.sh — Schema-Validator für mcp/servers.yaml
# ===========================================================================
# Validiert:
#   1. YAML ist parsebar (yq)
#   2. .version ist gesetzt und >= 1
#   3. .servers existiert und ist nicht leer
#   4. Pro Server:
#      - name (string, non-empty, unique)
#      - transport in {stdio, http, sse}
#      - stdio: command (string, non-empty)
#      - http/sse: url (string, non-empty)
#      - clis (list, non-empty, alle in {claude, cursor, gemini, codex})
#
# Exit 0 = alles ok, sonst 1.
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
CONFIG="${REPO_ROOT}/mcp/servers.yaml"

FAIL_COUNT=0

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { printf '[info] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Tool-Preflight
# ---------------------------------------------------------------------------
if ! command -v yq >/dev/null 2>&1; then
  fail "yq (v4+) nicht gefunden — benötigt für Validator"
  exit 1
fi

YQ_VER="$(yq --version 2>&1 || true)"
if ! printf '%s' "$YQ_VER" | grep -Eq '(mikefarah|version v?4|version v?5)'; then
  fail "yq v4+ (Mike Farah) benötigt. Gefunden: ${YQ_VER}"
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  fail "Config nicht gefunden: $CONFIG"
  exit 1
fi

info "Validiere: $CONFIG"

# ---------------------------------------------------------------------------
# 1) YAML parsebar
# ---------------------------------------------------------------------------
if yq eval '.' "$CONFIG" >/dev/null 2>&1; then
  pass "YAML parsebar"
else
  fail "YAML nicht parsebar"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2) .version
# ---------------------------------------------------------------------------
VERSION="$(yq -r '.version // ""' "$CONFIG")"
if [[ -z "$VERSION" ]]; then
  fail ".version fehlt"
elif ! [[ "$VERSION" =~ ^[0-9]+$ ]] || (( VERSION < 1 )); then
  fail ".version muss Integer >= 1 sein (gefunden: ${VERSION})"
else
  pass ".version = ${VERSION}"
fi

# ---------------------------------------------------------------------------
# 3) .servers
# ---------------------------------------------------------------------------
SERVER_COUNT="$(yq -r '.servers | length // 0' "$CONFIG")"
if [[ -z "$SERVER_COUNT" ]] || (( SERVER_COUNT == 0 )); then
  fail ".servers fehlt oder ist leer"
  exit 1
fi
pass ".servers enthält ${SERVER_COUNT} Einträge"

# ---------------------------------------------------------------------------
# 4) Pro-Server-Validierung
# ---------------------------------------------------------------------------
ALLOWED_TRANSPORTS=("stdio" "http" "sse")
ALLOWED_CLIS=("claude" "cursor" "gemini" "codex")

in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

declare -A SEEN_NAMES=()

i=0
while (( i < SERVER_COUNT )); do
  NAME="$(yq -r ".servers[${i}].name // \"\"" "$CONFIG")"
  TRANSPORT="$(yq -r ".servers[${i}].transport // \"\"" "$CONFIG")"
  COMMAND="$(yq -r ".servers[${i}].command // \"\"" "$CONFIG")"
  URL="$(yq -r ".servers[${i}].url // \"\"" "$CONFIG")"
  CLIS_COUNT="$(yq -r ".servers[${i}].clis | length // 0" "$CONFIG")"

  LABEL="server[${i}]"
  if [[ -n "$NAME" ]]; then
    LABEL="${LABEL} (${NAME})"
  fi

  # name
  if [[ -z "$NAME" ]]; then
    fail "${LABEL}: name fehlt"
  elif [[ -n "${SEEN_NAMES[$NAME]:-}" ]]; then
    fail "${LABEL}: name '${NAME}' ist doppelt"
  else
    SEEN_NAMES[$NAME]=1
    pass "${LABEL}: name ok"
  fi

  # transport
  if [[ -z "$TRANSPORT" ]]; then
    fail "${LABEL}: transport fehlt"
  elif ! in_list "$TRANSPORT" "${ALLOWED_TRANSPORTS[@]}"; then
    fail "${LABEL}: transport '${TRANSPORT}' ungültig (erlaubt: ${ALLOWED_TRANSPORTS[*]})"
  else
    pass "${LABEL}: transport = ${TRANSPORT}"
  fi

  # command/url je Transport
  case "$TRANSPORT" in
    stdio)
      if [[ -z "$COMMAND" ]]; then
        fail "${LABEL}: command fehlt (stdio-transport)"
      else
        pass "${LABEL}: command = ${COMMAND}"
      fi
      ;;
    http|sse)
      if [[ -z "$URL" ]]; then
        fail "${LABEL}: url fehlt (${TRANSPORT}-transport)"
      else
        pass "${LABEL}: url = ${URL}"
      fi
      ;;
  esac

  # clis
  if [[ -z "$CLIS_COUNT" ]] || (( CLIS_COUNT == 0 )); then
    fail "${LABEL}: clis fehlt oder leer"
  else
    j=0
    all_clis_ok=1
    while (( j < CLIS_COUNT )); do
      CLI="$(yq -r ".servers[${i}].clis[${j}]" "$CONFIG")"
      if ! in_list "$CLI" "${ALLOWED_CLIS[@]}"; then
        fail "${LABEL}: cli '${CLI}' ungültig (erlaubt: ${ALLOWED_CLIS[*]})"
        all_clis_ok=0
      fi
      j=$((j + 1))
    done
    if (( all_clis_ok )); then
      pass "${LABEL}: clis (${CLIS_COUNT}) alle erlaubt"
    fi
  fi

  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if (( FAIL_COUNT == 0 )); then
  pass "ALL CHECKS PASSED"
  exit 0
else
  fail "${FAIL_COUNT} check(s) failed"
  exit 1
fi
