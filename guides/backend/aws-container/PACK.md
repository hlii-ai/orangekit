<!-- orangekit-pack: backend/aws-container v3.35.0 verified 2026-08-22 hono@4 @hono/node-server@1 typescript@5 drizzle-orm@0.45 drizzle-kit@0.31 pg@8 jose@5 zod@4 vitest@2 aws-cdk-lib@2 @aws-sdk/client-s3@3 @aws-sdk/s3-request-presigner@3 @types/node@22 -->

# aws-container axis pack — hub fragments

These are the **axis-local fragments to insert verbatim** when building the combination hub (`SKILL.md`). A combination that has a
pre-built seam does not use this file — there the seam's `HUB.md` holds the whole hub.

> **Premise of this axis**: the data layer has **no** row-level policy engine. The app attaches to the DB with
> trusted credentials, so one query missing its ownership filter is a data leak. Move the BaaS combination's
> "the data layer backs you up" statement into this pack and it becomes exactly the opposite guidance.

<!-- pack-slot: quick-start-axis -->
### Schema change / migration

- [ ] Open `.claude/rules/data-modeling.md` and check the table design rules first
- [ ] Edit `src/db/schema.ts` — add the owner column (`owner_id`) and the read index together
- [ ] Generate the SQL with `npx drizzle-kit generate` — do not hand-write SQL first
- [ ] Read the generated `drizzle/*.sql` and check for destructive statements (DROP, adding NOT NULL)
- [ ] Apply it locally with `docker compose up -d --wait db` followed by `npx drizzle-kit migrate`
- [ ] Run the integration tests and confirm the existing queries are not broken
- [ ] Split a destructive change into stages (add the column → backfill → promote to NOT NULL)
- [ ] Put the schema edit and the generated migration file in **the same commit**
<!-- /pack-slot -->

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├─ index.ts             # Boot: serve(), SIGTERM handling, closing the Pool
├─ app.ts               # Hono app assembly: middleware → public routes → requireAuth → protected routes
├─ config/env.ts        # The single entry point for validated env vars (one safeParse at boot)
├─ http/
│  ├─ types.ts          # AppEnv — the c.get/c.set types (declared once, project-wide)
│  ├─ errors.ts         # AppError, the error code table, the onError mapping
│  ├─ validate.ts       # jsonBody() / queryParams() / pathParam() parsing helpers
│  ├─ auth.ts           # The makeRequireAuth(verify) factory + requireAuth (OIDC/JWKS)
│  ├─ return-path.ts    # safeReturnPath — return path validation (blocks open redirects)
│  └─ logger.ts         # Structured JSON logger to stdout + requestId
├─ routes/
│  ├─ auth.ts           # Login and logout URLs + state signing and verification (public routes)
│  └─ tasks.ts          # Per-resource sub-app (HTTP contract only)
├─ services/tasks.ts    # Domain rules + ownership decisions
├─ db/
│  ├─ client.ts         # pg Pool + drizzle instance (singleton)
│  ├─ schema.ts         # Drizzle table definitions (the source for migrations)
│  ├─ errors.ts         # SQLSTATE → domain error conversion (23505 → 409)
│  └─ queries/tasks.ts  # Queries only — every function takes an ownerId
├─ storage/
│  ├─ index.ts          # The ObjectStorage port (the only type app code sees)
│  └─ s3.ts             # The only file that knows the AWS SDK (MinIO-compatible via S3_ENDPOINT)
└─ schemas/tasks.ts     # Zod request/response DTOs
drizzle/                # drizzle-kit generated SQL + meta/ (do not hand-edit)
tests/{unit,handler,integration}/ + tests/test-env.ts
docker-compose.yml      # app + postgres:16 (+ docker/init-test-db.sql)
drizzle.config.ts · Dockerfile
infra/                  # AWS CDK — never imported from src/
```
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
### 1. Parse at the trust boundary with Zod — it is parsing, not validation

The request body, query and path parameters are all `unknown`. Only the parsed type flows downward.

```ts
// ✅ Only parsed values go on to the service
const body = await jsonBody(c, CreateTaskInput)   // throws into the 400 envelope on failure
const task = await createTask(user.sub, body)

// ❌ A cast is not validation — it blocks nothing at runtime
const body = (await c.req.json()) as CreateTaskInput
await createTask(user.sub, body)   // a 12MB title string passes straight through
```

Using `z.infer<typeof CreateTaskInput>` in the service signature makes the schema the contract.
Attach it once more with DB constraints (`notNull`, a unique index, a check) → `resources/input-validation.md`

### 2. Validate environment variables once, at boot

Do not read `process.env` directly in app code. A missing value must die **at boot**, not on the first request.

```ts
// ✅ src/config/env.ts — a single entry point, validated once at import time
const parsed = EnvSchema.safeParse(process.env)
if (!parsed.success) { logInvalidEnvKeys(parsed.error); process.exit(1) }   // the deploy rolls back
export const env = parsed.data

// ❌ Reading it directly at each use site — a typo or omission blows up only on one path after deploy
const pool = new Pool({ connectionString: process.env.DATABSE_URL })   // undefined
```

Boot validation uses **exactly one form: `safeParse` + `process.exit(1)`** (the exception from `parse` loses which key
was missing from the logs). Never put a server secret behind a prefix that is inlined into the browser bundle (`VITE_*`),
and keep separate schemas for public variables and secrets → `resources/input-validation.md`

### 3. The ownership filter has to live inside the query

This stack has no data-layer line of defense. Put the owner condition in **every** query, read and mutation alike.

```ts
// ✅ Ownership is in the WHERE clause — someone else's rows are never returned in the first place
export function findOwnedTask(ownerId: string, id: string) {
  return db.select().from(tasks)
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId))).limit(1)
}

// ❌ Fetch everything then filter in code — the moment you forget to filter it is a leak, and it lands in logs and caches too
export function findTask(id: string) {
  return db.select().from(tasks).where(eq(tasks.id, id)).limit(1)
}
```

Pinning the first argument of a query function signature to `ownerId` makes an omission surface as a type error.

### 4. Absent and unauthorized get the same response (no existence leaks)

Answer 403 and 404 differently and an unauthorized user can enumerate which resources exist.

```ts
// ✅ Read with the ownership condition and answer with a single 404 when there is nothing
const task = await findOwnedTask(user.sub, id)
if (!task) throw new AppError(404, 'NOT_FOUND', 'Task not found')

// ❌ It reveals existence — sweeping ids builds a list of someone else's resources
const task = await findTask(id)
if (!task) throw new AppError(404, 'NOT_FOUND', 'Task not found')
if (task.ownerId !== user.sub) throw new AppError(403, 'FORBIDDEN', 'Not your task')
```

A token verification failure does not distinguish its reason either — expiry, signature mismatch and issuer mismatch all give the same
401 `UNAUTHENTICATED` envelope. Use 403 only on the **non-ownership axis** (admin-only and the like).

### 5. A mutation checks the affected row count

Answer a 0-row mutation as success and the "it says deleted but it is still there" bug appears silently.

```ts
// ✅ An empty .returning() result means there is no target or it is not mine → 404
const [updated] = await db.update(tasks).set({ title, updatedAt: new Date() })
  .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId))).returning()
if (!updated) throw new AppError(404, 'NOT_FOUND', 'Task not found')

// ❌ Discard the result — a 204 goes out even when called with someone else's id
await db.delete(tasks).where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
return c.body(null, 204)
```

### 6. Confine vendor SDKs to the infrastructure layer

The company may move this backend on-premises. Let an AWS-only API into `src/` and the migration becomes
a rewrite.

```ts
// ✅ Standard OIDC verification — swap the issuer/JWKS URL and you are on another IdP
import { createRemoteJWKSet, jwtVerify } from 'jose'
const jwks = createRemoteJWKSet(new URL(env.OIDC_JWKS_URL))

// ❌ App code knowing a Cognito-only library or SDK directly
import { CognitoJwtVerifier } from 'aws-jwt-verify'   // a full rewrite when migrating
```

Write logs as **structured JSON on stdout**, not through the CloudWatch SDK. The decision table is in
`resources/portability-boundaries.md`.
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
```ts
// HTTP layer
import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { bodyLimit } from 'hono/body-limit'
import { createMiddleware } from 'hono/factory'
import { HTTPException } from 'hono/http-exception'
import { serve } from '@hono/node-server'

// Validation / auth (standard OIDC — not a vendor SDK)
import { z } from 'zod'
import { createRemoteJWKSet, jwtVerify } from 'jose'

// Data access
import { drizzle } from 'drizzle-orm/node-postgres'
import { Pool } from 'pg'
import { and, desc, eq, inArray, isNotNull, isNull, sql } from 'drizzle-orm'
import { index, pgTable, text, timestamp, uuid } from 'drizzle-orm/pg-core'

// Testing
import { afterEach, beforeAll, describe, expect, it } from 'vitest'

// Project-internal ('@/' → 'src/' registered in tsconfig paths + the vitest alias)
import { env } from '@/config/env'
import { db } from '@/db/client'
import { AppError } from '@/http/errors'
```
<!-- /pack-slot -->

<!-- pack-slot: anti-patterns-axis -->
**Anti-Patterns**

- Answering 200 with `{ ok: false }` in the body → the client misses the error
- `catch (e) { console.error(e) }` and carrying on → a failure is reported as success
- Registering `app.use('*', requireAuth)` **before** `/healthz` → the ALB health check dies with a 401.
  Hono executes in registration order, so register the public paths (`/healthz`, `/api/auth`) **first**
- Running migrations at server boot → several Fargate tasks boot at once and contend.
  Run migrations as **a separate one-off task** in the deploy pipeline
- Returning DB constraint names, SQL or stacks to the client in an error message → the schema leaks out
- Returning everything in a list response with no `limit` → it silently times out as the rows grow
- Trusting an `ownerId` or `role` the SPA sent → the owner comes only from **the `sub` of the verified token**
<!-- /pack-slot -->

## For the seam to fill — what is not in this pack

| hub slot | why it is a function of the combination |
| --- | --- |
| Architecture Overview | What the client is and where the trust boundary sits depend on the frontend axis |
| Quick Start "add a new endpoint" | The handler shape and the response envelope depend on the wire contract |
| HTTP Status Codes table | The error code ↔ status mapping is the wire contract itself |
| The "bundle exposure prefix" example in Core Principle 2 | The prefix name (`VITE_*`, `NEXT_PUBLIC_*`, …) depends on the frontend axis. **The rule itself is in the pack; only the prefix is substituted** |
| Navigation Guide | `pack.json` supplies the pack resource rows and the seam adds the seam resource rows |
