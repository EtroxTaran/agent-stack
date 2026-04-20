---
name: design-review
description: 'Use this skill to check a PR or diff against DESIGN.md conformance - shared-ui usage, Tailwind-token-only styling, no raw HTML form/table elements in plugin code, correct container padding, subtle-tint badge variants. Triggers on "design review", "UI conformance check", "DESIGN.md violations", "check shared-ui usage", "theme violations", "Tailwind token check", "badge variant audit". Produces findings with path:line plus concrete replace-with suggestions. NOT for code-correctness (use code-review-expert), NOT for security (use security-audit), NOT for perf tuning, and auto-skips diffs without UI files. Reason to use over ad-hoc eyeballing - applies the same DESIGN.md rule-set identically from Claude, Cursor, Gemini, or Codex, so the AI-review pipeline sees a consistent design signal.'
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
  - mcp__github__get_pull_request_files
  - mcp__filesystem__read_text_file
---

# Design Review

DESIGN.md-conformance review for UI-touching PRs. Lead-reviewer is
Claude (DESIGN.md author-facing). Tool-neutral body - the checklist runs
identically from every CLI.

## When to use

Invoke when the user asks for a design review, UI-conformance check,
shared-ui audit, or mentions DESIGN.md. Stay silent and emit
`SKIPPED - no UI changes` if the diff has zero UI files.

## Inputs you may receive

- A PR number plus repo context - use `github` MCP for file list + diff.
- A branch range (`main..HEAD`) - use `git diff`.
- A single file path - `Read` / `filesystem` MCP.

## Skip-filter (run first)

Produce `SKIPPED - no UI changes` and exit early when none of these
patterns appear in the diff:

```bash
git diff --name-only "<base>...HEAD" | grep -E '\.(tsx|jsx|css|scss|vue|svelte)$|/components/|/pages/|/views/' \
  || { echo "SKIPPED - no UI changes"; exit 0; }
```

Design review wastes reviewer time on pure-backend diffs.

## Workflow

### Stage 1 - Collect UI-touching files

```bash
base="$(git merge-base origin/main HEAD)"
ui_files=$(git diff --name-only "$base...HEAD" \
  | grep -E '\.(tsx|jsx|css|scss)$|plugins/[^/]+/.+/(components|pages)/' \
  | grep -v '\.test\.' | grep -v '\.spec\.' | grep -v 'node_modules')
```

Read each file in full (not just the hunk) - a tint violation in one
import block may shadow a later correct import.

### Stage 2 - DESIGN.md Non-Negotiables checklist

Run every rule. Record each hit as `path:line - [rule-id] - message -
replace-with`.

#### R1 - No raw HTML form / table elements in plugin code

Forbidden in any file under `plugins/*/`, `apps/*/` UI code, or shared
page components:

- `<table>`, `<thead>`, `<tbody>`, `<tr>`, `<td>`, `<th>` - use
  `DataTable` from `@nexus/shared-ui`.
- `<button>` - use `Button`.
- `<input>`, `<textarea>`, `<select>` - use `Input`, `Textarea`, `Select`,
  or `Form` + `FormField`.
- `<form>` - use `Form` wrapper.

Detection:

```bash
grep -nE '<(table|thead|tbody|tr|td|th|button|input|textarea|select|form)[\s>]' \
  -- <ui-files>
```

Allowed exception: shared-ui source itself
(`packages/shared-ui/src/components/ui/*`). Skip matches in that path.

#### R2 - Tailwind tokens only, no raw hex / palette colors

Forbidden:
- Hex literals in JSX or CSS: `#ffffff`, `#3B82F6`, etc.
- `rgb(...)`, `rgba(...)` inline.
- Tailwind palette color classes:
  `text-red-[0-9]+`, `bg-red-[0-9]+`, `border-red-[0-9]+`,
  `text-green-[0-9]+`, `bg-green-[0-9]+`,
  `text-blue-[0-9]+`, `bg-blue-[0-9]+`,
  `text-yellow-[0-9]+`, `bg-yellow-[0-9]+`,
  `text-emerald-[0-9]+`, `bg-emerald-[0-9]+`,
  `text-gray-[0-9]+`, `text-zinc-[0-9]+`, `text-slate-[0-9]+`,
  `text-amber-[0-9]+`, `bg-amber-[0-9]+`.

Detection:

```bash
grep -nE "#[0-9a-fA-F]{3,8}\b|rgba?\(|\b(text|bg|border)-(red|green|blue|yellow|emerald|gray|zinc|slate|amber|purple|pink|indigo|cyan|teal)-[0-9]{2,3}\b" \
  -- <ui-files>
```

Replace-with mapping (see `references/design-system-rules.md`):

| From | To |
|---|---|
| `text-emerald-*`, `text-green-*` | `text-chart-2` |
| `text-red-*`, `bg-red-*` | `text-destructive`, `bg-destructive` |
| `text-gray-*`, `text-zinc-*`, `text-slate-*` | `text-foreground` / `text-muted-foreground` |
| `bg-blue-*` | `bg-primary` |
| `bg-yellow-*`, `bg-amber-*` | `bg-chart-3/10` (subtle tint) |
| `stroke="#3B82F6"` | `stroke="var(--chart-1)"` |

Exception: `@media print` blocks may use palette colors if the token
system does not resolve in print context - require a comment
`/* palette-ok: print-only */` adjacent to the override.

#### R3 - Container padding is `p-4 md:p-8`

Top-level page containers in plugins use `p-4 md:p-8`. Bare `p-6`,
`p-8` alone, or `px-N py-N` patterns are non-conforming.

Detection:

```bash
grep -nE 'className="[^"]*\bp-[468](\s|")' -- <ui-files>
```

False-positive guard: this rule applies only to files under
`plugins/*/src/pages/` or files whose root element is a full-viewport
container. When unsure, flag as `medium` and let the author confirm.

#### R4 - Badge variants are subtle tints

Badge variants must be subtle tints, not solid fills. Solid-fill pattern
is `bg-<color>` without an alpha, tint pattern is `bg-<token>/10`.

Forbidden (in badge components): `bg-green-500`, `bg-red-500`,
`bg-blue-500` as solid.

Prefer: `bg-chart-2/10 text-chart-2 border-chart-2/20` for success-like,
`bg-destructive/10 text-destructive border-destructive/20` for error.

Use the helper `statusToVariant(status)` in DESIGN.md § Status mapping.

#### R5 - Imports from shared-ui, not shadcn / radix / recharts directly

In any file under `plugins/*/` or `apps/portal-shell/`:

Forbidden:
- `from 'shadcn/ui'` or deep shadcn paths.
- `from '@radix-ui/*'` (except types in shared-ui itself).
- `from 'recharts'` (use `ChartContainer` from `@nexus/shared-ui`).
- `from '@tanstack/react-table'` (use `DataTable`).
- `from 'react-hook-form'` (use `Form`, `FormField`).

Detection:

```bash
grep -nE "from ['\"](shadcn/ui|@radix-ui/|recharts['\"]|@tanstack/react-table['\"]|react-hook-form['\"])" \
  -- <ui-files>
```

Replace-with: `from '@nexus/shared-ui'`.

#### R6 - Charts via `ChartContainer`, Forms via `Form`/`FormField`

- Any `recharts` chart in plugin code must be wrapped in
  `ChartContainer` (enables CSS-token injection).
- Forms must use `Form` + `FormField` from `@nexus/shared-ui` to get
  consistent label/error rendering and zod-resolver wiring.

### Stage 3 - Render findings

Group by severity. `R1` (raw HTML elements) and `R5` (wrong imports)
are **blocking** - they fragment the design system. `R2` (palette
colors) is **blocking** for new code, **non-blocking** if the diff is
only moving or reformatting existing offenders. `R3` / `R4` / `R6` are
**non-blocking** unless they break visual hierarchy.

## Output Format

```
# Design Review: <pr-title or branch>

## Verdict
<PASS | REQUEST_CHANGES | SKIPPED>

## Blocking (must fix before merge)
- plugins/finance/src/pages/Dashboard.tsx:42 - [R1] <button> used
  instead of Button.
  Replace with: import { Button } from '@nexus/shared-ui'; <Button>...</Button>.
- plugins/finance/src/pages/Dashboard.tsx:77 - [R2] bg-red-500 is a
  palette color.
  Replace with: bg-destructive.

## Non-blocking
- plugins/finance/src/pages/Dashboard.tsx:12 - [R3] Container uses p-6;
  convention is p-4 md:p-8.

## What looked good
- All new charts wrapped in ChartContainer.
- Form uses Form + FormField + zod resolver correctly.
```

## When findings are ambiguous

Say so. Do not invent a DESIGN.md rule - cite only rules that exist in
`references/design-system-rules.md`. If the diff uses a palette color
intentionally for a print-only path, ask the author to add the
`palette-ok: print-only` comment rather than silently allowing it.

## Integration points

- Consumed by AI-review pipeline Stage 3 (design-review).
- `code-review-expert` - defers design depth here.
- `security-audit` - separate, does not overlap.

## References

- `references/design-system-rules.md` - compact DESIGN.md rule list +
  semantic-color mapping + status-to-variant table.
