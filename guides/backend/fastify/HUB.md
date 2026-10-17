---
name: backend-guide
description: "Fastify 5 + Drizzle + PostgreSQL API server guide: plugin encapsulation and auth hook placement, Zod route schemas, ownership-scoped queries with cursor pagination, one error envelope for every bypass path, Bearer auth (self-issued with refresh rotation, or OIDC JWKS), inject tests on a real DB. Use when creating or modifying routes, schemas, queries, migrations, auth, error handling, CORS, or backend tests."
---
<!-- orangekit-guide-baseline: verified 2026-10-15 fastify@5 fastify-plugin@5 fastify-type-provider-zod@7 zod@4 drizzle-orm@0.45 drizzle-kit@0.31 jose@6 @fastify/cookie@11 @fastify/cors@11 pg@8 @types/pg@8 typescript@5 tsx@4 vitest@3 @types/node@24 -->

# Fastify API Server Guide (Fastify 5 + Drizzle + PostgreSQL)

This guide covers a server where **the application connects to PostgreSQL over a trusted connection**. There is no
row-level policy engine, so the routes' auth hook and the queries' ownership condition are the only boundary.

If the project has its own API spec (e.g. `dev/docs/api/`), that is canonical, and the wire values in this guide (paths · codes · statuses) are pattern examples.
The example values follow the standard HTTP contract v1 — success `{ data }` · list `{ data, nextCursor }`, failure
`{ error: { code, message, details? }, requestId }`, cursor pagination, someone else's resource is 404, `Authorization: Bearer`.
The auth method (self-issued · external IdP) was chosen at install time — the title of `resources/auth-boundaries.md` says which.

## Quick Start

### Adding a new endpoint

1. Request schema in `src/schemas/task.ts` — the body is `z.strictObject`, the query `z.object` + `z.coerce`, the path id `z.uuid()`
2. The response schema includes the envelope — `z.object({ data: TaskViewSchema })` · a list is `{ data, nextCursor }` (no `ownerId`)
3. Query in `src/db/tasks.ts` — first argument `ownerId`, ownership in the `where`, a mutation 404s on the `returning` length · `rowCount`
4. Route in `src/http/routes/tasks.ts` — `req.body` · `req.query` are already parsed values. Do not `parse` them again
5. Take the subject only through `ownerOf(req.user)` — never trust an owner value in the body or query
6. Failure is `throw new AppError(code, …)` — no `reply.code(4xx).send(…)`. Only success's 201 · 204 go through `reply`
7. Test: owner 200 and other-user 404 as a pair **in the same `it`** (`resources/testing.md` §4)

### Attaching a new domain (route plugin)

1. Create a `FastifyPluginAsyncZod` in `src/http/routes/<domain>.ts` with `app.addHook('onRequest', requireAuth)` **as the first line of the body**
2. Do not wrap it in `fp()` — wrapped, the hook moves up to the root and even `/healthz` becomes 401
3. In `buildApp`: `await app.register(<domain>Routes, { prefix: '/api/<domain>' })` — after `authPlugin`
4. If you need public routes, make them **a separate plugin** — do not switch auth on and off per route inside one plugin
5. For a table: `src/db/schema.ts` → `npx drizzle-kit generate` → read the SQL and commit it (`migrate` is a deploy step)
6. New browser origins go in the `WEB_ORIGINS` environment variable — not in code
7. Run it to confirm the auth test over every registered route picks up the new plugin automatically (`resources/testing.md` §4)

<!-- pack-slot: architecture-overview -->
## Architecture Overview

**Fastify's structural unit is the plugin, and a plugin is an encapsulation context.** `app.register(fn)` creates a
child context. Hooks · `setErrorHandler` · `decorate` set inside it reach **only that context and its descendants**,
never siblings or the parent. Wrapping it in `fastify-plugin` (`fp`) removes the encapsulation and attaches it to the
parent context. This one paragraph decides the auth boundary on this axis — principle 4.

**What goes at the root and what goes in a plugin**:

| root (`buildApp`) | route plugin (`tasksRoutes`) |
| --- | --- |
| `setValidatorCompiler` · `setSerializerCompiler` — children inherit them | `app.addHook('onRequest', requireAuth)` — only this context's routes |
| `setErrorHandler(errorHandler)` · `setNotFoundHandler` | route declarations and their `schema` |
| `/healthz` · `/readyz` — outside auth · `authPlugin` (CORS) · the `x-request-id` hook | domain-specific hooks |

**Data access is a module, not a decorator.** `db` is not carried with `app.decorate('db', …)` but imported from
`src/db/client.ts` — principle 6 holds only if query functions do not take the app instance.

**Module resolution is `bundler`** — relative imports carry no extension (`'./errors'`). `tsx` runs the code.

**Auth is a variant.** The **paths and export names** of `require-auth.ts` · `auth-plugin.ts` · `auth-env.ts` are
fixed, and only their bodies differ by auth method (self-issued · OIDC) — so every other file compiles unchanged
whichever variant is in place.
<!-- /pack-slot -->

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── index.ts                 # boot only — buildApp() + listen({ host, port }) + signal wiring
├── app.ts                   # buildApp(): compilers · error/404 handling · plugin registration (does not listen)
├── env.ts                   # the **only** file in app code that reads the process environment (exceptions: test/env · global-setup)
├── auth-env.ts              # AuthEnvSchema — auth keys (env.ts merges and validates them)
├── db/
│   ├── client.ts            # pg Pool + drizzle singleton — the only pool in this repository
│   ├── schema.ts            # pgTable definitions — the input to drizzle-kit
│   ├── auth-schema.ts       # users · refresh_tokens — only with self-issued auth
│   └── tasks.ts             # query functions. know nothing about HTTP (they take no FastifyRequest · FastifyReply)
├── schemas/task.ts          # Zod schemas — requests (body · querystring · params) and responses (the serialization boundary)
├── services/                # the transaction boundary — task-service.ts · auth-service.ts (self-issued)
├── http/
│   ├── app-error.ts         # AppError · ErrorCode
│   ├── errors.ts            # the ERROR_STATUS table · toAppError · fieldErrors · SQLSTATE detection
│   ├── error-handler.ts     # errorHandler — emits the envelope (the only place)
│   ├── require-auth.ts      # requireAuth · AuthUser — onRequest hook (differs per auth variant)
│   ├── auth-plugin.ts       # authPlugin — CORS (+ /api/auth if self-issued). no requireAuth hook
│   └── routes/tasks.ts      # tasksRoutes — /api/tasks
├── ops/                     # health.ts (healthz · readyz · beginDrain) · logger.ts (pino **options**) · shutdown.ts
└── test/                    # env.ts (_test guard · auth test keys) · global-setup.ts (migrations) · db.ts
                             # auth.ts (authFor — synchronous) · *.test.ts (inject + real DB)
drizzle/ · drizzle.config.ts # generate output SQL (commit it) · the config imports env.ts to get the same validation
vitest.config.ts             # defineConfig from 'vitest/config' · fileParallelism: false
```

**Layering flows in one direction only**: `routes → services → db`. The one exception is `http/app-error.ts` — `AppError`
is a pure error class that knows nothing about HTTP status, so the data layer throwing it does not invert the dependency.
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
## Core Principles (7 Key Rules)

This axis **has no row-level policy engine.** The application connects to PostgreSQL over a trusted connection, so
rules 1–4 are the only boundary. `req.user` is the `AuthUser` that `requireAuth` attached.

### 1. Ownership lives in the read condition — not in a comparison after the read

A query missing the ownership condition does not get slower; it **returns someone else's row.** Put it in the
condition and forgetting it becomes impossible.

```ts
// src/db/tasks.ts
// ❌ Reads, then compares the owner — if the comparison is left out, no layer catches it
const [found] = await db.select().from(tasks).where(eq(tasks.id, id))
// ✅ Ownership is in the WHERE
const [row] = await db.select(view).from(tasks)
  .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
```

### 2. A mutation is decided by the affected row count

An update or delete under an ownership condition **silently succeeds with 0 rows changed** against someone else's row.
<!-- verified: ran drizzle-orm@0.45.4 + pg@8.23.1 — update().returning() gives an empty array for 0 rows, delete() gives QueryResult.rowCount 0 (2026-10-15) -->

```ts
// src/db/tasks.ts
// ❌ Does not look at returning — even with someone else's id, a 200 with an undefined body goes out
return (await db.update(tasks).set(patch).where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId))).returning(view))[0]!
// ✅ An empty returning means 0 rows — someone else's id does not produce a 200
if (rows.length === 0) throw new AppError('NOT_FOUND', 'Task not found')
// ✅ A delete without returning is checked with rowCount
if (res.rowCount === 0) throw new AppError('NOT_FOUND', 'Task not found')
```

### 3. Absence and non-ownership look the same from outside

The mere fact that a 403 comes back answers "that id exists". Because the read went through the ownership condition,
both cases are the same `null`, and the distinction is left only in `req.log`. The tests go as far as asserting that
the two responses' **bodies are byte-for-byte identical** (`testing.md`).

### 4. The auth hook goes in the same encapsulation context as the routes

<!-- verified: ran fastify@5.12.7 — an onRequest hook on a sibling plugin did not apply to another sibling's routes, giving 200 without auth; wrapping it in fp gave a global 401; in the same context, addHook after the route declarations still gave 401 (2026-10-15) -->
A hook set on a sibling plugin **does not reach another sibling's routes** — a 200 goes out without auth. Set it at
the root and even `/healthz` is blocked. Set it inside the route plugin.

```ts
// ❌ The auth plugin and the route plugin are siblings — the hook does not reach tasksRoutes
app.register(async (s) => { s.addHook('onRequest', requireAuth) })
app.register(tasksRoutes, { prefix: '/api/tasks' })
// ✅ src/http/routes/tasks.ts — the first line of the route plugin body, the same context as the routes
app.addHook('onRequest', requireAuth)
```

### 5. Input and output pass through the route schema — an environment variable is input too

The route `schema` validates the body, query, and params, and a failure reaches `errorHandler` as an error carrying
`err.validation`. **The response schema is the serialization boundary** — fields not in `TaskViewSchema` are removed
from the response<!-- verified: ran fastify-type-provider-zod@7.0.0 + zod@4.6.7 — an ownerId not in the response schema was missing from the inject response body (2026-10-15) -->. Environment variables are read only through `env`, after passing `EnvSchema` — it blows up at boot.

### 6. The data layer knows nothing about HTTP

When `FastifyRequest` · `FastifyReply` · `FastifyInstance` show up in the signatures under `src/db/*`, the layering is
inverted — testing a single query then needs the app. Query functions take only `ownerId` and parsed values.

### 7. A status code is derived from the domain code and nothing else

A handler does not write a failure with `reply.code(404).send(...)`; it **throws** an `AppError`. One table,
`ERROR_STATUS`, decides the status, and one place, the root `errorHandler`, decides the envelope.

```ts
// src/http/routes/tasks.ts
// ❌ The handler builds the status and the envelope itself — the same failure goes out in a different shape in each place
if (!task) return reply.code(403).send({ error: 'not yours' })
// ✅ Throw only the domain code
if (!task) throw new AppError('NOT_FOUND', 'Task not found')
```
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
## Common Imports

The paths are exactly the Directory Structure above. Module resolution is `bundler`, so **relative imports carry no
extension.** Pick only the lines each file needs, and **the comments decide in which layer each line is legitimate.**

```ts
// Libraries
import Fastify from 'fastify'                                   // only in src/app.ts
import type { FastifyReply, FastifyRequest } from 'fastify'      // only in http/ · ops/ — forbidden in db/
import type { FastifyPluginAsyncZod } from 'fastify-type-provider-zod'  // route plugins
import { z } from 'zod'                                          // src/schemas/* · src/env.ts · db/tasks (cursor) · route response wrappers
import { and, desc, eq, lt, or, sql } from 'drizzle-orm'         // src/db/* · ops/health (sql)

// Modules owned by the pack — paths relative to one level below src/<layer>/ (ledger.md is the authority on assignment)
import { env } from '../env'                                     // any layer
import { db, pool } from '../db/client'                          // src/db/* · services · ops/health · shutdown · test/
import { tasks } from '../db/schema'                             // src/db/* · services · test/
import { listTasks, getTask, insertTask, updateTask, deleteTask, encodeCursor } from '../db/tasks'  // services · routes
import { TaskCreateSchema, TaskUpdateSchema, TaskQuerySchema, TaskParamsSchema, TaskViewSchema } from '../schemas/task'  // routes
import type { TaskCreate, TaskUpdate, TaskQuery, TaskView } from '../schemas/task'  // services · queries
import { ERROR_STATUS, toAppError, errorLogFields } from '../http/errors'  // only in errorHandler
import { healthz, readyz } from '../ops/health'                  // only in src/app.ts
import { AppError } from '../http/app-error'                     // any layer may throw it
import { requireAuth, type AuthUser } from '../http/require-auth'  // only in route plugins
import { authFor } from './auth'                                  // only in src/test/*
```

`errorHandler` · `tasksRoutes` · `authPlugin` are imported only by `buildApp`, so they are not here (`src/app.ts`).
<!-- /pack-slot -->

<!-- pack-slot: http-status-and-antipatterns -->
## HTTP Status Codes & Anti-Patterns

**The authority on status codes is `ERROR_STATUS`, owned by `error-handling.md`.** Below is a summary of it; where
they disagree, `ERROR_STATUS` wins.

| code | domain code | when it goes out |
| --- | --- | --- |
| 200 | — | read · update succeeded |
| 201 | — | create succeeded — `Location: /api/tasks/{id}` |
| 204 | — | delete succeeded (no body) |
| 400 | `VALIDATION_FAILED` | route schema violation · broken JSON · empty JSON body · invalid cursor (uuid · range) · NUL character |
| 401 | `UNAUTHENTICATED` | credentials missing or expired — thrown by `requireAuth` |
| 403 | `FORBIDDEN` | only for refusing an action (missing role) on a resource **whose existence is already known** |
| 404 | `NOT_FOUND` | absence **and** someone else's ownership · a missing route |
| 409 | `CONFLICT` | unique violation — SQLSTATE `23505` |
| 429 | `RATE_LIMITED` | login · refresh limits on the self-issued variant's `/api/auth` (other routes when the project adds them) |
| 413 | `PAYLOAD_TOO_LARGE` | over `bodyLimit` — `FST_ERR_CTP_BODY_TOO_LARGE` |
| 415 | `UNSUPPORTED_MEDIA_TYPE` | a Content-Type with no parser — `FST_ERR_CTP_INVALID_MEDIA_TYPE` |
| 500 | `INTERNAL` | everything else · response schema mismatch (`FST_ERR_RESPONSE_SERIALIZATION`). The cause goes to the log only |

### Anti-patterns — what is actually observed on Fastify 5 + Drizzle 0.45

<!-- verified: ran fastify@5.12.7 · drizzle-orm@0.45.4 · pg@8.23.1 locally (2026-10-15) -->

| ❌ shape | why it is wrong / instead |
| --- | --- |
| `app.listen(3000)` | there is no positional-argument signature in v5 — the boot fails with `Cannot create property 'host' on number`. Use `listen({ host, port })` <!-- verified: fastify@5.12.7 — listen(0) threw a TypeError --> |
| deploying to EC2 or a container with only `listen({ port })` | host defaults to `127.0.0.1` · `::1`, so it is unreachable from outside. Use `host: env.HOST` (default `0.0.0.0`) <!-- verified: fastify@5.12.7 — app.addresses() returned only 127.0.0.1 and ::1 --> |
| `Fastify({ logger: pino() })` | v5 rejects it with `FST_ERR_LOG_INVALID_LOGGER_CONFIG`. Pass an options object, or use `loggerInstance` <!-- verified: fastify@5.12.7 — passing an instance to logger threw with that code --> |
| `reply.send(x)` then `return y` in an async handler | whatever was sent first goes out, with a "Reply was already sent" warning. Use only one — `return reply.code(201).send(x)` <!-- verified: fastify@5.12.7 — 200 {"a":1} + a warning log --> |
| wrapping the auth plugin in `fp()` and registering it at the root | it becomes a global hook and even `/healthz` is 401 — the load balancer takes the instance out (principle 4) |
| `isUniqueViolation` checks `e.code === '23505'` | Drizzle wraps it in `DrizzleQueryError` — the SQLSTATE is on `e.cause.code` <!-- verified: drizzle-orm@0.45.4 — ctor DrizzleQueryError, cause DatabaseError code 23505 --> |
| putting `err.message` in the response and `{ err }` in the log | a `DrizzleQueryError`'s message is the `Failed query: …` SQL plus **the bound values** — a fixed phrase in the response, `errorLogFields` in the log |
| `db.insert(...)` inside a transaction callback | it goes out on another connection and **is not rolled back** — query only through the callback argument `tx` <!-- verified: drizzle-orm@0.45.4 — writing through db instead of tx left 1 row after the rollback --> |
| taking the sort column via `sql.raw(\`… ${column}\`)` | `sql.raw` does not escape — narrow the sort column with an allowlist |
| request logging with `console.log` | no request correlation (`reqId`), no level, no redact. Use `req.log` |
| a list response as `{ items }`, a single item as a bare object | contract v1 is `{ data, nextCursor }` · `{ data }` — the client opens both with one function |
<!-- /pack-slot -->

## Navigation Guide

| what you want to do | file to read |
| --- | --- |
| `buildApp` assembly order · plugin encapsulation · where `fp` belongs · layer boundaries | `resources/project-structure.md` |
| Drizzle queries · ownership condition · affected row count · cursor · transactions · migrations | `resources/data-access.md` |
| route schema · Zod type provider · filtering fields with the response schema · environment variable validation | `resources/input-validation.md` |
| the status table `ERROR_STATUS` · normalizing validation errors · `FST_ERR_*` mapping · SQLSTATE · no leaks into logs | `resources/error-handling.md` |
| `AppError` · the `errorHandler` envelope · paths that bypass the handler (404 · 405 · 413 · 415 · 500) · `tasksRoutes` CRUD | `resources/api-endpoints.md` |
| the auth boundary — `requireAuth` · `AuthUser` · auth environment keys · the test header `authFor` | `resources/auth-boundaries.md` |
| the auth flow — login · refresh · logout, or IdP registration · CORS (`authPlugin`) | `resources/auth-flows.md` |
| one task end to end (migration → response) · failure points at each request stage · the order for adding a feature | `resources/complete-example.md` |
| Vitest setup · the `_test` DB guard · 4 ownership pairs · auth over every registered route · the mutation table | `resources/testing.md` |
| boot · health checks · graceful shutdown · logger redact · pool sizing · deploy order | `resources/operations.md` |
