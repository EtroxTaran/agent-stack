# Auto-Fix-Loop — Findings, Fix, nochmal prüfen

> **TL;DR:** Wenn eine Review-Stage Findings meldet (z.B. "fehlender Test für Edge-Case X"), kann die Pipeline automatisch versuchen, sie zu beheben. Ein Auto-Fix-Agent liest die Findings, patcht den Code, commited + pushed auf den PR-Branch, und lässt die Stage erneut laufen. Maximal zwei Iterationen pro Stage, sonst wird abgebrochen und an einen Menschen übergeben. Der Loop ist konservativ gebaut: Er fixt maximal 10 Dateien pro Pass, rollback bei Fehler, und wird bei Security-Findings gar nicht ausgelöst — da will die Pipeline immer einen Menschen draufschauen lassen.

## Wie es funktioniert

```mermaid
sequenceDiagram
    participant Stage as Review-Stage (z.B. code-review)
    participant Loop as fix_loop.py
    participant AF as auto_fix.py
    participant GH as GitHub
    participant R as r2d2 Runner

    Stage->>Loop: Findings: ["missing test for empty-array case", ...]<br/>Score: 5, confidence: 0.7

    Note over Loop: Iteration 1 startet

    Loop->>AF: generate-fix --findings=[...] --pr=42
    AF->>AF: LLM: generate patch
    AF->>GH: git commit -m "auto-fix: add edge-case test for empty array"
    AF->>GH: git push origin branch

    Note over GH: synchronize-Event triggert PR-Workflows

    GH->>R: re-run Stage
    R->>Stage: ai-review stage code-review --pr 42
    Stage->>Stage: LLM-Review nochmal
    Stage-->>Loop: Score: 9, confidence: 0.94 — clean

    alt improved AND score ≥ 8
        Loop-->>Stage: success, pass back to consensus
    else score still < 8
        Note over Loop: Iteration 2 (max 2)
        Loop->>AF: generate-fix again...
        AF-->>Loop: neuer Patch
        Loop->>Stage: re-run
        alt still < 8
            Loop-->>Stage: abort, escalate to human
        end
    end
```

Der Auto-Fix-Loop ist **pragmatisch einfach**: Findings reingeben, Patch bekommen, Commit machen, Stage nochmal laufen. Keine komplexe Dependency-Analyse, keine Multi-Branch-Strategie. Das funktioniert, weil die Findings normalerweise klein und lokal sind — ein fehlender Test, eine unsichere Type-Assertion, ein vergessenes Null-Check.

Die **2-Iterations-Grenze** schützt vor Endlos-Loops. Wenn nach zwei Versuchen immer noch Score < 8 ist, liegt wahrscheinlich ein tieferes Problem vor, das ein Mensch anschauen muss.

Der **Security-Ausschluss** ist wichtig: Stage-2-Findings (Security) werden **niemals** automatisch gepatcht. Ein Auto-Fix könnte eine Injection-Lücke versehentlich "fixen" indem er sie elegant verschleiert — das ist schlimmer als das Original. Security-Findings kriegen immer einen Menschen zu sehen.

## Technische Details

### Wann der Loop triggert

Konfiguration pro Stage in `.ai-review/config.yaml`:

```yaml
stages:
  code_review:
    enabled: true
    blocking: true
    auto_fix:
      enabled: true
      max_iterations: 2
  security:
    enabled: true
    blocking: true
    auto_fix:
      enabled: false  # Security niemals auto-fixen
  design:
    enabled: true
    blocking: false
    auto_fix:
      enabled: true
      max_iterations: 1  # Design-Fixes sind riskanter — nur 1 Versuch
```

Default ist `auto_fix.enabled: false` — Auto-Fix muss pro Stage explizit aktiviert werden.

### Die Auto-Fix-Command

```bash
ai-review auto-fix \
  --pr 42 \
  --stage code-review \
  --findings-file /tmp/findings.json \
  --max-files 10
```

Inputs:
- `findings-file`: JSON-Liste der Findings mit `{severity, file, line, description, suggested_fix}`
- `max-files`: harte Grenze pro Pass, default 10 — verhindert riesige All-in-One-Patches

Output:
- Exit 0: Fix commited + gepushed
- Exit 1: Kein Fix möglich (LLM konnte keine Lösung generieren)
- Exit 2: Patch zu groß (>max-files), abgebrochen
- Exit 3: Git-Konflict beim Push, Rollback erfolgt

### Die Fix-Generation

Aus [`src/ai_review_pipeline/auto_fix.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/auto_fix.py):

```python
def generate_fix(findings, stage_name, pr_number):
    # 1. Findings zu einem kombinierten Prompt zusammenführen
    prompt = build_fix_prompt(findings, stage_name)

    # 2. LLM fragen (Codex für code-review-Stage, Claude für design-Stage)
    model = get_fix_model(stage_name)
    patch = call_llm(model, prompt)

    # 3. Patch validieren
    if count_changed_files(patch) > MAX_FILES:
        return FixResult.TOO_BIG
    if has_dangerous_changes(patch):  # z.B. löscht 100+ Zeilen
        return FixResult.RISKY

    # 4. Anwenden
    apply_patch(patch)
    run_local_validators(patch)  # typecheck, lint

    # 5. Commit + Push
    commit_message = generate_commit_message(findings, stage_name)
    git_commit_and_push(commit_message, branch=current_branch())

    return FixResult.APPLIED
```

### Commit-Message-Konvention

Auto-Fix-Commits folgen Conventional-Commit mit `fix:`-Prefix und klarer Attribution:

```
fix(auto-review): address code-review findings on PR #42

Applied:
  - add edge-case test for empty array (suggestion from code-review stage)
  - narrow type assertion in validateInput() (null-safety)
  - extract duplicated logic to shared helper

Stage: code-review
Iteration: 1/2
Co-Authored-By: ai-review-auto-fix <bot@ai-review-pipeline>
```

Die `Co-Authored-By`-Zeile macht klar, dass ein Bot commited hat — hilft beim späteren Code-Archäologie.

### Der fix-loop-Flow

```bash
ai-review fix-loop \
  --stage code-review \
  --pr 42 \
  --max-iterations 2
```

Das ist der übergeordnete Workflow, der auto-fix + re-run-stage orchestriert:

```python
def fix_loop(stage_name, pr_number, max_iterations):
    for i in range(max_iterations):
        result = run_stage(stage_name, pr_number)

        if result.score >= SUCCESS_THRESHOLD:
            return "success"

        if not stage_config.auto_fix.enabled:
            return "needs_human"

        fix_result = auto_fix(result.findings, stage_name, pr_number)

        if fix_result != FixResult.APPLIED:
            return "needs_human"  # Fix-Generation failed

        # Warten, bis der Push-Workflow die Stage neu getriggert hat
        wait_for_new_stage_run(stage_name, pr_number)

    return "max_iterations_reached"
```

### Rollback bei Fehler

Wenn der Fix einen Test kaputt macht oder einen Typecheck-Fehler einführt:

1. **Pre-Commit-Check:** Auto-Fix läuft `pnpm typecheck` (oder `pytest --fast`) lokal BEVOR gepushed wird
2. **Post-Push-Check:** Die CI auf GitHub läuft die Volltests. Schlägt etwas fehl → Auto-Fix committet revert mit `revert: auto-fix attempt — broke typecheck`
3. **Rollback-Safety:** Der Commit bleibt in der History (kein force-push), der Entwickler sieht nachvollziehbar was passiert ist

### Was der Auto-Fix NICHT tut

- **Keine Refactorings** — nur einzelne Findings addressen, keine strukturellen Änderungen
- **Keine Dependencies upgraden** — wäre zu risky für einen Bot
- **Keine API-Contract-Änderungen** — Zod-Schema-Änderungen brauchen manuellen Review
- **Keine `.env*`-Dateien anfassen**
- **Keine Schema-Migrations**
- **Keine Design-System-Foundations** (globals.css, theme-Tokens)

Die Blacklist ist in `auto_fix.py`:

```python
PROTECTED_PATTERNS = [
    r"\.env(\..*)?$",
    r"schema/.*\.surql$",
    r"packages/shared-ui/src/styles/.*\.css$",
    r".*\.proto$",
    r"migrations/.*",
]
```

Ein Fix, der eine protected file anfasst, wird sofort abgelehnt.

### Metrics

Jede Auto-Fix-Iteration wird in metrics.jsonl geloggt:

```json
{
  "type": "auto_fix",
  "pr": 42,
  "stage": "code-review",
  "iteration": 1,
  "result": "applied",
  "files_changed": 3,
  "lines_added": 47,
  "lines_removed": 12,
  "post_fix_score": 9,
  "duration_seconds": 34
}
```

Nützlich für Trend-Analyse: Wie oft sind Fixes erfolgreich (Score-Lift ≥ 2)? Wie oft iteration 1 vs. iteration 2? Welche Stages profitieren am meisten?

### Manueller Trigger

Der Auto-Fix kann auch manuell via `workflow_dispatch` gestartet werden:

```bash
gh workflow run ai-review-auto-fix.yml \
  --ref feat/my-branch \
  -f pr=42 \
  -f stage=code-review \
  -f reason="post-hoc cleanup after manual fix"
```

Nützlich wenn der automatische Loop abgebrochen hat und ein Mensch die Findings trotzdem automatisch wegaggregieren lassen will.

## Verwandte Seiten

- [AI-Review-Pipeline (Konzept)](../10-konzepte/00-ai-review-pipeline.md) — welche Stages auto-fixen
- [Consensus-Scoring](../10-konzepte/10-consensus-scoring.md) — was den Loop startet
- [Neuer PR E2E](00-neuer-pr-e2e.md) — wo der Loop im Gesamtflow sitzt
- [CLI-Commands](../70-reference/00-cli-commands.md) — `ai-review auto-fix` + `fix-loop` Flags

## Quelle der Wahrheit (SoT)

- [`src/ai_review_pipeline/auto_fix.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/auto_fix.py) — Fix-Generation
- [`src/ai_review_pipeline/fix_loop.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/fix_loop.py) — Loop-Orchestrierung
- [`workflows/ai-review-auto-fix.yml`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/workflows/ai-review-auto-fix.yml) — Workflow-Template
