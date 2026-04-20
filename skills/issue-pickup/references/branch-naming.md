# Branch Naming Convention

Every working branch encodes three facts in its name: the change type,
a human-readable slug, and the originating issue number. This lets the
`pr-open` skill derive `Closes #N` without asking, and lets tooling
(`ai-review-pipeline`, status badges, changelog generators) group work
deterministically.

## Format

```
<type>/<slug>-issue-<N>
```

## `<type>` - derived from issue labels

Precedence (first match wins):

| Label on issue | Branch type |
|---|---|
| `bug`, `defect`, `regression` | `fix` |
| `feature`, `enhancement`, `epic` | `feat` |
| `chore`, `dep-bump`, `infra` | `chore` |
| `refactor`, `tech-debt`, `cleanup` | `refactor` |
| `docs`, `documentation` | `docs` |
| `test`, `tests` | `test` |
| (no matching label) | `feat` (default) |

If multiple matching labels exist, keep the first from the order above.
Never mix types in a single branch; split into separate branches.

## `<slug>` - derived from issue title

- Lowercase.
- Keep only `[a-z0-9-]`; replace every other run of chars with a single
  `-`.
- Trim leading/trailing hyphens.
- Truncate to 40 characters (cut at a hyphen boundary if possible).

Example: `Add "forgot password" flow for existing users (German)` ->
`add-forgot-password-flow-for-existing-u`.

## `<N>` - issue number

Always present. Multi-issue branches pick the primary issue; the rest
land as `Refs #X` in the PR body (handled by `pr-open`).

## Examples

- `feat/user-can-log-in-issue-42`
- `fix/timezone-offset-off-by-one-issue-108`
- `chore/bump-tailwind-to-4-1-issue-57`
- `refactor/extract-auth-module-issue-73`

## Anti-patterns (reject)

- `nico/try-stuff` - no type, no issue
- `feat/new` - not specific enough
- `wip-42` - no type, no slug
- `feat/issue-42` - missing slug (human-unreadable)
- `feat/log-in-issue-42-fix-race` - two concerns, split into two
  branches
- `feature/log-in-issue-42` - `feature` is not the short form; use
  `feat`

## Long-running branches

Release branches (`release/2026.04`) and hotfix trains
(`hotfix/<date>`) are out-of-scope for this convention - they do not
originate from a single issue. The AI-review pipeline skips AC-coverage
checks on branches that do not match the `<type>/<slug>-issue-<N>`
pattern and falls back to "Refs" detection in the PR body.
