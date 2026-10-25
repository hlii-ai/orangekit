---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "lib/**"
---
<!-- orangekit-pack: backend/fastify v3.36.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (ownership in the query condition · 404 instead of 403 · no internal details in error responses) belong to security.md, so they are not here. -->

# Fastify 5 + Drizzle core card

The project spec (`dev/docs/api/` etc.) and `.claude/rules/code-conventions.md` take precedence over this card and the `backend-guide` skill.
Look up wiring and examples in the `backend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Path prefix · id type · success/error envelope · validation-failure status code: if existing code or the spec has them, follow them as they are; if not, decide once and write it in `code-conventions.md`. Do not carry over the guide example values (`/api` · `{ data }` · 400). — why models get it wrong: it anchors on example values <!-- evidence: guide-ab T-B(/v1·422), T-D A run3 UUID · model-gap: observed -->
- [consistency] Build the error envelope only in the root `setErrorHandler`. Overriding it in a child plugin sends a different envelope from those routes only. — why models get it wrong: encapsulation applies to handlers too <!-- evidence: policies error-handler-at-root (run-verified) · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Put the auth `onRequest` hook in **the same plugin context** that registers the routes it protects. A sibling plugin's hook does not reach them and they answer 200 without auth. — why models get it wrong: the hook does exist in the code <!-- evidence: policies requireauth-in-route-plugin (run-verified) · model-gap: not-observed -->
- [security] Never log a whole error object. `DrizzleQueryError` carries the SQL and the **bound values** in its message. Log only the SQLSTATE (`err.cause.code`) and a fixed message, and redact the `authorization`/`cookie` headers. — why models get it wrong: `req.log.error(err)` is the idiom <!-- evidence: fastify-authoring audit A, guide-ab T-D B run1 · model-gap: observed -->
- [security] A 0-row mutation is a failure. Judge by the `returning()` length (`rowCount` for delete) and answer 404. — why models get it wrong: an update of someone else's row succeeds without an error <!-- evidence: policies mutation-returning-checked · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Reject NUL (`\u0000`) in text input schemas. PostgreSQL cannot store it, so it becomes a 500. — why models get it wrong: it stops at length validation <!-- evidence: fastify-authoring audit A, guide-ab T-D B run1 · model-gap: observed -->
- [performance] Inside a transaction callback use only `tx`. `db` runs outside the transaction and survives the rollback. — why models get it wrong: the two look the same <!-- evidence: policies (what humans keep; run-verified, 1 row left behind) · model-gap: not-observed -->
- [performance] Cut cursors on a monotonic key or the `(created_at, id)` tuple. A `timestamptz` (µs) round-tripped through a JS `Date` (ms) drops rows with the same instant. — why models get it wrong: sorting by `createdAt` alone is common <!-- evidence: fastify-authoring found only by running (rows missing out of 7) · model-gap: not-observed -->
- [performance] For uniqueness, do not check then insert; insert, and turn `23505` into 409. Concurrent requests leak a 500. — why models get it wrong: single-request tests pass <!-- evidence: fastify-authoring sqlState · model-gap: not-observed -->
- [performance] Name the host with `listen({ host, port })`. v5 has no positional arguments and the default host is loopback. — why models get it wrong: the v4 idiom <!-- evidence: policies listen-explicit-host · no-listen-positional (run-verified) · model-gap: not-observed -->
