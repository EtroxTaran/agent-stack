---
name: project-setup-check
description: 'Use this skill PROACTIVELY at session-start in a project directory to detect whether the AI-Review-Pipeline is configured. Triggers on: opening a new session in a git repo, the first substantive user request in an EtroxTaran/* repo, or any message mentioning "setup", "getting started", "init", "neues Projekt", "ai-review einrichten", "aktivieren", "bootstrap". Checks .ai-review/config.yaml + .github/workflows/ai-review*.yml existence, reads the git remote to identify EtroxTaran/* vs. foreign repos, prints a handlungsbare Setup-Anleitung if missing. NOT for non-git directories, not for repos outside EtroxTaran/*, not for already-configured repos (stay silent). Reason to use over the Claude-only hook — makes the SessionStart-Nudge available in Cursor, Gemini and Codex CLIs, which have no hooks-interface of their own.'
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
  - mcp__filesystem__read_text_file
---

# Project Setup Check

Verify that the current project is connected to the AI-Review-Pipeline and,
if not, surface a clear setup nudge to the user in the first substantive
response of the session.

## When to run

Invoke this skill **once** per session, as close to the user's first message
as possible, when all of these hold:

1. The working directory is inside a git repository.
2. The repository's `origin` remote points to `github.com/EtroxTaran/*` (case-insensitive match, including SSH `git@github.com:EtroxTaran/...` form).
3. `CLAUDE_SKIP_AI_REVIEW_SETUP` is not set to `1` in the environment.
4. Neither `.ai-review/.noreview` nor `.noaireview` exists at the repo root.

If any of these conditions fails → stay silent. This skill does not
make the user aware of its own existence — the only surface is the
setup-nudge output itself.

## Preconditions (fail closed, silent)

Abort the skill without any output when:

- `git rev-parse --git-dir` exits non-zero → not a git repo.
- `git config --get remote.origin.url` is empty → local-only repo.
- The origin URL does not match `[/:]EtroxTaran/` → foreign repo or fork.
- `$CLAUDE_SKIP_AI_REVIEW_SETUP` equals `1` → user opted out.
- `.ai-review/.noreview` exists → repo opted out.
- `.ai-review/config.yaml` exists AND **any** `.github/workflows/ai-review*.yml` exists → already configured.

## Detection logic

Run (any CLI, tool-neutral):

```bash
# From the repo root. Any line failing → bail silently.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
origin=$(git config --get remote.origin.url 2>/dev/null || echo "")
[ -z "$origin" ] && exit 0
echo "$origin" | grep -qE '[/:]EtroxTaran/' || exit 0
[ "${CLAUDE_SKIP_AI_REVIEW_SETUP:-0}" = "1" ] && exit 0
[ -f ".ai-review/.noreview" ] && exit 0

have_config=0
[ -f ".ai-review/config.yaml" ] && have_config=1

have_workflow=0
for f in .github/workflows/ai-review*.yml; do
    [ -f "$f" ] && have_workflow=1 && break
done

if [ "$have_config" = "1" ] && [ "$have_workflow" = "1" ]; then
    exit 0   # Already configured, stay silent
fi
```

If execution reaches the end without exiting, **render the nudge** (next section).

## The nudge (render once)

Post exactly this text at the top of your first response in the session
(it is short enough that it does not distract, and clear enough that the
user can act on it immediately):

```
ℹ️  AI-Review-Pipeline ist für dieses Repo noch nicht konfiguriert.

   Setup (~5 Min):
     gh extension install EtroxTaran/gh-ai-review     # einmalig
     gh ai-review install                              # im Repo-Root
     $EDITOR .ai-review/config.yaml                    # Channel-ID eintragen
     gh ai-review verify                               # Sanity-Check

   Details: agent-stack/docs/wiki/40-setup/00-quickstart-neues-projekt.md

   Skippen für dieses Repo:  touch .ai-review/.noreview
   Skippen für diese Session: export CLAUDE_SKIP_AI_REVIEW_SETUP=1
```

**Do not** repeat the nudge in subsequent turns of the same session.
**Do not** offer to run the setup unsolicited — wait for the user to
say "ja, setup" oder "install it" oder similar explicit intent.

## After the nudge

If the user accepts the setup offer (explicit: "ja", "setup", "install"):

1. Confirm the repo (`gh repo view --json nameWithOwner`).
2. Run `gh extension install EtroxTaran/gh-ai-review` if the extension is not present.
3. Run `gh ai-review install` to scaffold `.github/workflows/` templates and `.ai-review/config.yaml`.
4. Open `.ai-review/config.yaml` and point out the `channel_id` + `allowed_labels` lines that typically need editing.
5. Offer to run `gh ai-review verify` and summarize the output.

If the user declines or ignores → drop the topic. Do not remind.

## What NOT to do

- Do not bypass any of the preconditions. Non-EtroxTaran repos are none of your business.
- Do not modify files. The nudge is informational only.
- Do not invoke this skill more than once per session. If the session has already printed the nudge, stay silent on repeat triggers.
- Do not read `.ai-review/config.yaml` contents if it exists — that is user-owned config. The existence check alone is sufficient to decide "configured".
- Do not prompt for the Discord-Channel-ID automatically — that is explicitly a manual step that needs user judgement.

## Companion to the Claude-hook

Claude Code additionally runs `configs/claude/hooks/project-setup-check.sh`
via `SessionStart` hook. That hook does the same detection but runs
deterministically *before* the model sees the first message. This skill is
the cross-CLI complement for Cursor / Gemini / Codex which have no such
hook interface (verified 2026-04-24: forum.cursor.com/t/is-skills-supported,
geminicli.com/docs/cli/skills, developers.openai.com/codex/skills).

When both the hook and the skill fire (Claude case), the hook's output
takes precedence and the skill should stay silent. Detection: if the
Claude transcript already contains the `ℹ️  AI-Review-Pipeline ist für dieses Repo noch nicht konfiguriert.` string from a prior turn, skip the skill.
