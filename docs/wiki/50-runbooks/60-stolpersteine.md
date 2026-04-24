# Stolpersteine — Die aggregierte Liste

> **TL;DR:** Eine kompakte Liste aller historisch aufgetretenen Fallen beim Betrieb der AI-Review-Toolchain. Jeder Eintrag hat ein kurzes "Symptom → Ursache → Fix"-Triptychon. Diese Liste ist der erste Ort, wo man bei einem unbekannten Problem schaut — oft reichen 2 Sätze hier um zu verstehen, was grade schief läuft. Für detaillierte Runbooks verlinken wir auf die passenden Seiten.

## Wie es funktioniert

Jeder Stolperstein ist einmal aufgetreten, wurde analysiert, gefixt, und hier dokumentiert. Die Reihenfolge folgt grob der Häufigkeit — häufigste Fallen oben. Wenn du ein unbekanntes Symptom siehst, scrolle hier durch; meistens ist es schon mal jemand anderem passiert.

## Die Stolpersteine

### 1. n8n SQLite-Korruption

**Symptom:** `SQLITE_CORRUPT: database disk image is malformed` im n8n-Log
**Ursache:** Direkte DB-Manipulation während Container läuft (WAL-Inkonsistenz)
**Fix:** `n8n import:workflow` CLI statt SQL-Write. Bei schon kaputten DBs: [`10-n8n-db-korruption.md`](10-n8n-db-korruption.md)

### 2. Webhook-Registration-Fail

**Symptom:** n8n-Callback-Endpoint gibt 404, Discord kann Interactions-URL nicht verifizieren
**Ursache:** Fehlendes `webhookId` am Webhook-Node → n8n registriert unter nested Path
**Fix:** `webhookId: "discord-interaction"` im Webhook-Node setzen (siehe `ai-review-callback.json`)

### 3. Ed25519-Verify in n8n unzuverlässig

**Symptom:** `crypto.subtle.verify` liefert mal true, mal false bei gleichen Inputs
**Ursache:** Inkonsistenz zwischen Node-Versionen beim WebCrypto-Subtle-Handling
**Fix:** `crypto.verify` mit SPKI-prefix (`302a300506032b6570032100` + 32-byte Pub) — deterministisch

### 4. Raw-Body-Handling

**Symptom:** Signatur-Verify failt obwohl Request von Discord korrekt signiert ist
**Ursache:** n8n parst JSON-Body automatisch → die Bytes für Signatur-Check sind nicht mehr die Original-Bytes
**Fix:** `options.rawBody: true` auf Webhook-Node, `$input.first().binary.data` statt `$json.body`

### 5. Replay-Schutz vergessen

**Symptom:** Theoretisch: Alter abgefangener Request kann repliziert werden
**Ursache:** Kein Timestamp-Check
**Fix:** ±300s-Skew-Toleranz im Code-Node (Discord-Doku empfiehlt das)

### 6. HTTP-Retry-Gap bei Discord-ACK

**Symptom:** Discord zeigt "This interaction failed" obwohl alles OK ist
**Ursache:** GitHub-API hing 3s+, Respond-Node konnte nicht rechtzeitig ACK schicken
**Fix:** `retryOnFail: true, neverError: true, fullResponse: true` — ACK wird immer gesendet, GitHub-Retry läuft async

### 7. GitHub workflow_dispatch 404

**Symptom:** Button-Klick löst keine GH-Action aus, `gh api` gibt 404
**Ursache:** Target-Workflow muss auf default-Branch (main) existieren
**Fix:** Workflow-YAML zuerst mergen (via PR), erst dann kann `workflow_dispatch` auf nem anderen Branch damit arbeiten

### 8. Package-Daten-Files nicht im Wheel

**Symptom:** `FileNotFoundError: stages/prompts/code_review.md` in Stage-Run
**Ursache:** `.md`-Files im Source-Tree, aber hatchling packaging hat sie nicht ins Wheel genommen
**Fix:** `packages = ["src/ai_review_pipeline"]` in pyproject.toml (nicht `src`). Regression-Test: [`20-wheel-packaging-regression.md`](../60-tests/20-wheel-packaging-regression.md)

### 9. Branch-Protection + pending-Check

**Symptom:** GitHub Admin-Merge schlägt bei "pending" (nicht "failing") fehl
**Ursache:** Branch-Protection-Regel "alle Required-Checks müssen Abschluss erreicht haben"
**Fix:** Required-Check temporär aus Protection entfernen → merge → Protection wiederherstellen. Langfristig: keine pending-States in consensus schreiben

### 10. Shadow-Pipeline triggert nur auf `pull_request`

**Symptom:** Ich will die Pipeline manuell re-triggern, aber nichts passiert
**Ursache:** `ai-review-v2-shadow.yml` hat nur `on: pull_request`
**Fix:** Leeren Commit auf PR-Branch pushen (`git commit --allow-empty`) oder `gh run rerun <run-id> --failed`

### 11. pip skip-reinstall bei git+URL

**Symptom:** Stages crashen mit `FileNotFoundError`, obwohl der Code auf main frisch ist
**Ursache:** pip erkennt `ai-review-pipeline==0.1.0` als "satisfied" und skippt Install, Version bumpt nicht zwischen Commits
**Fix:** `--force-reinstall --no-deps --no-cache-dir` vor jedem Install. Details: [`30-pip-install-bricht.md`](30-pip-install-bricht.md)

### 12. Broken pip half-upgrade

**Symptom:** `ImportError: cannot import name 'RequirementInformation' from 'pip._vendor.resolvelib.structs'`
**Ursache:** Im Tool-Cache `pip-25.0.1.dist-info` + `pip-26.0.1.dist-info` parallel → vendored resolvelib halb ausgetauscht
**Fix:** `rm -rf pip/ pip-*.dist-info/ _distutils_hack` + `python -m ensurepip --upgrade`

### 13. Runner tool-cache != User-site

**Symptom:** `python3 -m pip` schlägt mit "No module named pip" fehl beim manuellen Debug
**Ursache:** PYTHONPATH zeigt default nur auf `~/.local/lib/python3.12/site-packages`, nicht auf Tool-Cache
**Fix:** `PYTHONPATH=/home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/lib/python3.12/site-packages python3 -m pip …` (CI setzt das automatisch via setup-python)

### 14. Orphan 160000-Gitlink ohne `.gitmodules`

**Symptom:** `fatal: no submodule mapping found in .gitmodules for path '.temp/Uiplatformguide'`
**Ursache:** Historischer Checkpoint-Commit hat einen Submodule-Gitlink (160000-Mode), aber es gibt keinen `.gitmodules`-Eintrag dazu. `git submodule status` (den actions/checkout intern ruft) crasht
**Fix:** `.gitmodules`-Datei anlegen mit URL-Mapping für den Gitlink. Alternativ: `submodules: false` in actions/checkout

### 15. `gh pr view --json closingIssuesReferences`

**Symptom:** `Unknown JSON field: "closingIssuesReferences"`
**Ursache:** Das Feld existiert nur im GitHub-GraphQL-Schema, nicht im REST-Wrapper von `gh pr view`
**Fix:** `gh api graphql -F owner -F repo -F number -f query='…closingIssuesReferences…'` direkt ans GraphQL-API

### 16. `update:workflow` deprecated

**Symptom:** n8n-CLI-Warnung: `update:workflow is deprecated, use publish:workflow`
**Ursache:** n8n 2.15+ deprecatet das Command
**Fix:** In Scripts `publish:workflow` nutzen; `update:workflow` läuft noch, aber logged Warnung

### 17. Workflow-Änderungen brauchen Restart

**Symptom:** JS-Code-Änderung am Workflow hat keine Wirkung, alter Code läuft weiter
**Ursache:** n8n 2.15+ cached Workflow-Code im Memory, neues Loading nur bei Restart
**Fix:** `docker restart ai-portal-n8n-portal-1` nach Workflow-Änderungen

### 18. `execSync(gemini ...)` blockiert Task-Runner

**Symptom:** n8n wirft `Task runner timeout` bei längeren LLM-Calls
**Ursache:** `execSync` blockt die Event-Loop, Runner's Default-Heartbeat (30s) kündigt ab
**Fix:** `N8N_RUNNERS_HEARTBEAT_INTERVAL=300` + `TASK_TIMEOUT=600` in Service-Environment

### 19. Gemini CLI Flag-Order

**Symptom:** `gemini -p -m gemini-3.1-pro-preview "prompt"` → `Not enough arguments following: p`
**Ursache:** yargs behandelt `-p` als String-Option, `-m` wird als dessen Wert konsumiert
**Fix:** Immer `gemini -m gemini-3.1-pro-preview -p "prompt"` (model-Flag VOR prompt-Flag)

### 20. Re-Import strippt Credentials (historisch)

**Symptom:** Nach `n8n import:workflow` sind alle Credentials im Workflow weg
**Ursache:** Ältere n8n-Versionen haben das getan; gefixt seit commit `8024360`
**Fix:** Aktuelle n8n-Version nutzen. Flash-Mode-Smoke-Test nach jedem Re-Import als Sanity-Check

## Wie man die Liste pflegt

Neue Stolpersteine dokumentieren:

1. Incident passiert → lösen
2. Entry hier anhängen im Format "Symptom → Ursache → Fix"
3. Falls komplexer: eigene Runbook-Seite in `50-runbooks/`, von hier verlinken
4. `80-historie/10-lessons-learned.md` für längere Retrospektive

## Verwandte Seiten

- [Alle Runbooks](.) — detaillierte Incident-Response-Anleitungen
- [Lessons Learned](../80-historie/10-lessons-learned.md) — längere Retrospektiven
- [Überblick](../00-ueberblick.md) — wie die Toolchain zusammenhängt
- [Changelog](../80-historie/00-changelog.md) — wann was passierte

## Quelle der Wahrheit (SoT)

- `~/.claude/plans/ai-review-pipeline-completion-report.md` Sektion 5 — ursprüngliche Liste
- [`ai-portal/CLAUDE.md` Research-Pipeline Operational Notes](https://github.com/EtroxTaran/ai-portal/blob/main/CLAUDE.md) — n8n-spezifische Gotchas
