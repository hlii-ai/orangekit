<!-- orangekit-pack: backend/fastify v3.36.0 -->
# Input validation — route schemas and the Zod type provider

This file owns the environment variable schema (`src/env.ts`) and the request and response schemas
(`src/schemas/task.ts`). Turning a validation failure into a status code and field errors belongs to
`error-handling.md`, and the route plugin bodies that attach the schemas to routes are owned by
`resources/api-endpoints.md`.

## 1. Decision tree — where validation happens

| input | where it is validated | on failure |
| --- | --- | --- |
| request body · query · path params | `body` · `querystring` · `params` of the route `schema` | a 400 carrying `err.validation` → the root `errorHandler` |
| response | `response` of the route `schema` | fields outside the schema are removed, a type mismatch is a 500 (§5) |
| environment variables | `EnvSchema.safeParse` in `src/env.ts` | **boot failure** — it does not wait for the first request |
| a value with structure inside a string, like a cursor | the query function that interprets it (`decodeCursor` in `data-access.md`) | `AppError('VALIDATION_FAILED')` |

Do not call `Schema.parse(req.body)` again inside the handler — the type provider has already replaced `req.body`
**with the parsed value** (§4). Parse twice and `.default()` and `.trim()` run twice.

## 2. Environment variables (`src/env.ts`)

This is the **only** module in the application code that reads `process.env` (policy `env-single-entry`). Of the
base keys only `DATABASE_URL` is required. The auth keys differ per auth method, so `resources/auth-boundaries.md`
defines them as `AuthEnvSchema` in `src/auth-env.ts`, and they are **merged and validated in one go** here — there is
still only one place that reads.

<!-- file: src/env.ts -->
```ts
// src/env.ts
import { z } from 'zod'
import { AuthEnvSchema } from './auth-env'

export const EnvSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  HOST: z.string().default('0.0.0.0'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  DATABASE_URL: z.url({ protocol: /^postgres(ql)?$/ }),
  DB_POOL_MAX: z.coerce.number().int().min(1).default(10),
  BODY_LIMIT_BYTES: z.coerce.number().int().min(1024).default(1_048_576),
  SHUTDOWN_TIMEOUT_MS: z.coerce.number().int().min(1000).default(10_000),
}).extend(AuthEnvSchema.shape)
export type Env = z.infer<typeof EnvSchema>

const parsed = EnvSchema.safeParse({ ...process.env })
if (!parsed.success) {
  // Boot-time failure — there is no logger yet, so write to stderr directly
  process.stderr.write(`Invalid environment variables:\n${z.prettifyError(parsed.error)}\n`)
  process.exit(1)
}
export const env: Env = parsed.data
```

Without `DATABASE_URL` it prints `✖ Invalid input: expected string, received undefined → at DATABASE_URL` and stops
<!-- verified: real output of zod@4.6.7 z.prettifyError — ran src/index.ts without DATABASE_URL (2026-10-15) -->.
Why `HOST` defaults to `0.0.0.0` is in `operations.md` §2.

## 3. Request and response schemas (`src/schemas/task.ts`)

<!-- file: src/schemas/task.ts -->
```ts
// src/schemas/task.ts
import { z } from 'zod'

// PostgreSQL text rejects U+0000 (22021) — if the schema does not block it, it becomes a 500
const Title = z.string().trim().min(1).max(200).refine((s) => !s.includes('\0'), { message: 'NUL characters are not allowed' })
const Status = z.enum(['open', 'done'])

// Create body — rejects unknown keys (so a misspelled field is not silently dropped)
export const TaskCreateSchema = z.strictObject({
  title: Title,
  status: Status.default('open'),
})

// Partial update — do not stack .default(). Fields that were not sent must stay undefined
export const TaskUpdateSchema = z.strictObject({
  title: Title.optional(),
  status: Status.optional(),
}).refine((v) => Object.keys(v).length > 0, { message: 'No fields to update' })

// Query string — every value arrives as a string, so coerce. Unknown keys are stripped (not rejected)
export const TaskQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(20),
  cursor: z.string().optional(),
  status: Status.optional(),
})

export const TaskParamsSchema = z.object({ id: z.uuid() })

// Response schema — the serialization boundary. ownerId is not here, so it is removed from the response
export const TaskViewSchema = z.object({
  id: z.uuid(),
  title: z.string(),
  status: Status,
  createdAt: z.date(),
})

export type TaskCreate = z.output<typeof TaskCreateSchema>
export type TaskUpdate = z.output<typeof TaskUpdateSchema>
export type TaskQuery = z.output<typeof TaskQuerySchema>
export type TaskView = z.output<typeof TaskViewSchema>
```

`TaskParamsSchema` being `z.uuid()` is not just a format check — when a non-uuid id reaches the DB, PostgreSQL throws
`invalid input syntax for type uuid` (SQLSTATE `22P02`) and that becomes a 500. Block it at the boundary with a 400
<!-- verified: drizzle-orm@0.45.4 — getTask('alice','not-a-uuid') gave DrizzleQueryError (cause.code 22P02) → toAppError INTERNAL (2026-10-15) -->.

## 4. The type provider — validation and types come from one declaration

`buildApp` sets `setValidatorCompiler(validatorCompiler)` · `setSerializerCompiler(serializerCompiler)` at the root and
attaches `withTypeProvider<ZodTypeProvider>()` (`project-structure.md` §2). Type a route plugin as
`FastifyPluginAsyncZod` and `req.body` and `req.query` become the schema's **output type**.

```ts
// src/http/routes/tasks.ts — the schema wiring of a single route (in full in resources/api-endpoints.md §5)
app.get('/', {
  schema: { querystring: TaskQuerySchema, response: { 200: z.object({ data: z.array(TaskViewSchema), nextCursor: z.string().nullable() }) } },
}, async (req) => ({ data: await listTasks(ownerOf(req.user), req.query), nextCursor: null }))
```

<!-- verified: fastify-type-provider-zod@7.0.0 inject — ?limit=7&evil=1 arrived at the handler as req.query {"limit":7} (number), and the body {"title":"  spaced  "} as {"title":"spaced","status":"open"} (2026-10-15) -->
What the handler receives is **the parse result**: `limit` is a number, unknown query keys are stripped, `title` is
trimmed, and a missing `status` is `'open'`. There is never a reason to reread the raw string.

## 5. The response schema is the serialization boundary

| what the handler returned | result |
| --- | --- |
| a field not in the schema (`ownerId`) | **removed from the response** — not an error |
| a `Date` where `z.date()` is | serialized as an ISO string (`"1970-01-01T00:00:00.000Z"`) |
| a string where `z.date()` is | **500** `FST_ERR_RESPONSE_SERIALIZATION` |
| a number where `z.string()` is | 500 — same code |

<!-- verified: ran fastify-type-provider-zod@7.0.0 + zod@4.6.7 through inject, each of the four rows observed (2026-10-15) -->

The first row is the second line of defense. The first is the data layer not selecting `ownerId` in `view`; even if
someone returns the whole row with `select()`, the response schema filters it. **Do not trust only one of the two**
— on a route that forgot its response schema, only the first remains. The third row comes from a query that read a
date back as a string through an `sql` template — the Drizzle builder's `timestamp` column returns a `Date`.

## 6. Partial updates · unknown keys · empty bodies

| input | `TaskCreateSchema` | `TaskUpdateSchema` | `TaskQuerySchema` |
| --- | --- | --- | --- |
| `{}` | rejected — `title` is required | rejected — `refine` | passes — `limit: 20` |
| `{ title: 'b' }` | passes + `status: 'open'` | passes — **no `status`** | — |
| includes an unknown key | rejected (`unrecognized_keys`) | rejected | **stripped** |

<!-- verified: ran zod@4.6.7 safeParse — each cell of the table (2026-10-15) -->

Attach `.default('open')` to `status` in `TaskUpdateSchema` and **a request that only edits the title resets the
status to `open`.** The syntax is perfect and the types pass — the partial-update test in `testing.md` catches it by
running (it failed when that mutation was introduced).

Why the query strips rather than rejects: proxies and analytics tools append keys like `utm_*`. The body is built by
the client directly, so silently dropping a typo turns into "I saved it but nothing changed".

## 7. Double up with the DB constraints

Zod guards the shape; the DB guards **the facts under concurrency**. `TaskCreateSchema` cannot see title uniqueness
— when two requests arrive at once with the same title, both pass the schema. The `(owner_id, title)` unique index
(`data-access.md` §3) stops the second, and `toAppError` turns that error into a 409.

| rule | Zod | DB |
| --- | --- | --- |
| `title` 1–200 characters | `Title` | — (the shape lives in Zod alone) |
| no U+0000 in `title` | the `refine` on `Title` | text rejects it with `22021` → a 500 unless blocked <!-- verified: measured in audit A — {"title":"a\u0000b"} was a 500 before the refine, a 400 after --> |
| `title` unique within an owner | impossible | `tasks_owner_title_uq` |
| `status` ∈ open/done | `Status` | the `task_status` enum |

## Misuse list ① — Zod 3 · JSON Schema habits → current idioms

| old habit | current form (Zod 4 + type provider 7) |
| --- | --- |
| `z.string().uuid()` · `z.string().url()` | `z.uuid()` · `z.url()` — top-level format functions. The old forms still work in Zod 4.6 but are not the current idiom <!-- verified: zod@4.6.7 — both forms exist, the pack compiled and ran with the top-level forms (confirmed by audit B) --> |
| a `.strict()` chain | `z.strictObject({...})` |
| assembling messages with `error.format()` / `error.flatten()` | `z.prettifyError(error)` for the boot output |
| a JSON Schema object on the route + a separate TS interface | one Zod schema — validation and type in the same declaration |
| `Schema.parse(req.body)` inside the handler | attach it to the route's `schema.body` and use `req.body` as-is |

## Misuse list ② — confusable pairs

| often picked wrong | exact condition |
| --- | --- |
| `z.object` vs `z.strictObject` | the former for queries (strip), the latter for bodies (reject) |
| `.optional()` vs `.default()` | only the former for partial updates. The latter only for create bodies |
| `z.input` vs `z.output` types | handlers and query functions receive the latter — the value with `default` and `coerce` applied |
| `parse` vs `safeParse` (env) | the latter — catch the failure, print human-readable output, and exit |
