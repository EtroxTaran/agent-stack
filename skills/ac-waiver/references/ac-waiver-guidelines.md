# AC Waiver - When Is It Legitimate?

Reference for the `ac-waiver` skill. Use this as the mental filter
BEFORE composing a waiver. Default action is "write the test"; a
waiver is the exception.

## Legitimate Scenarios

### 1. Slug mismatch (most common)

AC-Parser derives a slug from the Gherkin scenario title:

```
Scenario: User can log in with valid credentials
```

becomes `user-can-log-in-with-valid-credentials`. The parser then
searches for `user-can-log-in*` in test names. Your test happens to
be named:

```ts
describe('auth', () => {
  it('accepts email + password -> returns session', () => { ... });
});
```

Not a naming match, but semantically it IS the AC.

Waiver reason:

```
AC-1 "User can log in with valid credentials" ist gedeckt durch
tests/auth/login.test.ts:14 (`accepts email + password -> returns
session`). Der AC-Parser matcht auf den Slug
`user-can-log-in-with-valid-credentials`, unsere Test-Convention
nutzt kuerzere Intent-Form (`accepts ... -> returns ...`).
```

Follow-up (not required, but recommended): rename the test on the
next non-hotfix PR to match the AC slug, so future PRs do not need
the same waiver.

### 2. Cross-layer coverage

AC is user-facing behavior, covered only by an E2E test:

```
Given the user is on /signup
When they submit a valid form
Then they see /welcome and a session cookie exists
```

Playwright covers this end-to-end. The AC-Parser scans `tests/` (unit)
and misses `e2e/`.

Waiver reason:

```
AC-2 ist gedeckt durch e2e/signup.spec.ts:22 ("Given valid signup
form, then lands on /welcome with session cookie"). AC-Parser scant
nur tests/** - die E2E-Pfad-Scans haengen an Playwright-Naming.
Funktional verifiziert, laeuft in jedem CI-Run gruen.
```

Follow-up: extend the AC-Parser config to scan `e2e/` too, so this
never happens again.

### 3. Integration-via-composition

AC is "the trip-window rule" which is covered by the combination of:

- `tests/finance/categorization.test.ts` (happy-path)
- `tests/finance/trip-overlap.test.ts` (tiebreaker)
- `tests/finance/categorization-i18n.test.ts` (slug normalization)

No single test carries the AC slug. The parser can only see one
file per AC by design.

Waiver reason:

```
AC-3 "Transaction in Trip-Window erhaelt Trip-Kategorie statt
Account-Kategorie" ist gedeckt durch die Summe von:
- tests/finance/categorization.test.ts:45 (Happy-Path)
- tests/finance/trip-overlap.test.ts:12 (Tiebreaker newest-createdAt)
- tests/finance/categorization-i18n.test.ts:8 (Slug-Normalisierung)
Kein einzelner Test matcht den AC-Slug - compositional coverage.
```

### 4. Manual smoke only (rare)

AC is inherently visual or a11y-related and cannot be automated
reliably. Example: "the focus ring matches the design-token
`--ring`".

Waiver reason:

```
AC-4 "Focus-Ring nutzt Design-Token --ring, nicht hardcoded blau"
ist nicht E2E-automatisierbar (Playwright kann computed-styles
nicht verlaesslich auf CSS-Variable-Resolution pruefen). Manuell
verifiziert via DevTools auf /login, /signup, /settings - alle
drei Screens zeigen `outline-color: oklch(0.61 0.2 258.09)`
(chart-1 Token).
```

This reason is pushing the 30-char minimum by a lot. Always prefer
Playwright's `toHaveCSS` or a visual-regression test when possible.

## Illegitimate Scenarios

### "I will add the test in a follow-up PR"

No. The TDD rule is Red -> Green -> Refactor, not Green -> Merge ->
Red-later. The AC-Validation stage exists to enforce this.

If you really cannot add the test in this PR (e.g. the test harness
itself is being rewritten), tactical options:

- Split the PR: land the test-harness rewrite first, then the
  feature.
- Add a skipped test with a TODO comment and an issue link. Stage 5
  accepts skipped tests IF they carry the AC slug. It is ugly but
  honest - and shows up in weekly metrics as skipped-test debt.

### "The test is obvious"

Every AC needs a test. "Obvious" features regress the same as complex
ones; "obvious" tests are the easiest to write anyway.

### "Implementation is too simple to test"

Simple code breaks too, especially under refactoring. Simple code is
the EASIEST to test.

### "LLM generated the implementation, I trust it"

LLM-generated code is exactly the code that MOST needs a human-
authored test. Waiving an AC on LLM code is actively dangerous.

## Reason Quality Checklist

Before posting, verify your reason contains:

- [ ] The specific AC number or scenario title.
- [ ] At least one test-file path with a line number.
- [ ] WHY the parser missed it (naming, layer, composition).
- [ ] Optionally: a follow-up plan (rename test, extend parser
  scan path, etc.).

A reason that names NO test file is a yellow flag in the weekly
metrics review - it is the single most-common audit-weak waiver.

## Reasons That Trigger The Generic-Filter

Do NOT start your reason with:

- `covered`, `tested`, `done`, `lgtm`, `fine`
- `trust me`, `obviously`, `simple`
- `wird schon`, `ist gedeckt` (ohne Dateipfad)

The filter is syntactic - it does not read your mind. Start with the
AC number and the test file, not with a verdict.

## Weekly Review

`metrics_summary.py --since 7d --json | jq '.ac_waivers'` surfaces:

- `count`
- `reasons_without_test_file` - waivers whose reason did not name a
  test path. Investigate these first; they are the weakest audit
  trail.

If AC waivers are trending up, usually one of:

1. AC-Parser is outdated - extend scan paths (`e2e/`, `test/`, etc.).
2. Test naming conventions drift from Gherkin slugs - agree on a
   convention, rename old tests.
3. Authors are genuinely skipping tests - uncomfortable conversation.

## Related

- `skills/nachfrage-respond/SKILL.md` - server-side consumer
- `skills/security-waiver/SKILL.md` - sibling for Stage 2
- `skills/pr-open/SKILL.md` - seeds the AC-Verification table
- `docs/v2/40-ai-review-pipeline/05-security-waiver.md` - design doc
  (same audit-trail mechanics for both waiver types)
