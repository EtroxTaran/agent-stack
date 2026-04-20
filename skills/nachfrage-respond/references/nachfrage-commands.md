# Nachfrage Commands - Full Matrix

Reference for the four `/ai-review` commands the soft-consensus +
waiver paths rely on. Authoritative for the `nachfrage-respond` skill.

## Command Matrix

| Command | Args | Auth | Min reason | Effect |
|---|---|---|---|---|
| `/ai-review approve` | none | PR-author | n/a | Sets `ai-review/consensus=success` (blocked if `ai-review/security=failure` without waiver) |
| `/ai-review retry` | none | PR-author | n/a | Dispatches `ai-review-auto-fix.yml`, resets `ai-review/consensus=pending` |
| `/ai-review security-waiver <reason>` | reason | PR-author | 30 chars | Sets `ai-review/security-waiver=success` with 140-char truncated description |
| `/ai-review ac-waiver <reason>` | reason | PR-author | 30 chars | Sets `ai-review/ac-waiver=success` with 140-char truncated description |

## Parsing Rules

- Case-insensitive on the command token (`APPROVE` and `approve` both
  parse).
- Only the first line of the comment is scanned for the command. Extra
  explanation in subsequent lines is fine; it just does not change the
  dispatch.
- Leading whitespace inside `<reason>` is stripped (`reason.strip()`).
- Trailing whitespace on the command line is ignored.

### Allow-list regex

```
^/ai-review\s+(approve|retry|security-waiver|ac-waiver)(\s+(.*))?\s*$
```

Case-insensitive, multiline. Anything else is NOT a command.

## Authorization

```
commenter.login == pr.author.login
```

No exceptions. Repository admins, co-authors, and org owners are all
rejected. Document this in the rejection reply:

> Nur der PR-Author (@<author>) darf `/ai-review`-Commands triggern.
> Du bist @<commenter> - bitte den Author fragen.

## Rejection Templates

### Reason too short (waivers)

```
Waiver zurueckgewiesen - Begruendung zu kurz (<len> Zeichen, mind. 30 noetig).

Beispiel:
/ai-review security-waiver Gemini hat `actions/checkout@v4` als ungueltigen
Pfad markiert - manuell verifiziert, Zeile 29 enthaelt den korrekten ref.
```

### Reason too generic

Generic-pattern match on `^(fp|ok|done|false|trust me|lgtm|sure)\b`
after whitespace strip:

```
Waiver zurueckgewiesen - Begruendung zu generisch.
Nenne das konkrete Finding und WARUM es ein False-Positive ist.
Siehe docs/v2/40-ai-review-pipeline/05-security-waiver.md.
```

### Unknown command

```
Unbekanntes /ai-review-Command: `<cmd>`. Erlaubt:
  /ai-review approve
  /ai-review retry
  /ai-review security-waiver <reason>
  /ai-review ac-waiver <reason>
```

### Approve blocked by security veto

```
`/ai-review approve` blockiert - Security-Veto aktiv.
Use `/ai-review security-waiver <reason>` first (>= 30 chars, nicht generisch).
```

## Sticky Comment Markers

Each command owns exactly one sticky-comment marker so the audit trail
is trivially greppable:

| Command | Marker |
|---|---|
| `approve` | `<!-- nexus-ai-review-human-override -->` |
| `retry` | `<!-- nexus-ai-review-retry -->` (optional; workflow reply may replace) |
| `security-waiver` | `<!-- nexus-ai-review-security-waiver -->` |
| `ac-waiver` | `<!-- nexus-ai-review-ac-waiver -->` |

The marker lives as an HTML comment at the top of the sticky body.
Posting the same command twice UPDATES the existing comment instead of
appending a new one.

## Metrics Schema (`.ai-review/metrics.jsonl`)

One JSON object per line, append-only. Fields:

| Field | Type | Notes |
|---|---|---|
| `timestamp` | string (ISO 8601 UTC) | When dispatch completed |
| `pr` | int | PR number |
| `head_sha` | string | Full commit SHA (40 chars) |
| `commenter` | string | GitHub login (verified as PR-author) |
| `command` | string | One of `approve | retry | security-waiver | ac-waiver` |
| `reason` | string | Full reason for waivers, empty for approve/retry |
| `dispatch_result` | string | `ok | rejected-short-reason | rejected-generic | rejected-auth | rejected-veto | dispatch-failed` |
| `error` | string (optional) | Present only when `dispatch_result != ok` |

Example:

```jsonl
{"timestamp":"2026-04-20T12:34:56Z","pr":42,"head_sha":"7db41d7f7246292ca00ce494b932795f12d8f9b","commenter":"EtroxTaran","command":"security-waiver","reason":"Gemini hallucinated the actions/checkout reference on line 29 - verified manually","dispatch_result":"ok"}
```

## Worked Examples

### 1. Clean approve on a soft consensus (no security veto)

Input comment body:

```
/ai-review approve

Ich habe den Diff nochmal drueber gelesen, Cursor hat den neuen
Helper uebersehen.
```

Parse:
- cmd: `approve`
- rest: empty
- reason: n/a

Dispatch:
- `gh api statuses/<SHA>` with `ai-review/consensus=success`,
  description `"Human-override: /ai-review approve by PR-Author"`
- Sticky `<!-- nexus-ai-review-human-override -->` posted/updated
- metrics.jsonl: `{"command":"approve","reason":"",...}`

### 2. Security-waiver with valid reason

Input:

```
/ai-review security-waiver Gemini reported "malformed reference @docs/legacy/..." on line 29 but the actual line is a clean actions/checkout@v4 - verified via cat on the workflow file.
```

Parse:
- cmd: `security-waiver`
- rest: `Gemini reported ... on line 29 ... verified via cat on the workflow file.`
- reason length: > 30, not generic -> OK

Dispatch:
- `gh api statuses/<SHA>` with `ai-review/security-waiver=success`
- `description` truncated to 140 chars
- Sticky `<!-- nexus-ai-review-security-waiver -->` with FULL reason

### 3. Rejected: waiver from non-author

Input body from `@other-user`:

```
/ai-review approve
```

Authorization fails (`@other-user != @EtroxTaran`). Reply:

```
Nur der PR-Author (@EtroxTaran) darf /ai-review-Commands triggern.
```

metrics.jsonl: `{"command":"approve","dispatch_result":"rejected-auth",...}`

### 4. Rejected: waiver reason too short

Input:

```
/ai-review ac-waiver fp
```

Parse: reason is `"fp"` (2 chars). Generic-pattern matches AND length
check fails. Reply with the "Reason too short" template. No status
update, no workflow dispatch.

## Related Docs

- `docs/v2/40-ai-review-pipeline/05-security-waiver.md` - full audit
  rationale
- `docs/v2/40-ai-review-pipeline/06-nachfrage-soft-consensus.md` -
  soft-consensus flow
- `skills/security-waiver/SKILL.md` - user-facing composer
- `skills/ac-waiver/SKILL.md` - user-facing composer for AC side
