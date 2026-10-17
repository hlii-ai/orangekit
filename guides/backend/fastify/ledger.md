<!-- orangekit-pack-ledger: backend/fastify v3.35.0 -->

# fastify pack — symbol ledger (L0 declaration)

**This is the contract the main session declares before authoring.** Assigning a definition file in `provides` is an
**ownership assignment**, and the shape column carries **the signatures that actually compiled and ran in the scratch
reference implementation** (`tsc --noEmit` passed · Vitest 9/9 · a real PostgreSQL 18.4).

`requires` is what this pack consumes but does not define. In 3.35.0, 7 project symbols (`AppError` · `ErrorCode` ·
`errorHandler` · `requireAuth` · `AuthUser` · `authFor` · `tasksRoutes`) moved from requires to provides — the shape
column carries over what it said in the requires days (argument order · pinned paths). Library APIs are not subject to
the ledger.

**Symbols assigned to variant files** (`auth-boundaries.md` · `auth-flows.md`) are defined in the same shape by
**both** auth variants (`variants/auth/self-issued` · `variants/auth/oidc`) — the gate checks each variant combination.

## provides — this pack defines them

Only symbols with an `export` declaration are listed. **The first token of the shape column is the source path** —
which resource file owns a symbol and where its code lives are different things.

| symbol | definition file | shape | kind |
| --- | --- | --- | --- |
| `buildApp` | project-structure.md | **`src/app.ts`** — `(opts?: { logger?: boolean; onRoute?: (route: RouteOptions) => void }) => Promise<App>` — it does not `listen`. `onRoute` is set as a hook **before** registration so tests can enumerate the routes. Sets the compilers · `setErrorHandler` · `setNotFoundHandler` · the `x-request-id` hook **at the root** and `register`s `authPlugin` and the route plugins. `genReqId` is a UUID | Fastify app assembly. Tests call it through `inject` |
| `App` | project-structure.md | **`src/app.ts`** — `Awaited<ReturnType<typeof buildApp>>` — the instance type with `ZodTypeProvider` attached | tests and boot type the instance with it |
| `pool` | data-access.md | **`src/db/client.ts`** — `pg.Pool` — `max: env.DB_POOL_MAX`. **Not closed in an `onClose` hook** (`shutdown` closes it) | the connection pool (the only pool in this repository) |
| `db` | data-access.md | **`src/db/client.ts`** — the return of `drizzle(pool, { schema })` — a module singleton. Not `decorate`d onto the app instance | the Drizzle client |
| `tasks` | data-access.md | **`src/db/schema.ts`** — `pgTable('tasks', …)` — `id uuid` · `ownerId text` · `title text` · `status task_status` · `createdAt timestamptz(3)`. Unique on `(owner_id, title)` | the table definition — the input to drizzle-kit |
| `taskStatus` | data-access.md | **`src/db/schema.ts`** — `pgEnum('task_status', ['open', 'done'])` | the status enum |
| `TaskRow` | data-access.md | **`src/db/schema.ts`** — `typeof tasks.$inferSelect` — it **carries** `ownerId` (not a response type) | the row type. Used by test fixtures |
| `listTasks` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, q: TaskQuery) => Promise<TaskView[]>` — **the owner comes first**. At most `q.limit` rows. Validates the cursor's id (uuid) and date (ISO round trip · 1970–9999), and a violation is `AppError('VALIDATION_FAILED')` | list (ownership condition + `(createdAt, id)` cursor) |
| `getTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, id: string) => Promise<TaskView \| null>` — **the owner comes first** | single item (ownership condition included) |
| `insertTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, input: TaskCreate) => Promise<TaskView>` — a unique conflict is not caught but thrown (`toAppError` turns it into a 409) | create |
| `updateTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, id: string, patch: TaskUpdate) => Promise<TaskView>` — 0 rows from `returning` means `AppError('NOT_FOUND')` | update — **decided by the affected row count** |
| `deleteTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, id: string) => Promise<void>` — `rowCount === 0` means `AppError('NOT_FOUND')` | delete — **decided by the affected row count** |
| `encodeCursor` | data-access.md | **`src/db/tasks.ts`** — `(row: Pick<TaskView, 'createdAt' \| 'id'>) => string` — `<ISO>_<id>` | the next-page cursor. The seam's list route builds `nextCursor` with it |
| `EnvSchema` | input-validation.md | **`src/env.ts`** — `z.object` — `NODE_ENV` · `HOST` · `PORT` · `LOG_LEVEL` · `DATABASE_URL` · `DB_POOL_MAX` · `BODY_LIMIT_BYTES` · `SHUTDOWN_TIMEOUT_MS` + `.extend(AuthEnvSchema.shape)` | the environment variable schema — the variant decides the auth keys and they are validated here together |
| `Env` | input-validation.md | **`src/env.ts`** — `z.infer<typeof EnvSchema>` | the validated environment type |
| `env` | input-validation.md | **`src/env.ts`** — `Env` — on `safeParse({ ...process.env })` failure, stderr + `process.exit(1)` | the validated environment values — the only place that reads `process.env` |
| `TaskCreateSchema` | input-validation.md | **`src/schemas/task.ts`** — `z.strictObject` — **rejects** unknown keys | create body |
| `TaskUpdateSchema` | input-validation.md | **`src/schemas/task.ts`** — `z.strictObject` + `.refine(reject empty object)` — no stacked `.default()` | update body (partial update) |
| `TaskQuerySchema` | input-validation.md | **`src/schemas/task.ts`** — `z.object` — **strips** unknown keys. `limit` uses `z.coerce` | list query string |
| `TaskParamsSchema` | input-validation.md | **`src/schemas/task.ts`** — `z.object({ id: z.uuid() })` | path params — a 400 before reaching the DB if not a uuid |
| `TaskViewSchema` | input-validation.md | **`src/schemas/task.ts`** — `z.object` — `id` · `title` · `status` · `createdAt: z.date()`. **No** `ownerId` | response schema — filters fields at the serialization boundary |
| `TaskCreate` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskCreateSchema>` | create body type |
| `TaskUpdate` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskUpdateSchema>` | update body type |
| `TaskQuery` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskQuerySchema>` | list query type |
| `TaskView` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskViewSchema>` — the return type of the 5 queries | the response type. **The seam's routes type their handlers with it** |
| `ERROR_STATUS` | error-handling.md | **`src/http/errors.ts`** — `Record<ErrorCode, number>` — **the only mapping table**. A missing code is a compile error | domain code → HTTP status |
| `toAppError` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => AppError` — `errorHandler` **must call it first**. It does not carry the cause's message over into the response message | normalizes an unknown throw → `AppError` |
| `fieldErrors` | error-handling.md | **`src/http/errors.ts`** — `(issues: readonly ValidationIssue[]) => Record<string, string[]>` — the input is Fastify's `err.validation` | validation issues → field errors |
| `errorLogFields` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => Record<string, unknown>` — for a DB error only `{ type: 'db', sqlState, constraint, table }`, otherwise `{ type, message, stack }` | error fields for the log. **Keeps `{ err }` from being logged whole** — DrizzleQueryError carries the bound values |
| `isUniqueViolation` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => boolean` — `e.cause.code === '23505'` | unique violation detection |
| `testDb` | testing.md | **`src/test/db.ts`** — the same singleton as `db` — does not create a new client | the test DB handle |
| `resetDb` | testing.md | **`src/test/db.ts`** — `() => Promise<void>` — set in `beforeEach` | cleanup between tests |
| `seedTask` | testing.md | **`src/test/db.ts`** — `(ownerId: string, patch?: Partial<typeof tasks.$inferInsert>) => Promise<TaskRow>` — **the owner comes first** | fixture creation |
| `AppError` | api-endpoints.md | **`src/http/app-error.ts`** — `new AppError(code: ErrorCode, message: string, details?: Record<string, string[]>)` · fields `code` · `details`. A pure error class — knows nothing about HTTP | a domain failure. Any layer throws it |
| `ErrorCode` | api-endpoints.md | **`src/http/app-error.ts`** — a string literal union: `VALIDATION_FAILED` · `UNAUTHENTICATED` · `FORBIDDEN` · `NOT_FOUND` · `CONFLICT` · `PAYLOAD_TOO_LARGE` · `UNSUPPORTED_MEDIA_TYPE` · `RATE_LIMITED` · `INTERNAL` (every server code in contract §4). `ERROR_STATUS` is `Record<ErrorCode, number>`, so a missing or extra code is a compile error | the domain code |
| `errorHandler` | api-endpoints.md | **`src/http/error-handler.ts`** — `(err: FastifyError, req: FastifyRequest, reply: FastifyReply) => FastifyReply` — `toAppError` → `ERROR_STATUS` → the envelope `{ error: { code, message, details? }, requestId }` + `x-request-id`. Logging goes **by the final status**: 5xx is `req.log.error({ err: errorLogFields(err) })`, 4xx is `info`. `buildApp` sets it at the root with `setErrorHandler` | emits the envelope — the only place |
| `tasksRoutes` | api-endpoints.md | **`src/http/routes/tasks.ts`** — `FastifyPluginAsyncZod` — the first line of the body is `app.addHook('onRequest', requireAuth)`. `buildApp` `register`s it with `{ prefix: '/api/tasks' }`. Single item `{ data }` · list `{ data, nextCursor }` · 201 + `Location` · 204 | task CRUD routes |
| `requireAuth` | auth-boundaries.md | **`src/http/require-auth.ts`** — an `onRequest` hook `(req: FastifyRequest) => Promise<void>` — puts the verified subject on `req.user`. Failure **throws** `AppError('UNAUTHENTICATED')` (it does not write the reply directly). **Inside the route plugin**: `app.addHook('onRequest', requireAuth)` | bearer verification (self-issued: HS256 secret · OIDC: remote JWKS + `iss` · `aud`) |
| `AuthUser` | auth-boundaries.md | **`src/http/require-auth.ts`** — `{ id: string }`. Attached with `declare module 'fastify' { interface FastifyRequest { user?: AuthUser } }` — an **optional property** | the authenticated subject |
| `AuthEnvSchema` | auth-boundaries.md | **`src/auth-env.ts`** — `z.object` — does not read `process.env`. Self-issued: `AUTH_JWT_SECRET` · `AUTH_ACCESS_TTL_SEC` · `AUTH_REFRESH_TTL_DAYS` · `AUTH_COOKIE_SAMESITE` · `WEB_ORIGINS`. OIDC: `OIDC_ISSUER` · `OIDC_AUDIENCE` · `OIDC_JWKS_URI` · `WEB_ORIGINS` | auth environment keys — `EnvSchema` merges them |
| `authTestEnv` | auth-boundaries.md | **`src/auth-env.ts`** — `Record<string, string>` — `src/test/env.ts` fills only the keys that are empty | test-only values for the auth keys |
| `authFor` | auth-boundaries.md | **`src/test/auth.ts`** — `authFor(ownerId: string) => Record<string, string>` — **synchronous**. The header object to pass to `app.inject({ headers })` (`authorization: Bearer …`). Not in an app module — **test-only** | test auth header |
| `authPlugin` | auth-flows.md | **`src/http/auth-plugin.ts`** — `fp(async (app) => …)` — CORS (`WEB_ORIGINS` · `exposedHeaders` `location` · `x-request-id`) + for self-issued, the `/api/auth` routes. **Does not carry the `requireAuth` hook**. `buildApp` `register`s it at the root | CORS · auth endpoints |
| `loggerOptions` | operations.md | **`src/ops/logger.ts`** — `FastifyServerOptions['logger']` — level + `redact`. **Not** a pino instance | logger options |
| `healthz` | operations.md | **`src/ops/health.ts`** — `() => Promise<{ status: 'ok' }>` — does not look at dependencies | liveness |
| `readyz` | operations.md | **`src/ops/health.ts`** — `(req: FastifyRequest, reply: FastifyReply) => Promise<…>` — 503 while draining or when the DB is unreachable | readiness |
| `beginDrain` | operations.md | **`src/ops/health.ts`** — `() => void` — drops `readyz` to 503 | the drain-start flag. `shutdown` (the writer) and `readyz` (the reader) see the same module state |
| `shutdown` | operations.md | **`src/ops/shutdown.ts`** — `(app: FastifyInstance, drainDelayMs?: number) => Promise<void>` — **performs the drain**. It is not the signal wiring — the caller invokes it inside `process.once('SIGTERM', …)` | drain → grace period → `app.close()` → `pool.end()` |

## requires — the combination has to provide them

Since 3.35.0 **there are 0 project-symbol requires** — through the wire contract (http-standard@1) and the auth
variants, this pack owns the whole HTTP layer. The hybrid RN shell's (`appShell`) bridge has nothing to do with the
backend axis.

| symbol | kind | shape the pack assumes | why it is the combination's |
| --- | --- | --- | --- |

## Known gaps

`knownGaps` in `pack.json` is the authority. All 7 mandatory slots are inside the pack — in 3.35.0 it absorbed the API
endpoints · the authentication boundary · the complete example, and `seamSlots` became empty.

## Symbols appearing in examples — app symbols (the project creates them)

Neither `provides` nor `requires` — the pack does not define them and the seam is not going to hand them over either.
They appear in the examples by name only, so having no definition after assembly is normal.

| name | appears in | kind |
| --- | --- | --- |
| `usersRoutes` | project-structure.md (encapsulation example) | another domain's route plugin |
| `importTasks` | data-access.md (transaction example) · testing.md (rollback test) | service-layer example. It lives in `src/services/task-service.ts` and has no route consumer — an example showing the shape of a transaction. A bulk-create endpoint is not in contract v1 |
| `ValidationIssue` | error-handling.md | the input type of `fieldErrors`. A file-local type, so it is not exported |

## Variant-only symbols — treated like the ledger's 'examples' section

**Exports that exist in one variant only.** Listing them in `provides` would make them "no definition" in the other
variant's combination, so they live here. Files outside the variant do not import them — the only consumers are files of
the same variant and that variant's tests.

| name | variant · file | shape |
| --- | --- | --- |
| `users` · `refreshTokens` | self-issued · auth-boundaries.md | `src/db/auth-schema.ts` — `pgTable('users')` · `pgTable('refresh_tokens')` (`familyId` · `tokenHash` · `usedAt` · `revokedAt`) |
| `signAccessToken` | self-issued · auth-boundaries.md | `src/http/require-auth.ts` — `(userId: string) => Promise<string>` — HS256, `AUTH_ACCESS_TTL_SEC` |
| `createUser` · `authenticate` | self-issued · auth-flows.md | `src/services/auth-service.ts` — `(email: string, password: string) => Promise<string>` (user id). An `authenticate` failure is a 401 without a reason |
| `issueRefreshToken` · `rotateRefreshToken` · `revokeRefreshToken` | self-issued · auth-flows.md | `src/services/auth-service.ts` — `(userId)` → the raw token · `(raw)` → `{ userId, token }` (on reuse, invalidates the family, then 401) · `(raw)` → `void` |
| `useTestVerificationKey` | oidc · auth-boundaries.md | `src/http/require-auth.ts` — `(key: KeyObject) => void` — throws if `NODE_ENV !== 'test'` |
| `signTestToken` | oidc · auth-boundaries.md | `src/test/auth.ts` — `(claims: Record<string, unknown>) => string` — overlays the default `iss` · `aud` · `exp` |
