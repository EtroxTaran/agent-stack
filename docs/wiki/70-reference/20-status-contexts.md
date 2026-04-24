# Status-Contexts — `ai-review/*`

> **TL;DR:** Jede Review-Stage schreibt am Ende einen GitHub-Commit-Status auf den PR-HEAD-Commit. Der "Context-Name" dieses Status entscheidet, ob die Branch-Protection ihn als Required-Check behandelt. Seit dem Phase-5-Cutover (ai-portal, 2026-04-24) gibt es nur noch einen Präfix-Raum: `ai-review/*`. Der historische `ai-review-v2/*`-Shadow-Präfix existiert nicht mehr.

## Kontext-Matrix

```mermaid
graph LR
    subgraph "Phase 5 (aktuell)"
        V[ai-review/*]
    end

    subgraph "Branch-Protection"
        REQ[Required Checks]
    end

    V -->|ai-review/consensus required| REQ

    classDef current fill:#43a047,color:#fff
    classDef protection fill:#e53935,color:#fff
    class V current
    class REQ protection
```

## Die Context-Namen im Detail

### `ai-review/*` — produktive Pipeline

| Context | Stage | Status-Werte |
|---|---|---|
| `ai-review/scope-check` | Pre-Flight | success (ok), failure (PR-Body-Fehler) |
| `ai-review/code` | Stage 1 Codex | success, failure, pending |
| `ai-review/code-cursor` | Stage 1b Cursor | success (+"skipped: rate-limit" möglich), failure, pending |
| `ai-review/security` | Stage 2 Gemini+semgrep | success, failure, pending |
| `ai-review/design` | Stage 3 Claude | success (+"skipped — no UI"), failure, pending |
| `ai-review/ac-validation` | Stage 5 Codex+Claude | success, failure (coverage < min), pending |
| `ai-review/consensus` | Aggregation | success (avg≥8), pending (soft 5-7 oder missing), failure (<5) |

### Historisch: `ai-review-v2/*` (Shadow-Präfix, bis 2026-04-24)

Während der Phase-4-Shadow-Validierung (20.–24. April 2026) lief die damals neue v2-Pipeline unter einem eigenen Präfix `ai-review-v2/*`, parallel zur bestehenden v1-Legacy-Pipeline. Im Cutover wurde der Shadow-Präfix entfernt und die Stages schreiben seither direkt `ai-review/*`. Der Shadow-Präfix ist nur noch für Archiv-Analysen alter PRs relevant.

## Branch-Protection-Konfiguration

Die Protection auf `ai-portal/main` listet folgende Required-Checks (Stand Phase 5):

```
checks                                                         [CI]
e2e                                                            [Playwright]
design-conformance                                             [Design-Linter]
Secret Scan (gitleaks)                                         [Security]
SAST (semgrep)                                                 [Security]
Container CVE Scan (trivy) (portal-api, ., apps/portal-api/Dockerfile)
Container CVE Scan (trivy) (portal-shell, ., apps/portal-shell/Dockerfile)
ai-review/consensus                                            [AI-Review Aggregation]
```

**Kritisch:** Nur `ai-review/consensus` ist aus der Pipeline required, nicht die einzelnen Stages. Die Stages fließen in die Aggregation ein, der Branch-Protection-Gate ist der Consensus-Status.

## Status-Context-Präfix

Die Pipeline nutzt `ai-review/*` als Default-Präfix. Der `--status-context-prefix`-Flag ist weiterhin implementiert, wird aber nicht genutzt — der Shadow-Use-Case fiel mit dem Phase-5-Cutover weg. Er bleibt nutzbar für künftige Shadow-Deployments in anderen Projekten:

```bash
# Produktiv (default):
ai-review stage code-review --pr 42
# schreibt: ai-review/code = success

# Zukünftiger Shadow-Run in einem neuen Projekt:
ai-review stage code-review --pr 42 --status-context-prefix ai-review-v2
# schreibt: ai-review-v2/code = success
```

## Status-Description-Konventionen

Jeder Context hat eine kurze Description (max 140 chars), die im GitHub-UI als Tooltip erscheint:

**Success-Descriptions:**
- `"Codex GPT-5 clean"` — Stage 1 ohne Findings
- `"2/5 green"` — altes v1-Format bei Consensus
- `"5/5 stages green, avg 9.2"` — neues v2-Format
- `"skipped — no design-relevant files changed"` — Design-Skip
- `"skipped: rate-limit — consensus uses other stages"` — Cursor-Sentinel

**Failure-Descriptions:**
- `"Gemini 3.1 Pro flagged 1 critical finding"`
- `"AC-Validation failed: 0/3 AC mapped to tests"`
- `"consensus below threshold: avg 4.2"`

**Pending-Descriptions:**
- `"Waiting for stages to complete"` (Consensus-Race-Condition)
- `"3/5 green, 2 soft — requires human ack"` (Soft-Consensus)

Die Descriptions werden im [`ai-review-pipeline/src/.../consensus.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/consensus.py) und pro Stage-Modul gesetzt.

## Wie Status-Updates ineinandergreifen

Status-API ist **write-once-by-context**: Ein neuer POST überschreibt den alten. Die Stages schreiben ihr eigenes Präfix, der Consensus-Job liest alle passenden Präfixe und schreibt sein eigenes.

Timeline einer erfolgreichen Pipeline:

```
t=00s  PR opened → 5 Stage-Jobs + 1 Consensus-Job queued
t=05s  Scope-Check → success → writes ai-review/scope-check
t=20s  Code-Review → success → writes ai-review/code
t=30s  Cursor-Review → success → writes ai-review/code-cursor
t=35s  Security-Review → success → writes ai-review/security
t=15s  Design-Review → success (skipped) → writes ai-review/design
t=45s  AC-Validate → success → writes ai-review/ac-validation
t=50s  Consensus → polls alle ai-review/*, aggregiert, writes ai-review/consensus = success
```

Ab Sekunde 50 ist die Pipeline grün, Branch-Protection erfüllt.

## Cutover-Historie

Im Phase-5-Cutover (ai-portal, 2026-04-24) wurden die Kontext-Namen umgestellt:

```
Phase 4 (Shadow, 20.–24. April 2026):
  v1 required:     ai-review/consensus
  v2 non-required: ai-review-v2/consensus

Phase 5 (ab 2026-04-24):
  required:        ai-review/consensus    ← v2 nutzt jetzt den Default-Präfix
  gelöscht:        alle ai-review-v2/*    ← Shadow-Präfix entfernt
```

**Für künftige Cutover in anderen Projekten:** Beim Swap PR-Queue möglichst leer halten, sonst haben offene PRs alte Shadow-Contexts, die plötzlich "stale" wirken. Playbook: [`30-workflows/40-shadow-zu-produktion-cutover.md`](../30-workflows/40-shadow-zu-produktion-cutover.md).

## Status-Context abfragen

**Via `gh` CLI:**

```bash
HEAD=$(gh pr view 42 --repo EtroxTaran/ai-portal --json headRefOid --jq .headRefOid)
gh api repos/EtroxTaran/ai-portal/commits/$HEAD/status \
  --jq '.statuses[] | {context, state, description}'
```

**Via UI:**

GitHub PR-Seite → "Checks"-Tab → jeder Context hat Status + Description sichtbar.

## Verwandte Seiten

- [Consensus-Scoring](../10-konzepte/10-consensus-scoring.md) — wie die Aggregation entscheidet
- [Shadow-Mode vs. Cutover](../10-konzepte/20-shadow-vs-cutover.md) — Phasenmodell
- [Shadow-zu-Produktion Cutover](../30-workflows/40-shadow-zu-produktion-cutover.md) — Migration
- [Consensus-stuck-pending Runbook](../50-runbooks/40-consensus-stuck-pending.md)

## Quelle der Wahrheit (SoT)

- [`src/ai_review_pipeline/common.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/src/ai_review_pipeline/common.py) — Status-Post-Helper
- [GitHub Commit Status API](https://docs.github.com/en/rest/commits/statuses)
- [Branch-Protection-API](https://docs.github.com/en/rest/branches/branch-protection)
