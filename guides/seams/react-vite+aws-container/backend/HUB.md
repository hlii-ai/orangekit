---
name: backend-guide
description: "[Preset: react-vite × aws-container] Hono + TypeScript container backend for React SPA clients: HTTP routes, Drizzle ORM with drizzle-kit migrations on RDS PostgreSQL, Zod validation, Cognito OIDC/JWKS verification, ownership checks, Vitest, ECS/Fargate portability. Use when creating or modifying Hono routes, Drizzle schemas or migrations, Zod schemas, JWT auth guards, REST endpoints, or backend tests. Use ONLY when the active preset matches."
---
<!-- orangekit-guide-baseline: verified 2026-08-22 hono@4 @hono/node-server@1 typescript@5 drizzle-orm@0.45 drizzle-kit@0.31 pg@8 jose@5 zod@4 vitest@2 aws-cdk-lib@2 @aws-sdk/client-s3@3 @aws-sdk/s3-request-presigner@3 -->

A container backend guide for a React + Vite SPA client. The frontend has no server runtime,
so **this backend owns all of the server logic**, and the browser calls this REST API directly.

## Quick Start

> If `dev/docs/api/wire-contract.md` exists, that file is canonical for the envelope, error codes and pagination. If it does not exist and you are building the frontend and backend together from scratch, do steps 1 and 2 of "Inner Order Within One Feature" in `workflow-routing.md` first.

### Adding a new endpoint

- [ ] Define the Zod request/response schemas in `src/schemas/<resource>.ts` — derive the PATCH schema
      from a **base without defaults** (`Create.partial()` overwrites unspecified fields)
- [ ] Check that the table you need exists in `src/db/schema.ts` — if not, run the checklist below first
- [ ] Add the query in `src/db/queries/<resource>.ts` — **the first argument is always `ownerId`**
- [ ] Put the domain rules and the ownership ruling in `src/services/<resource>.ts`
- [ ] Add the route in `src/routes/<resource>.ts` and attach `requireAuth`
- [ ] Parse on the first line of the handler with `jsonBody(c, Schema)` / `queryParams(c, Schema)`
- [ ] A mutation throws 404 when the `.returning()` result is empty — never answer 0 rows with a 200
- [ ] Check that the sub-app is mounted in `src/app.ts`
- [ ] Add one handler test + one integration test against a real DB (`docker compose up -d --wait db`)

### Schema change / migration

- [ ] Open `.claude/rules/data-modeling.md` and check the table design rules first
- [ ] Edit `src/db/schema.ts` — add the owner column (`owner_id`) and the lookup index together
- [ ] Generate the SQL with `npx drizzle-kit generate` — never write the SQL by hand first
- [ ] Read the generated `drizzle/*.sql` and check for destructive statements (DROP, adding NOT NULL)
- [ ] After `docker compose up -d --wait db`, apply it locally with `npx drizzle-kit migrate`
- [ ] Run the integration tests to confirm existing queries are not broken
- [ ] Split a destructive change into stages (add the column → backfill → promote to NOT NULL)
- [ ] Put the schema edit and the generated migration file in the **same commit**

## Architecture Overview

```
Browser (React + Vite SPA)
   │  Authorization: Bearer <access token>   (cross-origin CORS)
   ▼
ALB  ──►  ECS/Fargate : Hono container (a standard HTTP server)
                │
                ├─► RDS PostgreSQL (trusted connection, Drizzle ORM)
                └─► JWKS public key cache ◄── Cognito (OIDC issuer)
```

- **An SPA is not a server**: authentication · permissions · business rules · secrets exist only in the backend.
  Every value that went down to the browser is treated as public
- **Request flow**: `routes/` (HTTP contract) → `schemas/` (Zod parsing) → `services/` (domain rules · ownership)
  → `db/queries/` (SQL). No reverse import — `db/queries/` knows nothing of the Hono `Context`
- **The application layer is the only trust boundary**: this stack has no row-level policy engine.
  The app connects to the DB with trusted credentials, so **the data layer does not back you up**.
  One query that drops the ownership filter is a data leak
- **Cognito is only the issuer**: verification uses standard OIDC/JWKS and the app code does not depend on
  a vendor SDK → `resources/portability-boundaries.md`
- **Local = production**: `docker compose` brings up the app together with PostgreSQL 16, so migrations and
  integration tests are verified by actually running them

## Directory Structure

```
src/
├─ index.ts             # boot: serve(), SIGTERM handling, closing the Pool
├─ app.ts               # Hono app assembly: middleware → public routes → requireAuth → protected routes
├─ config/env.ts        # the single entry point for validated env vars (one safeParse at boot)
├─ http/
│  ├─ types.ts          # AppEnv — the types of c.get/c.set (declared once for the whole project)
│  ├─ errors.ts         # AppError, the error code table, onError mapping
│  ├─ validate.ts       # jsonBody() / queryParams() / pathParam() parsing helpers
│  ├─ auth.ts           # the makeRequireAuth(verify) factory + requireAuth (OIDC/JWKS)
│  ├─ return-path.ts    # safeReturnPath — return path validation (blocks open redirects)
│  └─ logger.ts         # structured JSON logger to stdout + requestId
├─ routes/
│  ├─ auth.ts           # login/logout URLs + state signing and verification (public routes)
│  └─ tasks.ts          # a sub-app per resource (HTTP contract only)
├─ services/tasks.ts    # domain rules + ownership ruling
├─ db/
│  ├─ client.ts         # pg Pool + drizzle instance (singleton)
│  ├─ schema.ts         # Drizzle table definitions (the source of the migrations)
│  ├─ errors.ts         # SQLSTATE → domain error translation (23505 → 409)
│  └─ queries/tasks.ts  # queries only — every function takes ownerId
├─ storage/
│  ├─ index.ts          # the ObjectStorage port (the only type app code sees)
│  └─ s3.ts             # the only file that knows the AWS SDK (MinIO-compatible via S3_ENDPOINT)
└─ schemas/tasks.ts     # Zod request/response DTOs
drizzle/                # drizzle-kit generated SQL + meta/ (never hand-edited)
tests/{unit,handler,integration}/ + tests/test-env.ts
docker-compose.yml      # app + postgres:16 (+ docker/init-test-db.sql)
drizzle.config.ts · Dockerfile
infra/                  # AWS CDK — never imported from src/
```

## Core Principles (6 Key Rules)

### 1. Parse at the trust boundary with Zod — this is parsing, not validation

The request body · query · path parameters are all `unknown`. Only the parsed type flows downward.

```ts
// ✅ only the parsed value goes to the service
const body = await jsonBody(c, CreateTaskInput)   // throws the 400 envelope on failure
const task = await createTask(user.sub, body)

// ❌ a cast is not validation — it blocks nothing at runtime
const body = (await c.req.json()) as CreateTaskInput
await createTask(user.sub, body)   // a 12MB string as title passes straight through
```

Using `z.infer<typeof CreateTaskInput>` in the service signature makes the schema the contract itself.
Apply it once more as a DB constraint (`notNull`, unique index, check) → `resources/input-validation.md`

### 2. Validate environment variables once at boot

Do not read `process.env` directly in app code. A missing value must die **at boot**, not on the first request.

```ts
// ✅ src/config/env.ts — a single entry point, validated once at import time
const parsed = EnvSchema.safeParse(process.env)
if (!parsed.success) { logInvalidEnvKeys(parsed.error); process.exit(1) }   // the deploy rolls back
export const env = parsed.data

// ❌ reading it directly at each use site — a typo or omission blows up only on one path after deploy
const pool = new Pool({ connectionString: process.env.DATABSE_URL })   // undefined
```

Boot validation uses **only the `safeParse` + `process.exit(1)` form** (an exception from `parse` loses which key
was missing from the log). Never put a server secret behind the prefix that is inlined into the browser bundle (`VITE_*`),
and keep separate schemas for public variables and secrets → `resources/input-validation.md`

### 3. The ownership filter must be inside the query

This stack has no line of defense in the data layer. Put the owner condition in **every** query, read and mutation alike.

```ts
// ✅ ownership is in the WHERE clause — someone else's row is never returned in the first place
export function findOwnedTask(ownerId: string, id: string) {
  return db.select().from(tasks)
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId))).limit(1)
}

// ❌ fetching everything and filtering in code — the moment you forget to filter it leaks, and it lingers in logs and caches
export function findTask(id: string) {
  return db.select().from(tasks).where(eq(tasks.id, id)).limit(1)
}
```

Pinning `ownerId` as the first argument of every query signature turns an omission into a type error.

### 4. Absent and unauthorized get the same response (do not leak existence)

Answering 403 and 404 differently lets an unauthorized user enumerate the existence of resources.

```ts
// ✅ query with the owner condition and answer with a single 404 when there is nothing
const task = await findOwnedTask(user.sub, id)
if (!task) throw new AppError(404, 'NOT_FOUND', 'Task not found')

// ❌ this tells them whether it exists — sweeping ids builds a list of other people's resources
const task = await findTask(id)
if (!task) throw new AppError(404, 'NOT_FOUND', 'Task not found')
if (task.ownerId !== user.sub) throw new AppError(403, 'FORBIDDEN', 'Not your task')
```

A token verification failure does not distinguish the reason either — expiry · signature mismatch · issuer mismatch all get the same
401 `UNAUTHENTICATED` envelope. 403 is used only on the **non-ownership axis** (admin-only and the like).

### 5. A mutation checks the number of affected rows

Answering a 0-row mutation with success quietly creates the "it said it was deleted but it is still there" bug.

```ts
// ✅ an empty .returning() result means there is no target or it is not mine → 404
const [updated] = await db.update(tasks).set({ title, updatedAt: new Date() })
  .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId))).returning()
if (!updated) throw new AppError(404, 'NOT_FOUND', 'Task not found')

// ❌ discarding the result — a call with someone else's id still returns 204
await db.delete(tasks).where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
return c.body(null, 204)
```

### 6. Confine the vendor SDK to the infrastructure layer

The company may move this backend on-premises. If an AWS-only API gets into `src/`, the migration
becomes a rewrite.

```ts
// ✅ standard OIDC verification — swapping the issuer/JWKS URL moves you to another IdP
import { createRemoteJWKSet, jwtVerify } from 'jose'
const jwks = createRemoteJWKSet(new URL(env.OIDC_JWKS_URL))

// ❌ app code knowing a Cognito-only library or SDK directly
import { CognitoJwtVerifier } from 'aws-jwt-verify'   // a full rewrite when migrating
```

Logs are written as **structured JSON to stdout**, not through the CloudWatch SDK. The decision table is in
`resources/portability-boundaries.md`.

## Common Imports

```ts
// the HTTP layer
import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { bodyLimit } from 'hono/body-limit'
import { createMiddleware } from 'hono/factory'
import { HTTPException } from 'hono/http-exception'
import { serve } from '@hono/node-server'

// validation / auth (standard OIDC — not a vendor SDK)
import { z } from 'zod'
import { createRemoteJWKSet, jwtVerify } from 'jose'

// data access
import { drizzle } from 'drizzle-orm/node-postgres'
import { Pool } from 'pg'
import { and, desc, eq, inArray, isNotNull, isNull, sql } from 'drizzle-orm'
import { index, pgTable, text, timestamp, uuid } from 'drizzle-orm/pg-core'

// tests
import { afterEach, beforeAll, describe, expect, it } from 'vitest'

// project-internal (register '@/' → 'src/' in tsconfig paths + the vitest alias)
import { env } from '@/config/env'
import { db } from '@/db/client'
import { AppError } from '@/http/errors'
```

## HTTP Status Codes & Anti-Patterns

| Situation | Code | Envelope `error.code` |
| --- | --- | --- |
| read succeeded / created / deleted | 200 / 201 / 204 | — |
| schema validation failed, JSON cannot be parsed, malformed query | 400 | `VALIDATION_FAILED` |
| token missing · expired · signature mismatch (reason not distinguished) | 401 | `UNAUTHENTICATED` |
| authenticated but insufficient role · scope (not ownership) | 403 | `FORBIDDEN` |
| resource absent **or** unauthorized access | 404 | `NOT_FOUND` |
| unique constraint violation, state conflict | 409 | `CONFLICT` |
| unexpected exception (do not expose the internal message) | 500 | `INTERNAL` |

**Anti-Patterns**

- Answering 200 with `{ ok: false }` in the body → the client misses the error
- `catch (e) { console.error(e) }` and then continuing → a failure is reported as success
- Registering `app.use('*', requireAuth)` **before** `/healthz` → the ALB health check dies with a 401.
  Hono runs in registration order, so register the public paths (`/healthz`, `/api/auth`) **first**
- Running migrations at server boot → several Fargate tasks boot at once and race.
  Run migrations as a **separate one-off task** in the deployment pipeline
- Returning a DB constraint name · SQL · stack in the error message → the schema leaks out
- Returning a list without a `limit` → it quietly times out as rows grow
- Trusting the `ownerId`/`role` the SPA sent → the owner comes only from the **`sub` of a verified token**

## Navigation Guide

| What you want to do | File to read |
| --- | --- |
| Add a route or handler, request/response envelope, pagination contract, CORS | `resources/api-endpoints.md` |
| Status code mapping, the error code table, global `onError` handling, PostgreSQL error translation | `resources/api-endpoints.md` |
| Drizzle queries and transactions, ownership filters, checking affected rows, running migrations | `resources/data-access.md` |
| **Table · column · index design rules** (normalization, keys, constraints) | `.claude/rules/data-modeling.md` |
| Writing Zod schemas, request parsing helpers, duplicating rules as DB constraints | `resources/input-validation.md` |
| The env var schema, separating secret and public values, failing at boot | `resources/input-validation.md` |
| Token verification, `requireAuth` wiring, roles and scopes, login/logout flow, return path validation | `resources/auth-boundaries.md` |
| Vitest setup, handler tests, integration tests against a real DB, signing tokens for tests | `resources/testing.md` |
| `docker compose` local parity, initializing and isolating the integration test DB | `resources/testing.md` |
| Confining AWS dependencies to the infrastructure layer, the on-premises migration checklist, logging · storage · secrets | `resources/portability-boundaries.md` |
| Dockerfile, deployment order (migration as a separate task), health check and shutdown, pool sizing, observing slow queries and N+1 | `resources/deployment-and-operations.md` |
| The full `docker-compose.yml`, the local smoke check, what changes on-premises | `resources/deployment-and-operations.md` |
| A migration → schema → handler → test example across the whole span | `resources/complete-example.md` |
