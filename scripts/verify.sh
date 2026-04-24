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
#
# Skills-Pfad-Strategie (siehe install.conf.yaml):
# - ~/.agents/skills/<name>     → Primär-SoT für Codex + Gemini (offizielle Discovery-Pfade)
# - ~/.claude/skills/<name>     → redundanter Claude-spezifischer Pfad
# - ~/.cursor/skills/           → nicht mehr angelegt (Cursor hat keinen nativen Support,
#                                  MCP-Bridge als Follow-up — siehe #25)
# - ~/.codex/skills/            → nicht mehr angelegt (Codex nutzt ~/.agents/skills/)
SKILLS=(
    ac-validate
    ac-waiver
    code-review-expert
    design-review
    issue-pickup
    nachfrage-respond
    pr-open
    release-checklist
    review-gate
    security-audit
    security-waiver
    tdd-guard
)

SYMLINK_CHECKS=(
    "${HOME}/.claude/CLAUDE.md:AGENTS.md"
    "${HOME}/.claude/settings.json:configs/claude/settings.json"
    "${HOME}/.claude/hooks:configs/claude/hooks"
    "${HOME}/.cursor/AGENTS.md:AGENTS.md"
    "${HOME}/.cursor/rules/global.mdc:configs/cursor/rules/global.mdc"
    "${HOME}/.gemini/GEMINI.md:AGENTS.md"
    "${HOME}/.codex/AGENTS.md:AGENTS.md"
)

# Skill-Symlinks dynamisch aus der Liste generieren
for skill in "${SKILLS[@]}"; do
    SYMLINK_CHECKS+=("${HOME}/.agents/skills/${skill}:skills/${skill}")
    SYMLINK_CHECKS+=("${HOME}/.claude/skills/${skill}:skills/${skill}")
done

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
printf '\n%sSkill directories reachable (primary %s~/.agents/skills%s + Claude)%s\n' \
    "${C_DIM}" "${C_RESET}" "${C_DIM}" "${C_RESET}"

# Alle 12 Skills müssen in ~/.agents/skills/ (primary) UND ~/.claude/skills/ (redundant) da sein.
# Cursor + Gemini + Codex erreichen sie über ~/.agents/skills/ (nativ) oder via eigenen Fallback.
for skill in "${SKILLS[@]}"; do
    for base in ".agents" ".claude"; do
        path="${HOME}/${base}/skills/${skill}/SKILL.md"
        if [[ -r "${path}" ]]; then
            _pass "${base}/skills/${skill}/SKILL.md"
        else
            _fail "missing: ${path}"
        fi
    done
done

# Cursor: dokumentierter Gap — keine nativen Skills, siehe Follow-up-Issue
if [[ -d "${HOME}/.cursor/skills" ]]; then
    _warn "\${HOME}/.cursor/skills existiert noch (legacy) — kann bei Bedarf entfernt werden"
fi
# Codex: nicht mehr an ${HOME}/.codex/skills/, sondern ${HOME}/.agents/skills/
if [[ -d "${HOME}/.codex/skills" ]]; then
    _warn "\${HOME}/.codex/skills existiert noch (legacy) — Codex nutzt \${HOME}/.agents/skills/"
fi

# ---------------------------------------------------------------------------
# 4. ai-review-pipeline (optional Integration)
# ---------------------------------------------------------------------------
printf '\n%sai-review-pipeline (optional)%s\n' "${C_DIM}" "${C_RESET}"

if command -v ai-review >/dev/null 2>&1; then
    aireview_version_out="$(ai-review --version 2>&1)" || aireview_version_out=""
    if [[ -n "${aireview_version_out}" ]]; then
        _pass "ai-review-pipeline installiert: ${aireview_version_out}"
    else
        _warn "ai-review binary gefunden, aber --version schlägt fehl — Installation möglicherweise defekt"
    fi
else
    printf '  %s·%s ai-review-pipeline: nicht installiert\n' "${C_DIM}" "${C_RESET}"
    printf '  %s·%s Fuer optionale Integration: ./install.sh --with-ai-review\n' "${C_DIM}" "${C_RESET}"
fi

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
