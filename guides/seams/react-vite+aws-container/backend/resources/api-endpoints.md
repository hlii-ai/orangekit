<!-- orangekit-seam: react-vite+aws-container/backend v3.34.0 -->
# API endpoints and error handling

Covers the standard shape of a Hono 4 route, the request/response contract, status code mapping, and global error handling.
There is only one client, a React SPA, so **every response is JSON** — there are no page redirects.

## App assembly (`src/app.ts`)

The order of middleware registration is the order of execution. Put the health check **before** authentication.

```ts
import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { bodyLimit } from 'hono/body-limit'
import { sql } from 'drizzle-orm'
import { env } from '@/config/env'
import { db } from '@/db/client'
import { AppError, onError, notFound } from '@/http/errors'
import { requestContext } from '@/http/logger'
import { requireAuth } from '@/http/auth'
import type { AppEnv } from '@/http/types'
import { authRoutes } from '@/routes/auth'
import { tasksRoutes } from '@/routes/tasks'

export const app = new Hono<AppEnv>()

app.use('*', requestContext)                       // assign a requestId + access log
app.get('/healthz', (c) => c.json({ status: 'ok' }))            // no auth (liveness)
app.get('/readyz', async (c) => {                                // check the DB connection (readiness)
  await db.execute(sql`select 1`)
  return c.json({ status: 'ready' })
})

app.use('/api/*', cors({
  origin: env.CORS_ORIGINS,                        // the list of SPA origins (no wildcard)
  allowHeaders: ['Content-Type', 'Authorization'],
  allowMethods: ['GET', 'POST', 'PATCH', 'DELETE'],
  maxAge: 600,
}))
app.use('/api/*', bodyLimit({
  maxSize: 1024 * 1024,                            // 1MB — even behind an ALB the app cuts it off itself
  onError: () => { throw new AppError(413, 'PAYLOAD_TOO_LARGE', 'The request body is too large') },
}))

app.route('/api/auth', authRoutes)                 // public — the login URL is fetched before signing in
app.use('/api/*', requireAuth)                     // only what is registered below this gets authentication
app.route('/api/tasks', tasksRoutes)

app.notFound(notFound)
app.onError(onError)
```

**Registration order is the authentication boundary.** Hono runs in registration order, and the chain ends when a handler
returns a Response without calling `next()`. So `/healthz` and `/api/auth/*`, registered **before** `requireAuth`,
never meet authentication, while `/api/tasks`, registered after it, always does. The moment `requireAuth` goes above
`/healthz`, the ALB health check gets a 401 and the task cycles.

`AppEnv` creates the types for `c.get`/`c.set`. Declare it once for the whole project.

```ts
// src/http/types.ts
import type { AuthUser } from '@/http/auth'
export type AppEnv = { Variables: { user: AuthUser; requestId: string } }
```

## The standard shape of a handler

A handler is a four-line adapter: **parse → call the service → pick the status code → return the envelope**.
When a branch · SQL · authorization ruling gets into a handler, push it down into the service.

```ts
// src/routes/tasks.ts
import { Hono } from 'hono'
import { jsonBody, queryParams, pathParam } from '@/http/validate'
import { CreateTaskInput, ListTasksQuery, TaskIdParam, UpdateTaskInput } from '@/schemas/tasks'
import * as tasks from '@/services/tasks'
import type { AppEnv } from '@/http/types'

export const tasksRoutes = new Hono<AppEnv>()

tasksRoutes.get('/', async (c) => {
  const q = queryParams(c, ListTasksQuery)
  const page = await tasks.listTasks(c.get('user').sub, q)
  return c.json({ data: page.items, nextCursor: page.nextCursor })
})

tasksRoutes.post('/', async (c) => {
  const body = await jsonBody(c, CreateTaskInput)
  const created = await tasks.createTask(c.get('user').sub, body)
  return c.json({ data: created }, 201)
})

tasksRoutes.patch('/:id', async (c) => {
  const { id } = pathParam(c, TaskIdParam)
  const body = await jsonBody(c, UpdateTaskInput)
  return c.json({ data: await tasks.updateTask(c.get('user').sub, id, body) })
})

tasksRoutes.delete('/:id', async (c) => {
  const { id } = pathParam(c, TaskIdParam)
  await tasks.deleteTask(c.get('user').sub, id)     // the service throws 404 on 0 rows
  return c.body(null, 204)
})
```

The owner is always `c.get('user').sub`. An `ownerId` carried in the body or query is never read.

## The response envelope contract

| Kind | Shape |
| --- | --- |
| single success | `{ "data": { ... } }` |
| list success | `{ "data": [ ... ], "nextCursor": "<cursor>" \| null }` |
| delete success | no body (204) |
| failure | `{ "error": { "code": "...", "message": "...", "details"?: ... }, "requestId": "..." }` |

- `code` is read by a machine and `message` by a person. The SPA branches **on `code` only**
- `details` is carried on a validation failure (`VALIDATION_FAILED`) only — a map of per-field messages
- `requestId` goes into every error response. When a user reports that value you find it in the log immediately

## Pagination is done with a cursor

With `offset`, inserted rows shift the items and produce duplicates and omissions. Use a `(created_at, id)` tuple cursor.

- The canonical definition of the request schema `ListTasksQuery` (`limit` · `cursor` · `archived`) is in
  `resources/input-validation.md` — it is not declared again here
- `cursor` is `base64url("<iso>|<uuid>")` and is **a string with an upper bound (`.max(200)`)**.
  The cursor is also a client-supplied value, so it needs a length limit and decode-failure handling (400)
- When `nextCursor` in the response is `null`, that is the last page. The query implementation is in `resources/data-access.md`,
  and the encoding/decoding is in the service layer of `resources/complete-example.md`

## The error code table

| `error.code` | Status | Meaning | Where it arises |
| --- | --- | --- | --- |
| `VALIDATION_FAILED` | 400 | Zod schema violation, JSON parse failure, malformed query | `validate.ts` |
| `UNAUTHENTICATED` | 401 | token missing · expired · signature/issuer mismatch (**reason not distinguished**) | `auth.ts` |
| `FORBIDDEN` | 403 | authenticated but insufficient role · scope (not ownership) | service |
| `NOT_FOUND` | 404 | resource absent **or** unauthorized access (same response) | service |
| `CONFLICT` | 409 | unique constraint violation, state transition conflict | service / DB |
| `PAYLOAD_TOO_LARGE` | 413 | body size exceeded | the body size guard |
| `INTERNAL` | 500 | unexpected exception | `onError` |

Pick codes from this table only. If you need a new one, add it to the table first — it is the contract the SPA branches on.

## AppError and global handling (`src/http/errors.ts`)

```ts
import type { Context } from 'hono'
import { HTTPException } from 'hono/http-exception'
import { log } from '@/http/logger'

export type ErrorStatus = 400 | 401 | 403 | 404 | 409 | 413 | 415 | 429 | 500
export type ErrorCode =
  | 'VALIDATION_FAILED' | 'UNAUTHENTICATED' | 'FORBIDDEN' | 'NOT_FOUND'
  | 'CONFLICT' | 'PAYLOAD_TOO_LARGE' | 'UNSUPPORTED_MEDIA_TYPE' | 'RATE_LIMITED' | 'INTERNAL'

export class AppError extends Error {
  constructor(
    readonly status: ErrorStatus,
    readonly code: ErrorCode,
    message: string,
    readonly details?: unknown,
  ) { super(message) }
}

// the status of a framework-thrown HTTPException → the contractual code. A status not in the table folds into 500
const FRAMEWORK_CODES: Partial<Record<number, ErrorCode>> = {
  400: 'VALIDATION_FAILED', 401: 'UNAUTHENTICATED', 403: 'FORBIDDEN',
  404: 'NOT_FOUND', 409: 'CONFLICT', 413: 'PAYLOAD_TOO_LARGE',
  415: 'UNSUPPORTED_MEDIA_TYPE', 429: 'RATE_LIMITED',
}

export const notFound = (c: Context) =>
  c.json({ error: { code: 'NOT_FOUND', message: 'Not found' }, requestId: c.get('requestId') }, 404)

export const onError = (err: Error, c: Context) => {
  const requestId = c.get('requestId')
  if (err instanceof AppError) {
    if (err.status >= 500) log.error({ msg: err.message, code: err.code, requestId })
    if (err.status === 401) c.header('WWW-Authenticate', 'Bearer')   // the standard challenge header
    return c.json({ error: { code: err.code, message: err.message, details: err.details }, requestId },
      err.status)
  }
  if (err instanceof HTTPException) {                       // thrown by the framework
    const code = FRAMEWORK_CODES[err.status]
    if (!code) {
      log.error({ msg: 'unmapped framework error', status: err.status, requestId })
      return c.json({ error: { code: 'INTERNAL', message: 'Internal Server Error' }, requestId }, 500)
    }
    if (err.status === 401) c.header('WWW-Authenticate', 'Bearer')
    return c.json({ error: { code, message: err.message }, requestId }, err.status as ErrorStatus)
  }
  log.error({ msg: 'unhandled error', error: String(err), stack: err.stack, requestId })
  return c.json({ error: { code: 'INTERNAL', message: 'Internal Server Error' }, requestId }, 500)
}
```

**Throw errors, and map them in one place only.** A try/catch in every handler makes the envelope diverge.

Why `err.getResponse()` is not returned as it is: the framework response has neither `error.code` nor
`requestId`, so the contract "the SPA branches on `code` only" breaks on that path alone. **Take the status code only
and rebuild the body as our envelope.** Conversely, mashing every `HTTPException` into `VALIDATION_FAILED`
puts a `VALIDATION_FAILED` code on a 413 response, and the 413 row of the code table is never produced —
middleware that decides its own status, such as `bodyLimit`, must either register that status in the table above (`FRAMEWORK_CODES`)
or be brought inside the contract by throwing an `AppError` through the `onError` option, as in `app.ts`.

## Turn PostgreSQL errors into domain responses

Do not let a driver error flow through as a 500. A constraint violation is a 409 the user can fix.

```ts
// src/db/errors.ts
export function isUniqueViolation(err: unknown, constraint?: string): boolean {
  const e = err as { code?: string; constraint?: string }
  return e?.code === '23505' && (constraint === undefined || e.constraint === constraint)
}

// in the service
try {
  return await insertTask(ownerId, input)
} catch (err) {
  if (isUniqueViolation(err, 'tasks_owner_title_key')) {
    throw new AppError(409, 'CONFLICT', 'A task with the same title already exists')
  }
  throw err                                    // an unknown error is raised, not swallowed
}
```

The main SQLSTATEs: `23505` unique violation (409), `23503` FK violation (409 or 400), `23514` check
violation (400), `22P02` invalid text→type conversion (400 — usually Zod should catch it first).

## Body size and timeouts

- Apply a body size limit globally: register `bodyLimit` (`hono/body-limit`) on `/api/*`.
  **The default `onError` knows nothing of our envelope** — you have to pass an `onError` that throws
  `AppError(413, 'PAYLOAD_TOO_LARGE')`, as in `app.ts` above, for the 413 to go out per the code table. Even behind an ALB the application cuts it off itself
- Put a request timeout shorter than the ALB idle timeout in the service layer. Pass
  `AbortSignal.timeout(ms)` to external calls — so an unresponsive dependency does not lock a worker

## Misuse list (confused pairs)

| Frequently chosen wrongly | The exact condition for each |
| --- | --- |
| `c.json(null, 204)` | A 204 has no body → use `c.body(null, 204)` |
| `c.req.param('id')` vs `c.req.query('id')` | A path segment is `param`, `?id=` is `query`. Both are strings, so parse them with Zod |
| Using `await c.req.json()` directly | With a missing body or broken JSON it simply throws → wrap it in `jsonBody(c, Schema)` to produce the 400 envelope |
| `c.req.query()` vs `c.req.queries()` | A single value is `query()`; a repeated key (`?tag=a&tag=b`) gives an array through `queries()` |
| `throw new HTTPException(404)` | That is a framework error — throw an `AppError` for a domain failure so `code` matches the contract |
| `app.use(mw)` vs `app.use('/api/*', mw)` | A pathless `use` applies to every path → even the health check gets authentication and the ALB kills the task |
| Mounting a public route behind `requireAuth` | It deadlocks: you have to sign in to get the login URL → register `/api/auth` **before** `requireAuth` |
| `app.route()` vs `app.mount()` | Combining Hono sub-apps is `route()`. `mount()` is only for attaching a handler from another framework |
| Exposing `err.message` as-is in an error response | For the 500 family send only a fixed phrase and put the original in the log |
| 200 + `{ ok: false }` | The SPA's fetch wrapper treats it as success → a failure must always carry a 4xx/5xx status |
| A try/catch in every handler | The envelope ends up different everywhere → gather it into one `onError` |
