---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "lib/**"
---
<!-- orangekit-pack: backend/node-api v3.13.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (ownership in the query condition · a 0-row mutation is 404 · 404 instead of 403 · no raw SQL) belong to security.md, so they are not here. -->

# Express + Prisma core card

The project spec (`dev/docs/api/` etc.) and `.claude/rules/code-conventions.md` take precedence over this card and the `backend-guide` skill.
Verified versions — `express@5` · `prisma@6`. Install the latest stable release (`code-change.md` "Before Adding a Dependency") — where an item conflicts with a newer major, the official upgrade docs take precedence.
Look up wiring and examples in the `backend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Path prefix · id type · success/error envelope · validation-failure status code follow existing code or the spec; if there is none, decide once and write it in `code-conventions.md`. Do not carry over the guide example values. — why models get it wrong: it anchors on example values <!-- evidence: guide-ab T-B·T-D (fastify measured) · model-gap: not-observed -->
- [consistency] Envelope and status code are decided only by the one last 4-argument error middleware and one code→status table. Routers never answer with `res.status().json()` directly. — why models get it wrong: written with 3 arguments it is an ordinary middleware and errors pass through it <!-- evidence: policies envelope-from-error-handler · error-status-single-table, PACK.md §6 run-verified · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Check that the auth middleware is wired for every route it protects (or that router's mount). — why models get it wrong: missing, the handler still answers 200 <!-- evidence: policies requireauth-on-router · model-gap: not-observed -->
- [security] Put the session value **after** the spread in create data, as in `{ ...body, ownerId }`. — why models get it wrong: swap the order and the body's `ownerId` wins, and the syntax passes <!-- evidence: data-access.md §3 measured (stored as attacker) · model-gap: not-observed -->
- [security] Never omit `select`, especially on models with hashes or internal columns. — why models get it wrong: omitted, every column goes to the response and the logs <!-- evidence: policies (what humans keep), data-access.md select · model-gap: not-observed -->
- [security] Turn `count` of `updateMany`/`deleteMany`, and `P2025` of `update`/`delete`, into 404. — why models get it wrong: the former give `{ count: 0 }` on someone else's row with no exception <!-- evidence: policies mutation-affected-rows, data-access.md §4 measured · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Do not layer `.default()` onto a partial-update schema. — why models get it wrong: fields not sent get overwritten with defaults <!-- evidence: policies (what humans keep; the worst measured defect) · model-gap: not-observed -->
- [performance] Use the validation result as a return value; never reassign it to `req.query`. — why models get it wrong: Express 5 makes it a getter, so under CJS the assignment is silently ignored <!-- evidence: input-validation.md run-verified (express 5.2.1) · model-gap: not-observed -->
- [performance] Sort cursors by the `(createdAt, id)` total order. — why models get it wrong: rows in the same millisecond are common and drop at page boundaries <!-- evidence: data-access.md measured (6 rows, same ms) · model-gap: not-observed -->
- [performance] Use a single `PrismaClient` singleton (tests inject the URL). — why models get it wrong: every instance creates its own connection pool <!-- evidence: policies prisma-single-client · model-gap: not-observed -->
