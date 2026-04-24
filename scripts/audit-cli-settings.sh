#!/usr/bin/env bash
# audit-cli-settings.sh — Config-Drift-Check gegen BASELINE.assertions.json.
#
# Wird von update-clis.sh am Ende aufgerufen. Kann auch standalone laufen.
# Meldet nur — ändert nie Configs.
#
# Exit-Code:
#   0  alles grün
#   1  Drift gefunden
#   2  Baseline-Datei kaputt oder Config-Datei fehlt
#
# Usage:
#   audit-cli-settings.sh              # Human-readable
#   audit-cli-settings.sh --json       # Machine-readable
#   audit-cli-settings.sh --release-notes  # Inkl. GitHub-Release-Scraping

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_JSON="${REPO_ROOT}/configs/BASELINE.assertions.json"

OUTPUT_JSON=false
CHECK_RELEASES=false
for arg in "$@"; do
    case "$arg" in
        --json) OUTPUT_JSON=true ;;
        --release-notes) CHECK_RELEASES=true ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    esac
done

if [[ ! -f "$BASELINE_JSON" ]]; then
    echo "ERROR: Baseline $BASELINE_JSON fehlt." >&2
    exit 2
fi

# Sammelt Drift-Befunde. Format: "<cli>|<severity>|<message>".
# severity: ok | warn | error
declare -a FINDINGS=()

_finding() {
    FINDINGS+=("$1|$2|$3")
}

# JSON-Key-Check via jq. Key-Pfad ist ein jq-Ausdruck (mit führendem Punkt).
_jq_key_exists() {
    local file="$1" key="$2"
    jq -e "$key != null" "$file" >/dev/null 2>&1
}

_jq_get_value() {
    local file="$1" key="$2"
    jq -r "$key // empty" "$file" 2>/dev/null
}

_check_json_config() {
    local cli="$1" file_rel
    file_rel=$(jq -r ".${cli}.file" "$BASELINE_JSON")
    local file_abs="${REPO_ROOT}/${file_rel}"

    if [[ ! -f "$file_abs" ]]; then
        _finding "$cli" "error" "Config-Datei fehlt: ${file_rel}"
        return
    fi

    # Alle required_keys prüfen
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if ! _jq_key_exists "$file_abs" "$key"; then
            _finding "$cli" "warn" "Fehlender Key: ${key}"
        fi
    done < <(jq -r ".${cli}.required_keys[]?" "$BASELINE_JSON")

    # expected_values prüfen (tolerant bei Typen: jq vergleicht als String)
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local expected actual
        expected=$(jq -r ".${cli}.expected_values[\"${key}\"]" "$BASELINE_JSON")
        actual=$(_jq_get_value "$file_abs" "$key")
        if [[ "$actual" != "$expected" ]]; then
            _finding "$cli" "warn" "Wert-Drift ${key}: soll='${expected}' ist='${actual:-<missing>}'"
        fi
    done < <(jq -r ".${cli}.expected_values | keys[]?" "$BASELINE_JSON")

    # Claude: required_deny_patterns
    if [[ "$cli" == "claude" ]]; then
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            if ! jq -e --arg p "$pattern" '.permissions.deny | index($p)' "$file_abs" >/dev/null 2>&1; then
                _finding "$cli" "warn" "Fehlendes Deny-Pattern: ${pattern}"
            fi
        done < <(jq -r '.claude.required_deny_patterns[]?' "$BASELINE_JSON")
    fi
}

# Codex nutzt TOML — mini-parser via python3.
_check_toml_config() {
    local cli="$1" file_rel file_abs
    file_rel=$(jq -r ".${cli}.file" "$BASELINE_JSON")
    file_abs="${REPO_ROOT}/${file_rel}"

    if [[ ! -f "$file_abs" ]]; then
        _finding "$cli" "error" "Config-Datei fehlt: ${file_rel}"
        return
    fi

    # Required-Keys-Check. TOML-Keys sind dotted paths wie model.name.
    local required expected
    required=$(jq -r ".${cli}.required_keys[]?" "$BASELINE_JSON")
    expected=$(jq -r ".${cli}.expected_values | to_entries[] | \"\(.key)=\(.value)\"" "$BASELINE_JSON")

    local py_out
    py_out=$(python3 - "$file_abs" "$required" "$expected" <<'PY'
import sys, tomllib, pathlib
path = pathlib.Path(sys.argv[1])
required = [k for k in sys.argv[2].splitlines() if k.strip()]
expected = {}
for line in sys.argv[3].splitlines():
    if not line.strip():
        continue
    k, _, v = line.partition("=")
    expected[k] = v

data = tomllib.loads(path.read_text())

def lookup(d, key):
    cur = d
    for part in key.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur

for k in required:
    if lookup(data, k) is None:
        print(f"MISSING|{k}")

for k, want in expected.items():
    actual = lookup(data, k)
    actual_str = str(actual) if actual is not None else ""
    if actual_str != want:
        print(f"DRIFT|{k}|{want}|{actual_str}")
PY
)

    while IFS='|' read -r kind rest1 rest2 rest3; do
        [[ -z "$kind" ]] && continue
        case "$kind" in
            MISSING) _finding "$cli" "warn" "Fehlender Key: ${rest1}" ;;
            DRIFT)   _finding "$cli" "warn" "Wert-Drift ${rest1}: soll='${rest2}' ist='${rest3:-<missing>}'" ;;
        esac
    done <<<"$py_out"
}

# Cross-Check: CLI-Config-Modelle vs. MODEL_REGISTRY.md.
# Ließt die registry_key=value Zeilen und vergleicht mit dem tatsächlichen
# Modell-Wert aus der jeweiligen Config. Claude/Cursor sind bewusst nicht
# gemappt (siehe BASELINE.assertions.json).
_check_model_registry() {
    local registry_path
    registry_path=$(jq -r '.model_registry.path' "$BASELINE_JSON")
    # Tilde expandieren
    registry_path="${registry_path/#\~/$HOME}"
    if [[ ! -f "$registry_path" ]]; then
        _finding "registry" "warn" "MODEL_REGISTRY.md fehlt unter ${registry_path}"
        return
    fi

    # Registry-Alter checken (stale >14d = warn)
    local age_days
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$registry_path") ) / 86400 ))
    if [[ $age_days -gt 14 ]]; then
        _finding "registry" "warn" "MODEL_REGISTRY.md ist ${age_days}d alt — run model-version-check.py --apply"
    fi

    local mapping_count
    mapping_count=$(jq '.model_registry.mappings | length' "$BASELINE_JSON")
    local i=0
    while [[ $i -lt $mapping_count ]]; do
        local cli config_file config_type config_key registry_key
        cli=$(jq -r ".model_registry.mappings[$i].cli" "$BASELINE_JSON")
        config_file=$(jq -r ".model_registry.mappings[$i].config_file" "$BASELINE_JSON")
        config_type=$(jq -r ".model_registry.mappings[$i].config_type" "$BASELINE_JSON")
        config_key=$(jq -r ".model_registry.mappings[$i].config_key" "$BASELINE_JSON")
        registry_key=$(jq -r ".model_registry.mappings[$i].registry_key" "$BASELINE_JSON")
        i=$((i + 1))

        # Registry-Wert parsen. Format: KEY=value oder KEY=vendor/value
        local registry_value
        registry_value=$(grep -E "^${registry_key}=" "$registry_path" | head -n1 | cut -d= -f2- | tr -d '"')
        registry_value="${registry_value##*/}"  # vendor-prefix strippen (anthropic/claude-… → claude-…)
        if [[ -z "$registry_value" ]]; then
            _finding "$cli" "warn" "Registry-Key ${registry_key} nicht in MODEL_REGISTRY.md"
            continue
        fi

        # Config-Wert lesen
        local config_abs="${REPO_ROOT}/${config_file}"
        if [[ ! -f "$config_abs" ]]; then
            # Wurde bereits von _check_*_config als error gemeldet — skip hier.
            continue
        fi
        local config_value=""
        if [[ "$config_type" == "json" ]]; then
            config_value=$(_jq_get_value "$config_abs" "$config_key" || true)
        elif [[ "$config_type" == "toml" ]]; then
            config_value=$(python3 - "$config_abs" "$config_key" <<'PY'
import sys, tomllib, pathlib
data = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
cur = data
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        print("")
        sys.exit(0)
    cur = cur[part]
print(cur if cur is not None else "")
PY
)
        fi

        if [[ "$config_value" == "$registry_value" ]]; then
            continue
        fi
        # Soft-Match: Config nutzt Alias (z.B. "gpt-5"), Registry hat Spezifik ("gpt-5.3-codex")
        if [[ -n "$config_value" && "$registry_value" == "$config_value"* ]]; then
            _finding "$cli" "warn" "Modell-Alias ${config_key}: Config='${config_value}' Registry='${registry_value}' (spezifischer Wert empfohlen)"
        else
            _finding "$cli" "warn" "Modell-Drift ${config_key}: Config='${config_value:-<missing>}' Registry='${registry_value}'"
        fi
    done
}

# ---- Haupt-Audit-Pass ----
_check_json_config claude
_check_json_config cursor
_check_json_config gemini
_check_toml_config codex
_check_model_registry

# ---- Release-Notes-Scraping (best-effort) ----
declare -a RELEASE_NOTES=()
if $CHECK_RELEASES && command -v gh >/dev/null 2>&1; then
    for cli in claude cursor gemini codex; do
        repo=$(jq -r ".release_notes.${cli}" "$BASELINE_JSON")
        [[ "$repo" == "null" || -z "$repo" ]] && continue
        # Silently skip wenn kein Zugriff / Rate-Limit.
        latest=$(gh api "repos/${repo}/releases/latest" --jq '{tag: .tag_name, body: .body}' 2>/dev/null || true)
        if [[ -n "$latest" && "$latest" != "null" ]]; then
            tag=$(jq -r '.tag' <<<"$latest")
            # Grep in Release-Body nach Settings-relevanten Keywords
            hits=$(jq -r '.body' <<<"$latest" | grep -iE '\b(setting|config|env|flag|option|permission|hook)\b' | head -3 || true)
            if [[ -n "$hits" ]]; then
                RELEASE_NOTES+=("${cli} ${tag}: $(echo "$hits" | head -1 | sed 's/[[:space:]]\+/ /g' | cut -c1-120)")
            fi
        fi
    done
fi

# ---- Output ----
DRIFT_COUNT=0
ERROR_COUNT=0
for f in "${FINDINGS[@]-}"; do
    [[ -z "$f" ]] && continue
    sev="${f#*|}"; sev="${sev%%|*}"
    [[ "$sev" == "warn" ]] && DRIFT_COUNT=$((DRIFT_COUNT + 1))
    [[ "$sev" == "error" ]] && ERROR_COUNT=$((ERROR_COUNT + 1))
done

if $OUTPUT_JSON; then
    printf '{\n  "findings": [\n'
    first=true
    for f in "${FINDINGS[@]-}"; do
        [[ -z "$f" ]] && continue
        cli="${f%%|*}"; rest="${f#*|}"; sev="${rest%%|*}"; msg="${rest#*|}"
        $first || printf ',\n'
        first=false
        # Escape Quotes im msg
        msg_esc=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '    {"cli": "%s", "severity": "%s", "message": "%s"}' "$cli" "$sev" "$msg_esc"
    done
    printf '\n  ],\n  "release_notes": [\n'
    first=true
    for n in "${RELEASE_NOTES[@]-}"; do
        [[ -z "$n" ]] && continue
        $first || printf ',\n'
        first=false
        n_esc=$(printf '%s' "$n" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '    "%s"' "$n_esc"
    done
    printf '\n  ],\n  "drift_count": %d,\n  "error_count": %d\n}\n' "$DRIFT_COUNT" "$ERROR_COUNT"
else
    if [[ $DRIFT_COUNT -eq 0 && $ERROR_COUNT -eq 0 ]]; then
        echo "✓ Keine Drift gefunden. Alle vier CLI-Configs matchen BASELINE."
    else
        echo "Config-Drift (${DRIFT_COUNT} warn, ${ERROR_COUNT} error):"
        for f in "${FINDINGS[@]-}"; do
            [[ -z "$f" ]] && continue
            cli="${f%%|*}"; rest="${f#*|}"; sev="${rest%%|*}"; msg="${rest#*|}"
            icon="⚠"
            [[ "$sev" == "error" ]] && icon="✗"
            printf '  %s [%-6s] %s\n' "$icon" "$cli" "$msg"
        done
    fi
    if [[ ${#RELEASE_NOTES[@]} -gt 0 ]]; then
        echo
        echo "Neue Release-Notes (potenzielle Settings):"
        for n in "${RELEASE_NOTES[@]}"; do
            printf '  • %s\n' "$n"
        done
    fi
fi

if [[ $ERROR_COUNT -gt 0 ]]; then
    exit 2
elif [[ $DRIFT_COUNT -gt 0 ]]; then
    exit 1
else
    exit 0
fi
