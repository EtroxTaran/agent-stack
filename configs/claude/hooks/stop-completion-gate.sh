#!/usr/bin/env bash
# stop-completion-gate.sh — Stop hook
# Ruft das projekt-übergreifende completion-gate.sh auf, falls vorhanden.
# Silent-skip wenn Gate fehlt. Darf Session-Stop nie blocken (immer exit 0).

set -u

GATE="${HOME}/.openclaw/workspace/scripts/completion-gate.sh"

if [[ -x "${GATE}" ]]; then
  "${GATE}" "$(pwd)" >&2 || true
fi

exit 0
