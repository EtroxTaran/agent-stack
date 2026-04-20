# Semver Decision Tree

Reference for the `release-checklist` skill. Use this to decide
whether the next release is `MAJOR`, `MINOR`, or `PATCH`, and what
the CHANGELOG must contain at that level.

## Semver in one sentence

> Given a version `MAJOR.MINOR.PATCH`, increment the:
> - `MAJOR` when you make incompatible API changes,
> - `MINOR` when you add functionality in a backward-compatible manner,
> - `PATCH` when you make backward-compatible bug fixes.

(Source: semver.org 2.0.0.)

## Decision Tree

```
Did any of these happen since the last tag?
│
├── Removed or renamed a PUBLIC export (function, type, route, CLI
│    flag, config key, env var)?
│   └── YES -> MAJOR
│
├── Changed the SHAPE of a public contract (added required param,
│    narrowed return type, removed enum member, changed HTTP status
│    code for an existing endpoint)?
│   └── YES -> MAJOR
│
├── Changed the MEANING of a public contract without changing shape
│    (e.g. a function that used to ignore unknown fields now rejects
│    them)?
│   └── YES -> MAJOR (silent breaking change is the worst kind)
│
├── Added a new PUBLIC export or a new optional field?
│   └── YES -> MINOR
│
├── Added new internal-only behavior (perf improvement, refactor,
│    internal deprecation flag)?
│   └── YES -> MINOR (if user-observable) OR PATCH (if not)
│
├── Fixed a bug without changing the public contract?
│   └── YES -> PATCH
│
├── Only docs / CI / build-infra changes?
│   └── YES -> PATCH (or skip the release entirely if nothing ships)
│
└── Nothing changed since the last tag?
    └── Do not release. Delete the branch or merge the empty PR with
        a clear "no-op release" justification in the body.
```

## CHANGELOG Section Requirements

Keep-a-Changelog section headings per bump level:

| Bump | Required sections | Optional |
|---|---|---|
| MAJOR | `### Breaking` or `### Removed` | `### Added`, `### Changed`, `### Fixed` |
| MINOR | `### Added` | `### Changed`, `### Fixed`, `### Deprecated` |
| PATCH | `### Fixed` or `### Changed` | `### Security` |

The release-checklist skill checks for the REQUIRED section and
emits `WARN` if it is absent. It does not block - the maintainer may
have chosen a different changelog style - but the warning makes the
mismatch visible.

## Worked Examples

### Example 1: API route parameter renamed

```
- POST /api/finance/categorize { txns: [...] }
+ POST /api/finance/categorize { transactions: [...] }
```

The field `txns` was renamed. Old clients break.

- Bump: **MAJOR**
- CHANGELOG must include `### Breaking` with a migration note:
  > `POST /api/finance/categorize` now expects `transactions` instead
  > of `txns`. Callers must update the payload key.
- Migration guide (`docs/migration-v<new>.md`) is REQUIRED (Check 6).

### Example 2: Optional filter added to an existing endpoint

```
GET /api/finance/transactions?from=2026-01-01&to=2026-04-20
+ optional &category=<string>
```

Existing callers keep working; new callers may filter.

- Bump: **MINOR**
- CHANGELOG `### Added`:
  > Optional `category` query param on
  > `GET /api/finance/transactions`.
- No migration guide needed.

### Example 3: Fixed a rounding bug in the portfolio valuation

Internal function `calculateValue` returned values off by 0.01 EUR
in 3% of cases; now fixed.

- Bump: **PATCH**
- CHANGELOG `### Fixed`:
  > Portfolio valuation no longer rounds mid-calculation; results
  > match broker statements to 0.01 EUR.
- No migration guide.

### Example 4: Internal refactor, no user-visible change

Extracted a helper module. Public API unchanged.

- Bump: **PATCH** (or skip the release; small internal refactors do
  not deserve a version bump if nothing user-observable shipped).
- CHANGELOG: either `### Changed` with a one-liner, or merge without
  a release and wait for the next feature.

## MAJOR vs. MINOR Edge Cases

### Adding a required header to an existing endpoint

```
POST /api/research/runs
+ required header: X-Portal-Version
```

Old callers break. MAJOR.

### Adding a NEW endpoint that requires a new header

```
+ POST /api/research/analyze (requires X-Portal-Version)
```

Old callers do not call the new endpoint, so they do not break. MINOR.

### Changing a default value

```
- retries = 3
+ retries = 1
```

User-observable: retry budget shrank. Depends on whether the default
is contractual:

- Documented default -> MAJOR.
- Undocumented internal default -> MINOR (if noted in changelog).

### Upgrading a transitive dependency

- Dependency's semver bump is MAJOR and WE re-export its types -> MAJOR.
- Dependency's semver bump is MAJOR but we hide it behind our own
  stable facade -> MINOR at most, PATCH if the upgrade is purely
  internal.
- Dependency's semver bump is MINOR or PATCH -> PATCH.

## Pre-1.0 Exception

Semver allows `0.x.y` to treat every MINOR bump as potentially
breaking. We do NOT use that freedom. For any project past Phase 1:

- Treat every public contract as stable.
- Bump MAJOR on breaks, even pre-1.0.

Pre-1.0 projects without a stable contract yet (prototypes, spikes)
are exempt, but should be explicitly labeled `status: prototype` in
the project README.

## "This might be breaking" - how to decide

If you genuinely cannot tell:

1. Search for the public API surface (`git grep 'export ' src/ |
   wc -l`) and ask: did any of those exports change shape?
2. Search for HTTP routes (`git grep -E '(app|router)\.(get|post|put|patch|delete)\('`).
3. Diff the public type-definition files (`*.d.ts`, OpenAPI yaml,
   GraphQL schema). Any removal is MAJOR.
4. If still unsure -> bump MAJOR. Over-bumping is cheap; under-bumping
   breaks downstream silently.

## Related

- `skills/release-checklist/SKILL.md` - the consumer of this tree
- `skills/pr-open/SKILL.md` - the branch that usually drives the
  release PR (`release/*`)
- Keep a Changelog - https://keepachangelog.com/en/1.1.0/
- Semantic Versioning - https://semver.org/spec/v2.0.0.html
