---
name: security-review
description: Audits the whole codebase for security vulnerabilities and produces a report by severity. Use for pre-release checks, full security audits, dependency CVE checks, exhaustive secret sweeps, and payment/sensitive-data security review. To see only vulnerabilities newly introduced in a branch diff, use Claude Code's built-in /security-review — this skill covers the full audit, dependencies, secrets and payments, and the built-in tool does not cover those areas.
---

# Security Review

OWASP Top 10 based vulnerability inspection and structured report generation.

## Workflow

### Step 1: Decide the review scope

| Review type | Trigger | Inspection scope | Steps to run |
|----------|--------|----------|----------|
| Full review | user requests a full security audit | the whole project | 2 → 3 → 4 → 5 → 6 |
| Change review | after a feature is implemented, PR review | the files in `git diff` | 2 → 3 → 4 → 6 |
| Targeted review | security check of a specific domain/feature | only the given paths | 2 → 3 → 6 |

**Then pick only the references that match the project** — a standard that does not apply eats context and adds no findings.

| If the project | Read |
|-----------|--------|
| is a web app (always) | `references/owasp-top10.md` |
| serves an HTTP API | `references/api-top10.md` |
| has LLM or agent features | `references/agentic.md` |
| has a mobile app | `references/mobile-masvs.md` |
| deploys on K8s or containers | `references/kubernetes.md` |

`owasp-top10.md` is a **map** — each entry is either "delegated" (pointing at an existing canonical
source) or "new", and a delegated entry is not ruled on again there.

### Step 2: Secret and environment variable inspection

| Pattern | Severity | How to inspect |
|------|--------|----------|
| Hardcoded API keys/tokens | Critical | grep for `sk_`, `pk_`, `key=`, `token=`, `password=` and the like |
| Environment files tracked by git | Critical | whether `.gitignore` covers `.env*` |
| Server-only secrets exposed to the client | Critical | whether client code uses a server-only key |
| Environment variable prefix abuse | High | whether a server-only value carries a client prefix |

**Config defaults — does it open when the value is missing?** What was dismissed after reading only the default
(a dev fallback secret · retention period 0 · a check skipped when unset) was caught again by other audits.
Collect env reads (`process.env` · `getenv` · `${VAR:-}` · Dockerfile `ARG`) with **one** `grep -n -A3`
(diff only, for a change review), and do not open new files when the surrounding lines settle it:

1. Keep **only those that reach a security decision** (secrets · CORS · HTTPS · env mode · retention · allowlists) — drop any whose sink you cannot cite
2. Follow each when it is **missing · empty string · 0** — startup failure is closed; running on a default means: is that default safe?
3. For a branch on an env name like `NODE_ENV`, check **the other side** too — "production sets it" is not a refutation but a conditional severity

### Step 3: Input validation and authentication/authorization inspection

**Input validation:**

| Target | What is inspected | Severity (if not met) |
|------|----------|-----------------|
| API endpoints | schema-based input validation | High |
| Server-side actions | argument validation | High |
| Dynamic route parameters | parameter type validation | Medium |
| File upload | type/size limits | Medium |

**Authentication/authorization:**

| Target | What is inspected | Severity (if not met) |
|------|----------|-----------------|
| Server-side actions | authenticated user check | Critical |
| API endpoints | session/token validation | Critical |
| Middleware/guards | protected path definitions + session validation | High |
| DB access control | row-level security (RLS) or query filters | Critical |

**Run it, do not read it.** Return paths, path normalization, token comparison, escaping and authorization
rulings were **missed by three audits through reading and caught in one by execution.** **Feed** the canonical vectors in
`${CLAUDE_PLUGIN_ROOT}/skills/stack-guide-generator/assets/security-vectors.md` **directly to the matching functions in the consumer's code**:

1. Find the return-path validation, path assembly, token comparison and escaping functions in the audit target
2. Actually call the vectors (A 12 return paths · B path normalization · C token comparison · D escaping · E authorization)
3. **Put valid input in too** — over-blocking is a defect
4. If the function does not exist, that itself is a finding (it means it is used with no validation)

### Step 4: Infrastructure security inspection

**Dependency audit** — identify the manager from the lockfile and run it (canonical: `skills/health-check/SKILL.md` Step 5:
`pnpm-lock.yaml`→`pnpm audit` · `yarn.lock`→`yarn audit` · `package-lock.json`→`npm audit` ·
`uv.lock`·`requirements.txt`→`pip-audit` · `Cargo.lock`→`cargo audit` · `go.sum`→`govulncheck`.
No lockfile → **undecidable**):

```bash
pnpm audit 2>&1   # substitute the identified manager and actually run it
```

**If a static analysis tool is on PATH, run it too.** If not, **do not demand an install** — write it
into the report's "undecidable" section, so that the absence of a tool is not folded into the absence of a vulnerability.

```bash
command -v semgrep     >/dev/null && semgrep --config=auto --error 2>&1
command -v bandit      >/dev/null && bandit -r . 2>&1        # Python
command -v gosec       >/dev/null && gosec ./... 2>&1        # Go
command -v govulncheck >/dev/null && govulncheck ./... 2>&1  # Go
command -v sonar-scanner >/dev/null && echo "SonarQube detected — delegating to health-check Step 5.5"
```

**Do not run SonarQube here** — it needs a server, minutes and user consent, so health-check Step 5.5 owns it.
If it already ran, fold in its Hotspot and Vulnerability results. **Do not re-audit by hand the axes a tool
covered** — duplicate reports breed alert fatigue, and alert fatigue makes the report go unread.

| Item inspected | Severity |
|----------|--------|
| Critical/High CVE dependencies | Critical/High |
| Security headers not set (CSP, X-Frame-Options, etc.) | Medium |
| Unsafe HTML injection | High |
| Internal information exposed in error responses | Medium |

### Step 5: Payment / sensitive data security inspection

Performed only when payment or sensitive-data (health · financial · biometric · location · ID number · IP) handling code exists:

| Item inspected | Severity (if not met) |
|----------|-----------------|
| Server-side validation of amount/quantity (client-sent values distrusted) | Critical |
| Webhook/callback signature verification | Critical |
| Secret keys used server-side only | Critical |
| State changes handled server-side | High |

**Count sensitive data down to its copies** — looking only at DB rows misses values copied into queue payloads and logs (observed).
Without new exploration, follow only the calls through which the **write entry points** read in Step 3 pass the value, and fill
the copy table with where it lands (DB · queue · logs · cache · browser storage · object storage · disk · external processor).
An empty cell is a finding: retention-enforcing code · per-subject erasure path · the entry point's consent/authz gate
(present on other entry points but not this one). Check retention code against the Step 2 table — does it switch off at 0 or unset?

### Step 6: Produce the security report

Write the report in this format:

```
Security review report
======================

Scope: [full/changes/targeted] ([N] files)
Date: [YYYY-MM-DD]

CRITICAL (N)
------------
1. [file:line] - [vulnerability title]
   Finding: [concrete description]
   Impact: [impact if exploited]
   Fix: [concrete fix]
   Reference: OWASP A03:2021 · CWE-89   ← write the real standard IDs (no placeholders)

HIGH · MEDIUM · LOW (N) — same format

Dependency vulnerabilities
--------------------------
[summary of the package manager audit results]

Config defaults (N — open M)   ← list closed ones too, one line each; they are the dismissal evidence
---------------
[setting] | [read at file:line] | [when missing·empty·0] | [closed / open → finding no.]

Sensitive data copies (when Step 5 applies)
---------------------
[data] | [where it lands] | [retention code] | [erasure path] | [writing entry point · gate]

Undecidable (N)
---------------
[what could not be confirmed and why — tool missing (e.g. semgrep not installed) · no lockfile · no runtime environment · no access]

Overall assessment
------------------
Security level: [good/caution/risky/severe]   ※ do not write 'good' while undecidable items remain
Immediate action required: [list]
Recommendations: [list]
```

## Severity definitions

| Severity | Criteria | Fix deadline |
|--------|------|----------|
| **Critical** | data leak, authentication bypass, secret exposure, RCE | immediately |
| **High** | privilege escalation, XSS, missing input validation, one anonymous request maps straight to an uncapped paid call | within 24 hours |
| **Medium** | information disclosure, security headers not set, weak validation, anonymous resource/cost abuse, no basis for retention·erasure·consent of sensitive data | before the next release |
| **Low** | best practice not followed, improvement recommended | backlog |

**When a severity depends on a deployment fact, do not leave it blank** — write `conditional High (condition: secret unset + URL public)`.
A blank severity reads as zero. Where a legal judgment is needed (consent basis etc.), add "legal review".

This table is the security domain standard (CVSS-aligned), so its vocabulary and scale differ from the review scale. Convert when handing off to `/receiving-code-review` or `orangekit-reviewer` — **Critical · High → Critical · Medium → Important · Low → Suggestion**.

## Relationship to the `security-check` hook

The hook **blocks** (exit 2) secrets in a change **just before** a file write; this skill finds **what is already in**,
across the whole codebase. Having the hook is not a reason to skip this inspection — code from before the hook was introduced has never been inspected.

## Project custom resources

> If a path has `.md` files they are referenced; otherwise skip this section.

| Category | Path | Use in this skill |
|---------|------|-------------------|
| Coding standards | `.claude/resources/coding-standards/` | secure coding criteria — verifying project-specific security patterns |
