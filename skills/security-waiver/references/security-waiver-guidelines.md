# Security Waiver - When Is It Legitimate?

Reference for the `security-waiver` skill. Use this as the mental
filter BEFORE composing a waiver. If your situation does not match one
of the legitimate patterns, fix the code instead of waiving.

## Legitimate Scenarios

### 1. LLM hallucinated a finding

Most common. Gemini or Claude reports a line number, pattern, or
"malformed" reference that does NOT exist in the file.

Verification protocol before waiving:

```bash
# Read the exact file + line the review quoted
sed -n '<N>p' <path>
# Search the pattern the review claimed
grep -n '<pattern>' <path>
```

If the evidence contradicts the finding, waive with:

```
/ai-review security-waiver Gemini markierte `<claim>` in <path>:<N> -
der tatsaechliche Inhalt dieser Zeile ist `<actual>`, verifiziert
via `sed -n <N>p <path>`. Das Pattern `<claim>` kommt im gesamten
File nicht vor.
```

### 2. Known-safe fixture / example

A test fixture intentionally contains a fake credential so the test
can exercise the auth-failure path. The value is never used in
production code.

```
/ai-review security-waiver Fake-Credential in tests/fixtures/auth.json -
dient dem Error-Path-Test in tests/auth.spec.ts:42. Kein Production-
Secret, kein Rotieren noetig. Pattern ist Regex-matchable, daher der
gitleaks-Hit.
```

Bonus: add a file-level `nosemgrep` or a dedicated gitleaks allowlist
entry so the next PR does not need the same waiver.

### 3. Context-unaware SAST hit

semgrep flags `eval(x)` but `x` comes from a trusted AST compiler, not
user input. Or Bandit flags `subprocess.run(..., shell=True)` but the
command string is a constant.

```
/ai-review security-waiver semgrep flagged `eval(compiled_ast)` in
src/lib/ast-runner.ts:88 als RCE-Vektor - `compiled_ast` stammt aus
unserem eigenen AST-Compiler (kein User-Input), der Check ist hier
ein False-Positive. AST-Input wird in der darunterliegenden Schicht
via Zod-Schema validiert.
```

### 4. Duplicate finding

Same root cause reported twice under different rule ids. Waive the
duplicate; keep the canonical finding visible:

```
/ai-review security-waiver Duplikat - selbes Finding wird auch
durch gitleaks-Rule `generic-api-key` abgedeckt, der hier bereits
als failure reportet ist. Waive nur das duplicate Bandit-Finding
B105, die echte Fix-Action liegt bei gitleaks-Hit in der selben
Zeile.
```

## Illegitimate Scenarios - Fix The Code

### It's a real secret in the diff

- Rotate the credential at the provider.
- Remove the secret from git history (`git filter-repo --invert-paths
  --path <file>` or interactive rebase, depending on reach).
- Re-commit with the secret in `.env` (gitignored) and the key name
  in `.env.example`.

No waiver. The finding is correct.

### It's a real XSS / SQLi / SSRF / RCE

- XSS: escape output, use `textContent` / `v-html`-disable,
  framework-safe rendering.
- SQLi: parameterize, use the ORM, never string-concat.
- SSRF: allow-list target domains, block private IPs + metadata
  endpoints.
- RCE: never `eval` user input, never `subprocess(..., shell=True)`
  with untrusted strings.

No waiver. Patch the code.

### "It's only internal" / "we trust our users"

Not a valid argument. Internal tools get popped too. Family-portal
with 2 users is STILL not an excuse to ship known vulns - the
waiver audit trail exists specifically to make "we trust our users"
visible as a weekly pattern.

### "The finding is cosmetic, not exploitable"

If it is genuinely non-exploitable, reason like (1) / (3) above and
waive with that reasoning explicit. If you cannot explain WHY it is
not exploitable in >= 30 chars, it probably is exploitable and needs
fixing.

## Reason Quality Checklist

Before posting, verify the reason contains:

- [ ] The specific finding id or quoted text from the review
  (`gitleaks generic-api-key`, `semgrep python.lang.eval`, etc.)
- [ ] The file + line number the finding referenced
- [ ] WHY it is a false positive (evidence, not opinion)
- [ ] Either a pointer to a follow-up fix (allowlist entry,
  nosemgrep marker) OR an explicit "no follow-up needed because X"

A reason that omits any of these is a candidate for weekly-review
flag-up via `metrics_summary.py`.

## Reasons That Trigger The Generic-Filter

Do NOT start your reason with:

- `fp`, `false positive` (without evidence)
- `ok`, `done`, `lgtm`, `sure`
- `trust me`, `i checked`
- `known issue`, `bekannt`, `wie besprochen`

Even if the full reason is long, the generic-prefix heuristic may
reject it. Lead with the specific finding, not the verdict.

## Weekly Review

`metrics_summary.py --since 7d --json | jq '.security_waivers'`
surfaces:

- `count` - number of waivers in the window
- `reasons` - first 80 chars of each

If `count > 3/week`, investigate:

1. Are Gemini's prompts drifting? (Most likely - re-tune.)
2. Is a specific pattern in the codebase recurring-FP? (Add an
   allowlist.)
3. Is the PR-author defaulting to waive instead of fix? (Uncomfortable
   but important self-audit.)

## Related

- `skills/nachfrage-respond/SKILL.md` - server-side consumer
- `skills/ac-waiver/SKILL.md` - sibling for Stage 5
- `docs/v2/40-ai-review-pipeline/05-security-waiver.md` - design doc
- `docs/v2/40-ai-review-pipeline/10-metrics-monitoring.md` - weekly
  metrics query recipes
