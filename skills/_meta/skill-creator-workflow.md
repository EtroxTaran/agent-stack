# Skill Creation — Anthropic Skill-Creator-Workflow

Alle Skills in diesem Repo folgen dem Anthropic Skill-Creator-Standard.
Wir duplizieren den Workflow nicht hier — er lebt in OpenClaw:

- Skill-Creator Skill: `~/.openclaw/skills/skill-creator/SKILL.md`
- Masterplan: `~/.openclaw/workspace/SKILL_CREATOR_MASTERPLAN.md`
- Eval-Script: `~/.openclaw/skills/skill-creator/scripts/run_eval.py`
- Description-Tuning: `~/.openclaw/skills/skill-creator/scripts/improve_description.py`

## Kurzfassung des Prozesses

1. **Draft** `SKILL.md` mit pushy-Description (Trigger-Phrases + "NOT for:")
2. **Evals** `evals/evals.json` — 5 Trigger + 3 No-Trigger + expected_output
3. **Benchmark** parallel with-skill vs. without-skill → `run_eval.py`
4. **Iterate** bis Pass-Rate ≥ 80%
5. **Commit** via Conventional-Commit `feat(skills): <name>`
6. **CI** validiert YAML-Frontmatter via `.github/workflows/validate-skills.yml`

## Status der bestehenden Skills

Die vier Initial-Skills (`code-review-expert`, `issue-pickup`, `pr-open`,
`review-gate`) sind **Drafts**. Evals und ≥80%-Pass-Rate-Tuning ist
**Phase 2** des Implementation-Plans.
