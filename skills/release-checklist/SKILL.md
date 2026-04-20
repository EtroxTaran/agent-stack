---
name: release-checklist
description: 'Use this skill to run the pre-merge checklist for a release PR that ships the next version of a project. Triggers on "release checklist", "prepare release", "version bump", "tag release", "/release", "cut a release", "ready to tag", "bereit zum release", "bump to v<x>". Walks through branch-check (release/* or main), changelog has an entry for the new version, package.json / pyproject.toml / Cargo.toml version consistent, last-tag semver delta matches the changelog (major / minor / patch), tests green (typecheck + unit + e2e), migration-guide presence for breaking changes, and deploy-readiness (deploy.yml present, secrets set). Emits a per-item PASS / FAIL / WARN matrix plus a verdict line. NOT for feature PRs, not for hotfixes (separate workflow with compressed checks), and not for breaking-change announcements (those deserve their own PR + social rollout). Reason to use over manual review - guarantees every release goes through the same mechanical gate regardless of which CLI the maintainer drives.'
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
  - mcp__github__list_commits
  - mcp__filesystem__read_text_file
  - mcp__filesystem__get_file_info
---

# Release Checklist

Pre-merge gate for a release PR. Runs 8 mechanical checks and emits a
verdict. Failure on any blocking check -> do not merge; WARN is
acceptable if the maintainer acknowledges it.

## Preconditions

1. Inside a git repo (`git rev-parse --show-toplevel`).
2. Working tree clean (`git status --porcelain` empty). A release from
   a dirty tree is undefined behavior.
3. `gh auth status` OK (for tag + release checks).
4. Network reachable (for `git fetch --tags`).

Any fail -> stop with a diagnostic.

## Inputs

- Optional `target_version` (e.g. `v1.4.0`) - if not given, derive from
  `package.json` / `pyproject.toml` / `Cargo.toml`.
- Optional `skip_e2e` flag - only when the user explicitly accepts the
  risk (WARN, not FAIL, in the matrix).

## Workflow

All checks run in sequence. Collect results; do not short-circuit on
first failure - the maintainer wants to see everything.

### Check 1 - Branch context

```bash
branch=$(git rev-parse --abbrev-ref HEAD)
case "$branch" in
  release/*|main) echo "PASS" ;;
  *) echo "FAIL - expected release/* or main, got $branch" ;;
esac
```

Hotfixes run on `hotfix/*` and use a separate skill - refuse to proceed
on hotfix branches with a redirect message.

### Check 2 - Changelog entry

`CHANGELOG.md` must exist at repo root and contain a heading for
`$target_version`. Accept the Keep-a-Changelog convention:

```
## [1.4.0] - 2026-04-20
```

```bash
if ! [ -f CHANGELOG.md ]; then
  echo "FAIL - no CHANGELOG.md"
elif ! grep -qE "^## \[?${target_version#v}\]?" CHANGELOG.md; then
  echo "FAIL - no entry for $target_version in CHANGELOG.md"
else
  echo "PASS"
fi
```

Missing changelog is blocking. A release without a changelog has no
audit trail of WHAT changed.

### Check 3 - Version-bump consistency

Detect the language and read the version field:

```bash
if [ -f package.json ]; then
  v=$(jq -r .version package.json)
elif [ -f pyproject.toml ]; then
  v=$(grep -E '^version\s*=' pyproject.toml | head -1 | cut -d'"' -f2)
elif [ -f Cargo.toml ]; then
  v=$(grep -E '^version\s*=' Cargo.toml | head -1 | cut -d'"' -f2)
fi
```

- `v == ${target_version#v}` -> PASS
- Mismatch -> FAIL (do not auto-fix; the maintainer must decide which
  value is canonical)

Monorepo extension: if `pnpm-workspace.yaml` exists, run the check on
every package.json in `apps/*` and `packages/*`. All must match.

### Check 4 - Tag + semver delta

```bash
git fetch --tags
last=$(git tag --sort=-v:refname | head -n1)
```

Compute the delta from `last` to `target_version`:

- major bump (`1.x -> 2.0`): require evidence in CHANGELOG for
  `### Breaking` or `### Removed` section; WARN if absent.
- minor bump (`1.3 -> 1.4`): require `### Added` section; WARN if
  absent.
- patch bump (`1.3.0 -> 1.3.1`): require `### Fixed` or `### Changed`
  section; WARN if absent.

See `references/semver-decision-tree.md` for the full decision table.

Block on:
- `target_version <= last` (non-monotonic) -> FAIL.
- `target_version` is not valid semver -> FAIL.

### Check 5 - Tests green

Run in order; first failure flips the check to FAIL but keep running
for visibility:

```bash
# TypeScript / Node
if [ -f pnpm-lock.yaml ]; then
  pnpm typecheck   && pnpm test --run   && { [ "$skip_e2e" = true ] || pnpm test:e2e; }
fi
# Python
if [ -f pyproject.toml ] && grep -q pytest pyproject.toml; then
  mypy src/ && pytest -q && { [ "$skip_e2e" = true ] || pytest -q tests/e2e; }
fi
# Rust
if [ -f Cargo.toml ]; then
  cargo check --all-targets && cargo test --all
fi
```

If `skip_e2e` is set, the E2E check is reported as `WARN (skipped)`
instead of PASS. It is never silently ignored.

### Check 6 - Docs check (migration guide for breaking changes)

If the version delta is a major bump OR `CHANGELOG.md` contains a
`### Breaking` section:

```bash
migration_files=$(find docs -iname 'migration*.md' -o -iname 'upgrade*.md' 2>/dev/null)
if [ -z "$migration_files" ]; then
  echo "FAIL - breaking change detected, no migration guide"
else
  echo "PASS"
fi
```

Non-breaking release -> auto-PASS.

### Check 7 - Deploy readiness

```bash
if [ -d .github/workflows ]; then
  deploy_yml=$(ls .github/workflows/ | grep -E 'deploy|release|publish' | head -1)
fi
```

- Deploy workflow exists -> PASS.
- Missing -> WARN (maybe published via a different path; ask user).

Secrets: list the `${{ secrets.X }}` references in the deploy
workflow and confirm via `gh secret list` that each is set:

```bash
refs=$(grep -oE 'secrets\.[A-Z_]+' "$deploy_yml" | sort -u | sed 's/secrets\.//')
have=$(gh secret list --json name -q '.[].name')
for r in $refs; do
  if echo "$have" | grep -qx "$r"; then echo "  $r: PASS";
  else echo "  $r: FAIL"; fi
done
```

Any missing secret -> blocking FAIL. For the Nexus Portal context:
verify `SSH_PRIVATE_KEY_R2D2`, `DOCKER_REGISTRY_TOKEN` if the workflow
pushes images, and any Tailscale / n8n secrets referenced.

### Check 8 - Clean merge target

```bash
git fetch origin main
behind=$(git rev-list --count HEAD..origin/main)
if [ "$behind" -gt 0 ]; then
  echo "WARN - branch is $behind commit(s) behind origin/main; rebase before tag"
else
  echo "PASS"
fi
```

Not blocking (can be rebased immediately before merge), but visible so
the maintainer is not surprised.

## Output Format

```
Release Checklist: v1.4.0
-------------------------
1. Branch context            : PASS  (release/v1.4.0)
2. Changelog entry           : PASS  (## [1.4.0] - 2026-04-20)
3. Version-bump consistency  : PASS  (4/4 packages match)
4. Tag + semver delta        : PASS  (v1.3.2 -> v1.4.0, minor bump)
5. Tests green               : PASS  (typecheck 3.4s, unit 12.1s, e2e 42s)
6. Migration guide           : PASS  (non-breaking)
7. Deploy readiness          : WARN  (deploy.yml present, secret DOCKER_REGISTRY_TOKEN missing)
8. Clean merge target        : PASS  (up to date with origin/main)

Verdict: NOT READY - fix secret DOCKER_REGISTRY_TOKEN then re-run.
Next tag: v1.4.0 (minor bump from v1.3.2)
```

When everything passes:

```
Verdict: READY TO MERGE -> tag v1.4.0
Merge command: gh pr merge <PR> --merge --match-head-commit <SHA>
Tag command:   git tag -a v1.4.0 -m "Release v1.4.0" && git push origin v1.4.0
```

## Exit codes

- `0` - all PASS (WARN allowed if user opted in).
- `1` - at least one blocking FAIL. Do not merge.
- `2` - precondition failure (dirty tree, missing gh auth, etc.).

## Error handling

- `gh secret list` returns 403 (insufficient permissions) -> downgrade
  to WARN and list the required secrets for manual verification.
- `git fetch --tags` fails offline -> skip Check 4's tag-monotonic
  verification; WARN that semver delta was not verified.
- `pnpm test:e2e` times out -> treat as FAIL with the timeout value in
  the report. Do not retry; the maintainer can re-run manually.

## Integration points

- Runs after `review-gate` (which covers the unit/lint checks the
  feature branches needed). Release-checklist adds the release-specific
  layers.
- Pairs with `pr-open` - if the release PR was opened via `pr-open`,
  the AC-Verification section is already there; this skill does not
  touch it.
- Feeds the maintainer's merge action. Never auto-merges.

## References

- `references/semver-decision-tree.md` - when major, when minor,
  when patch; CHANGELOG-section requirements per bump level.
