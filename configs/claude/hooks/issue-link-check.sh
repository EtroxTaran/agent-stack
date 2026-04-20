#!/usr/bin/env bash
# issue-link-check.sh — PreToolUse hook for Edit|Write
# Warnt (ohne zu blocken), wenn Schreibarbeit außerhalb eines Issue-Branches läuft.
# Persistiert die Issue-Nummer nach .git/.current-issue wenn Branch-Pattern matcht.

set -u  # kein -e: Warn-Hook darf nie harte Fehler werfen

INPUT="$(cat)"

# Außerhalb eines Git-Repos → nichts zu tun
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || echo '')"
if [[ -z "${GIT_DIR}" ]]; then
  exit 0
fi

BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo '')"
if [[ -z "${BRANCH}" ]]; then
  exit 0
fi

# Auf Default-Branches keine Issue-Pflicht
case "${BRANCH}" in
  main|master|develop|trunk)
    exit 0
    ;;
esac

# Pattern: feat/<slug>-issue-<N>  oder  fix/<slug>-issue-<N>
ISSUE_RE='^(feat|fix)/.+-issue-([0-9]+)$'

if [[ "${BRANCH}" =~ ${ISSUE_RE} ]]; then
  ISSUE_NUM="${BASH_REMATCH[2]}"
  printf '%s\n' "${ISSUE_NUM}" > "${GIT_DIR}/.current-issue" 2>/dev/null || true
  exit 0
fi

# Warn, don't block
printf 'issue-link-check: branch "%s" has no issue-<N> suffix — consider feat/<slug>-issue-<N>\n' \
  "${BRANCH}" >&2

exit 0
