#!/usr/bin/env bash
# scripts/verify.sh — Post-install sanity checks.
#
# Checkt:
#   · Alle Pflicht-Symlinks existieren und zeigen ins agent-stack Repo
#   · MCP-Server sind pro CLI registriert (so weit automatisch checkbar)
#   · Alle Skill-Verzeichnisse erreichbar
#
# Exit 0 bei Pass, Exit 1 bei irgendwelchen Fails.

set -euo pipefail

readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[31m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_DIM=$'\033[2m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
WARN=0

_pass() {
    printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"
    PASS=$((PASS + 1))
}

_fail() {
    printf '  %s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1" >&2
    FAIL=$((FAIL + 1))
}

_warn() {
    printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"
    WARN=$((WARN + 1))
}

# ---------------------------------------------------------------------------
# 1. Symlink-Checks
# ---------------------------------------------------------------------------
printf '%sSymlink targets → agent-stack repo%s\n' "${C_DIM}" "${C_RESET}"

# format: "link_path:expected_target_relative_to_repo"
# NOTE: Nur statische Dateien sind symlinked. Live-mutable Configs (cursor/cli-config,
# gemini/settings.json, codex/config.toml) sind lokale Kopien — separat geprüft.
SYMLINK_CHECKS=(
    "${HOME}/.claude/CLAUDE.md:AGENTS.md"
    "${HOME}/.claude/settings.json:configs/claude/settings.json"
    "${HOME}/.claude/hooks:configs/claude/hooks"
    "${HOME}/.claude/skills/code-review-expert:skills/code-review-expert"
    "${HOME}/.claude/skills/issue-pickup:skills/issue-pickup"
    "${HOME}/.claude/skills/pr-open:skills/pr-open"
    "${HOME}/.claude/skills/review-gate:skills/review-gate"
    "${HOME}/.cursor/AGENTS.md:AGENTS.md"
    "${HOME}/.cursor/rules/global.mdc:configs/cursor/rules/global.mdc"
    "${HOME}/.cursor/skills/code-review-expert:skills/code-review-expert"
    "${HOME}/.cursor/skills/issue-pickup:skills/issue-pickup"
    "${HOME}/.cursor/skills/pr-open:skills/pr-open"
    "${HOME}/.cursor/skills/review-gate:skills/review-gate"
    "${HOME}/.gemini/GEMINI.md:AGENTS.md"
    "${HOME}/.gemini/skills/code-review-expert:skills/code-review-expert"
    "${HOME}/.gemini/skills/issue-pickup:skills/issue-pickup"
    "${HOME}/.gemini/skills/pr-open:skills/pr-open"
    "${HOME}/.gemini/skills/review-gate:skills/review-gate"
    "${HOME}/.codex/AGENTS.md:AGENTS.md"
    "${HOME}/.codex/skills/code-review-expert:skills/code-review-expert"
    "${HOME}/.codex/skills/issue-pickup:skills/issue-pickup"
    "${HOME}/.codex/skills/pr-open:skills/pr-open"
    "${HOME}/.codex/skills/review-gate:skills/review-gate"
)

# Live-mutable Configs: existieren als reale Datei (KEIN Symlink), werden von
# register.sh in-place mutiert. Nur Existenz-Check.
LOCAL_COPY_CHECKS=(
    "${HOME}/.cursor/cli-config.json"
    "${HOME}/.gemini/settings.json"
    "${HOME}/.codex/config.toml"
)

for entry in "${SYMLINK_CHECKS[@]}"; do
    link_path="${entry%%:*}"
    expected_rel="${entry#*:}"
    expected_abs="${REPO_ROOT}/${expected_rel}"

    if [[ ! -L "${link_path}" ]]; then
        _fail "not a symlink: ${link_path}"
        continue
    fi

    actual_target="$(readlink "${link_path}")"
    # readlink kann relativ oder absolut sein; kanonisieren.
    if [[ "${actual_target}" != /* ]]; then
        actual_target="$(cd "$(dirname "${link_path}")" && cd "$(dirname "${actual_target}")" && pwd)/$(basename "${actual_target}")"
    fi

    # Vergleich über Realpath (folgt intermediate links)
    if [[ "$(realpath -m "${actual_target}" 2>/dev/null || echo "${actual_target}")" == "$(realpath -m "${expected_abs}" 2>/dev/null || echo "${expected_abs}")" ]]; then
        _pass "${link_path}"
    else
        _fail "wrong target: ${link_path} → ${actual_target} (expected ${expected_abs})"
    fi
done

printf '\n%sLocal mutable configs (non-symlinked)%s\n' "${C_DIM}" "${C_RESET}"
for f in "${LOCAL_COPY_CHECKS[@]}"; do
    if [[ -f "$f" && ! -L "$f" ]]; then
        _pass "${f}"
    elif [[ -L "$f" ]]; then
        _fail "unexpected symlink (must be local file): ${f}"
    else
        _fail "missing: ${f}"
    fi
done

# ---------------------------------------------------------------------------
# 2. MCP-Server-Checks
# ---------------------------------------------------------------------------
printf '\n%sMCP server registrations%s\n' "${C_DIM}" "${C_RESET}"

# Claude
if command -v claude >/dev/null 2>&1; then
    if claude_mcp_out="$(claude mcp list 2>/dev/null)"; then
        for srv in github context7 filesystem; do
            if printf '%s' "${claude_mcp_out}" | grep -qi "${srv}"; then
                _pass "claude mcp: ${srv}"
            else
                _fail "claude mcp missing: ${srv}"
            fi
        done
    else
        _warn "claude mcp list failed — skipping claude checks"
    fi
else
    _warn "claude CLI not installed — skipping"
fi

# Cursor
if command -v cursor-agent >/dev/null 2>&1; then
    if cursor_mcp_out="$(cursor-agent mcp list 2>/dev/null)" && [[ -n "${cursor_mcp_out}" ]]; then
        if printf '%s' "${cursor_mcp_out}" | grep -qi "github"; then
            _pass "cursor-agent mcp: github"
        else
            _fail "cursor-agent mcp missing: github"
        fi
    elif [[ -f "${HOME}/.cursor/mcp.json" ]]; then
        # Fallback: grep in der Config-Datei
        if grep -q '"github"' "${HOME}/.cursor/mcp.json" 2>/dev/null; then
            _pass "cursor mcp.json has github"
        else
            _fail "cursor mcp.json missing github"
        fi
    else
        _warn "cursor-agent mcp list and ~/.cursor/mcp.json both unavailable"
    fi
else
    _warn "cursor-agent CLI not installed — skipping"
fi

# Codex
CODEX_CONFIG="${HOME}/.codex/config.toml"
if [[ -f "${CODEX_CONFIG}" ]]; then
    if grep -q '^\[mcp_servers\.github\]' "${CODEX_CONFIG}"; then
        _pass "codex config.toml has [mcp_servers.github]"
    else
        _fail "codex config.toml missing [mcp_servers.github] section"
    fi
else
    _fail "codex config.toml missing at ${CODEX_CONFIG}"
fi

# Gemini
GEMINI_SETTINGS="${HOME}/.gemini/settings.json"
if [[ -f "${GEMINI_SETTINGS}" ]]; then
    if command -v jq >/dev/null 2>&1; then
        if jq -e '.mcpServers.github' "${GEMINI_SETTINGS}" >/dev/null 2>&1; then
            _pass "gemini settings.json has mcpServers.github"
        else
            _fail "gemini settings.json missing mcpServers.github"
        fi
    else
        _warn "jq not available — can't deep-check gemini settings.json"
    fi
else
    _fail "gemini settings.json missing at ${GEMINI_SETTINGS}"
fi

# ---------------------------------------------------------------------------
# 3. Skill-Directories erreichbar
# ---------------------------------------------------------------------------
printf '\n%sSkill directories reachable across CLIs%s\n' "${C_DIM}" "${C_RESET}"

SKILLS=(code-review-expert issue-pickup pr-open review-gate)
CLI_DIRS=(".claude" ".cursor" ".gemini" ".codex")

for cli_dir in "${CLI_DIRS[@]}"; do
    for skill in "${SKILLS[@]}"; do
        path="${HOME}/${cli_dir}/skills/${skill}/SKILL.md"
        if [[ -r "${path}" ]]; then
            _pass "${cli_dir}/skills/${skill}/SKILL.md"
        else
            _fail "missing: ${path}"
        fi
    done
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
printf '\n%s─────────────────────────────────────────%s\n' "${C_DIM}" "${C_RESET}"
printf '%sVerify results:%s %s%d pass%s · %s%d fail%s · %s%d warn%s\n' \
    "${C_DIM}" "${C_RESET}" \
    "${C_GREEN}" "${PASS}" "${C_RESET}" \
    "${C_RED}"   "${FAIL}" "${C_RESET}" \
    "${C_YELLOW}" "${WARN}" "${C_RESET}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
