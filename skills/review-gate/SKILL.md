---
name: review-gate
description: Use this skill to run the AI-review pipeline and local checks on the developer machine BEFORE git push, catching failures that would otherwise block the PR. Triggers on "run review gate", "local review before push", "test pipeline locally", "/review-gate", "pre-push check", "simulate the AI review", "act dry run". Verifies act installed, workflow file present, runs pnpm test changed-only plus typecheck plus lint, then act pull_request for the code_review job with .env.act. Reports pass/fail per stage and exits non-zero when any stage fails. NOT for production deploys, not for post-push debugging, not for running the full AI-review consensus (that needs the runner cluster and external model API quotas). Reason to use - catches 80 percent of pipeline-blockers on the laptop in under two minutes, avoiding a 10-minute round-trip through the runner.
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
  - mcp__filesystem__read_text_file
  - mcp__filesystem__get_file_info
---

# Review Gate

Local pre-push smoke-test. Runs the same checks the AI-review pipeline
will run on the runner, short-circuits on failure, and prints a clear
pass/fail matrix. Saves cycle time by failing fast on the laptop.

## Preconditions

1. Inside a git repo, branch is not `main`.
2. Working tree is clean OR the user explicitly opts in to running
   against the dirty tree. A clean tree produces reproducible results -
   a dirty one does not.
3. `act` is installed (`command -v act`). If not, point the user at
   `references/act-setup.md` and stop.
4. `.github/workflows/ai-code-review.yml` exists. If not, the repo is
   not wired for AI-review yet - stop and say so.
5. `.env.act` exists at repo root. If not, hint: "copy the subset of
   `~/.openclaw/.env` required by the workflow into `.env.act`; see
   `references/act-setup.md`".

## Workflow

Run each stage in order. On the first failure, continue running the
remaining stages (developer wants to see all breakages at once), but
record the failure and exit non-zero at the end.

### Stage 1 - Typecheck

Detect the language and invoke:

```bash
if [ -f pnpm-lock.yaml ]; then
  pnpm typecheck
elif [ -f package-lock.json ]; then
  npm run typecheck
elif [ -f pyproject.toml ]; then
  mypy src/ || pyright
elif [ -f go.mod ]; then
  go build ./...
elif [ -f Cargo.toml ]; then
  cargo check --all-targets
fi
```

If no typecheck target defined, report `SKIP - no typecheck target`. Do
not invent one.

### Stage 2 - Lint

```bash
if [ -f pnpm-lock.yaml ]; then
  pnpm lint
elif [ -f pyproject.toml ]; then
  ruff check . && ruff format --check .
elif [ -f go.mod ]; then
  golangci-lint run ./...
fi
```

### Stage 3 - Unit tests (changed files only)

Scope to changed files to stay under two minutes. The full-suite run is
the runner's job.

```bash
base="$(git merge-base origin/main HEAD)"
changed_tests=$(git diff --name-only "$base"...HEAD | grep -E '\.(test|spec)\.' || true)
if [ -n "$changed_tests" ]; then
  if [ -f pnpm-lock.yaml ]; then
    pnpm test --run --changed "$base"
  elif [ -f pyproject.toml ]; then
    pytest --picked --mode=branch
  fi
else
  echo "No test files in diff - running smoke subset"
  pnpm test --run tests/smoke/ 2>/dev/null || true
fi
```

Failing tests are blocking.

### Stage 4 - act pull_request (code_review job)

```bash
act pull_request \
  --job code_review \
  --secret-file .env.act \
  --container-architecture linux/amd64 \
  --artifact-server-path /tmp/act-artifacts \
  --quiet
```

Notes:
- `--container-architecture linux/amd64` avoids M-series mac false
  positives. Omit on native linux if it causes pulls.
- If this is the first `act` run, it will prompt for a default image -
  `medium` is the right answer for our workflows. Document this in
  `references/act-setup.md`.

### Stage 5 - Commit hygiene

Quick sanity - every commit since `origin/main` must start with a
Conventional Commit prefix. Not an error to fail here (pipeline may
allow squash), but warn:

```bash
git log "origin/main..HEAD" --format='%s' | grep -vE '^(feat|fix|chore|docs|refactor|test|perf|ci|build|style|revert)(\(.+\))?!?:' || true
```

Non-empty output = warning, not failure.

## Output Format

```
Review Gate Result
------------------
Typecheck    : PASS  (3.4s)
Lint         : PASS  (1.8s)
Unit tests   : FAIL  (12 failed, 48 passed)  - see tests/foo.spec.ts
act/code_rev : PASS  (54.0s)
Commit hygie : WARN  (1 commit without conventional prefix)

Verdict: NOT READY TO PUSH
Next action: fix tests/foo.spec.ts line 42, then re-run /review-gate.
```

When everything passes:

```
Verdict: READY TO PUSH
Remaining cost on runner: ~8 minutes for full pipeline + consensus.
```

## Exit codes

- `0` = all PASS (or PASS+WARN). Safe to push.
- `1` = at least one FAIL. Do not push.
- `2` = precondition failure (missing tool, missing workflow). Fix setup.

## Integration points

- Consumes workflow file from `.github/workflows/ai-code-review.yml`.
- Reads secret subset from `.env.act`.
- Pairs with `pr-open` skill - run this BEFORE `pr-open` to avoid
  opening a PR that fails CI instantly.

## References

- `references/act-setup.md` - act install, `.env.act` template, runner
  image sizing, container-architecture notes.
