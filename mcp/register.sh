#!/usr/bin/env bash
# ===========================================================================
# register.sh — registriert MCP-Server aus servers.yaml in alle CLIs
# ===========================================================================
# Parst mcp/servers.yaml (yq v4+) und registriert jeden Server pro CLI:
#   - Claude:  claude mcp add-json --scope user <name> '<json>'
#   - Cursor:  jq-merge in ~/.cursor/mcp.json
#   - Gemini:  jq-merge in ~/.gemini/settings.json (Pfad .mcpServers.<name>)
#   - Codex:   yq-toml-merge in ~/.codex/config.toml ([mcp_servers.<name>])
#
# Idempotent: Re-Run darf nichts doppelt eintragen. Claude per remove-vor-add,
# die file-basierten CLIs per jq/yq-set (überschreibt den Pfad).
#
# Secrets: Env-Vars via ${VAR}-Placeholder in YAML; werden aus ~/.openclaw/.env
# geladen und mit envsubst ersetzt, BEVOR sie an CLIs übergeben werden.
# ---------------------------------------------------------------------------
# Usage:
#   mcp/register.sh                  # registriert alle Server für alle CLIs
#   mcp/register.sh --dry-run        # printet, was passieren würde
#   mcp/register.sh --only claude    # nur eine CLI
#   mcp/register.sh --config <path>  # alternative YAML
# ===========================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Pfade & Konstanten
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
DEFAULT_CONFIG="${REPO_ROOT}/mcp/servers.yaml"
ENV_FILE="${HOME}/.openclaw/.env"

# Erlaubte CLI-Namen (muss mit servers.yaml-Schema übereinstimmen)
ALLOWED_CLIS=(claude cursor gemini codex)

# Flags (werden via Args gesetzt)
DRY_RUN=0
ONLY_CLI=""
CONFIG="${DEFAULT_CONFIG}"

# ---------------------------------------------------------------------------
# Log-Helfer (alle schreiben auf stderr, Ergebnisse auf stdout)
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*" >&2; }
info() { printf '[info]  %s\n' "$*" >&2; }
ok()   { printf '[ok]    %s\n' "$*" >&2; }
warn() { printf '[warn]  %s\n' "$*" >&2; }
err()  { printf '[err]   %s\n' "$*" >&2; }

# Führt Befehl aus oder druckt ihn nur (Dry-Run)
run() {
  if (( DRY_RUN )); then
    printf '[dry-run] %s\n' "$*" >&2
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Argument-Parser
# ---------------------------------------------------------------------------
parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run)  DRY_RUN=1; shift ;;
      --only)     ONLY_CLI="${2:-}"; shift 2 ;;
      --config)   CONFIG="${2:-}"; shift 2 ;;
      -h|--help)
        sed -n '2,30p' "$0" >&2
        exit 0
        ;;
      *) err "unbekanntes Argument: $1"; exit 2 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Preflight: Tools & Env prüfen
# ---------------------------------------------------------------------------
need_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Pflicht-Tool fehlt: $cmd"
    return 1
  fi
}

preflight() {
  local missing=0
  need_cmd yq       || missing=1
  need_cmd jq       || missing=1
  need_cmd envsubst || missing=1

  # yq v4 (Mike Farah) wird gebraucht. v3 (Python-yq) ist inkompatibel.
  if command -v yq >/dev/null 2>&1; then
    local yq_ver
    yq_ver="$(yq --version 2>&1 || true)"
    if ! printf '%s' "$yq_ver" | grep -Eq '(mikefarah|version v?4|version v?5)'; then
      err "yq v4+ (Mike Farah) wird benötigt. Gefunden: ${yq_ver}"
      missing=1
    fi
  fi

  if (( missing )); then
    err "Preflight fehlgeschlagen — bitte fehlende Tools installieren."
    exit 1
  fi

  if [[ ! -f "$CONFIG" ]]; then
    err "Config nicht gefunden: $CONFIG"
    exit 1
  fi

  # ~/.openclaw/.env sourcen (für ${GITHUB_TOKEN} etc.)
  if [[ -f "$ENV_FILE" ]]; then
    info "Env-File wird geladen: $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  else
    warn "Env-File fehlt: $ENV_FILE — Servers mit Secrets könnten leere Werte bekommen"
  fi

  # HOME muss exportiert sein für envsubst auf ${HOME}/projects
  export HOME
}

# ---------------------------------------------------------------------------
# CLI-Filter
# ---------------------------------------------------------------------------
cli_is_target() {
  local cli="$1"
  if [[ -n "$ONLY_CLI" ]]; then
    [[ "$cli" == "$ONLY_CLI" ]]
    return
  fi
  return 0
}

# Prüft, ob $1 in ALLOWED_CLIS steckt
cli_allowed() {
  local cli="$1" x
  for x in "${ALLOWED_CLIS[@]}"; do
    [[ "$x" == "$cli" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# YAML → JSON-Objekt pro Server (envsubst-substituiert)
# ---------------------------------------------------------------------------
# Schreibt server-JSON (mit resolved Env-Vars) auf stdout.
# Format: { name, transport, command?, args?, url?, env?, clis[] }
server_json() {
  local idx="$1"
  # yq extrahiert den i-ten Server, sub_env resolved ${VAR}-Placeholder.
  yq -o=json ".servers[${idx}]" "$CONFIG" | envsubst
}

server_count() {
  yq '.servers | length' "$CONFIG"
}

# ---------------------------------------------------------------------------
# Per-Server-Metadaten auslesen
# ---------------------------------------------------------------------------
server_field() {
  local idx="$1" path="$2"
  yq -r ".servers[${idx}].${path} // \"\"" "$CONFIG"
}

server_clis() {
  local idx="$1"
  yq -r ".servers[${idx}].clis[]" "$CONFIG"
}

# ---------------------------------------------------------------------------
# Claude-Registrierung (via CLI)
# ---------------------------------------------------------------------------
# claude mcp add-json --scope user <name> '<json>'
# Schema laut Claude-Docs: { type, command, args, env }  oder  { type, url }
register_claude() {
  local name="$1" json="$2"
  local transport command url
  transport="$(printf '%s' "$json" | jq -r '.transport')"

  local claude_json
  if [[ "$transport" == "stdio" ]]; then
    command="$(printf '%s' "$json" | jq -r '.command')"
    claude_json="$(printf '%s' "$json" | jq --arg cmd "$command" '
      {
        type: "stdio",
        command: $cmd,
        args: (.args // []),
        env:  (.env  // {})
      }')"
  else
    url="$(printf '%s' "$json" | jq -r '.url')"
    claude_json="$(printf '%s' "$json" | jq --arg url "$url" --arg t "$transport" '
      { type: $t, url: $url }')"
  fi

  # Idempotenz: remove vor add (ignoriert Fehler, falls noch nicht vorhanden)
  run bash -c "claude mcp remove '$name' -s user >/dev/null 2>&1 || true"
  if run claude mcp add-json --scope user "$name" "$claude_json"; then
    ok "registered $name in claude"
  else
    err "failed to register $name in claude"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Cursor-Registrierung (via jq-merge in ~/.cursor/mcp.json)
# ---------------------------------------------------------------------------
# Cursor IDE + cursor-agent CLI teilen sich ~/.cursor/mcp.json.
# Schema: { "mcpServers": { "<name>": { command, args, env } | { url } } }
register_cursor() {
  local name="$1" json="$2"
  local cfg="${HOME}/.cursor/mcp.json"
  local transport
  transport="$(printf '%s' "$json" | jq -r '.transport')"

  mkdir -p "$(dirname "$cfg")"
  [[ -f "$cfg" ]] || printf '{"mcpServers":{}}\n' > "$cfg"

  local entry
  if [[ "$transport" == "stdio" ]]; then
    entry="$(printf '%s' "$json" | jq '{
      command: .command,
      args:    (.args // []),
      env:     (.env  // {})
    }')"
  else
    entry="$(printf '%s' "$json" | jq '{ url: .url }')"
  fi

  if (( DRY_RUN )); then
    info "[dry-run] would set ${cfg} .mcpServers.${name} = ${entry}"
    ok "registered $name in cursor (dry-run)"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg n "$name" --argjson e "$entry" '.mcpServers[$n] = $e' "$cfg" > "$tmp"
  mv "$tmp" "$cfg"
  ok "registered $name in cursor"
}

# ---------------------------------------------------------------------------
# Gemini-Registrierung (jq-merge in ~/.gemini/settings.json)
# ---------------------------------------------------------------------------
# Schema: { "mcpServers": { "<name>": { command, args, env } | { httpUrl } } }
register_gemini() {
  local name="$1" json="$2"
  local cfg="${HOME}/.gemini/settings.json"
  local transport
  transport="$(printf '%s' "$json" | jq -r '.transport')"

  mkdir -p "$(dirname "$cfg")"
  [[ -f "$cfg" ]] || printf '{}\n' > "$cfg"

  # Falls .mcpServers fehlt, init
  local entry
  if [[ "$transport" == "stdio" ]]; then
    entry="$(printf '%s' "$json" | jq '{
      command: .command,
      args:    (.args // []),
      env:     (.env  // {})
    }')"
  else
    # Gemini nennt das Feld httpUrl (laut Gemini-CLI-Docs)
    entry="$(printf '%s' "$json" | jq '{ httpUrl: .url }')"
  fi

  if (( DRY_RUN )); then
    info "[dry-run] would set ${cfg} .mcpServers.${name} = ${entry}"
    ok "registered $name in gemini (dry-run)"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg n "$name" --argjson e "$entry" '
    (.mcpServers // {}) as $m
    | .mcpServers = ($m + { ($n): $e })
  ' "$cfg" > "$tmp"
  mv "$tmp" "$cfg"
  ok "registered $name in gemini"
}

# ---------------------------------------------------------------------------
# Codex-Registrierung (yq-toml-merge in ~/.codex/config.toml)
# ---------------------------------------------------------------------------
# Schema: [mcp_servers.<name>]
#   command = "..."
#   args    = ["..."]
#   env     = { KEY = "value" }
#  oder für http:
#   url = "..."
register_codex() {
  local name="$1" json="$2"
  local cfg="${HOME}/.codex/config.toml"
  local transport
  transport="$(printf '%s' "$json" | jq -r '.transport')"

  mkdir -p "$(dirname "$cfg")"
  [[ -f "$cfg" ]] || : > "$cfg"

  # JSON → YAML-Fragment bauen, dann mit yq TOML-merge
  local entry_yaml
  if [[ "$transport" == "stdio" ]]; then
    entry_yaml="$(printf '%s' "$json" | yq -P '{
      "command": .command,
      "args":    (.args // []),
      "env":     (.env  // {})
    }')"
  else
    entry_yaml="$(printf '%s' "$json" | yq -P '{ "url": .url }')"
  fi

  if (( DRY_RUN )); then
    info "[dry-run] would set ${cfg} [mcp_servers.${name}] = <yaml>"
    ok "registered $name in codex (dry-run)"
    return 0
  fi

  local tmp_existing tmp_new
  tmp_existing="$(mktemp)"
  tmp_new="$(mktemp)"

  # Existierendes TOML → YAML (intern), mergen, zurück nach TOML
  if [[ -s "$cfg" ]]; then
    yq -p=toml -o=yaml '.' "$cfg" > "$tmp_existing" 2>/dev/null \
      || printf '{}\n' > "$tmp_existing"
  else
    printf '{}\n' > "$tmp_existing"
  fi

  # Entry-YAML als Datei (für yq load-Pfad)
  local tmp_entry
  tmp_entry="$(mktemp)"
  printf '%s\n' "$entry_yaml" > "$tmp_entry"

  # Merge: setzt .mcp_servers.<name> auf Inhalt von $tmp_entry
  yq eval-all "
    select(fileIndex == 0) as \$base
    | select(fileIndex == 1) as \$entry
    | \$base
    | .mcp_servers.\"${name}\" = \$entry
  " "$tmp_existing" "$tmp_entry" > "$tmp_new"

  # Zurück nach TOML
  yq -p=yaml -o=toml '.' "$tmp_new" > "$cfg"

  rm -f "$tmp_existing" "$tmp_new" "$tmp_entry"
  ok "registered $name in codex"
}

# ---------------------------------------------------------------------------
# Main-Dispatch: pro Server, pro gewünschter CLI, call register_<cli>
# ---------------------------------------------------------------------------
dispatch() {
  local total
  total="$(server_count)"
  info "Config: $CONFIG — $total Server gefunden"

  local i=0
  local registered_total=0 failed_total=0
  while (( i < total )); do
    local name transport json
    name="$(server_field "$i" 'name')"
    transport="$(server_field "$i" 'transport')"
    json="$(server_json "$i")"

    if [[ -z "$name" || -z "$transport" ]]; then
      err "server[${i}]: name oder transport fehlt — übersprungen"
      (( i++ ))
      continue
    fi

    info "→ ${name} (${transport})"

    local clis_for_server
    clis_for_server="$(server_clis "$i")"

    local cli
    while IFS= read -r cli; do
      [[ -z "$cli" ]] && continue

      if ! cli_allowed "$cli"; then
        warn "${name}: unbekannte CLI '${cli}' — übersprungen"
        continue
      fi

      if ! cli_is_target "$cli"; then
        continue
      fi

      case "$cli" in
        claude) register_claude "$name" "$json" && (( registered_total++ )) || (( failed_total++ )) ;;
        cursor) register_cursor "$name" "$json" && (( registered_total++ )) || (( failed_total++ )) ;;
        gemini) register_gemini "$name" "$json" && (( registered_total++ )) || (( failed_total++ )) ;;
        codex)  register_codex  "$name" "$json" && (( registered_total++ )) || (( failed_total++ )) ;;
      esac
    done <<< "$clis_for_server"

    (( i++ ))
  done

  log ""
  log "────────────────────────────────────────────────"
  ok   "Summary: ${registered_total} registrations ok, ${failed_total} failed"
  log "────────────────────────────────────────────────"

  (( failed_total == 0 ))
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  if [[ -n "$ONLY_CLI" ]] && ! cli_allowed "$ONLY_CLI"; then
    err "--only '${ONLY_CLI}' ist nicht erlaubt (allowed: ${ALLOWED_CLIS[*]})"
    exit 2
  fi

  preflight
  dispatch
}

main "$@"
