# TDD Patterns - Reference

Reference for the `tdd-guard` skill. Covers the patterns every test in
this codebase must follow. Sourced from AGENTS.md (TDD section) and
the project-level CLAUDE.md rules.

## Red -> Green -> Refactor

1. **Red** - write a test for the intended behaviour. Run it. It MUST
   fail. The failure proves the test is valid.
2. **Green** - write the minimum implementation to pass the test.
   Nothing more.
3. **Refactor** - clean up structure without changing behaviour. Tests
   stay green.

Never skip Red. Never reverse Green and Refactor.

---

## Arrange-Act-Assert (AAA)

One test = one `act`. Visible three-section structure.

```ts
it('returns the sum of two positive integers', () => {
  // Arrange
  const a = 2;
  const b = 3;

  // Act
  const result = sum(a, b);

  // Assert
  expect(result).toBe(5);
});
```

Python variant:

```python
def test_sum_returns_sum_of_two_positive_integers() -> None:
    # Arrange
    a, b = 2, 3

    # Act
    result = sum_(a, b)

    # Assert
    assert result == 5
```

---

## Given-When-Then (BDD)

Required for Playwright E2E tests. Outer `describe` describes the
precondition; inner `test` describes trigger + expected outcome.

```ts
test.describe('Given a logged-in user', () => {
  test('when they visit /dashboard then the summary renders', async ({ page }) => {
    // Arrange: mock the summary API
    await page.route('**/api/v1/summary', (route) =>
      route.fulfill({ json: MOCK_SUMMARY }),
    );

    // Act
    await page.goto('/dashboard');

    // Assert
    await expect(page.getByRole('heading', { name: /summary/i })).toBeVisible();
  });
});
```

### Playwright gotchas

- Set `page.route()` BEFORE `page.goto()`.
- URL-pattern suffix `**` matters:
  `**/api/v1/research/runs` does NOT match `/research/runs?limit=20`;
  use `**/api/v1/research/runs**`.
- `getByText('Claims (2)')` in strict mode needs `.first()` when
  multiple elements match.

---

## Test Doubles

Typed, never `as any`. Options-injected where possible, not
module-level monkey-patches.

| Double | Purpose | Example |
|---|---|---|
| Fake | in-memory stand-in | `class FakeUserRepo implements UserRepo { ... }` |
| Stub | fixed returns | `{ fetchQuotes: async () => MOCK_QUOTES }` |
| Mock | call verification | `vi.fn<[string], Promise<Quote>>()` |
| Spy | wraps the real fn | `vi.spyOn(obj, 'method')` |

Services expose external dependencies as options:

```ts
// Service factory
export function createFinanceService(deps: FinanceServiceDeps) { ... }

// Production
createFinanceService({ fetchQuotes: nativeFetchQuotes });

// Test
createFinanceService({ fetchQuotes: async () => MOCK_QUOTES });
```

---

## Contract Testing

When two modules speak across a boundary, they parse the **same** zod
schema in their tests - not separate hand-rolled fixtures.

```ts
// shared/contract.ts
export const TransactionSchema = z.object({
  id: z.string(),
  amount: z.number(),
  createdAt: z.string().datetime(),
});

// producer.test.ts
const parsed = TransactionSchema.parse(producer.toJson(tx));
expect(parsed.amount).toBe(42);

// consumer.test.ts
const incoming = TransactionSchema.parse(apiResponse);
expect(consumer.apply(incoming)).toBe(...);
```

---

## Deterministic Time

Any test touching date/time logic must control the clock.

```ts
import { vi } from 'vitest';

beforeEach(() => {
  vi.useFakeTimers({ now: new Date('2026-04-17T12:00:00Z') });
});

afterEach(() => {
  vi.useRealTimers();
});
```

Alternative: inject a clock adapter into the service under test.

```ts
interface ServiceDeps { now: () => Date; }

createService({ now: () => new Date('2026-04-17T12:00:00Z') });
```

No raw `Date.now()` / `new Date()` in production code that isn't
routed through the adapter.

---

## Error-Path Parity

Every happy-path assertion needs an error-path counterpart test. Ratio
is 1:1 minimum.

```ts
describe('parseInvoice', () => {
  it('parses a valid invoice payload', () => {
    expect(parseInvoice(VALID)).toMatchObject({ total: 42 });
  });

  it('rejects an invoice with negative total', () => {
    expect(() => parseInvoice({ ...VALID, total: -1 })).toThrow(/total/i);
  });

  it('rejects an invoice missing createdAt', () => {
    const { createdAt: _omit, ...bad } = VALID;
    expect(() => parseInvoice(bad)).toThrow(/createdAt/i);
  });
});
```

For HTTP boundaries: always test 4xx + 5xx + timeout in addition to
2xx.

---

## Forbidden Patterns

- **No-op Assertions** - `expect(result).toBeDefined()` without a
  follow-up assertion on the value.
- **Coverage Theater** - tests that run a branch without asserting
  on its output.
- **Mocked-Mock Tests** - tests that only assert mocks were called,
  not that logic is correct.
- **Unreachable Branches** - tests for code paths protected by
  upstream zod validation or exhaustive unions.
- **Snapshot Churn** - inline/file snapshots over dynamic outputs
  (timestamps, ids, reorderable arrays).
- **Timer Flakes** - `setTimeout` / real clock in a time-sensitive
  test without `useFakeTimers` or a clock adapter.

---

## Stub file templates (mirror of `scripts/scaffold_test.py`)

### TypeScript (vitest)

```ts
import { describe, it, expect } from 'vitest';
import { /* symbol */ } from './<source-stem>';

describe('<source-stem>', () => {
  it('should <behaviour in intent form>', () => {
    // Arrange
    // Act
    // Assert
    expect(true).toBe(false); // Red
  });
});
```

### Python (pytest)

```python
"""Tests for <source-stem>."""


def test_<source_stem>_should_describe_first_behaviour() -> None:
    # Arrange
    # Act
    # Assert
    assert False, "TDD Red"
```

### Go (testing)

```go
package <pkg>

import "testing"

func Test<Name>(t *testing.T) {
    // Arrange
    // Act
    // Assert
    t.Fatalf("TDD Red")
}
```
