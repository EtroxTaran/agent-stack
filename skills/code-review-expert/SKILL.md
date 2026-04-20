---
name: code-review-expert
description: Use this skill to perform a senior-engineer PR review across a diff or branch. Triggers on "review the PR", "code review", "check this diff", "senior review", "SOLID violations", "security risks in this change", "review my branch", "is this PR ready to merge". Produces structured findings (path:line refs) covering architecture, correctness, type safety, TDD completeness, error paths, security, performance, and commit hygiene. NOT for formatting-only changes, simple typo fixes, pure UI-polish, or generating new code from scratch. Reason to use over ad-hoc review - enforces a consistent cross-tool checklist identical on Claude, Cursor, Gemini, Codex, so reviews do not drift with the CLI.
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
  - mcp__github__get_pull_request_files
  - mcp__github__get_pull_request_comments
  - mcp__filesystem__read_text_file
---

# Code Review Expert

Generic senior-engineer PR-Review-Checklist. Tool-neutral. Works on a local
diff, a GitHub PR number, or a branch comparison. Emits findings as
`path:line - category - severity - message - suggested fix`.

## When to use

Invoke when the user asks for a review, code critique, SOLID check,
"is this PR ready", or a diff-level security sanity-check. Stay silent on
pure-format or typo patches - they waste reviewer attention.

## Inputs you may receive

- A PR number (e.g. `#42`) plus repo context - use `github` MCP to fetch
  diff and metadata.
- A range (`main..HEAD`, `origin/main...feature/foo`) - use `git diff`.
- A single file path plus context - use `Read` / `filesystem` MCP.
- Raw diff pasted by the user - review inline.

## Workflow

1. Acquire the diff. Prefer structured form:
   - GitHub PR: `mcp__github__get_pull_request_files` for the file list
     + `mcp__github__get_pull_request` for title/body/labels.
   - Local branch: `git diff <base>...<head> --stat` then per-file
     `git diff <base>...<head> -- <path>`.
2. Acquire context for each changed file. Open the full file (not just
   the hunk) - reviewing only hunks misses ripple effects.
3. Run the eight-category checklist below. Stop at first blocking finding
   per category only if time-boxed - otherwise log all.
4. Render findings in the Output Format. Group by severity. End with a
   verdict: `APPROVE`, `REQUEST_CHANGES`, `COMMENT`.

## Review Checklist (eight categories)

### 1. Architecture & Design

- Single Responsibility - does each new class/function do exactly one thing?
- Open/Closed - are extension points added without modifying stable code?
- Liskov - do subtype substitutions preserve contracts?
- Interface Segregation - any fat interfaces forcing unused deps?
- Dependency Inversion - concrete deps injected, not hard-coded?
- DRY - duplicated logic that should be extracted? Flag only if
  duplication causes a correctness or maintenance risk (rule of three).
- Layering - presentation, business, persistence remain separated?
- Module boundaries - no cross-domain imports leaking?

### 2. Correctness

- Edge cases - empty, null, negative, zero, max, unicode, timezones?
- Off-by-one errors in loops and slicing?
- Null/undefined/None handling on every external boundary?
- Race conditions - shared mutable state, async ordering, missed awaits?
- Idempotency - retriable operations safe to re-run?
- State machines - can the object reach an invalid state?

### 3. Type Safety

- TypeScript strict mode on (no implicit any, strictNullChecks)?
- Zero `any`, `unknown` narrowed before use?
- Return types declared explicitly on exported functions?
- Discriminated unions instead of optional-field polymorphism?
- Non-TS languages: mypy/pyright strict, no untyped dicts for structured
  data (use dataclasses/Pydantic), Go any-casts minimized, Rust no
  unchecked unwrap in non-test code.

### 4. TDD Completeness

- Every new feature function has at least one test written before or
  alongside it (Red-Green-Refactor)?
- Tests follow Arrange-Act-Assert or Given-When-Then structure?
- Tests named in intent form (`should_return_empty_list_when_query_is_blank`)?
- No test asserts on implementation detail (private internals)?
- Mocks/stubs/fakes isolated, not leaking across test files?
- Contract tests cover external boundaries (API clients, adapters)?

### 5. Error Paths

- Every happy-path test has a failure-path counterpart?
- Errors carry actionable context (resource id, input summary)?
- No silent `catch` blocks - either handle, rethrow, or log + rethrow?
- Error types are distinct from value types (no magic `-1` sentinels
  when an exception or Result type would serve)?
- Resource cleanup in finally / try-with-resources / defer / using?

### 6. Security

- Secrets not committed - scan diff for high-entropy strings, patterns
  `AKIA`, `sk_live_`, `-----BEGIN`, `eyJhbGci`.
- Auth-bypass risk - new endpoints have authZ check? Roles enforced?
- SQL injection - parameterized queries / ORM, no string concat?
- XSS - user input escaped on render, no `innerHTML` / `dangerouslySetInnerHTML`?
- SSRF - outbound requests to user-supplied URLs validated against allow-list?
- Deserialization - no untrusted data piped into `pickle`, `yaml.load`,
  `JSON.parse` on server without schema validation?
- Cross-reference with `security-audit` skill for deeper OWASP coverage.

### 7. Performance

- N+1 queries - loops that call DB/HTTP per element?
- Render thrash - React components without `useMemo` / stable deps;
  expensive work in render path?
- Unbounded loops - user-controlled counts without caps?
- Large synchronous work on hot path - should be async, streamed, or batched?
- Caching opportunities missed, or caching added without invalidation plan?

### 8. Commit Hygiene

- Conventional Commits prefix (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`)?
- No `wip`, `fixup!`, `squash!`, `tmp`, `asdf` in commit messages?
- Each commit is atomic - one logical change, passes tests independently?
- No binary blobs, no `.env`, no `.DS_Store`, no IDE config?
- Branch name matches convention (`feat/<slug>-issue-N`, `fix/<slug>-issue-N`)?

## Output Format

```
# Code Review: <pr-title or branch>

## Verdict
<APPROVE | REQUEST_CHANGES | COMMENT>

## Blocking (must fix before merge)
- path/to/file.ts:42 - [security] Auth check missing on new /admin route.
  Suggested: wrap handler with requireRole('admin').

## Non-blocking (nice to have)
- path/to/file.ts:77 - [perf] N+1 on users.map(fetchProfile).
  Suggested: batch with Promise.all + single IN query.

## Nits (optional)
- path/to/file.ts:12 - [hygiene] Commit message says "fix stuff".

## What went well
- New test file covers three edge cases (empty, unicode, max-length).
- Clean separation between adapter and service.
```

## Severity guide

- **Blocking**: security, data loss, breaks public contract, missing
  tests for new feature code, TypeScript `any` leaks into public API.
- **Non-blocking**: performance, refactor opportunities, naming.
- **Nit**: style, phrasing, commit message minor.

## When findings are ambiguous

Say so. Phrase as "I am not sure whether X or Y is intended - please
clarify" rather than inventing a fix. Never fabricate a bug to pad the
review.

## Integration points

- `security-audit` skill - invoke for deeper OWASP / SAST interpretation.
- `ac-validate` skill - invoke to verify acceptance-criteria coverage.
- `pr-open` skill - after review passes, next step for the author.
