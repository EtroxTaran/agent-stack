---
name: issue-pickup
description: 'Use this skill to start work on a GitHub Issue in a TDD-compliant way. Triggers on "pick up issue #N", "start working on #N", "begin feature from issue", "implement issue N", "/issue-pickup", "nehm dir issue N vor". Fetches issue body, parses Gherkin acceptance-criteria, creates a correctly-named branch, seeds one TODO per AC plus write-test/implement/refactor TODOs, and records a checkpoint commit before any feature write. NOT for generic task planning, bug investigation without an existing issue, or creating new issues (use gh issue create directly). Reason to use - guarantees branch naming, AC extraction, and TDD TODO-seed happen identically whether the driver is Claude, Cursor, Gemini, or Codex.'
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
  - mcp__github__get_issue
  - mcp__github__create_branch
  - mcp__filesystem__read_text_file
---

# Issue Pickup

Deterministic kickoff for a feature or bug pulled from a GitHub Issue.
The goal is to leave the workspace in a state where the next action is
"write the failing test for AC-1".

## Preconditions

1. `gh auth status` returns OK.
2. Current directory is inside a git repo (`git rev-parse --show-toplevel`).
3. Working tree is clean (`git status --porcelain` empty). If not, stop
   and ask the user to commit or stash first - never surprise-stash.
4. `git remote get-url origin` resolves and repo is linked to GitHub.

## Inputs

- Issue number `N` (mandatory).
- Optional repo override `<owner>/<repo>` - default `origin`.
- Optional branch-type override (`feat` / `fix` / `chore` / `refactor`) -
  otherwise inferred from labels (see `references/branch-naming.md`).

## Workflow

### Step 1 - Fetch the issue

Use `mcp__github__get_issue` or fall back to:

```bash
gh issue view "$N" --json number,title,body,labels,state,url
```

Verify `state == "open"`. If closed, ask the user to confirm before
proceeding.

### Step 2 - Parse Acceptance Criteria

Look for a fenced block in the issue body:

    ```gherkin
    Feature: ...
      Scenario: ...
        Given ...
        When ...
        Then ...
    ```

Use the helper script:

```bash
python3 scripts/parse_gherkin.py <(gh issue view "$N" --json body -q .body)
```

It prints one line per Scenario with a slug, e.g.:

```
AC-1: user-can-log-in-with-valid-credentials
AC-2: login-fails-with-clear-error-on-wrong-password
```

If the body has no Gherkin block - stop and ask the user. Do not invent
ACs. A feature issue without ACs is under-specified.

### Step 3 - Determine branch name

Apply the convention in `references/branch-naming.md`:

```
<type>/<slug>-issue-<N>
```

- `type` from label precedence: `bug` -> `fix`, `enhancement`/`feature` ->
  `feat`, `chore` -> `chore`, `refactor` -> `refactor`. Default `feat`.
- `slug` from the issue title, lowercased, hyphenated, `[a-z0-9-]` only,
  trimmed to 40 chars.

Example: `feat/user-can-log-in-issue-42`.

Verify the branch does not already exist on remote:

```bash
git ls-remote --exit-code --heads origin "refs/heads/<branch>" && {
  echo "Branch exists on remote - switching instead of creating"
  git fetch origin "<branch>" && git switch "<branch>"
} || {
  git switch -c "<branch>" "origin/main"
}
```

### Step 4 - Checkpoint commit

Before any feature write:

```bash
git commit --allow-empty -m "chore: pickup issue #$N

Refs #$N"
```

An empty checkpoint commit is intentional - it anchors the branch to a
known-clean state and makes later squash/rebase boundaries obvious.

### Step 5 - Seed TDD TODOs

Create `./.ai-todo.md` (or append if it exists) with one block per AC:

```markdown
## Issue #<N> - <title>

### AC-1: <slug from Step 2>
- [ ] write failing test for AC-1 (Red)
- [ ] implement minimal code to pass AC-1 (Green)
- [ ] refactor AC-1 keeping tests green

### AC-2: ...
- [ ] write failing test for AC-2
- [ ] implement
- [ ] refactor
```

The file is intentionally flat markdown so every CLI and every human can
read and mutate it.

### Step 6 - Report

Print a single summary:

```
Issue #<N> picked up.
Branch: <branch>
ACs seeded: <count>
Next action: write failing test for AC-1 (<slug>).
```

## Error handling

- Issue fetch fails - report exact `gh` error, do not retry silently.
- Gherkin parse fails - show the helper's error and the raw body, ask
  user to fix the issue or provide ACs manually.
- Branch switch fails - abort, leave working tree untouched.

## Scripts

- `scripts/parse_gherkin.py` - extracts `AC-N: <slug>` lines from issue
  body. Pure Python 3 stdlib, no external deps.

## References

- `references/branch-naming.md` - full branch-naming convention.
