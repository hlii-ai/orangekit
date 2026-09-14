# OWASP API Security Top 10 (2023) — the delta only

<!-- Inspired by: davila7/claude-code-templates `owasp-security` (MIT · Copyright (c) 2025 Daniel (San) Ávila)
     Canonical content: the public OWASP API Security Top 10 2023 standard. -->

**Entries that overlap the web Top 10 are not rewritten here.** Only API-specific surface is covered.
The overlapping ones go to `owasp-top10.md`: API7 (SSRF)→A10 · API8 (Misconfiguration)→A05 ·
API2 (Broken Authentication)→A07.

| ID | Name | In this harness |
| --- | --- | --- |
| API1:2023 | Broken Object Level Authorization (BOLA) | **delegated** — ownership and IDOR are covered more fully by our own asset (`owasp-top10.md` A01) |
| API2:2023 | Broken Authentication | delegated → A07 |
| API3:2023 | Broken Object Property Level Authorization | **below** |
| API4:2023 | Unrestricted Resource Consumption | **below** |
| API5:2023 | Broken Function Level Authorization | **below** |
| API6:2023 | Unrestricted Access to Sensitive Business Flows | **below** |
| API7:2023 | Server Side Request Forgery | delegated → A10 |
| API8:2023 | Security Misconfiguration | delegated → A05 |
| API9:2023 | Improper Inventory Management | **below** |
| API10:2023 | Unsafe Consumption of APIs | **below** |

---

### API3:2023 Broken Object Property Level Authorization — CWE-915 · CWE-213

Authorization exists at the **object** level but not at the **property** level. Both directions are
defects — taking a field you must not take (mass assignment), or giving a field you must not give (excessive exposure).

- [ ] The request body is not handed wholesale to the model. **Choose the fields to accept explicitly**
      (can `role` · `isAdmin` · `ownerId` · `balance` be overwritten by user input?)
- [ ] Responses go out **through a serialization schema**. ORM entities are not returned as they are
- [ ] Where visible fields differ by role, that branching happens **on the server**
- [ ] The schema validator is configured to **reject** unknown keys (zod `.strict()`, etc.)

### API4:2023 Unrestricted Resource Consumption — CWE-770

- [ ] There is a **rate limit** on both authenticated and unauthenticated paths (especially login, search, file upload)
- [ ] There is an upper bound on request body and upload size
- [ ] List queries have a **page size ceiling** (does `limit=999999` go through?)
- [ ] Expensive operations (reports, exports, image conversion) have a concurrency limit or a queue
- [ ] For GraphQL, there is a query depth and complexity ceiling

### API5:2023 Broken Function Level Authorization — CWE-285

- [ ] Admin-only operations go through a **role check**. They do not rely on the path being unknown
- [ ] **No endpoint is missing** the auth middleware in the router (the axis guide's `requireAuth`
      wiring policy checks this by machine)
- [ ] Where permissions differ by HTTP method, that branching actually exists (is `GET` allowed but `DELETE` not?)

### API6:2023 Unrestricted Access to Sensitive Business Flows — CWE-799

Technically valid requests that are **abused in business terms**. Sweeping up ticket inventory,
draining coupons automatically, mass account creation.

- [ ] The flows that would be harmful if abused have been identified (purchase · booking · invite · refund)
- [ ] Each such flow has at least one of: human verification, device fingerprinting, rate limiting
- [ ] Inventory and limits recover exactly even when it fails

### API9:2023 Improper Inventory Management — CWE-1059

- [ ] There is a list of deployed API versions, and **old versions are not still alive**
- [ ] Staging and debug endpoints are not exposed in production
- [ ] The documentation matches the real routes (a live endpoint absent from the docs is the most dangerous)

### API10:2023 Unsafe Consumption of APIs — CWE-1104

**The external APIs we call are outside the trust boundary too.**

- [ ] External responses are used **only after validation**. Schema validation is not skipped just because it is third-party
- [ ] External calls have a timeout and a retry ceiling
- [ ] A URL supplied by an external party is not followed as it is (same axis as SSRF — A10)
- [ ] External responses are not rendered to the screen as they are (same axis as XSS — A03)
