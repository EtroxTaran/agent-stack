#!/usr/bin/env bash
# scripts/install-ai-review-pipeline.sh — installiert ai-review-pipeline via pip.
#
# Wird von install.sh aufgerufen, wenn --with-ai-review übergeben wurde.
# Steht auch als standalone-Script zur Verfügung.
#
# Strategie (in dieser Reihenfolge):
#   1. Bereits installiert + Smoke-test OK → skip
#   2. `pip install --user ai-review-pipeline` (published PyPI)
#   3. Fallback: `pip install --user -e ~/projects/ai-review-pipeline` (lokales Dev-Repo)
#   4. Beides schlägt fehl → exit 1
#   Abschluss-Smoke-test: `ai-review --version` muss Exit 0 liefern.
#
# Usage: bash scripts/install-ai-review-pipeline.sh

set -euo pipefail

readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[31m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_DIM=$'\033[2m'

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
_ok() {
    printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"
}

_warn() {
    printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"
}

die() {
    printf '  %s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1" >&2
    exit 1
}

# Stellt sicher, dass das pip --user bin-Verzeichnis im PATH ist.
# Wird vor jedem Versuch, 'ai-review' aufzurufen, genutzt.
_ensure_user_bin_in_path() {
    # Python user base bin (z.B. ~/.local/bin)
    local py_user_bin
    py_user_bin="$(python3 -m site --user-base 2>/dev/null)/bin"
    if [[ -d "${py_user_bin}" ]] && [[ ":${PATH}:" != *":${py_user_bin}:"* ]]; then
        export PATH="${py_user_bin}:${PATH}"
        _warn "PATH erweitert um ${py_user_bin} (dauerhaft: .bashrc / .zshrc anpassen)"
    fi
}

# ---------------------------------------------------------------------------
# 1. pip vorhanden?
# ---------------------------------------------------------------------------
printf '%sChecking pip availability...%s\n' "${C_DIM}" "${C_RESET}"
if command -v pip3 >/dev/null 2>&1; then
    PIP="pip3"
elif command -v pip >/dev/null 2>&1; then
    PIP="pip"
else
    die "pip/pip3 nicht gefunden — installiere Python: apt install python3-pip | brew install python3"
fi
_ok "pip binary: ${PIP} ($(${PIP} --version 2>&1 | head -n1))"

# ---------------------------------------------------------------------------
# 2. Bereits installiert? Wenn ja + Smoke-test OK → frühzeitig raus
# ---------------------------------------------------------------------------
printf '\n%sChecking existing installation...%s\n' "${C_DIM}" "${C_RESET}"
if ${PIP} show ai-review-pipeline >/dev/null 2>&1; then
    INSTALLED_VERSION="$(${PIP} show ai-review-pipeline 2>/dev/null | awk '/^Version:/{print $2}')"
    _ok "ai-review-pipeline bereits installiert (Version ${INSTALLED_VERSION})"
    _ensure_user_bin_in_path
    if command -v ai-review >/dev/null 2>&1 && ai-review --version >/dev/null 2>&1; then
        AI_REVIEW_VERSION="$(ai-review --version 2>&1 | head -n1)"
        _ok "smoke-test bestanden: ${AI_REVIEW_VERSION} — kein Re-Install notwendig"
        exit 0
    else
        _warn "ai-review bereits via pip installiert, aber Binary nicht im PATH — versuche Re-Install"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Versuche PyPI-Install
# ---------------------------------------------------------------------------
printf '\n%sInstalling ai-review-pipeline from PyPI...%s\n' "${C_DIM}" "${C_RESET}"
PYPI_SUCCESS=false
if ${PIP} install --user ai-review-pipeline 2>/dev/null; then
    PYPI_SUCCESS=true
    _ok "pip install --user ai-review-pipeline erfolgreich"
else
    _warn "PyPI-Install fehlgeschlagen (Paket möglicherweise noch nicht veröffentlicht)"
fi

# ---------------------------------------------------------------------------
# 4. Fallback: lokales Dev-Repo
# ---------------------------------------------------------------------------
LOCAL_REPO="${HOME}/projects/ai-review-pipeline"
if [[ "${PYPI_SUCCESS}" == "false" ]]; then
    printf '\n%sFallback: lokales Dev-Repo...%s\n' "${C_DIM}" "${C_RESET}"
    if [[ -d "${LOCAL_REPO}" ]] && git -C "${LOCAL_REPO}" rev-parse --git-dir >/dev/null 2>&1; then
        _ok "lokales Repo gefunden: ${LOCAL_REPO}"
        if ${PIP} install --user -e "${LOCAL_REPO}"; then
            _ok "pip install --user -e ${LOCAL_REPO} erfolgreich (editable/dev-mode)"
        else
            die "Sowohl PyPI-Install als auch lokaler Dev-Install fehlgeschlagen. Prüfe pip-Ausgabe oben."
        fi
    else
        die "PyPI-Install fehlgeschlagen und kein lokales Repo unter ${LOCAL_REPO} gefunden. Entweder Paket publishen oder Repo klonen: git clone https://github.com/EtroxTaran/ai-review-pipeline ${LOCAL_REPO}"
    fi
fi

# ---------------------------------------------------------------------------
# 5. PATH sicherstellen + abschließender Smoke-test
# ---------------------------------------------------------------------------
printf '\n%sSmoke-test...%s\n' "${C_DIM}" "${C_RESET}"
_ensure_user_bin_in_path

if ! command -v ai-review >/dev/null 2>&1; then
    die "ai-review Binary nach Installation nicht im PATH. Füge dauerhaft hinzu: export PATH=\"\$(python3 -m site --user-base)/bin:\$PATH\""
fi

if ai-review --version >/dev/null 2>&1; then
    AI_REVIEW_VERSION="$(ai-review --version 2>&1 | head -n1)"
    _ok "smoke-test bestanden: ${AI_REVIEW_VERSION}"
else
    die "ai-review --version fehlgeschlagen — Installation defekt. Versuche: ${PIP} install --user --force-reinstall ai-review-pipeline"
fi

printf '\n%s✓ ai-review-pipeline installation complete%s\n' "${C_GREEN}" "${C_RESET}"
