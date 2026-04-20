---
name: security-waiver
description: 'Use this skill to compose and post a structured `/ai-review security-waiver` comment when Stage 2 (Security) flagged a finding the user has decided is a false positive. Triggers on "security waiver", "waive this security finding", "false positive security", "/ai-review security-waiver", "security-stage fehlalarm", "gemini hat halluziniert". Pre-flights that Security is actually `failure`, asks for a concrete reason (or parses from args), enforces the 30-char minimum and a no-generic-phrases guard, then posts via the gh MCP and warns about the audit trail (commit-status 140-char cap + sticky + metrics.jsonl, per-commit, author-only). NOT for real vulnerabilities (fix the code), not for code / design / AC waivers (other skills), not for skipping Security entirely. Reason to use over `gh pr comment` - every waiver lands with the same reason-quality gate and audit messaging regardless of CLI.'
license: MIT
metadata:
  version: 0.1.0
  status: draft
  audience: [claude, cursor, gemini, codex]
compatibility:
  agent-skills-spec: "1.0"
allowed-tools:
  - Bash
  - Read
  - Grep
  - mcp__github__get_pull_request
  - mcp__github__get_pull_request_status
  - mcp__github__add_issue_comment
---

# Security Waiver

Helps a user override a Stage-2 (Security) false positive with a valid,
audit-logged waiver. The skill composes the PR comment - the
`nachfrage-respond` skill consumes it on the server side.

## When to invoke

- User says "this Gemini finding is a false positive".
- User pastes a Security-stage finding and argues against it.
- User explicitly asks for `/ai-review security-waiver`.

## When NOT to invoke

- The finding looks legit -> fix the code, do not waive.
- Stage 2 did not fail (`ai-review/security` is `success` / `pending`
  / missing) -> no waiver needed; suggest the user check the sticky
  comment instead.
- User wants to waive a code / design / AC-stage finding -> use the
  right skill (`ac-waiver` for Stage 5, no waiver exists for Stage 1/4
  by design).
- User wants to merge around a security veto without reading the
  finding -> refuse; this is exactly the scenario the audit trail
  exists to catch.

## Preconditions

1. PR number `N` is known (either provided or derived via
   `gh pr view --json number`).
2. `gh auth status` OK.
3. User is the PR-author (`gh pr view --json author`). If not, stop
   and explain: waivers are author-only, ask the author to invoke
   this skill.

## Inputs

- `pr_number` (int) - mandatory if not in a checked-out PR branch.
- `reason` (string, optional) - if not given, ask the user
   interactively.

## Workflow

### Step 1 - Pre-flight: is Security actually failing?

```bash
PR_HEAD=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
statuses=$(gh api "repos/$REPO/statuses/$PR_HEAD")
sec_state=$(echo "$statuses" | jq -r '[.[] | select(.context=="ai-review/security")][0].state')
```

- `sec_state == "failure"` -> proceed.
- `sec_state` is `success` / `pending` / empty -> stop. Explain to the
  user that no waiver is needed (or that the stage has not finished
  yet). Suggest re-running the review or just merging.

### Step 2 - Require a concrete reason

If `reason` was not passed in, ask:

> Was genau ist an dem Security-Finding falsch? Beschreibe das
> konkrete Finding (Zeile, Pattern, Tool) und warum du es als
> False-Positive einstufst. Mindestens 30 Zeichen, keine Floskeln.

Do NOT accept the user's first one-line answer at face value. If the
response is under 30 chars OR matches the generic pattern
`^(fp|ok|done|false|trust me|lgtm|sure|bekannt)\b`, ask again with a
concrete example:

> "fp" reicht nicht. Beispiel:
> "Gemini hat `actions/checkout@v4` in line 29 als malformed path
> markiert - die Datei enthaelt tatsaechlich den korrekten Ref, nachgeprueft via cat."

Iterate until the reason passes both checks OR the user gives up (in
which case: do not post anything).

### Step 3 - Confirm before posting

Show the user the exact comment that will be posted:

```
/ai-review security-waiver <reason>
```

And repeat the audit summary BEFORE posting:

- Commit-status `ai-review/security-waiver` description will contain
  the first 140 chars of the reason.
- A sticky comment (`<!-- nexus-ai-review-security-waiver -->`) will
  carry the full reason as permanent audit trail.
- `.ai-review/metrics.jsonl` will gain a new row with commit SHA + full
  reason.
- The waiver is bound to the current commit SHA; pushing new commits
  invalidates it.
- Only the PR-author may waive; posting from a different account
  fails the server-side check.

Wait for explicit user confirmation. Do not post on ambiguous input
("ok", "yes?", empty).

### Step 4 - Post the comment

```bash
gh pr comment "$PR" --body "/ai-review security-waiver $reason"
```

Or via `mcp__github__add_issue_comment` when gh CLI is not available.

### Step 5 - Report

Single-line report plus follow-up hints:

```
Security-Waiver gepostet: PR #<N>, commit <sha7>.

Next:
- Warte auf ai-review-nachfrage Workflow (~1 min).
- Wenn validiert: ai-review/security-waiver = success, consensus
  wird re-computed und das Security-Veto geschattet.
- Wenn abgelehnt: Kommentar-Reply mit Grund - fix reason und
  erneut.
```

## Guidelines: when is a Security waiver legitimate?

See `references/security-waiver-guidelines.md`. Short version:

1. **LLM hallucinated a finding** - Gemini / Claude reported a line
   or pattern that does not exist. Verified via `cat`, `grep`, or by
   re-reading the referenced file.
2. **Known-safe pattern** - e.g. a test fixture with a fake
   credential, a regex that intentionally matches a demo token, a
   string that LOOKS like a secret but is public.
3. **Context-unaware SAST** - semgrep / Bandit flags a pattern that
   is actually correct in context (e.g. `eval` on a trusted compiler
   output).
4. **Duplicate finding** - same issue reported twice; waive the
   duplicate, keep the canonical one open.

Illegitimate (fix the code instead):

- Actual unescaped user input -> escape it.
- Actual secret in the diff -> rotate + remove via `git filter-repo`.
- Actual SQLi / XSS / SSRF / RCE vector -> patch.
- "It works in prod" -> not an argument; prod can be vulnerable too.

## Error handling

- gh CLI returns 404 on `statuses` -> PR head may have been force-pushed;
  re-read and retry once.
- gh CLI returns 422 on `add_issue_comment` -> PR may be closed; report
  and stop.
- User refuses to provide a longer reason -> abort without posting.
  Do not compose a synthetic reason on their behalf.

## Integration points

- Feeds `nachfrage-respond` skill on the server side.
- Sibling of `ac-waiver` skill (analogous structure for Stage 5).
- Invoked after `code-review-expert` or the AI-review pipeline has
  produced a Security finding the user disagrees with.

## References

- `references/security-waiver-guidelines.md` - full legit-vs-not
  checklist with worked examples for each scenario.
