---
name: ac-validate
description: 'Use this skill to validate acceptance-criteria coverage on a PR - every Gherkin AC in the linked issue must have a passing, correctly-scoped test in the PR. Triggers on "AC validation", "validate acceptance criteria", "check AC coverage", "does this PR cover all ACs", "verify gherkin", "AC coverage report". Extracts the linked issue from PR body, parses the Gherkin block, maps each Scenario to a test file via keyword heuristics, and emits a per-AC covered/partial/uncovered report plus a 1-10 score. NOT for general code review (use code-review-expert), NOT for security (use security-audit), NOT for style or design checks. Reason to use over ad-hoc spec-matching - fails closed when no issue is linked, only bypassable via /ai-review ac-waiver, so a PR with missing AC coverage cannot slip through by being reviewed from a different CLI.'
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
  - mcp__github__get_issue
  - mcp__filesystem__read_text_file
  - mcp__filesystem__search_files
---

# AC Validate

Gherkin acceptance-criteria coverage check. Lead-reviewer is Codex
(strict spec-matching); Claude is the second opinion. The review is
**fail-closed**: if a PR does not link an issue with ACs, the skill
blocks merge until the author either adds the link or invokes
`/ai-review ac-waiver <reason of at least 30 chars>`.

## When to use

Invoke when the user asks to validate ACs, check AC coverage, verify a
Gherkin scenario is tested, or confirm a PR meets its issue spec. Stay
silent on PRs that are explicitly doc-only or branch-to-branch merges.

## Inputs you may receive

- A PR number - use `github` MCP for PR body + linked issue.
- A pre-extracted Gherkin block plus repo root - skip Stage 1/2.
- An issue number directly - treat as "assumed PR is current branch".

## Preconditions

1. Inside a git repo (`git rev-parse --show-toplevel`).
2. `gh auth status` OK, or `github` MCP available.
3. At least one test-file glob in `TEST_GLOBS` (see script) present in
   the repo.

## Workflow

### Stage 1 - Extract linked issue(s) from PR

```bash
gh pr view "$PR" --json body,title,headRefName > /tmp/pr.json
body=$(jq -r .body /tmp/pr.json)
primary=$(grep -oE 'Closes #[0-9]+' <<<"$body" | grep -oE '[0-9]+' | head -n1)
refs=$(grep -oE 'Refs #[0-9]+' <<<"$body" | grep -oE '[0-9]+' || true)
```

- `primary` = the `Closes #N` issue. Mandatory.
- `refs` = additional issues (multi-issue PR). Parsed all the same.

Fall-back: parse `issue-<N>` token from `headRefName` (matches the
`pr-open` and `issue-pickup` branch convention).

**Fail-closed path:** if both checks produce zero issue numbers, emit:

```
AC Validate: FAIL - no linked issue.
This PR must reference an issue via `Closes #N` or `Refs #N`, or be
bypassed with: /ai-review ac-waiver <reason>=30+ chars>.
```

Return non-zero. Do not invent an issue number.

### Stage 2 - Fetch each issue and parse the Gherkin block

For every issue number collected:

```bash
gh issue view "$N" --json number,title,body > "/tmp/issue-$N.json"
jq -r .body "/tmp/issue-$N.json" | \
  python3 scripts/find_ac_tests.py --body /dev/stdin --root "$(git rev-parse --show-toplevel)" --json \
  > "/tmp/ac-coverage-$N.json"
```

The helper `scripts/find_ac_tests.py`:
- Parses the `` ```gherkin `` fenced block (same regex as
  `issue-pickup/scripts/parse_gherkin.py`).
- Extracts each `Scenario` title + its `Then`/`And`/`But` clauses.
- Derives a keyword set per scenario (stop-word filtered).
- Scans every test file under `TEST_GLOBS` and scores it:
  - `covered` - slug or >= required keyword hits in one file.
  - `partial` - at least one file with > 0 hits, but below threshold.
  - `uncovered` - no file scores > 0.

No Gherkin block in an issue body = fail-closed for that issue (same
message as Stage 1). Do not score if the issue has no ACs.

### Stage 3 - Per-AC verdict

For each AC from `/tmp/ac-coverage-*.json`:

| Status | Meaning | Treatment |
|---|---|---|
| `covered` | test file found, keywords match | green checkbox |
| `partial` | test file exists but Then-clause keywords missing | orange, request stronger assertion |
| `uncovered` | no matching test in the repo | blocking |

Score 1-10 = `round(10 * covered_count / total_acs)`. Partials count as
0.5 each for the ratio.

### Stage 4 - Render findings

Group by issue. Each AC gets a status line, a path (when available),
and a remediation hint. Reference examples in
`references/gherkin-coverage-patterns.md` for the heuristic mapping.

## Output Format

```
# AC Validate: PR #<pr>  (issue #<N> + refs)

## Score: 7/10  (3 covered, 1 partial, 1 uncovered of 5)

## Issue #42 - Login flow
- [x] AC-1 covered - tests/auth/login.test.ts (keywords: dashboard, session)
- [x] AC-2 covered - tests/auth/login.test.ts
- [~] AC-3 partial - tests/auth/login.test.ts (Then-clause "audit log
      entry written" has no assertion - add one or point to a dedicated
      audit test).
- [ ] AC-4 uncovered - no test matched keywords
      {"rate-limit", "429", "lockout"}. Suggest tests/auth/rate-limit.test.ts.

## Issue #108 - Password reset
- [x] AC-1 covered - tests/auth/reset.test.ts

## Verdict
REQUEST_CHANGES - 1 AC uncovered, 1 partial. Add tests before merge.

## Bypass
If the uncovered AC is intentional (e.g. environmental), use:
  /ai-review ac-waiver <reason of 30+ chars referencing AC-4>
```

## Error handling

- No issue linked -> Stage 1 fail-closed.
- Issue 404 / no access -> report raw gh error, do not retry silently.
- Issue body has no `gherkin` block -> fail-closed with a pointer to
  `issue-pickup` skill (author should have pushed ACs upstream first).
- Heuristic false-positive (partial marked covered or vice versa) ->
  the author may override with `/ai-review ac-waiver` referencing the
  specific AC id and test path.

## Heuristic limits (be honest)

The scoring script is **keyword-based**, not semantic. It can:
- Over-match when a test file mentions the feature domain broadly.
- Under-match when the Then clause uses different verbs than the test.

Mitigation: `partial` is a soft-signal. Reviewers should spot-check
partial-matched tests and re-run after the author names tests with AC
slugs (e.g. `describe('AC-1: user can log in', ...)`).

## Integration points

- Consumes PR body from `pr-open` skill (AC-Verification table).
- Consumed by AI-review pipeline Stage 5 (AC-coverage).
- Waiver path implemented by `ac-waiver` skill.
- `issue-pickup` seeds the Gherkin block this skill later reads.

## Scripts

- `scripts/find_ac_tests.py` - pure Python 3 stdlib; parses Gherkin,
  walks test globs, emits text or JSON. Exit 0 iff every AC >= partial.

## References

- `references/gherkin-coverage-patterns.md` - examples of AC -> test
  mappings and the heuristic's strengths/limits.
