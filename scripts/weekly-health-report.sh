#!/usr/bin/env bash
# scripts/weekly-health-report.sh
#
# Erzeugt einen JSON-Gesundheits-Report über den agent-stack:
#   · preflight.sh + verify.sh Exit-Codes
#   · MCP-Server-Reachability (aus mcp/servers.yaml)
#   · Skill-Eval-Coverage (wieviele Skills haben evals/evals.json)
#   · CLI-Version-Drift (claude, codex, cursor-agent, gemini)
#   · Drift-Guard Exit (check-docs-model-pins.sh)
#   · Dependency-Age (package.json + pyproject.toml, älter 90/180 Tage?)
#
# Output: JSON-Report auf stdout. Exit 0 auch bei Findings (informational).
# Consumer: weekly-health-report.py rendert den JSON in einen Discord-Embed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

# Bash assoziative Arrays für strukturiertes JSON-Compose
declare -A RESULTS
FINDINGS=()

add_finding() {
    FINDINGS+=("$1")
}

# --- 1. preflight.sh ------------------------------------------------------
if [[ -x "${REPO_ROOT}/scripts/preflight.sh" ]]; then
    if "${REPO_ROOT}/scripts/preflight.sh" > /dev/null 2>&1; then
        RESULTS[preflight]="pass"
    else
        RESULTS[preflight]="fail"
        add_finding "preflight.sh exit != 0"
    fi
else
    RESULTS[preflight]="missing"
    add_finding "preflight.sh fehlt oder nicht executable"
fi

# --- 2. verify.sh ---------------------------------------------------------
if [[ -x "${REPO_ROOT}/scripts/verify.sh" ]]; then
    if "${REPO_ROOT}/scripts/verify.sh" > /dev/null 2>&1; then
        RESULTS[verify]="pass"
    else
        RESULTS[verify]="fail"
        add_finding "verify.sh exit != 0 (z.B. Skills nicht symlinkt)"
    fi
else
    RESULTS[verify]="missing"
    add_finding "verify.sh fehlt"
fi

# --- 3. Drift-Guard -------------------------------------------------------
if [[ -x "${REPO_ROOT}/scripts/check-docs-model-pins.sh" ]]; then
    if "${REPO_ROOT}/scripts/check-docs-model-pins.sh" > /dev/null 2>&1; then
        RESULTS[drift_guard]="pass"
    else
        RESULTS[drift_guard]="fail"
        add_finding "check-docs-model-pins.sh zeigt Drift"
    fi
else
    RESULTS[drift_guard]="missing"
fi

# --- 4. MCP-Server-Reachability (aus servers.yaml) ------------------------
# Nur HTTP-Transports sind reachability-checkbar. stdio-MCP-Server brauchen npx etc.
MCP_OK=0
MCP_FAIL=0
if [[ -f "${REPO_ROOT}/mcp/servers.yaml" ]] && command -v python3 > /dev/null 2>&1; then
    while IFS=$'\t' read -r name url; do
        [[ -z "$name" ]] && continue
        if curl -sfL --max-time 5 -o /dev/null "$url" 2> /dev/null; then
            MCP_OK=$((MCP_OK + 1))
        else
            MCP_FAIL=$((MCP_FAIL + 1))
            add_finding "mcp.${name}.unreachable (${url})"
        fi
    done < <(python3 -c "
import yaml, sys
try:
    cfg = yaml.safe_load(open('${REPO_ROOT}/mcp/servers.yaml'))
    for s in cfg.get('servers', []):
        if s.get('transport') == 'http' and s.get('url'):
            print(f\"{s['name']}\t{s['url']}\")
except Exception as e:
    print(f'# error: {e}', file=sys.stderr)
" 2> /dev/null)
fi
RESULTS[mcp_http_ok]="$MCP_OK"
RESULTS[mcp_http_fail]="$MCP_FAIL"

# --- 5. Skill-Eval-Coverage -----------------------------------------------
SKILLS_TOTAL=0
SKILLS_WITH_EVALS=0
if [[ -d "${REPO_ROOT}/skills" ]]; then
    for skill_dir in "${REPO_ROOT}"/skills/*/; do
        name="$(basename "$skill_dir")"
        [[ "$name" == _* ]] && continue
        SKILLS_TOTAL=$((SKILLS_TOTAL + 1))
        if [[ -f "${skill_dir}evals/evals.json" ]]; then
            SKILLS_WITH_EVALS=$((SKILLS_WITH_EVALS + 1))
        fi
    done
fi
RESULTS[skills_total]="$SKILLS_TOTAL"
RESULTS[skills_with_evals]="$SKILLS_WITH_EVALS"
if [[ "$SKILLS_TOTAL" -gt 0 && "$SKILLS_WITH_EVALS" -lt "$SKILLS_TOTAL" ]]; then
    add_finding "skill_eval_coverage: ${SKILLS_WITH_EVALS}/${SKILLS_TOTAL}"
fi

# --- 6. CLI-Installed-Check -----------------------------------------------
for cli in claude codex cursor-agent gemini; do
    if command -v "$cli" > /dev/null 2>&1; then
        RESULTS[cli_$cli]="installed"
    else
        RESULTS[cli_$cli]="missing"
        add_finding "cli.${cli}.missing"
    fi
done

# --- 7. Aktuelles git-HEAD ------------------------------------------------
if GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2> /dev/null)"; then
    RESULTS[git_head]="$GIT_SHA"
fi
if GIT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2> /dev/null)"; then
    RESULTS[git_branch]="$GIT_BRANCH"
fi

# --- JSON ausgeben --------------------------------------------------------
python3 <<PYEOF
import json
results = {}
PYEOF

# Pure-Bash JSON-Compose (kein jq required — portable, einfach)
printf '{\n'
printf '  "timestamp_utc": "%s",\n' "$(date -u +%FT%TZ)"
printf '  "repo": "agent-stack",\n'

first=1
for key in "${!RESULTS[@]}"; do
    [[ $first -eq 1 ]] && first=0 || printf ',\n'
    printf '  "%s": "%s"' "$key" "${RESULTS[$key]}"
done

if [[ ${#FINDINGS[@]} -gt 0 ]]; then
    printf ',\n  "findings": [\n'
    for i in "${!FINDINGS[@]}"; do
        [[ $i -gt 0 ]] && printf ',\n'
        printf '    "%s"' "${FINDINGS[$i]}"
    done
    printf '\n  ]'
    printf ',\n  "status": "findings"'
else
    printf ',\n  "findings": []'
    printf ',\n  "status": "green"'
fi
printf '\n}\n'

# Exit 0 auch bei Findings — Report ist informativ, nicht blockierend
exit 0
