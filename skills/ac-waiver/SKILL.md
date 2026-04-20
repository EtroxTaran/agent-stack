---
name: ac-waiver
description: 'Use this skill to compose and post a structured `/ai-review ac-waiver` comment when Stage 5 (AC-Validation) flagged a mismatch the user has verified is a false positive - typically because a test covers the AC under a different naming convention than the parser expects. Triggers on "ac waiver", "acceptance criteria waiver", "/ai-review ac-waiver", "AC false positive", "AC-Validation Fehlalarm", "AC-Parser sieht meinen Test nicht". Pre-flights that AC-Validation is `failure`, requires a concrete reason (>=30 chars, no generic phrases), strongly recommends naming the test file in the reason, posts the comment, warns about the audit trail (commit-status 140-char cap + sticky + metrics.jsonl, per-commit, author-only). NOT for skipping AC-Validation entirely, not for real missing coverage (write the test), not for security waivers (use `security-waiver`). Reason to use over `gh pr comment` - enforces the "name the test file" discipline and author-only rule uniformly across CLIs.'
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
  - Glob
  - mcp__github__get_pull_request
  - mcp__github__get_pull_request_status
  - mcp__github__add_issue_comment
---

# AC Waiver

User-facing composer for the `/ai-review ac-waiver <reason>` command.
Stage 5 of the AI-review pipeline parses Gherkin ACs from the linked
issue and tries to match each AC to at least one test file. When the
match fails for non-coverage reasons (AC covered by a test with a
different slug, AC implicitly covered by an integration test, etc.),
this skill composes the waiver.

## When to invoke

- User says "the AC-check is wrong, that AC IS tested".
- User says "AC-Parser hat meinen Test uebersehen".
- User explicitly asks for `/ai-review ac-waiver`.

## When NOT to invoke

- The AC really is NOT tested -> write the test (Red-Green-Refactor).
  The whole point of Stage 5 is to force test coverage; waiving it
  because "I will do it next PR" is hygiene debt.
- AC-Validation did not fail (`ai-review/ac-validation` is success /
  pending / missing) -> no waiver needed.
- Security waiver -> use `security-waiver` skill.
- User wants to merge a PR with no ACs at all -> stop. A feature
  without ACs is under-specified; amend the issue first.

## Preconditions

1. PR number `N` is known.
2. `gh auth status` OK.
3. User is the PR-author.
4. Stage 5 (`ai-review/ac-validation`) is `failure` on the current
   head SHA.

## Inputs

- `pr_number` (int) - mandatory if not on a checked-out PR branch.
- `reason` (string, optional) - if not given, ask the user.

## Workflow

### Step 1 - Pre-flight: is AC-Validation actually failing?

```bash
PR_HEAD=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
statuses=$(gh api "repos/$REPO/statuses/$PR_HEAD")
ac_state=$(echo "$statuses" | jq -r '[.[] | select(.context=="ai-review/ac-validation")][0].state')
```

- `ac_state == "failure"` -> proceed.
- Anything else -> stop. Explain what the current state is and what
  the user might actually want (e.g. push a commit so Stage 5 re-runs,
  or look at the Nachfrage sticky comment for the real blocker).

### Step 2 - Require a concrete reason

Ask, if `reason` was not passed in:

> Welches AC aus dem verknuepften Issue wurde vom AC-Parser als
> "MISSING" markiert, obwohl es tatsaechlich durch einen Test
> abgedeckt ist? Nenne explizit:
> - Die AC-Nummer oder den Gherkin-Scenario-Titel.
> - Den Test-Datei-Pfad und idealerweise die Zeile.
> - Warum der Parser den Test nicht automatisch gefunden hat
>   (unterschiedliche Slug-Namen, anderer Layer, etc.).
> Mindestens 30 Zeichen, keine Floskeln.

### Step 3 - Recommend naming the test file

Before accepting the reason, check whether it names a test file
(`tests/...`, `e2e/...`, `*.test.ts`, `*.spec.ts`, `test_*.py`).

If not, strongly nudge:

> Deine Begruendung nennt keinen Test-Dateipfad. Das macht den Audit
> schwach - die naechste Review kann nicht verifizieren, dass du
> wirklich geprueft hast. Falls das AC wirklich gedeckt ist, nenne
> die Datei explizit, z.B.:
> "AC-2 ist gedeckt durch e2e/onboarding.spec.ts:42 ('user can
> complete signup with fresh email'), der AC-Parser erkennt den
> Scenario-Titel nicht weil er auf den Issue-Slug
> 'user-can-sign-up' matcht."
>
> Sonst: Waiver ist ehrlicher - schreib den Test, statt zu waivern.

The user may still insist without a test path (some ACs are covered
by manual smoke tests only). Accept it on the second prompt, but log
a warning in the report.

### Step 4 - Reason quality gate

Same rules as `security-waiver`:

- >= 30 chars after whitespace strip.
- Not matching generic pattern `^(fp|ok|done|trust me|lgtm|sure|covered|tested)\b`.

The `covered|tested` additions catch the common lazy AC-waiver
reasons ("tested - trust me").

### Step 5 - Confirm + audit warning

Show the exact comment and warn before posting:

- Commit-status `ai-review/ac-waiver` description = first 140 chars
  of reason.
- Sticky comment `<!-- nexus-ai-review-ac-waiver -->` with full reason.
- `.ai-review/metrics.jsonl` entry with SHA + reason.
- Waiver is per-commit; force-push or rebase invalidates it.
- Only PR-author can waive.

Wait for explicit confirmation.

### Step 6 - Post

```bash
gh pr comment "$PR" --body "/ai-review ac-waiver $reason"
```

Or via `mcp__github__add_issue_comment`.

### Step 7 - Report

```
AC-Waiver gepostet: PR #<N>, commit <sha7>.

Notes:
- Test-Datei in Reason: <yes|no - warning logged>
- Naechster Schritt: ai-review-nachfrage dispatch (~1 min).
- Wenn validiert: ai-review/ac-waiver=success, consensus re-computed.
- Wenn ac-validation beim naechsten push wieder failed, ueberdenke
  den Waiver - vielleicht fehlt der Test doch.
```

## When is an AC waiver legitimate?

See `references/ac-waiver-guidelines.md`. Short version:

1. **Slug-mismatch** - Gherkin scenario title does not match the
   test name the parser expects; the test exists and is green.
2. **Cross-layer coverage** - AC is functional, covered by an E2E
   test, but the parser only scans unit tests.
3. **Integration-via-composition** - AC is covered by the sum of
   two tests in different files, no single test matches.
4. **Manual smoke only** - AC is inherently manual (visual polish,
   a11y hover state that Playwright cannot assert reliably). Rare;
   document the manual procedure in the waiver reason.

Illegitimate (write the test instead):

- "I will add the test in a follow-up PR" - no. Write the test now.
- "The test is obvious, not worth the overhead" - every AC needs a
  test; that is the deal.
- "The implementation is simple, does not need testing" - simple
  code regresses just as easily as complex code.

## Error handling

- gh returns 404 on `statuses` -> head may have been force-pushed;
  re-read + retry once.
- User refuses to provide a test-file path AND reason is only
  marginally over 30 chars -> still post (second-prompt acceptance),
  but the report must flag the weak audit trail.
- AC-Parser output not found -> cannot pre-flight. Explain and ask
  the user to re-run Stage 5, or post the waiver with the heads-up
  that without a current failure, the waiver is a no-op.

## Integration points

- Feeds `nachfrage-respond` skill on the server side.
- Sibling of `security-waiver` skill (same structure, different
  stage).
- Invoked after the AI-review pipeline Stage 5 posts a sticky with
  MISSING ACs.

## References

- `references/ac-waiver-guidelines.md` - legit scenarios, illegit
  scenarios, and reason-quality templates.
