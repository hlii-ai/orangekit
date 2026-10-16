<!-- orangekit-pack-ledger: backend/fastify v3.33.0 -->

# fastify pack — symbol ledger (L0 declaration)

**This is the contract the main session declares before authoring.** Assigning a definition file in `provides` is an
**ownership assignment**, and the shape column carries **the signatures that actually compiled and ran in the scratch
reference implementation** (`tsc --noEmit` passed · Vitest 9/9 · a real PostgreSQL 18.4).

`requires` is what this pack consumes but does not define — **the seam has to provide it**.
Library APIs are not subject to the ledger.

## provides — this pack defines them

Only symbols with an `export` declaration are listed. **The first token of the shape column is the source path** —
which resource file owns a symbol and where its code lives are different things.

| symbol | definition file | shape | kind |
| --- | --- | --- | --- |
| `buildApp` | project-structure.md | **`src/app.ts`** — `(opts?: { logger?: boolean; onRoute?: (route: RouteOptions) => void }) => Promise<App>` — it does not `listen`. `onRoute` is set as a hook **before** registration so tests can enumerate the routes. Sets the compilers · `setErrorHandler` · `setNotFoundHandler` **at the root** and `register`s the route plugins | Fastify app assembly. Tests call it through `inject` |
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
| `EnvSchema` | input-validation.md | **`src/env.ts`** — `z.object` — `NODE_ENV` · `HOST` · `PORT` · `LOG_LEVEL` · `DATABASE_URL` · `DB_POOL_MAX` · `BODY_LIMIT_BYTES` · `SHUTDOWN_TIMEOUT_MS` | the environment variable schema |
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
| `loggerOptions` | operations.md | **`src/ops/logger.ts`** — `FastifyServerOptions['logger']` — level + `redact`. **Not** a pino instance | logger options |
| `healthz` | operations.md | **`src/ops/health.ts`** — `() => Promise<{ status: 'ok' }>` — does not look at dependencies | liveness |
| `readyz` | operations.md | **`src/ops/health.ts`** — `(req: FastifyRequest, reply: FastifyReply) => Promise<…>` — 503 while draining or when the DB is unreachable | readiness |
| `beginDrain` | operations.md | **`src/ops/health.ts`** — `() => void` — drops `readyz` to 503 | the drain-start flag. `shutdown` (the writer) and `readyz` (the reader) see the same module state |
| `shutdown` | operations.md | **`src/ops/shutdown.ts`** — `(app: FastifyInstance, drainDelayMs?: number) => Promise<void>` — **performs the drain**. It is not the signal wiring — the caller invokes it inside `process.once('SIGTERM', …)` | drain → grace period → `app.close()` → `pool.end()` |

## requires — the seam has to provide them

`project` has to be `export`ed by the seam; `library` comes from a package the seam chose, so it is decided by whether
the name appears in an import statement.

| symbol | kind | shape the pack assumes | why it is a seam |
| --- | --- | --- | --- |
| `AppError` | project | goes in `src/http/app-error.ts`. `new AppError(code: ErrorCode, message: string, details?: Record<string, string[]>)` · fields `code` · `details`. A pure error class — knows nothing about HTTP | the error code table and the field-error shape are a function of the wire contract |
| `ErrorCode` | project | `src/http/app-error.ts`. A string literal union. **Must include**: `VALIDATION_FAILED` (`fieldErrors` · cursor) · `UNAUTHENTICATED` · `FORBIDDEN` · `NOT_FOUND` · `CONFLICT` (`isUniqueViolation`) · `PAYLOAD_TOO_LARGE` · `UNSUPPORTED_MEDIA_TYPE` (`FST_ERR_CTP_*`) · `INTERNAL`. `ERROR_STATUS` is `Record<ErrorCode, number>`, so a missing or extra code is a compile error | same as above |
| `errorHandler` | project | `src/http/error-handler.ts`. `(err: FastifyError, req: FastifyRequest, reply: FastifyReply) => FastifyReply` — `toAppError` → `ERROR_STATUS` → **emits the envelope**. Logging goes **by the final status**: 5xx is `req.log.error({ err: errorLogFields(err) })`, 4xx is `info` — never log `{ err }` whole. `buildApp` sets it at the root with `setErrorHandler` | the response envelope shape is a function of the wire contract |
| `requireAuth` | project | `src/http/require-auth.ts`. An `onRequest` hook `(req: FastifyRequest) => Promise<void>` — puts the verified subject on `req.user`. Failure **throws** `AppError('UNAUTHENTICATED')` (it does not write the reply directly). **Inside the route plugin**: `app.addHook('onRequest', requireAuth)` | **how the token is verified is a function of the combination** — with a server runtime on the frontend axis it is a session cookie, with an SPA or app a bearer token |
| `AuthUser` | project | at minimum `{ id: string }`. Attached with `declare module 'fastify' { interface FastifyRequest { user?: AuthUser } }` | same as above |
| `authFor` | project | goes in **`src/test/auth.ts`** (not in an app module). `authFor(ownerId: string) => Record<string, string>` — the header object to pass to `app.inject({ headers })`. **Test-only** | whether it is a header or a cookie is a function of `auth-boundaries` |
| `tasksRoutes` | project | `src/http/routes/tasks.ts`. `FastifyPluginAsyncZod` — consumes this pack's queries and schemas to attach the endpoints and response schemas. `buildApp` `register`s it with `{ prefix: '/api/tasks' }` | the handler shape and the envelope are a function of the combination (`api-endpoints` in `seamSlots`) |

## Known gaps

`knownGaps` in `pack.json` is the authority. All 6 axis-local mandatory slots are filled, and what looks empty (API
endpoints · the authentication boundary · the complete example) is not a gap but **the seam's share**, declared by
`seamSlots`.

## Symbols appearing in examples — app symbols (the project creates them)

Neither `provides` nor `requires` — the pack does not define them and the seam is not going to hand them over either.
They appear in the examples by name only, so having no definition after assembly is normal.

| name | appears in | kind |
| --- | --- | --- |
| `usersRoutes` | project-structure.md (encapsulation example) | another domain's route plugin |
| `importTasks` | data-access.md (transaction example) · testing.md (rollback test) | service-layer example. It lives in `src/services/task-service.ts` and has no route consumer — **the seam's `complete-example` consumes it** |
| `ValidationIssue` | error-handling.md | the input type of `fieldErrors`. A file-local type, so it is not exported |
