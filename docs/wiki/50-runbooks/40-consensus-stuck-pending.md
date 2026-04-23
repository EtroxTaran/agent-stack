# `ai-review/consensus` hängt auf pending

> **TL;DR:** Ein PR hat alle fünf Review-Stages als erfolgreich durchlaufen, aber der Consensus-Status bleibt auf "pending" stehen und blockiert den Merge. Ursache ist fast immer ein Race-Condition: Der Consensus-Aggregator-Job hat gepolled, als die Stage-Statuses noch nicht terminal waren, und hat deshalb ein vorläufiges "pending" geschrieben — das dann nicht mehr automatisch flippt, wenn die Stages später terminieren. Der Fix ist ein einzelner `gh run rerun` auf den Consensus-Job.

## Symptom

- PR zeigt grüne Häkchen bei `ai-review/code`, `ai-review/cursor`, `ai-review/security`, `ai-review/design`, `ai-review/ac-validation`
- Aber `ai-review/consensus` bleibt auf gelb/pending
- Branch-Protection erlaubt den Merge nicht
- Auto-Merge (falls enabled) triggert nicht
- PR-Status zeigt: "Waiting for status to be reported"

## Diagnose

```bash
# 1. Liste alle Status-Contexts für das PR-HEAD
HEAD=$(gh pr view <PR> --repo <repo> --json headRefOid --jq .headRefOid)
gh api repos/<owner>/<repo>/commits/$HEAD/status \
  --jq '.statuses[] | select(.context | startswith("ai-review")) | {state, context, description}'
```

Erwartetes Output bei gesunder Pipeline (alle success):

```json
{"context":"ai-review/code", "state":"success", "description":"Codex GPT-5 clean"}
{"context":"ai-review/code-cursor", "state":"success", "description":"Cursor clean"}
{"context":"ai-review/security", "state":"success", "description":"Gemini clean"}
{"context":"ai-review/design", "state":"success", "description":"skipped - no UI"}
{"context":"ai-review/ac-validation", "state":"success", "description":"3/3 coverage"}
{"context":"ai-review/consensus", "state":"success", "description":"5/5 green"}
```

**Problem-Output (Consensus hängt):**

```json
{"context":"ai-review/consensus", "state":"pending", "description":"Waiting for stages to complete"}
```

Obwohl die 5 Stage-Contexts `state: success` haben.

```bash
# 2. Welcher Run hat den Consensus-Status geschrieben?
gh run list --repo <repo> --workflow ai-review-consensus.yml --limit 5 --json databaseId,conclusion,headSha,createdAt
```

Der Run mit dem passenden `headSha` ist der, der gerepeatet werden muss.

## Fix

### Einfacher Re-Run

```bash
# Consensus-Workflow neu triggern
gh run rerun <run-id> --repo <repo>

# Warten:
sleep 30

# Nochmal checken:
gh api repos/<owner>/<repo>/commits/$HEAD/status \
  --jq '.statuses[] | select(.context == "ai-review/consensus")'
# Erwartet: state: success
```

Das reicht in ~95% der Fälle. Der Consensus-Job liest jetzt die (mittlerweile terminalen) Stage-Statuses, aggregiert, schreibt success.

### Wenn der Re-Run nicht greift

Der Consensus hat einen internen Retry-Loop: Er pollt 12× alle 30 Sekunden (= 6 Minuten), bevor er aufgibt. Wenn er aufgibt, schreibt er `failure` mit Beschreibung `"Consensus timeout — stages never terminal"`. Falls das passiert:

```bash
# Manuell einen success setzen (nur wenn alle 5 Stages tatsächlich success sind!)
gh api -X POST repos/<owner>/<repo>/statuses/$HEAD \
  -F state=success \
  -F context=ai-review/consensus \
  -F description="5/5 stages green (manual override after race)" \
  -F target_url="https://github.com/..."
```

**Achtung:** Manual override sollte Ausnahme sein. Wenn das häufig nötig ist → Consensus-Logik hat einen Bug.

## Root-Cause-Analyse

### Warum passiert das?

Der Consensus-Workflow hat ein `needs:`-Direktive:

```yaml
jobs:
  consensus:
    needs:
      - ac-validate
      - code-review
      - cursor-review
      - security-review
      - design-review
```

Das heißt: Der Consensus-Job wartet, bis alle 5 Stage-Jobs **auf Job-Ebene** terminiert sind (success/failure/cancelled). Aber die **Status-Context-Posts** (HTTP-Calls zur GitHub-Status-API) passieren am Ende des jeweiligen Job-Steps, und zwischen Job-Termination und API-Propagierung gibt es Sekunden bis Minuten Delay.

Der Consensus-Job startet also sobald alle 5 Jobs "done" sind, aber die Status-API sieht die 5 Erfolgs-Status vielleicht noch nicht. Er pollt 12× alle 30s (6 Min Timeout), aber bei ungünstigem Zeitpunkt des Polls sieht er mehrfach "pending" und schreibt dann selbst pending.

### Warum flippt es nicht automatisch?

Die GitHub-Status-API ist **write-once-by-context**: Jeder neue Status überschreibt den alten für denselben Context. Solange der Consensus-Job nicht nochmal läuft, bleibt der alte pending-Status stehen. Es gibt keinen Event, der "alle-5-Stages-endlich-terminal" triggert.

Deshalb der Re-Run-Fix: Ein neuer Consensus-Run liest die jetzt-terminalen Stages und schreibt success.

## Prevention

### Bessere Retry-Logik im Consensus

Der Consensus-Job könnte länger warten (z.B. 30 Min statt 6 Min), aber das verzögert Legit-Failures um 24 Min. Trade-off.

### Event-Driven statt Polling

Eine Architektur-Alternative wäre ein separater Workflow, der auf `status`-Events lauscht und beim 5ten success-Event Consensus triggert. Zusätzliche Komplexität; aktuell akzeptiert das System die seltene Race-Condition.

### Monitoring

```bash
# Wie oft hängt consensus auf pending?
gh api search/issues?q=repo:<repo>+status:pending+consensus+is:pr
```

Wenn > 5% der PRs betroffen sind → Retry-Logik erhöhen oder Event-driven umbauen.

### Konkret im Januar 2026

Während der Cutover-Tests trat das mehrfach auf — es war ein bekannter Flake. Das `--force-reinstall`-Pattern (siehe PR#43) + eine kleine Erhöhung auf 12 Retries (vorher 8) hat die Rate von ~20% auf < 5% gesenkt. Der Fix "Re-Run des Consensus" bleibt der Standard-Workaround.

## Verwandte Seiten

- [Consensus-Scoring](../10-konzepte/10-consensus-scoring.md) — wie die Aggregation grundsätzlich funktioniert
- [Neuer PR E2E](../30-workflows/00-neuer-pr-e2e.md) — der Normalflow
- [AI-Review-Pipeline (Konzept)](../10-konzepte/00-ai-review-pipeline.md) — die 5 Stages
- [Workflow-Templates](../40-setup/30-workflow-templates.md) — der `ai-review-consensus.yml`

## Quelle der Wahrheit (SoT)

- [`src/ai_review_pipeline/consensus.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/consensus.py) — Retry-Loop-Logik
- [`ai-review-pipeline/workflows/ai-review-consensus.yml`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/workflows/ai-review-consensus.yml) — Workflow-Template
- [GitHub Commit Status API](https://docs.github.com/en/rest/commits/statuses) — Write-once-by-context-Behavior
