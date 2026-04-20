---
name: tdd-guard
description: 'Use this skill to enforce the Red-Green-Refactor TDD cycle before touching a source file - companion to the opt-in shell hook (~/.claude/hooks/tdd-guard.sh, AI_TDD_GUARD=strict). Triggers on "TDD guard", "enforce TDD", "write test first", "red-green-refactor", "how to start TDD", "tdd-guard blocked me", "scaffold a failing test", "I need a failing test before I implement". When the hook blocks a write, this skill explains why, checks whether a matching test file exists, and scaffolds a failing-test stub (vitest/pytest/go-testing) when it does not. NOT for running tests (use review-gate), NOT for PR-level TDD-completeness review (use code-review-expert), NOT for generating implementation code. Reason to use over ad-hoc explanation - deterministic scaffold-then-Red-first workflow identical across Claude, Cursor, Gemini, Codex, so no CLI lets the author skip the Red step.'
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
  - Write
  - Glob
  - mcp__filesystem__read_text_file
  - mcp__filesystem__write_file
  - mcp__filesystem__search_files
---

# TDD Guard

Companion to the opt-in shell hook
`~/.claude/hooks/tdd-guard.sh` (enabled via `AI_TDD_GUARD=strict` in
the shell profile). When the hook blocks a source-file write, this
skill explains the Red -> Green -> Refactor cycle, verifies whether a
matching test already exists, and scaffolds a failing test if not.

## When to use

- The user hit `AI_TDD_GUARD blocked this write - see tdd-guard skill`.
- The user asks for the TDD workflow, the Red step, or a failing-test
  stub.
- A new feature is about to be written and no test is staged yet.

Stay silent on pure-refactor diffs (no behavioural change) - TDD
strictness there causes noise, not safety.

## TDD cycle (cite this verbatim when the user asks)

1. **Red** - write a test that describes the desired behaviour. Run it.
   It MUST fail. The failure proves the test is valid.
2. **Green** - write the minimum code needed to pass the test. Nothing
   more. Commit.
3. **Refactor** - clean up implementation and/or test without changing
   behaviour. Tests stay green. Commit.

Never skip Red. Never reverse Green and Refactor.

## Patterns required by the project

| Pattern | Where | Example |
|---|---|---|
| Arrange-Act-Assert (AAA) | Unit + integration tests | three blocks, one `act` |
| Given-When-Then | E2E (Playwright) | `test.describe('Given ...')` + `test('when ... then ...')` |
| Test Doubles | External deps (API/DB/n8n) | typed fakes/stubs/mocks, never `as any` |
| Contract Testing | API boundaries | both sides parse the same zod schema |
| Deterministic Time | any date/time logic | `vi.useFakeTimers({ now: ... })` or injected clock |
| Error-Path Parity | every happy path | at least one invalid-input / 4xx / timeout test |

## Inputs you may receive

- A source-file path the user was trying to edit
  (`apps/portal-api/src/routes/foo.ts`).
- A feature description with no files yet.
- Raw hook output pasted in.

## Workflow

### Step 1 - Identify the source file

Parse the file path from the hook message or user prompt. Resolve
relative -> absolute.

### Step 2 - Look for an existing test

For a source path like `apps/portal-api/src/routes/foo.ts`, look in
canonical locations:

```bash
src="apps/portal-api/src/routes/foo.ts"
stem="$(basename "$src" | sed -E 's/\.(ts|tsx|js|jsx|py|go)$//')"
dir="$(dirname "$src")"

candidates=(
  "$dir/$stem.test.ts" "$dir/$stem.test.tsx"
  "$dir/$stem.spec.ts" "$dir/$stem.spec.tsx"
  "$dir/__tests__/$stem.test.ts"
  "$dir/test_${stem}.py" "$dir/${stem}_test.py"
  "$dir/${stem}_test.go"
)
for c in "${candidates[@]}"; do [ -f "$c" ] && echo "FOUND: $c"; done
```

Also fall back to a repo-wide search for the source filename inside
test files:

```bash
grep -rln --include='*.test.*' --include='*.spec.*' --include='test_*.py' \
  --include='*_test.py' --include='*_test.go' \
  -E "from.*/$stem['\"]|import.*$stem[\" ]|${stem}_test" \
  -- tests/ apps/ packages/ plugins/ 2>/dev/null
```

If at least one test is found AND it references the feature, verify it
is in the Red state before allowing the source edit. Run the test and
confirm it fails:

```bash
# language-appropriate: vitest --run --reporter verbose <path>, pytest -xvs <path>, etc.
```

If the test passes, the user is in Green/Refactor - the hook should
have allowed the write. Suggest they re-check the hook logic. Do not
scaffold a new test.

### Step 3 - No test found -> scaffold one

Use `scripts/scaffold_test.py`:

```bash
python3 scripts/scaffold_test.py "<source-path>" --write
```

The script picks the right template (TS/TSX -> vitest, JS/JSX -> vitest,
Python -> pytest, Go -> `testing`) and writes next to the source under
the canonical filename. It refuses to overwrite an existing file.

If language is not auto-detected, pass `--lang`. If the language is
outside supported set, emit a hand-written stub following the
AAA/GWT templates below.

### Step 4 - Tell the author what to do next

Print a single block:

```
TDD Red step scaffolded.
Test file: <path-to-test>
Next actions:
  1. Open the test and name the first `it` / `def test_` in intent form.
  2. Fill in Arrange + Act + Assert using AAA.
  3. Run the test. Confirm it FAILS (Red):
     - vitest:  pnpm test <test-path>
     - pytest:  pytest -xvs <test-path>
     - go:      go test ./<dir>
  4. Only after Red is confirmed, implement <source-file>.
  5. Run the test again. It must pass (Green).
  6. Refactor source + test with tests staying green.
```

### Step 5 - If the user insists on skipping Red

There is no path inside this skill. The project-level rule is absolute:
"Kein Code darf als fertig gelten, wenn der zugehoerige Test nicht
vorher (im Red-State) existierte." (from project CLAUDE.md).

The only override is the escape hatch documented for human operators:
`git commit --no-verify` on the author's local machine. The skill does
not invoke or recommend that flag.

## Stub templates (for unsupported languages)

If the source file is in a language the script does not support, apply
the same AAA shape manually:

```text
// Arrange
<minimal input>

// Act
<call the function under test>

// Assert
<assert the exact observable outcome>
```

For E2E (Playwright) tests, use Given-When-Then:

```ts
test.describe('Given a logged-in user', () => {
  test('when they visit /dashboard then the summary renders', async ({ page }) => {
    // Arrange (mocks via page.route())
    await page.route('**/api/v1/summary', (route) => route.fulfill({ json: MOCK }));

    // Act
    await page.goto('/dashboard');

    // Assert
    await expect(page.getByRole('heading', { name: /summary/i })).toBeVisible();
  });
});
```

## Edge cases

- **Source file is a pure re-export / barrel file** - no test required.
  Tell the user and let them proceed.
- **Source file is a config** (`*.config.ts`, `tsconfig.json`) - no
  test required.
- **Source file is an ADR / doc** - no test required.
- **Multi-file feature** - scaffold one test per file that carries
  observable behaviour; shared helpers get tested via their callers.

## Integration points

- Paired with the opt-in Bash hook in `~/.claude/hooks/tdd-guard.sh`
  (`AI_TDD_GUARD=strict`). The hook calls into this skill's behaviour
  but the skill is usable without the hook.
- `code-review-expert` enforces TDD completeness at PR time (checklist
  item 4); this skill enforces it at write time.
- `review-gate` runs the resulting tests before push.
- `ac-validate` ties tests back to Gherkin ACs on the PR.

## Scripts

- `scripts/scaffold_test.py` - pure stdlib, supports TS/TSX/JS/JSX
  (vitest), Python (pytest), Go (`testing`). `--write` materializes the
  file; default emits to stdout.

## References

- `references/tdd-patterns.md` - AAA, Given-When-Then, Test Doubles,
  Contract Testing, Deterministic Time, Error-Path Parity with
  examples for the project's stack.
