# Design System Rules - Review Reference

Compact, review-oriented excerpt of DESIGN.md for the `design-review`
skill. The full spec lives in the project root `DESIGN.md`; this file
gives the rules + detection patterns in a form the skill can cite.

## Non-Negotiable Rules (block merge when violated)

### R1 - No raw HTML form / table elements in plugin code

Plugin and page code may not use:

- `<table>`, `<thead>`, `<tbody>`, `<tr>`, `<td>`, `<th>` - use `DataTable`.
- `<button>` - use `Button`.
- `<input>`, `<textarea>`, `<select>` - use `Input`, `Textarea`, `Select`.
- `<form>` - use `Form`.

Exception: source files inside `packages/shared-ui/src/components/ui/`
are where these primitives are defined and therefore allowed.

### R2 - Tokens only, no raw hex or palette colors

Allowed colors come from CSS custom properties exposed by the theme
layer. Examples: `--primary`, `--destructive`, `--chart-1`,
`--chart-2`, `--muted-foreground`, `--border`.

Forbidden in any JSX/TSX/CSS:

- Hex literals: `#ffffff`, `#3B82F6`, `#0ea5e9`.
- `rgb(...)` / `rgba(...)` inline colors.
- Tailwind palette classes: `text-red-500`, `bg-blue-600`,
  `border-green-400`, `text-emerald-*`, `bg-amber-*`, `text-gray-*`,
  `text-zinc-*`, `text-slate-*`, `text-indigo-*`, `bg-pink-*`, etc.

Allowed palette use: strictly within a `@media print` block where the
CSS-variable theme layer does not apply. Require an adjacent comment:

```css
@media print {
  /* palette-ok: print-only */
  .chart-label { color: #000000; }
}
```

### R3 - Container padding convention

Top-level page containers in plugins use `p-4 md:p-8`. Bare `p-6` or
`p-8` on a page root is non-conforming.

```tsx
// Good
<div className="p-4 md:p-8">...</div>

// Bad
<div className="p-6">...</div>
```

### R4 - Badge variants are subtle tints

Badge backgrounds are 10 % alpha over the token color. Solid fills on
badges are forbidden.

```tsx
// Good
<Badge className="bg-chart-2/10 text-chart-2 border-chart-2/20">paid</Badge>

// Bad
<Badge className="bg-green-500 text-white">paid</Badge>
```

### R5 - Imports via @nexus/shared-ui only

Plugin and app code import UI primitives from `@nexus/shared-ui`. Never
import directly from:

- `shadcn/ui`
- `@radix-ui/*`
- `recharts`
- `@tanstack/react-table`
- `react-hook-form`
- `sonner`

The wrappers in `@nexus/shared-ui` exist to guarantee token injection
and consistent prop signatures across the app.

### R6 - Chart + Form wrappers

- `recharts` charts must be wrapped in `ChartContainer` (CSS-token
  injection).
- Forms use `Form` + `FormField` + zod resolver.

---

## Semantic Color Mapping

When reviewing a palette-color violation, propose the token using this
table. Exact one-to-one mappings - do not over-translate.

| From (palette) | To (token) |
|---|---|
| `text-emerald-*`, `text-green-*` | `text-chart-2` |
| `bg-emerald-*`, `bg-green-*` | `bg-chart-2/10` (tint) or `bg-chart-2` (solid, rare) |
| `text-red-*`, `bg-red-*` | `text-destructive`, `bg-destructive` |
| `text-gray-*`, `text-zinc-*`, `text-slate-*` (headings) | `text-foreground` |
| `text-gray-*`, `text-zinc-*`, `text-slate-*` (secondary) | `text-muted-foreground` |
| `bg-blue-*` | `bg-primary` |
| `bg-yellow-*`, `bg-amber-*` | `bg-chart-3/10` |
| `stroke="#3B82F6"` (SVG inline) | `stroke="var(--chart-1)"` |

If the mapping is ambiguous (a shade of gray could be either foreground
or muted-foreground), flag as `medium` and let the author decide.

---

## Status -> Badge Variant

Use this helper rather than inlining conditional classes:

```tsx
function statusToVariant(status: string): BadgeVariant {
  if (status === 'completed' || status === 'paid' || status === 'active') return 'success';
  if (status === 'failed' || status === 'rejected') return 'destructive';
  if (status === 'pending' || status === 'draft') return 'warning';
  return 'secondary';
}
```

Badge variant -> token mapping:

| Variant | Background | Text | Border |
|---|---|---|---|
| `success` | `bg-chart-2/10` | `text-chart-2` | `border-chart-2/20` |
| `destructive` | `bg-destructive/10` | `text-destructive` | `border-destructive/20` |
| `warning` | `bg-chart-3/10` | `text-chart-3` | `border-chart-3/20` |
| `secondary` | `bg-muted` | `text-muted-foreground` | `border-border` |

---

## Detection Patterns (for grep)

Paste-ready patterns the skill uses in Stage 2.

### Raw HTML primitives (R1)

```
<(table|thead|tbody|tr|td|th|button|input|textarea|select|form)[\s>]
```

### Palette colors + hex (R2)

```
#[0-9a-fA-F]{3,8}\b|rgba?\(|\b(text|bg|border)-(red|green|blue|yellow|emerald|gray|zinc|slate|amber|purple|pink|indigo|cyan|teal|rose|fuchsia|violet|sky|stone|neutral)-[0-9]{2,3}\b
```

### Forbidden imports (R5)

```
from ['\"](shadcn/ui|@radix-ui/|recharts|@tanstack/react-table|react-hook-form|sonner)['\"]
```

### Container padding (R3)

```
className="[^"]*\bp-[68](\s|")
```

---

## Tailwind v4 Notes (for reviewers)

- No `tailwind.config.js`; theme is declared in CSS via
  `@import "tailwindcss"` + `@theme inline`.
- `@theme inline` maps CSS vars (`--color-chart-2`) to Tailwind
  utilities (`bg-chart-2/10` works because of this mapping).
- Dark mode via `.dark` class selector, not `media`.

When a reviewer sees `bg-chart-2/10` and cannot find where it is
declared - that is normal; the declaration is in
`apps/portal-shell/src/globals.css` or the shared theme file.

---

## Reject Examples (one-liners for PR comments)

- `[R1] <button> -> import { Button } from '@nexus/shared-ui'.`
- `[R2] bg-red-500 -> bg-destructive.`
- `[R2] text-emerald-600 -> text-chart-2.`
- `[R3] p-6 -> p-4 md:p-8 (top-level page container).`
- `[R4] Solid badge fill -> subtle tint (bg-<token>/10).`
- `[R5] from 'recharts' -> from '@nexus/shared-ui' + wrap in ChartContainer.`
