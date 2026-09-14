<!-- orangekit-pack-ledger: backend/node-api v3.13.0 -->

# node-api pack — symbol ledger (L0 declaration)

**This is the contract the main session declares before authoring.** Assigning a definition file in `provides` is an
**ownership assignment**, and it is the only device that keeps duplicate definitions from appearing when clusters are split and
written in parallel. L1 defines only the symbols assigned to its own cluster, and a stray one is caught at fan-in by the gate's `--pack`.

`requires` is what this pack consumes but does not define — **the seam has to provide it**.
Library APIs are not subject to the ledger.

## provides — this pack defines them

Only symbols with an `export` declaration are listed.

**The "shape" column is mandatory.** Assign only the owning file and leave the shape empty and, in parallel authoring, a sibling
cluster **guesses** the signature — measured (2026-08-23), another cluster called `getTask(ownerId, id)` as
`getTask(id, ownerId)`, and since both arguments were `string` **TypeScript did not catch it**, so
every single-item lookup returned 404. The cause was that the `requires` table had this column from the start while `provides`
did not.

| symbol | definition file | shape | kind |
| --- | --- | --- | --- |
| `makeApp` | project-structure.md | **`src/app.ts`** — `() => Express` — it does not `listen` | Express 5 app assembly (router mounting · middleware order) |
| `notFound` | project-structure.md | **`src/app.ts`** — `RequestHandler` (3 arguments) — mounted **before** the error middleware | the 404 middleware — goes **before** the error middleware |
| `prisma` | data-access.md | **`src/db/client.ts`** — a `PrismaClient` singleton | the PrismaClient singleton (the only instance in this pack) |
| `listTasks` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, q: { limit: number; cursor?: string; status?: TaskStatus }) => Promise<TaskView[]>` | list query (ownership filter + cursor pagination) |
| `getTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, id: string) => Promise<TaskView \| null>` — **the owner comes first** | single-item query (ownership filter included) |
| `insertTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, input: TaskCreate) => Promise<TaskView>` | create |
| `updateTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, id: string, patch: TaskUpdate) => Promise<TaskView>` — 0 rows means `AppError('NOT_FOUND')` | update — **checks the affected row count** |
| `deleteTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, id: string) => Promise<void>` — 0 rows means `AppError('NOT_FOUND')` | delete — **checks the affected row count** |
| `TaskView` | data-access.md | **`src/db/tasks.ts`** — `Prisma.TaskGetPayload<{ select: typeof fields }>` — it does not carry `ownerId` | the return type of the 5 queries (the shape narrowed by `select`). **The seam's `tasksRouter` needs a name for it to type its handlers** — anonymous, the consumer has to write `Awaited<ReturnType<typeof getTask>>` |
| `EnvSchema` | input-validation.md | **`src/env.ts`** — a `ZodObject` — applied at boot with `safeParse(process.env)` | environment variable schema |
| `env` | input-validation.md | **`src/env.ts`** — `Env` (the validated values). `PORT`·`LOG_LEVEL`·`NODE_ENV`·`DATABASE_URL`·`DRAIN_DELAY_MS`·`SHUTDOWN_TIMEOUT_MS` | validated environment values — the only place that reads `process.env` |
| `TaskCreateSchema` | input-validation.md | **`src/schemas/task.ts`** — `z.strictObject` — it **rejects** unknown keys | create request body |
| `TaskUpdateSchema` | input-validation.md | **`src/schemas/task.ts`** — a partial update. Does not stack a `.default()` | update request body (partial update) |
| `TaskQuerySchema` | input-validation.md | **`src/schemas/task.ts`** — `z.object` — it **strips** unknown keys (a query is not rejected) | list query string |
| `Env` | input-validation.md | **`src/env.ts`** — `z.infer<typeof EnvSchema>` | `z.infer<typeof EnvSchema>` |
| `TaskCreate` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskCreateSchema>` | create body type — **the seam's `tasksRouter` types its handlers with it** |
| `TaskUpdate` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskUpdateSchema>` | update body type |
| `TaskQuery` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskQuerySchema>` | list query type |
| `parseBody` | input-validation.md | **`src/http/parse.ts`** — `<S>(schema: S, req: Request) => z.output<S>` — failure is `AppError('VALIDATION_FAILED', …, fieldErrors)` | request body parsing helper — normalizes failure into `AppError` |
| `parseQuery` | input-validation.md | **`src/http/parse.ts`** — `<S>(schema: S, req: Request) => z.output<S>` — **use the return value**. Do not assign to `req.query` | query string parsing helper |
| `ERROR_STATUS` | error-handling.md | **`src/http/errors.ts`** — `Record<string, number>` — domain code → HTTP status. **The only mapping table** | domain error code → HTTP status table |
| `toAppError` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => AppError` — `errorHandler` **must call it first** | unknown throw → `AppError` normalization |
| `isUniqueViolation` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => boolean` — Prisma `P2002` | Prisma `P2002` detection |
| `isRecordNotFound` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => boolean` — Prisma `P2025` | Prisma `P2025` detection |
| `fieldErrors` | error-handling.md | **`src/http/errors.ts`** — `(e: ZodError) => Record<string, string[]>` | `ZodError` → `Record<string, string[]>` |
| `testDb` | testing.md | **`src/test/db.ts`** — `PrismaClient` — isolated by a per-worker schema | test DB connection (per-schema isolation) |
| `resetDb` | testing.md | **`src/test/db.ts`** — `() => Promise<void>` — cleanup between tests | cleanup between tests |
| `seedTask` | testing.md | **`src/test/db.ts`** — `(ownerId: string, patch?: Partial<Task>) => Promise<Task>` | fixture creation |
| `shutdown` | operations.md | **`src/ops/shutdown.ts`** — `(server: Server) => Promise<void>` — **it performs the drain**. It is not the signal wiring (`process.on('SIGTERM', () => void shutdown(server))`) | SIGTERM handling — drain the connections, then exit |
| `healthz` | operations.md | **`src/ops/health.ts`** — `RequestHandler` — liveness. It does not look at dependencies | liveness |
| `readyz` | operations.md | **`src/ops/health.ts`** — `RequestHandler` — readiness. 503 while draining | readiness — ready once the dependencies are confirmed |
| `logger` | operations.md | **`src/ops/logger.ts`** — `pino.Logger` — request scope uses `req.log` | structured logger (pino) |
| `beginDrain` | operations.md | **`src/ops/health.ts`** — `() => void` — drops `readyz` to 503 | the drain-start flag. **`shutdown` (the writer) and `readyz` (the reader) live in different modules, so an entry point is needed** — remove it and `readyz` returns 200 even while draining, and liveness ≠ readiness collapses (reviewed by C3) |

## requires — the seam has to provide them

**The kinds are distinguished.** `project` has to be `export`ed by the seam; `library` comes from a package the seam
chose, so it is decided by whether the name appears in an import statement. `generated` is produced by a tool, so it is
not checked.

| symbol | kind | shape the pack assumes | why it is a seam |
| --- | --- | --- | --- |
| `Task` | generated | `prisma generate` creates it in `@prisma/client`. `id` · `title` · `status: 'open' \| 'done'` · `ownerId` · `createdAt` | a tool creates it from the schema file — neither the pack nor the seam writes it by hand |
| `AppError` | project | goes in `src/http/app-error.ts`. `new AppError(code, message, details?)` · fields `code: string` · `details?: Record<string, string[]>`. **What the code table must include**: `VALIDATION_FAILED` (`parseBody` throws it) · `NOT_FOUND` · `CONFLICT` (`isUniqueViolation`) · `FORBIDDEN` · `INTERNAL`. If one is missing, `ERROR_STATUS` silently drops to 500 | the error code table and the field-error shape are a function of the wire contract |
| `errorHandler` | project | goes in `src/http/error-handler.ts`. An Express 5 error middleware `(err, req, res, next)` — it decides the status with `ERROR_STATUS` and **emits the envelope**. `makeApp` mounts it last | the response envelope shape is a function of the wire contract |
| `requireAuth` | project | goes in `src/http/require-auth.ts`. A `RequestHandler` — it puts the verified subject on `req.user`. Failure is `AppError('UNAUTHENTICATED')` | **how the token is verified is a function of the combination** — with a server runtime on the frontend axis it is a session cookie, with an SPA a bearer token |
| `AuthUser` | project | at minimum `{ id: string }`. Attached to `Express.Request['user']` by declaration merging | same as above |
| `authFor` | project | `authFor(ownerId: string) => Record<string, string>` — builds the auth header object to pass to supertest's `.set()`. **Test-only**, and application code never calls it | whether it is a header or a cookie is a function of `auth-boundaries`. Left as prose only, the gate cannot catch it after assembly (audit C) |
| `tasksRouter` | project | `express.Router()` — consumes this pack's queries and schemas to build the endpoints and the envelope. `makeApp` mounts it at `/api/tasks` | the handler shape and the envelope are a function of the combination (`api-endpoints` in `seamSlots`) |

## Known gaps

None. All 6 axis-local mandatory slots are filled, and what looks empty (API endpoints · the authentication boundary ·
the complete example) is not a gap but **the seam's share**, declared by `seamSlots` in `pack.json`.

## Symbols appearing in examples — app symbols (the project creates them)

Neither `provides` nor `requires` — the pack does not define them and the seam is not going to hand them over either; the consumer
project writes them for its own domain. They appear in the examples by name only, so having no definition after
assembly is normal.

| name | appears in | kind |
| --- | --- | --- |
| `usersRouter` | project-structure.md (mounting example) | another domain router |
| `TaskService` | project-structure.md (layering example) | service-layer example |
| `archiveTask` | data-access.md §7 (transaction boundary example) | service-layer example. It lives in `src/services/task-service.ts` and has no consumer inside the pack — **the seam's `complete-example` consumes it.** The gate reports this as a phantom-definition REVIEW, and this row is its justification |
