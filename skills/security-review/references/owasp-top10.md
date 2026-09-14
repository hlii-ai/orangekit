# OWASP Top 10 (2021) — the map for this harness

<!-- Inspired by: davila7/claude-code-templates `owasp-security` (MIT · Copyright (c) 2025 Daniel (San) Ávila)
     Canonical content: the public OWASP Top 10 2021 standard. The prose was not copied; it was rewritten to fit this harness's enforcement model. -->

**Each entry is either "delegated" or "new", never both.** Security knowledge already lives in four
places (`.claude/rules/security.md` · the axis guide's `policies.md` · `security-vectors.md` ·
the seam `contract.md`). Writing the same content again here makes it a fifth copy, and
a copy is a source of drift. A delegated entry says **only where to look**.

---

## Delegated — axes the harness already covers thickly

### A01:2021 Broken Access Control — CWE-284 · CWE-639 · CWE-862

**The strongest axis in this harness. It is not rewritten here.**

- Universal norms → `.claude/rules/security.md` "authorization boundary"
- Per-stack procedure → the auth/permission resources of the installed axis guide
- Failure surface contract → seam `contract.md` §5 (unauthenticated 401 · ownership failure 404 · role failure 403)
- Open redirect vectors → `stack-guide-generator/assets/security-vectors.md` section A

There is one thing to check when auditing: **is ownership part of the query condition**, or is it
compared after the fetch? The latter is open to zero-row mutation and enumeration attacks.

### A04:2021 Insecure Design — CWE-1173 · CWE-657

**Delegated.** The design phase is handled by the reversibility classification (T0) and by
`orangekit-planner` and `brainstorming`. A ruling of `Irreversible` (auth/RLS · payments · migrations)
forcing a multi-perspective fan-out and user confirmation is where threat modeling sits in this harness.

### A06:2021 Vulnerable and Outdated Components — CWE-1104 · CWE-1035

**Delegated.** The 5-step check before adopting a dependency is in `.claude/rules/code-change.md`;
auditing what is installed is Step 4 of this skill (identify the lockfile → run the manager's audit).

---

## New — axes with no canonical source in the harness

### A02:2021 Cryptographic Failures — CWE-327 · CWE-311 · CWE-326

Detection signals: sensitive data stored in plaintext · `MD5`/`SHA1` used for passwords · `DES` · `RC4` ·
ECB mode · TLS not enforced · hand-rolled crypto routines.

- [ ] Transport is TLS 1.2 or above. No path falls back to HTTP
- [ ] Fields needing encryption at rest (national ID · card · health data) have been identified
- [ ] Symmetric encryption uses an **authenticated mode** (AES-GCM, etc.). ECB is not used
- [ ] Keys live in the environment or a secret manager, not in code, and the rotation procedure is documented
- [ ] Randomness comes from a CSPRNG (`crypto.randomBytes` · the `secrets` module). `Math.random()` is not used for tokens

### A03:2021 Injection — CWE-89 · CWE-78 · CWE-79 · CWE-943

**The universal norms are in `.claude/rules/security.md` "input validation boundary". This is the detail.**

Detection signals: query string concatenation (`"SELECT … " + id`) · SQL built with template literals ·
user input in `exec`/`spawn` · NoSQL operator injection (`{$gt: ""}`) · dynamic `eval`.

- [ ] Every query is **parameterized** (placeholder/prepared statement). Even with an ORM, the raw
      escape hatches (`$queryRaw` · `text()`) carry no concatenation
- [ ] Positions that cannot be parameterized (table · column · sort direction) are narrowed with an **allowlist**
- [ ] Shell calls pass an argument array. They are not assembled into one string handed to a shell
- [ ] For NoSQL, user input is guaranteed to be **a value, not an object** (preventing operator injection)
- [ ] XSS escaping is per context — HTML body, attribute, URL, JS and CSS each differ

### A05:2021 Security Misconfiguration — CWE-16 · CWE-1188 · CWE-209

Detection signals: debug mode in production · default credentials · stack traces in responses ·
directory listing · overly broad CORS (`*` + credentials) · security headers not set.

- [ ] Debug and verbose errors are off in the production build (the output norms are in `security.md` "output security")
- [ ] No default accounts or default passwords remain
- [ ] CORS `origin` is an allowlist. `*` and `credentials: true` are not used together
- [ ] Security headers: `Content-Security-Policy` · `X-Content-Type-Options: nosniff` ·
      `Strict-Transport-Security` · `Referrer-Policy` · framing blocked
- [ ] Admin and debug endpoints are not exposed externally

### A07:2021 Identification and Authentication Failures — CWE-287 · CWE-916 · CWE-307 · CWE-384

Detection signals: passwords stored without a one-way hash · `md5(password)` · no login rate limit ·
predictable session IDs · sessions not invalidated on logout · low-entropy password reset tokens.

- [ ] Passwords use one of **bcrypt · scrypt · Argon2**. A general-purpose hash (SHA-256) is not used
- [ ] Login, reset and OTP have **rate limits and lockout**
- [ ] Session identifiers are 128 bits or more from a CSPRNG. They are **reissued** on successful login (preventing session fixation)
- [ ] Logout and password change invalidate existing sessions
- [ ] Authentication failure messages do not leak whether an account exists (failure reasons collapse into one)
- [ ] Reset tokens are single-use with a short expiry

### A08:2021 Software and Data Integrity Failures — CWE-502 · CWE-345 · CWE-494

Detection signals: `pickle.loads` · Java `ObjectInputStream` · PHP `unserialize` · YAML
`load` (not safe_load) · webhooks with no signature verification · external scripts loaded without integrity verification.

- [ ] **Untrusted data is not deserialized.** JSON is used as the serialization format
- [ ] Only the `safe_load` family is used for YAML
- [ ] Webhooks and callbacks are processed **only after the signature is verified** (the payment axis is Step 5 of this skill)
- [ ] CDN scripts carry SRI (`integrity`), or are bundled in the first place
- [ ] CI trusts the lockfile and does not perform arbitrary follow-up installs

### A09:2021 Security Logging and Monitoring Failures — CWE-778 · CWE-532 · CWE-223

**The axis asked for first in an enterprise audit, and the harness had no canonical source for it.**

Detection signals: authentication and authorization failures not logged · tokens, passwords or national
IDs written to logs verbatim · logs only in local files · no alerting on anomalies.

- [ ] **Security events are logged** — login success/failure, permission denial, admin operations,
      payment state changes, secret access
- [ ] Each record has **who · what · when · where** (subject identifier · action · timestamp · source IP)
- [ ] **Secrets are not written to logs** — tokens, passwords, card numbers and personally identifying
      information are masked (the `security-check` hook does not look at log strings — this is a place a human must look)
- [ ] Logs are centralized and have a defined retention period
- [ ] There is alerting on failure spikes and permission-denial spikes
- [ ] The logs themselves cannot be tampered with (append-only or shipped externally)

### A10:2021 Server-Side Request Forgery — CWE-918

Detection signals: the server does a `fetch`/`curl` to a user-supplied URL · a webhook registration
feature · fetching an image URL · a PDF renderer loading external resources.

- [ ] URLs received from outside must pass an **allowlist** (domain · scheme)
- [ ] Schemes other than `http`/`https` (`file:` · `gopher:` · `dict:`) are blocked
- [ ] **Private ranges and link-local are blocked** — `127.0.0.0/8` · `10/8` · `172.16/12` ·
      `192.168/16` · `169.254.169.254` (cloud metadata)
- [ ] DNS rebinding is accounted for — check that the verified host and the actual connection target are the same
- [ ] When following redirects, re-verify **at every hop**
