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

**Then pick the references that match the project's nature.** Do not read them all — reading a standard
that does not apply only eats context and does not increase findings.

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

Items inspected:

| Pattern | Severity | How to inspect |
|------|--------|----------|
| Hardcoded API keys/tokens | Critical | grep for `sk_`, `pk_`, `key=`, `token=`, `password=` and the like |
| Environment files tracked by git | Critical | whether `.gitignore` covers `.env*` |
| Server-only secrets exposed to the client | Critical | whether client code uses a server-only key |
| Environment variable prefix abuse | High | whether a server-only value carries a client prefix |

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
rulings were **missed by three audits through reading and caught in one by execution.** The canonical source for the attack vector list is
`${CLAUDE_PLUGIN_ROOT}/skills/stack-guide-generator/assets/security-vectors.md`,
and that file was originally used to verify **guide authoring**. Here the target changes: **feed it
directly to the corresponding functions in the consumer's code**:

1. Find the return-path validation, path assembly, token comparison and escaping functions in the audit target
2. Actually call the vectors in that file (section A's 12 return paths · B path normalization · C token
   comparison · D escaping · E authorization) and look at the results
3. **Put valid input in too** — over-blocking is a defect
4. If the function does not exist, that itself is a finding (it means it is used with no validation)

### Step 4: Infrastructure security inspection

**Dependency audit** — identify the manager from the lockfile and run it. The canonical source for the
procedure is `skills/health-check/SKILL.md` Step 5, and the same identification is used here (`pnpm-lock.yaml`→`pnpm audit` · `yarn.lock`→`yarn audit` ·
`package-lock.json`→`npm audit` · `uv.lock`·`requirements.txt`→`pip-audit` ·
`Cargo.lock`→`cargo audit` · `go.sum`→`govulncheck`. With no lockfile this item is **undecidable**):

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

**Do not run SonarQube here.** It needs a server and takes minutes, so the user's consent must come
first — running it and getting consent are health-check Step 5.5's job. If an analysis already ran
through that path, fold the Security Hotspot and Vulnerability results into this report, and
**do not re-audit by hand the axes Sonar covered** (the discipline just below).

**Do not re-audit by hand the axes a tool covered.** Reporting the same defect twice creates alert
fatigue, and alert fatigue makes the report go unread.

| Item inspected | Severity |
|----------|--------|
| Critical/High CVE dependencies | Critical/High |
| Security headers not set (CSP, X-Frame-Options, etc.) | Medium |
| Unsafe HTML injection | High |
| Internal information exposed in error responses | Medium |

### Step 5: Payment / sensitive data security inspection

Performed only when payment or sensitive-data handling code exists:

| Item inspected | Severity (if not met) |
|----------|-----------------|
| Server-side validation of amount/quantity (client-sent values distrusted) | Critical |
| Webhook/callback signature verification | Critical |
| Secret keys used server-side only | Critical |
| State changes handled server-side | High |

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

HIGH (N)
--------
...

MEDIUM (N)
----------
...

LOW (N)
-------
...

Dependency vulnerabilities
--------------------------
[summary of the package manager audit results]

Undecidable (N)
---------------
[what could not be confirmed and why — tool missing · no lockfile · no runtime environment · no access]
e.g. SAST: semgrep not installed — static rule inspection could not be performed
e.g. SAST: SonarQube not run (server down / user deferred) — rule-engine inspection could not be performed
e.g. Dependencies: no lockfile — CVE comparison not possible

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
| **High** | privilege escalation, XSS, missing input validation | within 24 hours |
| **Medium** | information disclosure, security headers not set, weak validation | before the next release |
| **Low** | best practice not followed, improvement recommended | backlog |

This table is the security domain standard (CVSS-aligned), so its vocabulary and scale differ from the review scale. Convert when handing off to `/receiving-code-review` or `orangekit-reviewer` — **Critical · High → Critical · Medium → Important · Low → Suggestion**.

## Security checklist

Below is **the core that applies to every project**. Cryptography (A02) · parameterization (A03) ·
configuration (A05) · authentication failures (A07) · integrity/deserialization (A08) · audit logging (A09) ·
SSRF (A10), plus the API, LLM, mobile and K8s items, live in the `references/` picked in Step 1 — **do not copy them here.**


### Authentication/authorization
- [ ] Authenticated user checked in server-side actions
- [ ] Session/token validated at API endpoints
- [ ] Protected paths defined in middleware/guards
- [ ] DB access control policy enabled (RLS or query filters)
- [ ] Server-only keys used only on the server

### Input validation
- [ ] Schema validation applied to every API endpoint input
- [ ] Schema validation applied to every server-side action input
- [ ] URL parameters/queries validated
- [ ] File upload type/size limited

### Secret management
- [ ] No hardcoded API keys/passwords
- [ ] Environment files covered by `.gitignore`
- [ ] No server-only values exposed to the client

### Output security
- [ ] No unsafe HTML injection (or sanitized)
- [ ] No internal information in error responses
- [ ] No unnecessary fields in API responses

### Dependencies
- [ ] No Critical/High findings in the package manager audit
- [ ] No packages with known vulnerabilities in use

## Relationship to the `security-check` hook

| | When | Scope | Behavior |
| --- | --- | --- | --- |
| `security-check.sh` hook | **just before** a file write | that change | **blocks** on secret detection (exit 2) |
| this skill | after the fact, on request | **the whole codebase** | produces a report |

The hook stops secrets coming in; this skill finds **what is already in**.
Having the hook is not a reason to skip this inspection — code from before the hook was introduced has never been inspected.

## Project custom resources

> If `.md` files exist at the paths below, they are referenced automatically during a security review. If the files do not exist, this section is ignored.

| Category | Path | Use in this skill |
|---------|------|-------------------|
| Coding standards | `.claude/resources/coding-standards/` | secure coding criteria — verifying project-specific security patterns |
