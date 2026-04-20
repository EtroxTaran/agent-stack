---
name: security-audit
description: 'Use this skill to run a security-focused PR review covering OWASP Top 10 (2025), secret-leakage scanning, SAST-report interpretation, and Nexus-specific security rules. Triggers on "security review", "audit this PR for vulnerabilities", "check for secret leaks", "SAST review", "OWASP scan", "semgrep findings", "security audit of this diff". Produces findings with severity (critical/high/medium/low), path:line references, and short remediation steps. NOT for formatting-only changes, style nits, performance tuning, or general code critique (use code-review-expert instead), and NOT for design-system conformance (use design-review). Reason to use over ad-hoc security spot-check - enforces the same OWASP checklist and the same Nexus-specific rule-set regardless of which CLI is driving, so the AI-review pipeline sees a consistent security signal.'
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
  - mcp__context7__query-docs
  - mcp__context7__resolve-library-id
---

# Security Audit

Security-focused PR review. Lead-reviewer is Gemini (paired with semgrep
in the existing pipeline), Claude serves as second opinion. Tool-neutral
body - the checklist runs the same way from every CLI.

## When to use

Invoke when the user asks for a security sanity-check, OWASP pass,
secret-leak scan, or wants semgrep output translated into actionable
findings. Stay silent on formatting-only diffs.

## Inputs you may receive

- A PR number plus repo context - use `github` MCP for diff + metadata.
- A branch range (`main..HEAD`) - use `git diff`.
- A semgrep JSON report on disk - parse it first (see Stage 1).
- Raw diff pasted by the user - review inline.

## Workflow

### Stage 1 - Pre-flight: parse semgrep report if present

Check for a SAST report at common locations:

```bash
for p in semgrep-report.json .semgrep/results.json /tmp/semgrep.json; do
  if [ -f "$p" ]; then
    REPORT="$p"; break
  fi
done
```

If found, extract findings the review must cite:

```bash
jq -r '.results[] | "\(.path):\(.start.line) - \(.check_id) - \(.extra.severity) - \(.extra.message)"' \
  "$REPORT"
```

Every `ERROR` severity semgrep finding becomes a blocking item in the
output unless a `nosemgrep` comment with a justification is adjacent
(see Nexus-rule 5 below).

### Stage 2 - OWASP Top 10 (2025) walkthrough

Run every item against the diff. See
`references/owasp-2025-checklist.md` for full rule text and examples.

1. **A01 Broken Access Control** - new routes enforce authZ; no IDOR on
   user-supplied ids; tenant boundaries respected.
2. **A02 Cryptographic Failures** - no hardcoded keys; TLS on external
   calls; password hashing uses argon2/bcrypt/scrypt with proper cost.
3. **A03 Injection** - parameterized SQL / SurrealQL / ORM binds; no
   shell string-concat; no `eval`, `Function`, `vm.runInNewContext` on
   user input.
4. **A04 Insecure Design** - missing rate-limits on login / password-reset;
   trust-boundary crossings reviewed.
5. **A05 Security Misconfiguration** - no `debug: true` in prod paths;
   default-deny CORS; CSP not disabled.
6. **A06 Vulnerable Components** - added deps checked against advisories
   (use `context7` or `npm audit`/`pip audit`/`cargo audit`).
7. **A07 Identification & Authentication Failures** - session fixation,
   weak password policy, missing MFA paths for admin.
8. **A08 Software & Data Integrity** - no unsigned auto-update; CI
   workflows do not use `pull_request_target` (see Nexus-rule 4).
9. **A09 Logging & Monitoring Failures** - security events logged with
   actor + resource; no secrets in logs.
10. **A10 SSRF** - outbound requests to user-supplied URLs validated
    against an allow-list or at minimum scheme/host restricted.

### Stage 3 - Nexus-specific rules (from AI-review pipeline)

These are project-durable and override generic advice for this codebase:

1. **OAuth scope lock** - Better Auth / Google OAuth scope must stay at
   `openid email profile`. Any widening (Drive, Gmail, Calendar) -
   **blocking** unless the diff also adds an ADR.
2. **LLM-API-key isolation** - `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
   `PERPLEXITY_API_KEY` may appear in n8n credentials only. If a diff
   references them from `apps/portal-api/` or any package - **blocking**.
3. **apiKeyAuth global-apply** - `apiKeyAuth` middleware must be attached
   globally in `app.ts`, never per-route. Per-route wiring is an easy
   authZ-bypass - **blocking**.
4. **`pull_request_target` banned** - any workflow file using this event
   is **critical blocking**. It grants write tokens to untrusted PR
   code. Use `pull_request` + explicit `permissions: { contents: read }`.
5. **`nosemgrep` requires justification** - every `nosemgrep` marker
   needs an inline comment explaining why. Bare `// nosemgrep` -
   **blocking**.
6. **SurrealDB parameterization** - SurrealQL queries must use `$var`
   bindings, never string-interpolated user input. String-interp into
   SurrealQL - **critical blocking** (A03).
7. **Tenant-iso / domain-spaces** - each plugin owns its SurrealDB
   namespace. Cross-plugin reads only via typed read-contracts. Raw
   cross-namespace SELECTs in a plugin - **blocking**.

### Stage 4 - Secret-leakage scan (diff-scoped)

Run high-signal pattern matches against the diff only (cheap, zero
false-negatives on known providers):

```bash
patterns='AKIA[0-9A-Z]{16}|sk_live_[0-9a-zA-Z]{24,}|sk-[0-9a-zA-Z]{32,}|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|ghp_[0-9a-zA-Z]{36}|xox[baprs]-[0-9a-zA-Z-]{10,}|eyJhbGciOi[A-Za-z0-9_.-]{20,}'
git diff "<base>...HEAD" | grep -nE "$patterns" || echo "clean"
```

Additional `.env*` and credential-filename check:

```bash
git diff --name-only "<base>...HEAD" | grep -E '(^|/)\.env($|\.|/)|credentials\.(json|ya?ml)|service-account.*\.json$' \
  && echo "secrets-filename hit"
```

Any hit is **critical blocking**. Recommend rotation + history rewrite
(`git filter-repo`) rather than just a revert commit.

### Stage 5 - Render findings

Severity mapping:

| Severity | Meaning | Examples |
|---|---|---|
| critical | exploit live in production path | leaked secret, injectable SQL, missing authZ on admin route |
| high | exploitable with effort | SSRF on internal net, weak crypto on password, CORS wildcard + creds |
| medium | defense-in-depth gap | missing rate-limit, verbose errors, outdated dep with public CVE |
| low | hardening nit | stronger CSP, HSTS preload, typed-error wrapping |

## Output Format

```
# Security Audit: <pr-title or branch>

## Verdict
<PASS | BLOCK | CONDITIONAL>

## Critical (blocking merge)
- apps/portal-api/src/routes/admin.ts:42 - [A01 Broken Access Control]
  New /admin/users route missing requireRole('admin') check.
  Remediation: wrap handler with requireRole middleware; add test.

## High
- apps/portal-api/src/services/webhook.ts:77 - [A10 SSRF] Outbound fetch
  to user-supplied url with no allow-list.
  Remediation: reject non-https, block RFC1918 + metadata IPs, or route
  via egress proxy.

## Medium / Low
- <path:line> - [category] <short message> - <remediation>

## Secret-leak scan
<clean | N hits>

## Semgrep
<parsed N findings, M promoted to blocking>

## What looked good
- All new routes have explicit authZ middleware.
- SurrealDB queries use $var bindings throughout the diff.
```

## When findings are ambiguous

Do not invent a vulnerability to pad the report. Phrase uncertainty as
"I cannot determine from this diff whether input X reaches sink Y -
please confirm the call-path or add a test." Never fabricate a CVE
reference.

## CVE lookups

Use `context7` to pull current advisory docs for a dependency before
asserting a CVE applies. Do not cite CVE numbers from training data -
cross-reference against `mcp__context7__query-docs` or
`github.com/advisories` via `gh api`.

## Integration points

- Consumes semgrep output from `.github/workflows/ai-code-review.yml`.
- Consumed by AI-review pipeline Stage 2 (security). A `BLOCK` verdict
  triggers the veto path unless a `/ai-review security-waiver` is in
  play.
- `code-review-expert` - generic review, defers OWASP depth here.
- `design-review` - separate skill for DESIGN.md conformance.

## References

- `references/owasp-2025-checklist.md` - full rule list with examples.
