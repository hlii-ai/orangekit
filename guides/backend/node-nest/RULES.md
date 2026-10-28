---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "lib/**"
---
<!-- orangekit-pack: backend/node-nest v3.16.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (ownership in the query condition · a 0-row mutation is 404 · 404 instead of 403 · no error objects in logs) belong to security.md, so they are not here. -->

# NestJS + TypeORM core card

The project spec (`dev/docs/api/` etc.) and `.claude/rules/code-conventions.md` take precedence over this card and the `backend-guide` skill.
Verified versions — `@nestjs/core@11` · `typeorm@1`. Install the latest stable release (`code-change.md` "Before Adding a Dependency") — where an item conflicts with a newer major, the official upgrade docs take precedence.
Look up wiring and examples in the `backend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Path prefix · id type · success/error envelope · validation-failure status code follow existing code or the spec; if there is none, decide once and write it in `code-conventions.md`. Do not carry over the guide example values. — why models get it wrong: it anchors on example values <!-- evidence: guide-ab T-B·T-D (fastify measured) · model-gap: not-observed -->
- [consistency] Envelope and status code are decided only by one global exception filter and one domain code→status table. Controllers never write with `@Res()` or pick an `HttpException` case by case. — why models get it wrong: a `throw` outside the filter still sends a response, so nobody notices the split <!-- evidence: policies envelope-from-filter · error-status-single-table · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Check that a new controller sits in auth-guard scope (class `@UseGuards` or a global guard). Open public exceptions only explicitly. — why models get it wrong: a guard is a decorator, so a missing one still compiles and answers 200 <!-- evidence: policies guard-on-controller · model-gap: not-observed -->
- [security] An array `where` is OR. Put the owner condition in every branch, cursor branches included. — why models get it wrong: one missing branch mixes in someone else's rows wholesale <!-- evidence: policies ownership-in-query, node-nest-authoring measured (8 rows leaked) · model-gap: not-observed -->
- [security] Mutate with `update`/`delete` plus an `.affected` check. TypeORM 1 `updateAll`/`deleteAll` have no WHERE; keep them out of domain code. — why models get it wrong: 0 rows and all rows both finish without an error <!-- evidence: policies mutation-affected-rows · no-blanket-mutation · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Set `forbidNonWhitelisted: true` on the global `ValidationPipe`. — why models get it wrong: with `whitelist` alone, a typo field is silently stripped and it is 200 <!-- evidence: policies validation-pipe-strict · model-gap: not-observed -->
- [performance] Declare the return type of a `select`-narrowed result as the narrowed type. — why models get it wrong: the type stays the entity, so unfetched columns compile and are `undefined` <!-- evidence: policies (what humans keep), node-nest-authoring measured · model-gap: not-observed -->
- [performance] Pin a `timestamptz` cursor column to `precision: 3`, or cut on a monotonic key. — why models get it wrong: the µs↔ms round trip drops rows <!-- evidence: policies timestamp-precision-pinned (measured 1 of 5 rows missing) · model-gap: not-observed -->
- [performance] Turn `synchronize` off and change the schema only through migrations. For shutdown, do not trust `enableShutdownHooks()` alone; add a SIGTERM drain. — why models get it wrong: unannounced DDL on every deploy, and shutdown without a drain is a 5xx <!-- evidence: policies no-synchronize · graceful-shutdown · model-gap: not-observed -->
