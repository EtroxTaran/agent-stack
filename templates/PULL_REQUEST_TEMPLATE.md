## Linked Issue

Closes #<N>

<!-- If multiple issues, use `Refs #N1`, `Refs #N2` and `Closes` only for the primary -->

## Summary

<1-3 bullet points: what this PR does and why>

## Acceptance Criteria Verification

<Copy Gherkin scenarios from the linked issue. Tick each, reference the test that proves it.>

- [ ] Scenario: "<title from issue>"
  - Verified by: `path/to/test.spec.ts`
- [ ] Scenario: "<title 2>"
  - Verified by: `path/to/other.spec.ts`

## Test Plan

- [ ] Unit tests added (TDD: red → green → refactor)
- [ ] E2E test with Playwright `page.route()` mocks (for UI changes)
- [ ] Manual smoke test in browser / CLI
- [ ] `pnpm typecheck && pnpm test` local green

## Screenshots

<For UI changes — before/after>

## Checklist

- [ ] Conventional Commits (`feat:`, `fix:`, `chore:`, ...)
- [ ] No secrets in diff
- [ ] AGENTS.md rules honored (TDD, No De-Scoping, Always-Latest)

---

AI-Review-Pipeline runs on push. Consensus status `ai-review-v2/consensus` is required for merge.
