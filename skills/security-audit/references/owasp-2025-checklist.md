# OWASP Top 10 (2025) - Review Checklist

Compact, code-review-oriented reference for the `security-audit` skill.
Each item lists the canonical risk, the diff-level signal to look for,
and a one-line remediation direction. Not a tutorial - use
`mcp__context7__query-docs` or OWASP.org for deep context.

## A01 - Broken Access Control

**Risk:** Missing or flawed authorization checks; IDOR; privilege
escalation; vertical/horizontal tenant-boundary breaks.

**Diff signals:**
- New route handler without a role/permission middleware.
- Object lookup by user-supplied id without an ownership check
  (`db.find(id)` where id comes from `req.params`).
- Server-side filter relying on a client-supplied flag (`isAdmin` in
  request body).
- Cross-tenant SELECT without a tenant-scope predicate.

**Remediation:** Deny-by-default; require auth on every route; scope
queries by the authenticated principal; add a negative-path test.

## A02 - Cryptographic Failures

**Risk:** Plaintext transit/rest; weak algorithms (MD5, SHA1 for
passwords); hardcoded keys/IVs; predictable randomness from
`Math.random` / `rand()` in security contexts.

**Diff signals:**
- `crypto.createHash('md5')`, `sha1` used on passwords or tokens.
- Hardcoded `const KEY = "..."` string longer than 16 chars.
- `http://` to an internal service that should be `https://`.
- Password hashing without a cost parameter
  (`bcrypt.hash(pw)` without rounds set, or raw SHA hashing).

**Remediation:** argon2id / bcrypt cost >= 12; TLS everywhere; keys in
a secret manager; `crypto.randomBytes` / `secrets.token_bytes` for
tokens.

## A03 - Injection

**Risk:** SQL, NoSQL, OS-command, LDAP, XPath, template, log injection.

**Diff signals:**
- String concatenation into SQL / SurrealQL / Mongo queries.
- `exec`, `execSync`, `spawn` with `shell: true` on user-reachable input.
- `eval`, `new Function(userInput)`, `vm.runInNewContext(userInput)`.
- Template engines rendered without auto-escape on user input.
- `pickle.loads` / `yaml.load` / `Marshal.load` on untrusted bytes.

**Remediation:** Parameterized queries (`$1`, `?`, `$var` for SurrealDB);
`execFile` / arg-array forms; schema-validated parsers
(`yaml.safe_load`, `JSON.parse` + zod).

## A04 - Insecure Design

**Risk:** Flaws baked into the design: missing rate limits, no lockout,
weak trust-boundary assumptions, no threat model.

**Diff signals:**
- New login / password-reset / OTP endpoint without rate-limit
  middleware.
- Trust-boundary crossing (public -> internal admin) without a threat
  comment.
- Business-logic check done client-side only (e.g., quota in JS, not
  enforced server-side).

**Remediation:** Add rate-limit + account lockout; document the trust
boundary in the ADR; enforce every constraint server-side.

## A05 - Security Misconfiguration

**Risk:** Defaults left on; verbose errors; permissive CORS; disabled
CSP; S3 buckets public.

**Diff signals:**
- `debug: true`, `NODE_ENV` check missing on a verbose error path.
- CORS `origin: '*'` combined with `credentials: true` - forbidden by
  spec and dangerous in practice.
- CSP disabled, `unsafe-eval` / `unsafe-inline` added.
- Storage bucket or container exposed without ACL review.

**Remediation:** Environment-specific configs; explicit allow-list CORS;
strict CSP; private-by-default storage.

## A06 - Vulnerable & Outdated Components

**Risk:** Known-CVE dependency pinned in the diff.

**Diff signals:**
- New dependency entry in `package.json`, `pyproject.toml`,
  `requirements.txt`, `go.mod`, `Cargo.toml`.
- Version downgrade on an existing dependency.

**Remediation:** Check advisories via `context7`,
`github.com/advisories`, `npm audit`, `pip audit`, `cargo audit`. Pin
to a patched version or add a justified-waiver comment.

## A07 - Identification & Authentication Failures

**Risk:** Weak password policy, no MFA for sensitive roles, session
fixation, predictable tokens, missing logout.

**Diff signals:**
- Session id in URL query string.
- JWT signed with `none` or a shared symmetric secret hardcoded.
- Password policy < 10 chars, no complexity, no breach-list check.
- Reset token using `uuid.v4` for security purposes (fine) vs.
  `Math.random` (not fine).

**Remediation:** Server-side session store; rotate session id on
privilege change; MFA on admin; breach-list check on password-set.

## A08 - Software & Data Integrity Failures

**Risk:** Unsigned artifacts, CI supply-chain compromise, deserialization
of untrusted data, auto-update without verification.

**Diff signals:**
- `pull_request_target` in a GitHub workflow (forbidden).
- CI step `curl ... | sh` without checksum verification.
- Deserialization on user bytes (`pickle`, `unserialize`, `BinaryFormatter`).
- Auto-update step without signature/subresource-integrity check.

**Remediation:** Use `pull_request`; pin actions to SHA; verify
checksums; prefer JSON over binary serializers; add SRI on CDN scripts.

## A09 - Security Logging & Monitoring Failures

**Risk:** Breaches unnoticed; secrets in logs; missing audit trail.

**Diff signals:**
- No log on auth failure, privilege change, admin action.
- Logging a request body that may contain `password`, `token`, `ssn`.
- Log statement without correlation id.

**Remediation:** Log actor + action + resource + outcome; scrub secrets
via a log redactor; include request id.

## A10 - Server-Side Request Forgery (SSRF)

**Risk:** Server fetches user-supplied URL; attacker reaches internal
services, cloud metadata, or localhost.

**Diff signals:**
- `fetch(userUrl)`, `axios.get(userUrl)`, `requests.get(userUrl)` without
  a host/scheme validator.
- URL-from-webhook-payload passed to an outbound call.

**Remediation:** Scheme allow-list (`https:` only); host allow-list OR
block RFC1918, link-local, `169.254.169.254`, `metadata.google.internal`;
route via an egress proxy that enforces the rule.

---

## Secret patterns (regex-grade)

Use these in Stage 4 secret-scan. Keep the list tight - false-positives
train reviewers to ignore output.

| Pattern | Provider |
|---|---|
| `AKIA[0-9A-Z]{16}` | AWS Access Key |
| `ASIA[0-9A-Z]{16}` | AWS Session Key |
| `sk_live_[0-9a-zA-Z]{24,}` | Stripe live |
| `sk-[0-9a-zA-Z]{32,}` | OpenAI / Anthropic-style |
| `ghp_[0-9a-zA-Z]{36}` | GitHub PAT |
| `gho_[0-9a-zA-Z]{36}` | GitHub OAuth |
| `xox[baprs]-[0-9a-zA-Z-]{10,}` | Slack |
| `-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----` | PEM key |
| `eyJhbGciOi[A-Za-z0-9_.-]{20,}` | JWT (context-dependent) |

## Filename heuristics

Flag these filenames in a diff even when contents look redacted:

- `.env`, `.env.*` (except `.env.example`, `.env.act.template`)
- `credentials.json`, `credentials.yaml`
- `service-account*.json`
- `*.pem`, `*.p12`, `*.pfx` checked into the repo
