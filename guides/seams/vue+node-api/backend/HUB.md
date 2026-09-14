---
name: backend-guide
description: Express 5 + Prisma 6 + PostgreSQL backend development guide. Covers routers and the response envelope, Zod request validation, ownership queries, cursor pagination, bearer token auth and reissue, CORS, error code mapping, and tests. Use when creating or modifying Express routers, request validation, Prisma queries, authentication middleware, error handling, CORS, pagination, or backend tests.
---
<!-- orangekit-seam: vue+node-api v3.13.0 -->

## Quick Start

> If `dev/docs/api/wire-contract.md` exists, that file is canonical for the envelope, error codes and pagination. If it does not exist and you are building the frontend and backend together from scratch, do steps 1 and 2 of "Inner Order Within One Feature" in `workflow-routing.md` first.

### Adding a new endpoint

1. Put the request schema in `src/schemas/task.ts` — the body is `z.strictObject`, the query is `z.object`
2. Put the query function in `src/db/tasks.ts` — the first argument is `ownerId` and ownership goes in the `where`
3. For a mutation, look at the affected row count: if `count === 0`, `AppError('NOT_FOUND')`
4. Attach the handler in `src/http/routers/tasks.ts` and use the **return value** of `parseBody`/`parseQuery`
5. Build only the success envelope — single `{ data }` · list `{ data, nextCursor }` · create 201 · delete 204
6. Throw on failure. Do not use `res.status(...).json(...)` in a router
7. Assert 200 and 404 **as a pair**, with the owner and a stranger as the two subjects (`resources/complete-example.md`)

### Adding a new protected path

1. Create the router and put `router.use(requireAuth)` **on its first line** — not on each route
2. Add `requireRole('admin')` only on the routes that need a role
3. Read the subject from `req.user` only — an owner value in the body · query · header is chosen by the attacker
4. An ownership failure is 404. 403 is used only for an insufficient role
5. Add the mount line in `makeApp()` — **before** `notFound` · `errorHandler`
6. When a new origin appears, put it in the `WEB_ORIGINS` environment variable — not in the code
7. Confirm **as a pair** that no token gives 401 and that adding the token gives 200

## Architecture Overview

**Module resolution is `bundler`** — relative imports carry no extension (`'./errors'`). Under `nodenext`, every
extensionless import fails with TS2835 and each example would need a `.js`. Execution is handled by `tsx`.

**There is exactly one exception to the layering discipline**: `http/app-error.ts`. Putting the common type that expresses a domain
failure in `db/` would make the HTTP layer type-depend on the data layer and invert the direction. `AppError` is
a pure error class that knows nothing of HTTP (the status is mapped separately by `ERROR_STATUS`), so its name merely lives in `http/`
while the dependency stays one-way. **The layer check script pierces this exception only.**

**The file set the seam owns**: `http/app-error.ts` · `http/error-handler.ts` ·
`http/require-auth.ts` · `http/routers/`. It is the only layout where the import DAG closes without a cycle as `app-error → errors → parse`
and `errors → error-handler` — without pinning the paths, the pack's
`import { AppError } from './app-error'` becomes dangling after assembly.

## Directory Structure

```
src/
├── index.ts                 # boot only — makeApp() + listen + shutdown wiring
├── app.ts                   # makeApp(): router mounts + middleware order (it does not receive requests)
├── env.ts                   # the **only** file that reads the process environment (validated, failing at boot)
├── db/
│   ├── client.ts            # the PrismaClient singleton — the only instance in this repository
│   └── tasks.ts             # query functions. They know nothing of HTTP (they take no Request or Response)
├── schemas/
│   └── task.ts              # Zod schemas — request body and query. Applied doubly with the DB constraints
├── http/
│   ├── app-error.ts         # AppError — **owned by the seam** (code string + details)
│   ├── parse.ts             # parseBody/parseQuery — normalizes a validation failure into an AppError
│   ├── errors.ts            # the ERROR_STATUS table · Prisma error detection · ZodError normalization
│   ├── error-handler.ts     # errorHandler — **owned by the seam** (emits the envelope)
│   ├── require-auth.ts      # requireAuth · AuthUser — **owned by the seam** (token verification)
│   └── routers/             # routers — **owned by the seam** (the pack fixes only the mount point)
├── services/                # domain logic that binds several queries (the transaction boundary)
├── ops/
│   ├── health.ts            # healthz (liveness) · readyz (readiness)
│   ├── logger.ts            # the pino structured logger
│   └── shutdown.ts          # SIGTERM → drain connections → exit
└── test/
    └── db.ts                # test DB connection · isolation · cleanup + fixtures (seedTask)

prisma/
├── schema.prisma            # model definitions — the T1 data-modeling card is canonical for table design
└── migrations/              # created by migrate dev, applied by migrate deploy (separate from the deploy)

vitest.config.ts             # defineConfig from 'vitest/config' — the one from 'vite' has no test key
package.json                 # the lint:layers script blocks reverse-direction layer imports
```

**Layers flow in one direction only**: `routers → services → db`. A reverse import breaks the layering
and makes a query test require a server. There is only one exception (see below).

## Core Principles (7 Key Rules)

This axis has **no row-level policy engine.** The application connects to PostgreSQL with a trusted connection, so
rules 1–3 are the only boundary — "the data layer backs us up, so it is double defense" does not hold here.
`user` is the `AuthUser` that `requireAuth` put on `req.user`.

### 1. Ownership belongs in the query condition — not in a comparison after the query

A query missing the ownership filter does not get slower; it **returns someone else's rows.** A comparison after the query is easy
to forget and is also pierced by races. Put it in the condition and forgetting becomes impossible.
<!-- verified: tsc --strict run locally after @prisma/client@6.19.3 generate (2026-08-23) -->
The where-unique input of Prisma 6 accepts a non-unique filter **together with** the unique field (`ownerId` alone is TS2322).
Even so this pack **unifies single reads on `findFirst`** — `getTask` is that shape.

```ts
// src/services/tasks.ts
// ❌ comparing the owner after the read — no layer will catch a missed comparison
const found = await prisma.task.findUnique({ where: { id } })
if (found && found.ownerId !== user.id) throw new AppError('FORBIDDEN', 'You do not have permission')
// ✅ ownership is the query condition
const task = await prisma.task.findFirst({ where: { id, ownerId: user.id } })
```

### 2. A mutation is judged by the affected row count

An update or delete carrying an ownership filter **succeeds silently with 0 rows changed** against someone else's row. Without looking
at the affected row count a 200 goes out, and the client believes it edited someone else's data.

```ts
// src/services/tasks.ts
// ❌ answering a 0-row change as success — even someone else's id gets a 200
await prisma.task.updateMany({ where: { id, ownerId: user.id }, data })
return { ok: true }
// ✅ the affected row count is the ruling — updateMany/deleteMany return { count }
const changed = await prisma.task.updateMany({ where: { id, ownerId: user.id }, data })
if (changed.count === 0) throw new AppError('NOT_FOUND', 'Task not found')
```

### 3. Absent and not-owned look the same from outside

The very fact that a 403 comes back answers "that id exists". An unauthorized user could sweep ids and map out
ownership, so the information separating the two stays in the log, not in the response.

```ts
// src/services/tasks.ts — take the request logger from req (a reqId is what lets requests be stitched together)
// ❌ absent is 404, someone else's is 403 — the response tells them it exists
if (!row) throw new AppError('NOT_FOUND', 'Not found')
if (row.ownerId !== user.id) throw new AppError('FORBIDDEN', 'You do not have permission')
// ✅ the read carried the ownership condition, so both cases give the same result. The distinction stays in the log
if (!task) {
  req.log.warn({ taskId: id }, 'task missing or not owned')
  throw new AppError('NOT_FOUND', 'Task not found')
}
```

An authentication failure is the same — telling wrong credentials apart from a missing account leaks account existence.

### 4. Input passes through a single schema — an environment variable is input too

The request body and query go through `TaskCreateSchema` · `TaskUpdateSchema` · `TaskQuerySchema`, applied by `parseBody`/
`parseQuery`, which normalizes a failure into `AppError('VALIDATION_FAILED')`. For environment variables, read only
the one `env` that passed `EnvSchema` — an omission or format error then blows up **at boot**, not on the first request.

```ts
// ❌ each module reading the environment directly — a typo or omission blows up on one request hours after deploy
const conn = process.env.DATABASE_URL ?? 'postgresql://localhost:5432/app'
// ✅ src/env.ts is the only module in app code that reads the process environment
import { env } from './env'
const conn = env.DATABASE_URL
```

The only exception is the test setup `src/test/db.ts` — it injects the isolated DB URL.

A Zod schema **does not replace** a DB constraint (`@unique` · `NOT NULL`) — apply both layers.

### 5. The data layer knows nothing of HTTP

If `Request` · `Response` · `NextFunction` appear in a signature under `src/db/*`, the layering is inverted —
testing a single query then needs a server and the `routers → services → db` direction collapses.

```ts
// src/db/tasks.ts
// ❌ a query function taking Express types
import type { Request, Response } from 'express'
// ✅ take only parsed values as arguments. HTTP interpretation is the router's job, emitting the envelope the errorHandler's
import type { TaskQuery } from '../schemas/task'
import { prisma } from './client'
```

### 6. Middleware order is behavior — an error middleware takes exactly four arguments

<!-- verified: express@5.2.1 run locally — a 3-argument function was skipped and only the 4-argument one received the error (2026-08-23) -->
An error handler declared with three arguments is **treated by Express as ordinary middleware** and the error simply passes by.
`notFound` goes **after** the routers, and `errorHandler` goes **last**.

```ts
// src/app.ts — inside makeApp()
// ❌ notFound before the routers makes every request a 404. Three arguments is not an error handler
app.use(notFound)
app.use('/api/tasks', tasksRouter)
app.use((err, req, res) => { res.status(500).json({ error: 'internal' }) })
// ✅ router → notFound → errorHandler (four arguments)
app.use('/api/tasks', tasksRouter)
app.use(notFound)
app.use(errorHandler)
```

### 7. The status code is derived from the domain code alone

If a router picks its own status code, the same failure goes out with a different code in each place. What is thrown is the domain
code only; the status is decided by the single `ERROR_STATUS` table and the envelope by the single `errorHandler`.

```ts
// src/http/routers/tasks.ts (owned by the seam)
// ❌ the router building the status code and envelope itself
if (!task) return res.status(403).json({ error: 'not yours' })
// ✅ throw the domain code only — ERROR_STATUS owns the status mapping
if (!task) throw new AppError('NOT_FOUND', 'Task not found')
```

## Common Imports

The paths are exactly those of the Directory Structure above. Module resolution is `bundler`, so **relative imports carry no
extension.** Pick only the lines each file needs, and **the comment decides which layer each line is legitimate in** —
an import that skips a layer is where rule 5 breaks. Within the same directory the path shortens to `./`.

```ts
// libraries — layer-independent
import { Router } from 'express'                    // in routers (the seam) only
import type { RequestHandler } from 'express'       // in routers and middleware (the seam) only
import { z } from 'zod'                             // src/schemas/*
import { Prisma, type Task } from '@prisma/client'

// modules the pack owns — paths are relative to one level under src/<layer>/ (ledger.md is canonical for the assignment)
import { env } from '../env'                        // any layer
import { prisma } from '../db/client'               // in src/db/* only
import { listTasks, getTask, insertTask, updateTask, deleteTask } from '../db/tasks'  // services and routers
import { TaskCreateSchema, TaskUpdateSchema, TaskQuerySchema } from '../schemas/task' // routers (the seam)
import type { TaskCreate, TaskUpdate, TaskQuery } from '../schemas/task'              // services and routers
import { parseBody, parseQuery } from '../http/parse'   // in routers (the seam) only — it takes a Request
import { ERROR_STATUS, isUniqueViolation, isRecordNotFound, fieldErrors } from '../http/errors'  // in the errorHandler (the seam) only
import { logger } from '../ops/logger'              // on the boot path only — inside a request it is req.log
import { AppError } from '../http/app-error'        // thrown from any layer
import { requireAuth } from '../http/require-auth'  // in routers (the seam) only
```

`AppError` · `errorHandler` (`src/http/error-handler.ts`) · `requireAuth` are **owned by the seam, but their paths are
fixed by the axis.** `AuthUser` · `tasksRouter` are only defined by the seam, so they are not here.

## HTTP Status Codes & Anti-Patterns

**The canonical source for status codes is the `ERROR_STATUS` owned by `error-handling.md`.** What follows is a summary of that table, and
where they diverge `ERROR_STATUS` wins — look at `ERROR_STATUS` before editing this table.

| Code | Domain code | When it goes out |
| --- | --- | --- |
| 200 | — | read or update succeeded (with a body) |
| 201 | — | create succeeded — `Location: /api/tasks/{id}` |
| 204 | — | delete succeeded (no body) |
| 400 | `VALIDATION_FAILED` | the body or query did not pass the Zod schema. Field errors go in `details` |
| 401 | `UNAUTHENTICATED` | credentials missing or expired — thrown by `requireAuth` |
| 403 | `FORBIDDEN` | used only to deny an action on a resource whose **existence is already known** (insufficient role) |
| 404 | `NOT_FOUND` | absent **and** owned by someone else. Separate the two and ids can be swept to learn what exists |
| 409 | `CONFLICT` | unique constraint collision — Prisma `P2002` |
| 413 | `PAYLOAD_TOO_LARGE` | the body exceeded the parser limit — thrown by `express.json({ limit })` |
| 500 | `INTERNAL` | everything else. The cause stays in the log, not in the response |

422 · 405 · 410 have no reach path on this axis. If a new code is needed, put the domain code into `ERROR_STATUS`
first and then update this table — grow the table first and the two canonical sources diverge.

### Anti-patterns — what is actually observed with Express 5 + Prisma 6

<!-- verified: express@5.2.1 · path-to-regexp@8.4.2 · @prisma/client@6.19.3 run locally (2026-08-23) -->

| ❌ Form | Why it is wrong / what to do instead |
| --- | --- |
| `asyncHandler(...)` · wrapping in `express-async-handler` | Express 5 sends the rejection of an async handler to the error middleware by itself (run confirmed). The wrapper is pure plumbing debt <!-- verified: express@5.2.1 run locally — a throw from an async handler reached the 4-argument middleware --> |
| `app.use((err, req, res) => ...)` | Three arguments is **ordinary middleware** — the error passes by and falls to the default handler (run confirmed). An error middleware takes exactly four arguments <!-- verified: express@5.2.1 run locally — the 3-argument use was skipped and the 4-argument one received err --> |
| `app.use('*', ...)` · `app.get('/*', ...)` | path-to-regexp 8 **fails the boot** with `Missing parameter name` (run confirmed). Use the pathless `app.use(notFound)` or `'/{*splat}'` <!-- verified: path-to-regexp@8.4.2 — boot failed with Missing parameter name at index 1 --> |
| `router.get('/:id?', ...)` | The optional-parameter `?` syntax is gone — the boot fails with `Unexpected ?` (run confirmed). Use `'/{:id}'` <!-- verified: path-to-regexp@8.4.2 — boot failed with Unexpected ? at index 4 --> |
| Assuming `?filter[status]=open` arrives as a nested object | The default query parser is `simple`, so `"filter[status]"` becomes the whole key (run confirmed). Use flat keys + the `z.coerce` of `TaskQuerySchema` <!-- verified: express@5.2.1 run locally — ?a[b]=1 parsed as {"a[b]":"1"} --> |
| `res.status(409).json(...)` in a router | The envelope diverges. Throw the domain code as an `AppError` and emit it in `errorHandler` alone |
| Passing the sort column through `prisma.$queryRawUnsafe` | Even the tagged `$queryRaw` **cannot parameterize an identifier** — narrow the sort column with an allowlist |
| Request logging with `console.log` | With no level, request correlation or serialization it cannot be searched in production. Use `logger` (pino) + `pino-http` |

## Navigation Guide

| What you want to do | File to read |
| --- | --- |
| Layer boundaries (routes → services → db) · Express 5 app assembly · router mounting · the order of 404 and error middleware · async handlers | `resources/project-structure.md` |
| The Prisma Client singleton · ownership filters · checking affected rows · transactions · pagination · N+1 and select · running migrations | `resources/data-access.md` |
| Writing Zod schemas · request parsing helpers · duplicating DB constraints · the env var schema · failing at boot | `resources/input-validation.md` |
| Domain error → status code mapping · detecting Prisma error codes (P2002 · P2025) · ZodError normalization · not leaking existence | `resources/error-handling.md` |
| Vitest setup · supertest router tests · integration tests against a real DB · test DB isolation · seeding and cleanup | `resources/testing.md` |
| Graceful shutdown · health checks (live/ready) · connection pool sizing · structured logging · the migration deploy order · observing slow queries | `resources/operations.md` |
| Adding a router · the request/response envelope · the cursor pagination response · status codes · CORS · consuming the validation helper | `resources/api-endpoints.md` |
| Token verification · `requireAuth` wiring · extending the `req.user` type · roles/scopes · login and logout · the 401 reissue contract | `resources/auth-boundaries.md` |
| Migration → schema → query → service → router → test, the whole span | `resources/complete-example.md` |
