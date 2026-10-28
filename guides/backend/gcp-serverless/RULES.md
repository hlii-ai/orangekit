---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "lib/**"
---
<!-- orangekit-pack: backend/gcp-serverless v3.14.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (ownership in the query condition · 404 instead of 403 · no internal details in error responses) belong to security.md, so they are not here. -->

# Cloud Run + Hono + Firestore core card

The project spec (`dev/docs/api/` etc.) and `.claude/rules/code-conventions.md` take precedence over this card and the `backend-guide` skill.
Verified versions — `hono@4` · `@google-cloud/firestore@9`. Install the latest stable release (`code-change.md` "Before Adding a Dependency") — where an item conflicts with a newer major, the official upgrade docs take precedence.
Look up wiring and examples in the `backend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Path prefix · id format · success/error envelope · validation-failure status code follow existing code or the spec; if there is none, decide once and write it in `code-conventions.md`. Do not carry over the guide example values. — why models get it wrong: it anchors on example values <!-- evidence: guide-ab T-B·T-D (fastify measured) · model-gap: not-observed -->
- [consistency] Read error code→status from one table through an accessor function only. No scattered subscript access. — why models get it wrong: a code missing from the table enters as an `undefined` status and becomes a 500 with no cause <!-- evidence: policies seam-status-lookup · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Firestore rules do not guard the server. Service-account access bypasses them, so the application check is the only boundary. Keep the rules deny-all and write no auth conditions in them. — why models get it wrong: "the rules protect us" loosens the app check <!-- evidence: policies rules-deny-all · ownership-in-query · model-gap: not-observed -->
- [security] Verify ID tokens in one function with explicit `issuer`/`audience`/`requiredClaims` (`exp`), and reject an empty `sub`. The owner key is `sub` (not `email`). Do not accept service-to-service calls in the same function; leave them to Cloud Run IAM. — why models get it wrong: leave them out and jose lets that token through <!-- evidence: policies seam-no-direct-token-parse, identity-tokens.md §4 measured · model-gap: not-observed -->
- [security] Read inside `runTransaction` for updates and deletes, and judge ownership before converter parsing. — why models get it wrong: `delete()` succeeds on a missing doc, and parsing first lets the 422/404 difference reveal existence <!-- evidence: policies mutation-in-transaction, vanilla-gcp-authoring audit A · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Add `__name__` after the sort key of a cursor query. — why models get it wrong: docs with the same instant drop at page boundaries without any error <!-- evidence: policies cursor-tiebreak (measured 5 of 7 missing) · model-gap: not-observed -->
- [performance] Do not fold `FAILED_PRECONDITION` (missing index) into a 4xx, and deploy indexes before the image. — why models get it wrong: it looks like a user error, so the missing deploy vanishes from the logs <!-- evidence: policies (what humans keep), testing-and-deploy.md · model-gap: not-observed -->
- [performance] Keep the Firestore and JWKS clients at module top level, and have the container CMD run `node` directly so SIGTERM arrives. — why models get it wrong: `npm start` or a shell chain removes the 10-second drain or records it as a failure <!-- evidence: policies (what humans keep), testing-and-deploy.md measured · model-gap: not-observed -->
