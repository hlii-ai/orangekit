<!-- orangekit-pack: backend/node-api v3.13.0 verified 2026-08-23 express@5 @prisma/client@6 prisma@6 zod@4 typescript@5 pino@9 pino-http@10 vitest@2 supertest@7 tsx@4 @types/express@5 @types/node@22 -->

# node-api axis pack — hub fragments

These are the **axis-local fragments to insert verbatim** when building the combination hub (`SKILL.md`). A combination that has
a pre-built seam does not use this file — in that case the seam's `HUB.md` holds the hub in full.

Each fragment sits between `<!-- pack-slot: name -->` and `<!-- /pack-slot -->`, and it closes inside the axis,
so it holds whatever the frontend axis is. Nothing here is a function of the combination —
the table at the end of the file states what belongs to the seam.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── index.ts                 # boot only — makeApp() + listen + shutdown wiring
├── app.ts                   # makeApp(): router mounting + middleware order (takes no request)
├── env.ts                   # the **only** file that reads the process environment (validates/fails at boot)
├── db/
│   ├── client.ts            # PrismaClient singleton — the only instance in this repository
│   └── tasks.ts             # query functions. know nothing about HTTP (they take no Request·Response)
├── schemas/
│   └── task.ts              # Zod schemas — request body and query. Doubled up with the DB constraints
├── http/
│   ├── app-error.ts         # AppError — **owned by the seam** (code string + details)
│   ├── parse.ts             # parseBody/parseQuery — normalize a validation failure into AppError
│   ├── errors.ts            # the ERROR_STATUS table · Prisma error detection · ZodError normalization
│   ├── error-handler.ts     # errorHandler — **owned by the seam** (emits the envelope)
│   ├── require-auth.ts      # requireAuth · AuthUser — **owned by the seam** (token verification)
│   └── routers/             # routers — **owned by the seam** (the pack fixes only the mount point)
├── services/                # domain logic tying several queries together (the transaction boundary)
├── ops/
│   ├── health.ts            # healthz (liveness) · readyz (readiness)
│   ├── logger.ts            # pino structured logger
│   └── shutdown.ts          # SIGTERM → drain the connections → exit
└── test/
    └── db.ts                # test DB connection, isolation, cleanup + fixtures (seedTask)

prisma/
├── schema.prisma            # model definitions — the T1 data modeling card is canonical for table design
└── migrations/              # created by migrate dev, applied by migrate deploy (separate from the deploy)

vitest.config.ts             # defineConfig from 'vitest/config' — the one in 'vite' has no test key
package.json                 # the lint:layers script blocks reverse-direction layer imports
```

**Layering flows in one direction only**: `routers → services → db`. A reverse import collapses the layering
and makes a query test require a server. There is exactly one exception (see below).
<!-- /pack-slot -->

<!-- pack-slot: architecture-overview -->
## Architecture Overview

**Module resolution is `bundler`** — do not put an extension on a relative import (`'./errors'`). Under `nodenext`,
every extensionless import fails with TS2835 and you have to add `.js` to every example. `tsx` handles execution.

**There is exactly one exception to the layering discipline**: `http/app-error.ts`. Put the common type that expresses a
domain failure in `db/` and the HTTP layer gains a type dependency on the data layer, which inverts the direction. `AppError` is
a pure error class that knows nothing about HTTP (the status is mapped separately by `ERROR_STATUS`), so it merely
lives under the name `http/` while the dependency stays one-way. **The layer-check script punches through this exception only.**

**The set of files the seam owns**: `http/app-error.ts` · `http/error-handler.ts` ·
`http/require-auth.ts` · `http/routers/`. It is the only layout where the import DAG closes without a cycle, as
`app-error → errors → parse` and `errors → error-handler` — without nailing the paths down, the pack's
`import { AppError } from './app-error'` becomes dangling after assembly.
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
## Core Principles (7 Key Rules)

This axis has **no row-level policy engine.** The application connects to PostgreSQL over a trusted connection, so
rules 1–3 are the only boundary — "the data layer is the backup, so this is defense in depth" does not hold here.
`user` is the `AuthUser` that `requireAuth` put on `req.user`.

### 1. Ownership lives in the read condition — not in a comparison after the read

A query missing the ownership filter does not get slow; it **returns someone else's rows.** Comparing after the read is easy
to forget and is open to a race. Put it in the condition and forgetting becomes impossible.
<!-- verified: ran tsc --strict locally after @prisma/client@6.19.3 generate (2026-08-23) -->
The where-unique input of Prisma 6 accepts a non-unique filter **together with** a unique field (`ownerId` alone is TS2322).
Even so, this pack **standardizes single-item lookups on `findFirst`** — `getTask` is that shape.

```ts
// src/services/tasks.ts
// ❌ read first, then compare the owner — no layer will catch a missing comparison
const found = await prisma.task.findUnique({ where: { id } })
if (found && found.ownerId !== user.id) throw new AppError('FORBIDDEN', 'you do not have permission')
// ✅ ownership is the read condition
const task = await prisma.task.findFirst({ where: { id, ownerId: user.id } })
```

### 2. A mutation is decided by the affected row count

An update or delete carrying an ownership filter **silently succeeds with 0 rows changed** against someone else's row. Without
looking at the affected row count a 200 goes out, and the client believes it edited someone else's data.

```ts
// src/services/tasks.ts
// ❌ answering 0 rows changed as success — put in someone else's id and a 200 comes back
await prisma.task.updateMany({ where: { id, ownerId: user.id }, data })
return { ok: true }
// ✅ the affected row count is the decision — updateMany/deleteMany return { count }
const changed = await prisma.task.updateMany({ where: { id, ownerId: user.id }, data })
if (changed.count === 0) throw new AppError('NOT_FOUND', 'task not found')
```

### 3. Absence and non-ownership look the same from outside

The mere fact that a 403 came back is the answer "that id exists". An unauthorized user can sweep ids and map out the
ownership relations, so what separates the two is kept in the log, not in the response.

```ts
// src/services/tasks.ts — take the request logger from req (reqId is what stitches a request together)
// ❌ 404 for absent, 403 for someone else's — the response reveals existence
if (!row) throw new AppError('NOT_FOUND', 'it does not exist')
if (row.ownerId !== user.id) throw new AppError('FORBIDDEN', 'you do not have permission')
// ✅ having read with the ownership condition, both cases give the same result. Only the log tells them apart
if (!task) {
  req.log.warn({ taskId: id }, 'task missing or not owned')
  throw new AppError('NOT_FOUND', 'task not found')
}
```

Authentication failure is the same — say whether the credentials were wrong or the account is missing and account existence leaks.

### 4. Input passes through exactly one schema — an environment variable is input too

`parseBody`/`parseQuery` apply `TaskCreateSchema`·`TaskUpdateSchema`·`TaskQuerySchema` to the request body and
query, normalizing a failure into `AppError('VALIDATION_FAILED')`. For environment variables, read only the one `env`
that passed `EnvSchema` — a missing or malformed value blows up **at boot**, not on the first request.

```ts
// ❌ every module reads the environment variable itself — a typo or omission blows up on one request hours after the deploy
const conn = process.env.DATABASE_URL ?? 'postgresql://localhost:5432/app'
// ✅ src/env.ts is the only module in application code that reads the process environment
import { env } from './env'
const conn = env.DATABASE_URL
```

The one exception is the test setup `src/test/db.ts` — it injects the isolated DB URL.

A Zod schema **does not replace** a DB constraint (`@unique` · `NOT NULL`) — apply both layers.

### 5. The data layer knows nothing about HTTP

Let `Request` · `Response` · `NextFunction` appear in a signature under `src/db/*` and the layering is inverted —
testing a single query starts requiring a server, and the `routers → services → db` direction collapses.

```ts
// src/db/tasks.ts
// ❌ the query function takes Express types
import type { Request, Response } from 'express'
// ✅ it takes only parsed values as arguments. HTTP interpretation belongs to the router, envelope emission to errorHandler
import type { TaskQuery } from '../schemas/task'
import { prisma } from './client'
```

### 6. Middleware order is behavior — and error middleware has exactly 4 arguments

<!-- verified: ran express@5.2.1 locally — the 3-argument function was skipped and only the 4-argument one received the error (2026-08-23) -->
An error handler declared with 3 arguments is **treated by Express as ordinary middleware**, so the error just passes through.
`notFound` goes **after** the routers, and `errorHandler` goes **last**.

```ts
// src/app.ts — inside makeApp()
// ❌ notFound before the routers makes every request a 404. 3 arguments is not an error handler
app.use(notFound)
app.use('/api/tasks', tasksRouter)
app.use((err, req, res) => { res.status(500).json({ error: 'internal' }) })
// ✅ routers → notFound → errorHandler (4 arguments)
app.use('/api/tasks', tasksRouter)
app.use(notFound)
app.use(errorHandler)
```

### 7. A status code is derived from the domain code and nothing else

Let a router pick its own status code and the same failure goes out with a different code depending on where it happened. What is thrown is the domain
code alone; the status is decided by the one `ERROR_STATUS` table, and the envelope by the one `errorHandler`.

```ts
// src/http/routers/tasks.ts (seam-owned)
// ❌ the router builds the status code and the envelope itself
if (!task) return res.status(403).json({ error: 'not yours' })
// ✅ throw only the domain code — ERROR_STATUS owns the status mapping
if (!task) throw new AppError('NOT_FOUND', 'task not found')
```
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
## Common Imports

The paths are exactly those of the Directory Structure above. Module resolution is `bundler`, so **do not put an extension
on a relative import.** Pick only the lines each file needs, and **the comment states which layer each line is legitimate in** —
an import that skips a layer is where rule 5 breaks. Within the same directory, shorten the path to `./`.

```ts
// libraries — layer-independent
import { Router } from 'express'                    // in routers (seam) only
import type { RequestHandler } from 'express'       // in routers and middleware (seam) only
import { z } from 'zod'                             // src/schemas/*
import { Prisma, type Task } from '@prisma/client'

// modules the pack owns — paths are relative to one level under src/<layer>/ (ledger.md is canonical for the assignment)
import { env } from '../env'                        // any layer
import { prisma } from '../db/client'               // in src/db/* only
import { listTasks, getTask, insertTask, updateTask, deleteTask } from '../db/tasks'  // services and routers
import { TaskCreateSchema, TaskUpdateSchema, TaskQuerySchema } from '../schemas/task' // routers (seam)
import type { TaskCreate, TaskUpdate, TaskQuery } from '../schemas/task'              // services and routers
import { parseBody, parseQuery } from '../http/parse'   // in routers (seam) only — it takes a Request
import { ERROR_STATUS, isUniqueViolation, isRecordNotFound, fieldErrors } from '../http/errors'  // in errorHandler (seam) only
import { logger } from '../ops/logger'              // on the boot path only — inside a request use req.log
import { AppError } from '../http/app-error'        // any layer throws it
import { requireAuth } from '../http/require-auth'  // in routers (seam) only
```

`AppError` · `errorHandler` (`src/http/error-handler.ts`) · `requireAuth` are **seam-owned, but the axis fixes
the paths.** `AuthUser`·`tasksRouter` are only defined by the seam, so they are not here.
<!-- /pack-slot -->

<!-- pack-slot: http-status-and-antipatterns -->
## HTTP Status Codes & Anti-Patterns

**The canonical source for status codes is `ERROR_STATUS`, owned by `error-handling.md`.** The table below is a summary of it,
and on a mismatch `ERROR_STATUS` wins — look at `ERROR_STATUS` before editing this table.

| code | domain code | when it goes out |
| --- | --- | --- |
| 200 | — | read or update succeeded (with a body) |
| 201 | — | create succeeded — `Location: /api/tasks/{id}` |
| 204 | — | delete succeeded (no body) |
| 400 | `VALIDATION_FAILED` | the body or query did not pass the Zod schema. The field errors go in `details` |
| 401 | `UNAUTHENTICATED` | credentials are missing or expired — `requireAuth` throws it |
| 403 | `FORBIDDEN` | use it only for refusing an action on a resource **whose existence is already known** (insufficient role) |
| 404 | `NOT_FOUND` | absent **and** owned by someone else. Split the two and ids can be swept to learn what exists |
| 409 | `CONFLICT` | unique constraint conflict — Prisma `P2002` |
| 413 | `PAYLOAD_TOO_LARGE` | the body exceeded the parser limit — `express.json({ limit })` throws it |
| 500 | `INTERNAL` | everything else. The cause goes to the log, never to the response |

422 · 405 · 410 have no reach path on this axis. If a new code is needed, put the domain code into `ERROR_STATUS` first
and then update this table — grow the table first and the two canonical sources diverge.

### Anti-patterns — what is actually observed on Express 5 + Prisma 6

<!-- verified: ran express@5.2.1 · path-to-regexp@8.4.2 · @prisma/client@6.19.3 locally (2026-08-23) -->

| ❌ shape | why it is wrong / instead |
| --- | --- |
| wrapping with `asyncHandler(...)` · `express-async-handler` | Express 5 sends a rejected async handler to the error middleware by itself (confirmed by running it). The wrapper is pure plumbing debt <!-- verified: ran express@5.2.1 locally — a throw in an async handler reached the 4-argument middleware --> |
| `app.use((err, req, res) => ...)` | 3 arguments is **ordinary middleware** — the error passes through and falls to the default handler (confirmed by running it). Error middleware has exactly 4 arguments <!-- verified: ran express@5.2.1 locally — the 3-argument use was skipped and the 4-argument one received err --> |
| `app.use('*', ...)` · `app.get('/*', ...)` | path-to-regexp 8 **fails the boot** with `Missing parameter name` (confirmed by running it). Use a path-less `app.use(notFound)` or `'/{*splat}'` <!-- verified: path-to-regexp@8.4.2 — boot failed with Missing parameter name at index 1 --> |
| `router.get('/:id?', ...)` | there is no optional-parameter `?` syntax — the boot fails with `Unexpected ?` (confirmed by running it). Use `'/{:id}'` <!-- verified: path-to-regexp@8.4.2 — boot failed with Unexpected ? at index 4 --> |
| assuming `?filter[status]=open` arrives as a nested object | the default query parser is `simple`, so `"filter[status]"` becomes the key in one piece (confirmed by running it). Use flat keys + `z.coerce` in `TaskQuerySchema` <!-- verified: ran express@5.2.1 locally — ?a[b]=1 parsed as {"a[b]":"1"} --> |
| `res.status(409).json(...)` in a router | the envelope splits. Throw the domain code as an `AppError` and emit from `errorHandler` alone |
| passing the sort column through `prisma.$queryRawUnsafe` | even the tagged `$queryRaw` **cannot parameterize an identifier** — narrow the sort column with an allowlist |
| request logging with `console.log` | no level, no request correlation, no serialization, so it is not searchable in production. Use `logger` (pino) + `pino-http` |
<!-- /pack-slot -->

## What the seam fills in

| slot | why it is a function of the combination |
| --- | --- |
| `api-endpoints` | router shape + request/response envelope. The wire contract decides the envelope |
| `auth-boundaries` | how the token is verified depends on whether the frontend axis has a server runtime |
| `complete-example` | a pass through migration → schema → query → service → router → test |
