---
name: nachfrage-respond
description: 'Use this skill to dispatch a PR-comment command when the AI-review consensus landed in the soft zone (avg 5-7.9) and the PR-author has posted a follow-up command. Triggers on "/ai-review approve", "/ai-review retry", "/ai-review security-waiver", "/ai-review ac-waiver", "handle soft consensus", "respond to nachfrage", "nachfrage dispatch", "process ai-review command". Parses the PR comment, enforces author-only authorization, validates the command and any waiver reason (≥30 chars), then updates commit-statuses and/or triggers the auto-fix workflow, and appends an entry to .ai-review/metrics.jsonl. NOT for opening PRs, running the initial review, branch operations, or approving on someone else`s behalf - those are other skills (pr-open, review-gate, issue-pickup). Reason to use over raw gh api - guarantees the same authorization, validation, and audit-trail rules are applied whether the command is dispatched from Claude, Cursor, Gemini, or Codex.'
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
  - Write
  - mcp__github__get_pull_request
  - mcp__github__get_pull_request_comments
  - mcp__github__add_issue_comment
  - mcp__filesystem__read_text_file
---

# Nachfrage Respond

Server-side handler for the four PR-comment commands that drive the
soft-consensus / waiver paths of the AI-review pipeline:

- `/ai-review approve` - human-override accept
- `/ai-review retry` - trigger auto-fix workflow
- `/ai-review security-waiver <reason>` - security false-positive override
- `/ai-review ac-waiver <reason>` - AC-validation false-positive override

The work is deliberately boring: parse, authorize, validate, dispatch,
audit. No creativity. The same rules must apply regardless of which CLI
invokes the skill.

## Preconditions (fail closed)

1. `gh auth status` returns OK.
2. A PR number `N` is provided (mandatory input).
3. A comment body is provided (mandatory input) - either from
   `github.event.comment.body` when running inside a workflow, or
   fetched via `mcp__github__get_pull_request_comments` when invoked
   locally against a specific comment id.
4. The commenter login is provided or resolvable (needed for the
   author-only check).

Any missing precondition -> stop and report. Do not assume a default.

## Inputs

- `pr_number` (int) - mandatory.
- `comment_body` (string) - mandatory.
- `commenter_login` (string) - mandatory.
- Optional `repo` override (`<owner>/<repo>`), default from
  `git remote get-url origin`.

## Workflow

### Step 1 - Resolve PR context

```bash
gh pr view "$PR" --json number,author,headRefOid,url > /tmp/pr-$PR.json
PR_AUTHOR=$(jq -r .author.login /tmp/pr-$PR.json)
PR_HEAD=$(jq -r .headRefOid /tmp/pr-$PR.json)
```

Abort if `headRefOid` is empty - PR is closed or detached.

### Step 2 - Authorize (PR-author only)

```bash
if [ "$commenter_login" != "$PR_AUTHOR" ]; then
  gh pr comment "$PR" --body "Nur der PR-Author (@$PR_AUTHOR) darf /ai-review-Commands triggern."
  exit 0
fi
```

No exceptions. A co-author or maintainer is not the same as the PR
author - this is a security boundary, not a politeness rule.

### Step 3 - Extract command + args

Split the first line of the comment on whitespace. The command token is
the second field (`$2`), the rest is the reason/args:

```bash
first_line=$(printf '%s' "$comment_body" | head -n1)
# /ai-review <cmd> <rest>
cmd=$(printf '%s' "$first_line" | awk '{print $2}')
rest=$(printf '%s' "$first_line" | cut -d' ' -f3-)
```

Normalize `cmd` to lowercase. Reject if `cmd` is not in the allow-list:

```
approve | retry | security-waiver | ac-waiver
```

Any other token -> reply with the allow-list and exit 0.

### Step 4 - Per-command validation

- `approve` / `retry`: no extra args required.
- `security-waiver` / `ac-waiver`: `rest` (stripped of leading
  whitespace) MUST be >= 30 chars and not match the generic-reason
  pattern `^(fp|ok|done|false|trust me|lgtm|sure)\b`.

Rejection -> post a reply comment with the exact rule and exit 0. The
workflow itself must still succeed; failing the job would mask the
user-facing message.

### Step 5 - Dispatch

#### `approve`

1. Read current `ai-review/security` + `ai-review/security-waiver`
   statuses. If security = failure and waiver != success, reply with
   `"approve blockiert - Security-Veto aktiv. Use /ai-review
   security-waiver <reason>."` and stop.
2. Otherwise:

```bash
gh api "repos/$REPO/statuses/$PR_HEAD" \
  -f state=success \
  -f context="ai-review/consensus" \
  -f description="Human-override: /ai-review approve by PR-Author"
```

3. Post / update sticky comment marker
   `<!-- nexus-ai-review-human-override -->` confirming the override.

#### `retry`

```bash
gh workflow run ai-review-auto-fix.yml \
  --field pr_number="$PR" \
  --field reason="manual-retry" \
  --field context_hint="PR-Author posted /ai-review retry"
gh api "repos/$REPO/statuses/$PR_HEAD" \
  -f state=pending \
  -f context="ai-review/consensus" \
  -f description="Retry requested - waiting for stages"
```

Reply with: "Retry requested - auto-fix dispatched. If no diff is
produced, push an empty commit (`git commit --allow-empty`) to force a
fresh stage cycle."

#### `security-waiver`

```bash
short_reason=$(printf '%s' "$rest" | cut -c1-140)
gh api "repos/$REPO/statuses/$PR_HEAD" \
  -f state=success \
  -f context="ai-review/security-waiver" \
  -f description="Waiver by PR-Author: $short_reason"
```

Update sticky comment marker `<!-- nexus-ai-review-security-waiver -->`
with the FULL reason (no 140 cap in comment body). Idempotent: second
waiver on same commit updates the sticky, does not append.

#### `ac-waiver`

Identical to `security-waiver` but with context `ai-review/ac-waiver`
and sticky marker `<!-- nexus-ai-review-ac-waiver -->`.

### Step 6 - Audit trail

Append one JSON line to `.ai-review/metrics.jsonl`:

```json
{
  "timestamp": "2026-04-20T12:34:56Z",
  "pr": 42,
  "head_sha": "7db41d7...",
  "commenter": "EtroxTaran",
  "command": "security-waiver",
  "reason": "<full reason or empty for approve/retry>",
  "dispatch_result": "ok"
}
```

Use `scripts/append_metrics.py` (pure stdlib) - never edit the file
by hand. See `references/nachfrage-commands.md` for the full schema.

If the repo has no `.ai-review/` directory yet, create it. Commit the
JSONL append ONLY if the workflow explicitly asks; usually the file is
git-ignored and kept on the runner's artifact path.

### Step 7 - Report

Single-line summary to stdout:

```
dispatched: command=<cmd> pr=<N> head=<sha7> result=ok
```

On failure:

```
rejected: command=<cmd> pr=<N> reason=<why>
```

## Error handling

- PR not found -> report exact gh error, exit 1.
- Comment is not a command (no `/ai-review` prefix) -> exit 0 silently;
  this handler may fire on unrelated comments when wired to
  `issue_comment:created`.
- `gh api` status update returns 422 -> usually a stale SHA; re-read
  `headRefOid` and retry once.
- Workflow dispatch fails -> post a reply comment with the gh error
  text; do not silently retry.

## Integration points

- Invoked by `.github/workflows/ai-review-nachfrage.yml` on
  `issue_comment:created`.
- Consumes commit-statuses set by Stage-handlers (`ai-review/security`,
  `ai-review/ac-validation`, etc.).
- Feeds `scripts/ai-review/metrics_summary.py` via the JSONL append.
- Pairs with `security-waiver` and `ac-waiver` user-facing skills,
  which compose the comment body this handler then consumes.

## References

- `references/nachfrage-commands.md` - full command matrix,
  authorization rules, rejection-reason templates, and worked examples
  for each of the four commands.
