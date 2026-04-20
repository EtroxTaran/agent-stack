# Gherkin Coverage Patterns

Reference for the `ac-validate` skill. Shows how AC text maps to test
code under the heuristic in `scripts/find_ac_tests.py`, with worked
examples that illustrate where the heuristic is reliable and where a
human reviewer still needs to read the code.

## How the heuristic scores

Per AC:

1. Parse the Scenario title - derive a kebab slug (same rule as
   `issue-pickup`) and a keyword set from the title words minus stop
   words.
2. Parse every `Then` / `And` / `But` line - collect keywords (stop
   words dropped).
3. For each test file:
   - `matches = keyword_hits + (slug_in_file ? 1 : 0) + (title_hits / 2)`
   - `required = max(2, min(4, len(then_keywords)))`
   - Verdict: `covered` if `matches >= required`, `partial` if `> 0`,
     `uncovered` otherwise.

Stop words include: `the`, `and`, `for`, `with`, `from`, `that`, `this`,
`then`, `when`, `should`, `must`, `will`, `have`, `has`, `can`, `not`,
`are`, `was`, `were`, `user`, `users`, `page`, `show`, `shows`, `see`,
`seen`, `system`, `feature`, `scenario`.

## Example 1 - reliable mapping

**Issue body**

````
```gherkin
Feature: login
  Scenario: user can log in with valid credentials
    Given a registered user
    When they submit correct credentials
    Then the dashboard is rendered
    And a session cookie is set
```
````

**Derived**
- slug: `user-can-log-in-with-valid-credentials`
- then-keywords: `dashboard`, `rendered`, `session`, `cookie`, `set`
- required: 4

**Good test (covered)**

```ts
// tests/auth/login.test.ts
describe('AC-1: user can log in with valid credentials', () => {
  it('renders the dashboard and sets a session cookie', async () => {
    ...
    expect(res.headers.get('set-cookie')).toMatch(/session=/);
    expect(await page.getByRole('heading', { name: /dashboard/i }).isVisible()).toBe(true);
  });
});
```

Slug + 4 keywords = matches = 5, required = 4 -> `covered`.

**Author tip:** embed `AC-N: <slug>` in the `describe` or `it` title -
it guarantees the slug hit and anchors reviewers to the spec.

---

## Example 2 - partial coverage (author must strengthen)

**Issue body**

````
```gherkin
Scenario: audit trail is written for each login
  Given a registered user
  When they log in successfully
  Then an entry is written to the audit log with actor + timestamp
  And the entry survives a restart of the portal process
```
````

**Existing test**

```ts
describe('login', () => {
  it('returns 200 on valid creds', async () => {
    ...
    expect(res.status).toBe(200);
  });
});
```

The test mentions `login` but no audit/keyword hit. Status: `partial`
(some title word hits, no Then-clause evidence).

**Fix:** add dedicated assertions or a new test:

```ts
it('AC-2: writes an audit entry with actor and timestamp on login', async () => {
  const entries = await db.query('SELECT * FROM audit_log WHERE action = "login"');
  expect(entries).toHaveLength(1);
  expect(entries[0]).toMatchObject({
    actor: 'alice@example.com',
    action: 'login',
    timestamp: expect.any(Date),
  });
});
```

---

## Example 3 - uncovered (needs new test)

**Issue body**

````
```gherkin
Scenario: login is rate-limited after five failed attempts
  Given a registered user
  When six invalid-password login attempts occur within a minute
  Then the sixth attempt returns 429
  And a lockout entry is recorded
```
````

**Repo scan finds no test file matching** `rate-limit`, `429`, or
`lockout`. Verdict: `uncovered`.

**Blocking remediation:** add `tests/auth/rate-limit.test.ts`:

```ts
it('AC-3: sixth attempt within a minute returns 429', async () => { ... });
it('AC-3: lockout entry is recorded after fifth failure', async () => { ... });
```

---

## Example 4 - heuristic limitation (false positive)

If the Scenario title is very generic, e.g. `Scenario: create record`,
the keyword set collapses to `create`, `record` and several unrelated
test files may score as `covered`. In that case the author should:

- Rename the Scenario to something distinctive (`create a finance
  invoice with tax lines`).
- OR use `describe('AC-1: create a finance invoice', ...)` in the test
  so the slug hit fires.

The skill does not try to infer semantic equivalence - it reports what
grep can see.

---

## Example 5 - heuristic limitation (false negative)

Scenario uses verbs like "returns", test uses "yields". Keywords
diverge. Score: `partial` or `uncovered` even though the test is
correct.

Options:
- Rename test to include one keyword from the Then clause.
- Or invoke `/ai-review ac-waiver` with a reason citing the AC id and
  the specific test path. The waiver is logged and reviewed - it does
  not silently pass.

---

## Recommended author conventions

- Embed `AC-N` in `describe` / `it` titles.
- Use noun-phrase Scenario titles (`dashboard is rendered`) over
  auxiliaries-only (`it works`).
- When a single test covers multiple ACs, mention each slug in a
  `it.each([...])` title.
- For Playwright E2E: `test('AC-3: sixth attempt within a minute
  returns 429', async () => { ... })` scores cleanly.

---

## Heuristic boundaries (honest statement)

The skill is **keyword-based**. It is not a parser that understands
Gherkin semantics or test intent. Use `partial` and `uncovered` as
prompts for a human review, not as a ground-truth oracle. The
`/ai-review ac-waiver` escape hatch exists for false positives the
heuristic cannot be expected to resolve.
