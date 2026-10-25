---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "ios/**"
  - "android/**"
  - "lib/**"
  - "server/**"
  - "backend/**"
  - "api/**"
---
<!-- orangekit-rule-version: 3.36.0 -->
<!-- security-check.sh (PreToolUse) blocks only hardcoded secret **strings**, by regex.
     This card carries what that regex can never catch — a problem of **placement** rather than of value,
     that is, "the right value put on the wrong side". Stack-specific procedures belong to the axis guides. -->

# Security Card

## The Secret Boundary — not the value, but which side it sits on

| Kind | Where it goes |
| --- | --- |
| Service role·admin keys (`service_role`, admin SDK, master tokens) | **Server only.** No import from a file that ends up in the client bundle |
| Payment secret keys | **Server only.** In server handlers/actions only |
| AI·external API keys | **Server only.** Never called directly from the browser |
| PEM private keys · service account JSON | An env var path or the filesystem. Never in the repository |
| Public client keys (an anon key, etc.) | Client side is fine — **but only when the key was designed to be public** |

**A public prefix puts it in the bundle.** Prefixes of the `NEXT_PUBLIC_` · `VITE_` · `PUBLIC_` · `EXPO_PUBLIC_`
family have their value statically substituted at build time. Putting such a prefix on a server-only key is
**exposure, not configuration.** Before adding the prefix, ask "is it acceptable for this value to be visible in the browser".

## The Input Validation Boundary

- External input (request body · query · form · webhook payload) reaches business logic or a DB query
  **only after it passes schema validation**. Do not let an unvalidated value flow straight through
- File uploads have their type·size ceiling enforced **on the server**. Client-side validation is UX, not a boundary
- **Parameterize** queries. Do not concatenate values into a string (SQL and NoSQL alike). Positions that cannot
  take a parameter (table·column·sort direction) are narrowed with an **allowlist**
- **Reject in the schema any value the store cannot hold** — a value like NUL (`\u0000`) in PostgreSQL text passes
  length and format validation and then blows up at the storage step as a 500
- If you do not know where the trust boundary is crossed, that function has not yet decided where validation belongs

## The Authorization Boundary

- At the server entry point (handler·action·job), **identify the authenticated principal first**. Do not trust
  a user identifier sent by the client — take it from the session·token
- Protect a guarded path at the **data access level** as well, not only per route. With only a screen guard,
  it is bypassed by calling the API directly
- When you take an identifier and act on a specific record, put ownership **into the query condition.** Comparing after fetching
  leaks through zero rows·races·enumeration, and the test still passes even when the condition is deleted
- **A mutation that touches 0 rows is a failure** — judge update·delete by the affected row count and answer 404. A mutation
  on someone else's row ends in 0 rows with no error, so unless you check, a success response goes out
- On a stack that uses row level security, the policy is not the only boundary — the policy plus the application check, both.
  (The checklist for attaching a policy at table creation is `.claude/rules/data-modeling.md` §8)

## Output Security

- Do not use raw HTML injection (`dangerouslySetInnerHTML` · `v-html` · `innerHTML =`).
  When it is unavoidable, run it through a sanitize library and **leave a comment on why it is unavoidable**
- Do not put a stack trace·DB schema·internal path in an error response. Return only a user-friendly message in the response
- **Do not leave values in the log either** — do not pass a whole error object to the logger. ORM·driver errors carry the SQL
  and the **bound values** in their message. Log only the error code (SQLSTATE etc.) and a fixed message, and redact the auth
  header·cookies in the request log
- If a redirect target comes from user input, **narrow it with an allowlist** (open redirect)
- On an authorization failure, **do not leak existence** — someone else's resource is a 404, not a 403.
  Distinguishing the two announces the existence of something the caller cannot access

## Integrity — where it breaks silently

- **Do not protect uniqueness by checking before inserting** — put a constraint on it and turn the violation (PostgreSQL `23505` etc.)
  into 409. A concurrent request between the check and the insert leaks out as a 500
- **Every write inside a transaction goes through that transaction's handle** — a row written with the outer client survives the rollback

## What Is Not Here

The five-step check before adopting a dependency → `.claude/rules/code-change.md`
Per-stack pitfalls → `.claude/rules/stack-*.md` (stacks that have a pack) · per-stack auth procedures·examples → the detailed guide skill (if installed)
