# Claude Code Hooks

Hooks for the multi-CLI agent-stack. Installed by `install.sh` into
`~/.claude/hooks/` and wired via `~/.claude/settings.json`.

All hooks are POSIX-`bash`, `shellcheck`-clean, fail-safe (a broken hook
never bricks the session).

## Inventory

| Hook | Event | Matcher | Always on? | Purpose |
|------|-------|---------|-----------|---------|
| `project-setup-check.sh` | `SessionStart` | `startup` | yes | Nudges setup of AI-Review-Pipeline when entering an `EtroxTaran/*` repo that lacks `.ai-review/config.yaml`. Exits 0 (info-only). Skippable via `CLAUDE_SKIP_AI_REVIEW_SETUP=1` or per-repo `.ai-review/.noreview`. See [docs/wiki/40-setup/50-project-setup-hook.md](../../../docs/wiki/40-setup/50-project-setup-hook.md). |
| `block-dangerous.sh` | `PreToolUse` | `Bash` | yes | Blocks destructive shell patterns (rm -rf /, force-push without lease, curl\|bash, sudo rm, writes to /etc/). |
| `format-on-write.sh` | `PostToolUse` | `Edit\|Write` | yes | Runs prettier / ruff / gofmt / rustfmt / shfmt on the written file. Silent-skip when formatter missing. |
| `issue-link-check.sh` | `PreToolUse` | `Edit\|Write` | yes | Warns (stderr) if branch has no `-issue-<N>` suffix. Persists issue number to `.git/.current-issue` on match. Never blocks. |
| `tdd-guard.sh` | `PreToolUse` | `Edit\|Write` | **opt-in** | Denies writes into `src/**`, `app/**`, `plugins/**` without a sibling `.test.` / `.spec.` file. |
| `stop-completion-gate.sh` | `Stop` | — | yes | Runs `~/.openclaw/workspace/scripts/completion-gate.sh <cwd>` if present. Never blocks stop. |

## Opt-in: `tdd-guard.sh`

The TDD guard is strict enough to slow down spikes and refactors, so it is
**off by default**. Enable per-session:

```bash
export AI_TDD_GUARD=strict
```

Or enable per-project via `.envrc` (direnv):

```bash
echo 'export AI_TDD_GUARD=strict' >> .envrc
direnv allow
```

Test files themselves (`*.test.*`, `*.spec.*`, `*_test.*`) are always
allowed. Files outside `src/**`, `app/**`, `plugins/**` are untouched.

## Exit-code contract

- `0` — allow, session continues
- `2` — deny with JSON `{"permissionDecision":"deny","reason":"..."}` on stdout (PreToolUse only)
- any other non-zero — treated as hook error by the harness

## Local development

```bash
bash -n configs/claude/hooks/*.sh      # syntax check
shellcheck configs/claude/hooks/*.sh   # static analysis
```
