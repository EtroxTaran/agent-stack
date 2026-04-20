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
  # Write-through statt mv, damit ein Symlink nicht durch eine reale Datei ersetzt wird
  cat "$tmp" > "$cfg"
  rm -f "$tmp"
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

  mkdir -p "$(dirname "$cfg")"
  [[ -f "$cfg" ]] || : > "$cfg"

  if (( DRY_RUN )); then
    info "[dry-run] would set ${cfg} [mcp_servers.${name}]"
    ok "registered $name in codex (dry-run)"
    return 0
  fi

  # Python-basierter TOML-Merge (yq kann keine nested tables schreiben).
  # Python 3.11+ hat tomllib für Read. Writer ist manuell (klar umrissenes Schema).
  # MCP_ENTRY_JSON wird als Env-Var durchgereicht.
  MCP_ENTRY_JSON="$json" python3 - "$cfg" "$name" <<'PY_EOF'
import sys, os, json, re
try:
    import tomllib
except ImportError:
    import tomli as tomllib  # type: ignore

cfg_path = sys.argv[1]
name     = sys.argv[2]
entry    = json.loads(os.environ["MCP_ENTRY_JSON"])

# Read existing TOML
try:
    with open(cfg_path, "rb") as f:
        data = tomllib.load(f)
except (FileNotFoundError, tomllib.TOMLDecodeError):
    data = {}

# Merge: set mcp_servers.<name> = cleaned entry
mcp = data.setdefault("mcp_servers", {})
if entry.get("transport") == "stdio":
    server = {
        "command": entry["command"],
        "args":    entry.get("args", []),
    }
    if entry.get("env"):
        server["env"] = entry["env"]
else:
    server = {"url": entry["url"]}
    if entry.get("headers"):
        server["http_headers"] = entry["headers"]

mcp[name] = server

# Manual TOML writer (simple, since our schema is well-defined)
def toml_escape(s: str) -> str:
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

def toml_value(v):
    if isinstance(v, bool):   return "true" if v else "false"
    if isinstance(v, int):    return str(v)
    if isinstance(v, float):  return str(v)
    if isinstance(v, str):    return toml_escape(v)
    if isinstance(v, list):
        return "[" + ", ".join(toml_value(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{ " + ", ".join(f"{k} = {toml_value(val)}" for k, val in v.items()) + " }"
    raise ValueError(f"unsupported TOML type: {type(v)}")

lines = []

# Preserve root-level scalars + [section] tables that are NOT mcp_servers
def emit_table(d, path_prefix=""):
    # Scalars first
    for k, v in d.items():
        if isinstance(v, dict):
            continue
        lines.append(f"{k} = {toml_value(v)}")
    # Tables
    for k, v in d.items():
        if not isinstance(v, dict):
            continue
        new_path = f"{path_prefix}{k}"
        lines.append("")
        lines.append(f"[{new_path}]")
        emit_table(v, new_path + ".")

# Root-level (non-dict keys)
for k, v in data.items():
    if k == "mcp_servers":
        continue
    if isinstance(v, dict):
        continue
    lines.append(f"{k} = {toml_value(v)}")

# Root-level dict-keys (except mcp_servers)
for k, v in data.items():
    if k == "mcp_servers":
        continue
    if not isinstance(v, dict):
        continue
    lines.append("")
    lines.append(f"[{k}]")
    emit_table(v, f"{k}.")

# Finally mcp_servers sections at the end
for server_name, server_cfg in mcp.items():
    lines.append("")
    lines.append(f"[mcp_servers.{server_name}]")
    for k, v in server_cfg.items():
        lines.append(f"{k} = {toml_value(v)}")

with open(cfg_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY_EOF

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
      i=$(( i + 1 ))
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

      # Ausführen und Counter pflegen. Kein "A && B || C" weil (( n++ )) bei n=0
      # unter `set -e` das Script killt (exit-code 1). Stattdessen expliziter if/else.
      local rc=0
      case "$cli" in
        claude) register_claude "$name" "$json" || rc=$? ;;
        cursor) register_cursor "$name" "$json" || rc=$? ;;
        gemini) register_gemini "$name" "$json" || rc=$? ;;
        codex)  register_codex  "$name" "$json" || rc=$? ;;
      esac
      if (( rc == 0 )); then
        registered_total=$(( registered_total + 1 ))
      else
        failed_total=$(( failed_total + 1 ))
      fi
    done <<< "$clis_for_server"

    i=$(( i + 1 ))
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
