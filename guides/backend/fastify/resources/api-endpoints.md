<!-- orangekit-pack: backend/fastify v3.36.0 -->
# API endpoints — route plugin · response envelope · error envelope

This file owns `src/http/app-error.ts` (`AppError` · `ErrorCode`) · `src/http/error-handler.ts` (`errorHandler`) ·
`src/http/routes/tasks.ts` (`tasksRoutes`). The status table and normalization (`ERROR_STATUS` · `toAppError`) are
owned by `resources/error-handling.md`, the place that registers the routes (`buildApp`) by
`resources/project-structure.md`, and `requireAuth` by `resources/auth-boundaries.md`.

The wire values follow the repository's `guides/contracts/http-standard.md` (HTTP standard v1). **If the project has
its own API spec (e.g. `dev/docs/api/`), that is canonical**, and the paths · codes · statuses here are pattern
examples.

## 1. Judgment — endpoints and envelopes

| request | success | body | failure (code) |
| --- | --- | --- | --- |
| `GET /api/tasks?limit&cursor&status` | 200 | `{ data: Task[], nextCursor }` | 400 (cursor · query) · 401 |
| `GET /api/tasks/:id` | 200 | `{ data: Task }` | 400 (not a uuid) · 401 · 404 |
| `POST /api/tasks` | 201 + `Location` | `{ data: Task }` | 400 · 401 · 409 · 413 · 415 |
| `PATCH /api/tasks/:id` | 200 | `{ data: Task }` | 400 · 401 · 404 · 409 |
| `DELETE /api/tasks/:id` | 204 | none | 401 · 404 |

A failure is always the one shape `{ error: { code, message, details? }, requestId }`. `details` is carried only on a
validation failure, as `Record<string, string[]>` (a form-wide error uses the key `_`). The request ID also goes out
in the `x-request-id` response header — the root `onRequest` hook in `buildApp` sets it so that even a bodiless
response like a 204 can be traced.

**Do not strip the success envelope.** A single item is wrapped in `{ data }` too — only when the list and the single
item share the same unwrapping rule can one client open every response with the same function. The wire fields of
`Task` are exactly four, `id` · `title` · `status` · `createdAt`, and `ownerId` is not carried (the response schema
filters it — `resources/input-validation.md` §5).

## 2. Domain codes (`src/http/app-error.ts`)

<!-- file: src/http/app-error.ts -->
```ts
// src/http/app-error.ts
// Every server code in wire contract §4. ERROR_STATUS is Record<ErrorCode, number>, so missing even one is a compile error
export type ErrorCode =
  | 'VALIDATION_FAILED'
  | 'UNAUTHENTICATED'
  | 'FORBIDDEN'
  | 'NOT_FOUND'
  | 'CONFLICT'
  | 'PAYLOAD_TOO_LARGE'
  | 'UNSUPPORTED_MEDIA_TYPE'
  | 'RATE_LIMITED'
  | 'INTERNAL'

// A pure error class — knows nothing about HTTP status. The data layer throwing it does not invert the dependency
export class AppError extends Error {
  readonly code: ErrorCode
  readonly details?: Record<string, string[]>

  constructor(code: ErrorCode, message: string, details?: Record<string, string[]>) {
    super(message)
    this.name = 'AppError'
    this.code = code
    this.details = details
  }
}
```

`message` is **a phrase the user may see**. The cause (driver message · SQL) does not go here — the moment it does, it
goes out in the response. Parameter properties (`constructor(readonly code …)`) are avoided so that this compiles
unchanged under a tsconfig with `erasableSyntaxOnly` on.

## 3. Emitting the envelope (`src/http/error-handler.ts`)

<!-- file: src/http/error-handler.ts -->
```ts
// src/http/error-handler.ts
import type { FastifyError, FastifyReply, FastifyRequest } from 'fastify'
import { ERROR_STATUS, errorLogFields, toAppError } from './errors'

// Set once at the root with setErrorHandler. One table decides the status, this one function decides the envelope
export function errorHandler(err: FastifyError, req: FastifyRequest, reply: FastifyReply): FastifyReply {
  const app = toAppError(err)
  const status = ERROR_STATUS[app.code]
  // The log level is decided by the final status — log 4xx as error and scanner traffic drowns out the alerts
  if (status >= 500) req.log.error({ err: errorLogFields(err) }, 'request failed')
  else req.log.info({ code: app.code }, 'request rejected')
  return reply
    .code(status)
    .header('x-request-id', req.id)
    .send({
      error: { code: app.code, message: app.message, ...(app.details ? { details: app.details } : {}) },
      requestId: req.id,
    })
}
```

Do not put `{ err }` in the log whole — a `DrizzleQueryError`'s message carries the SQL and the bound values
(`resources/error-handling.md` §4). `req.id` is the UUID made by `genReqId` in `buildApp`. Why the incoming
`x-request-id` is not trusted as-is: if a client-chosen value becomes the log correlation key, it can be mixed up with
someone else's request.

## 4. Paths that bypass the handler — all in the same envelope

Errors raised before the router is reached are the latest to be discovered on this axis. For each row of contract §7,
pin down what receives that path in Fastify.

| path | shape it arrives in on Fastify | result |
| --- | --- | --- |
| a missing route | the root `setNotFoundHandler` throws `AppError('NOT_FOUND')` | 404 `NOT_FOUND` |
| a method not allowed (`PUT /api/tasks`) | Fastify does not emit 405; it sends it to the same 404 handler | 404 `NOT_FOUND` |
| broken JSON · `Content-Type: application/json` + empty body | `FST_ERR_CTP_INVALID_JSON_BODY` · `FST_ERR_CTP_EMPTY_JSON_BODY` | 400 `VALIDATION_FAILED` |
| body over the limit | `FST_ERR_CTP_BODY_TOO_LARGE` (`bodyLimit` = `env.BODY_LIMIT_BYTES`) | 413 `PAYLOAD_TOO_LARGE` |
| a non-JSON body | `FST_ERR_CTP_INVALID_MEDIA_TYPE` | 415 `UNSUPPORTED_MEDIA_TYPE` |
| the auth hook | `requireAuth` throws `AppError('UNAUTHENTICATED')` | 401 `UNAUTHENTICATED` |
| a rate-limiter plugin | the self-issued variant puts it only on `/api/auth` (login · refresh) — a 429 maps to `RATE_LIMITED` (`toAppError`) | 429 `RATE_LIMITED` |
| an uncaught exception | anything → the `toAppError` fallback | 500 `INTERNAL` — the cause goes to the log only |

**`text/plain` is not a 415.** Fastify ships parsers for `application/json` and `text/plain` by default — a
`text/plain` body is parsed and then becomes a 400 at the body schema. To see a 415, send a type with no parser
(`application/xml` and the like). The test below asserts each row with a real request.

<!-- file: src/test/envelope.test.ts -->
```ts
// src/test/envelope.test.ts
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { buildApp, type App } from '../app'
import { pool } from '../db/client'
import { env } from '../env'
import { resetDb } from './db'
import { authFor } from './auth'

let app: App
beforeAll(async () => { app = await buildApp({ logger: false }) })
afterAll(async () => { await app.close(); await pool.end() })
beforeEach(resetDb)

const post = (payload: string, type: string) =>
  app.inject({ method: 'POST', url: '/api/tasks', headers: { ...authFor('alice'), 'content-type': type }, payload })

describe('paths that bypass the handler', () => {
  it('a normal create is a 201, and parser-stage failures are the same envelope with the contract code', async () => {
    expect((await post('{"title":"normal"}', 'application/json')).statusCode).toBe(201)
    const cases: [string, string, number, string][] = [
      ['{"title":', 'application/json', 400, 'VALIDATION_FAILED'],
      ['<task/>', 'application/xml', 415, 'UNSUPPORTED_MEDIA_TYPE'],
      [JSON.stringify({ title: 'x'.repeat(env.BODY_LIMIT_BYTES) }), 'application/json', 413, 'PAYLOAD_TOO_LARGE'],
    ]
    for (const [payload, type, status, code] of cases) {
      const res = await post(payload, type)
      expect(res.statusCode, code).toBe(status)
      expect(res.json().error.code).toBe(code)
      expect(res.json().requestId).toBe(res.headers['x-request-id'])
    }
  })

  it('a registered method is a 200, and a missing method is a 404 envelope, not a 405', async () => {
    expect((await app.inject({ url: '/api/tasks', headers: authFor('alice') })).statusCode).toBe(200)
    const res = await app.inject({ method: 'PUT', url: '/api/tasks', headers: authFor('alice') })
    expect(res.statusCode).toBe(404)
    expect(res.json().error.code).toBe('NOT_FOUND')
  })

  it('an uncaught exception is a 500 INTERNAL and the cause phrase does not leak', async () => {
    const probe = await buildApp({ logger: false })
    probe.get('/boom', async () => { throw new Error('password=hunter2') })
    probe.get('/fine', async () => ({ ok: true }))
    expect((await probe.inject({ url: '/fine' })).statusCode).toBe(200)
    const res = await probe.inject({ url: '/boom' })
    expect(res.statusCode).toBe(500)
    expect(res.json().error.code).toBe('INTERNAL')
    expect(res.body).not.toContain('hunter2')
    await probe.close()
  })
})
```

<!-- unverified: the four FST_ERR_CTP_* rows and the 404 in this table carry over the run observations (fastify@5.12.7) from resources/error-handling.md. This test file itself and the 405→404 · text/plain parser rows were not run -->

## 5. The route plugin (`src/http/routes/tasks.ts`)

<!-- file: src/http/routes/tasks.ts -->
```ts
// src/http/routes/tasks.ts
import type { FastifyPluginAsyncZod } from 'fastify-type-provider-zod'
import { z } from 'zod'
import { deleteTask, encodeCursor, getTask, insertTask, listTasks, updateTask } from '../../db/tasks'
import { TaskCreateSchema, TaskParamsSchema, TaskQuerySchema, TaskUpdateSchema, TaskViewSchema } from '../../schemas/task'
import { AppError } from '../app-error'
import { requireAuth, type AuthUser } from '../require-auth'

// Response schema = serialization boundary. The envelope has to be in the schema for ownerId to be filtered inside data too
const One = z.object({ data: TaskViewSchema })
const Page = z.object({ data: z.array(TaskViewSchema), nextCursor: z.string().nullable() })

// Even if called in a context missing the hook, it closes as a 401, not a 500 (assertion failure)
function ownerOf(user: AuthUser | undefined): string {
  if (!user) throw new AppError('UNAUTHENTICATED', 'Authentication required')
  return user.id
}

export const tasksRoutes: FastifyPluginAsyncZod = async (app) => {
  // The first line of the body — reaches only this context's routes. Never set it on a sibling or the root
  app.addHook('onRequest', requireAuth)

  app.get('/', { schema: { querystring: TaskQuerySchema, response: { 200: Page } } }, async (req) => {
    const data = await listTasks(ownerOf(req.user), req.query)
    const last = data.at(-1)
    return { data, nextCursor: last && data.length === req.query.limit ? encodeCursor(last) : null }
  })

  app.get('/:id', { schema: { params: TaskParamsSchema, response: { 200: One } } }, async (req) => {
    const task = await getTask(ownerOf(req.user), req.params.id)
    if (!task) {
      // Absence and non-ownership are logged without distinction — the two responses are byte-for-byte identical
      req.log.info({ taskId: req.params.id }, 'task missing or not owned')
      throw new AppError('NOT_FOUND', 'Task not found')
    }
    return { data: task }
  })

  app.post('/', { schema: { body: TaskCreateSchema, response: { 201: One } } }, async (req, reply) => {
    const task = await insertTask(ownerOf(req.user), req.body)
    return reply.code(201).header('location', `/api/tasks/${task.id}`).send({ data: task })
  })

  app.patch('/:id', { schema: { params: TaskParamsSchema, body: TaskUpdateSchema, response: { 200: One } } }, async (req) => {
    return { data: await updateTask(ownerOf(req.user), req.params.id, req.body) }
  })

  app.delete('/:id', { schema: { params: TaskParamsSchema } }, async (req, reply) => {
    await deleteTask(ownerOf(req.user), req.params.id)
    return reply.code(204).send()
  })
}
```

`nextCursor` is built only when this page filled up to `limit`. When the row count is an exact multiple of `limit`,
one extra empty page comes at the end — the client stops at `nextCursor: null`, so the result is not wrong
(`resources/data-access.md` §5). The 404 for update and delete is thrown by the data layer from the affected row
count — the route does not read again.

## Misuse list ① — Express · seam-era habits → Fastify 5 + contract v1 idioms

| old habit | current form |
| --- | --- |
| a single item as `return task` (no envelope) | `return { data: task }` + the response schema `One` — the same unwrapping rule as the list |
| a list as `{ items, nextCursor }` | `{ data, nextCursor }` — contract §1. Let the names diverge and the client differs per backend |
| a failure as `reply.code(404).send({ message })` | `throw new AppError('NOT_FOUND', …)` — the envelope is in one place, the root `errorHandler` |
| `res.status(err.statusCode ?? 500)` | `ERROR_STATUS[app.code]` — the `statusCode` Fastify attaches is only an input to the mapping |
| building a separate 405 | a missing method is a 404 `NOT_FOUND` too — contract §7 allows both, and Fastify's default is 404 |
| `req.user!.id` | `ownerOf(req.user)` — a route that missed the hook wiring closes as a 401, not a 500 |

## Misuse list ② — confusable pairs

| what is often picked wrong | exact condition for applying it |
| --- | --- |
| `return x` vs `return reply.code(201).send(x)` | the former for the default status (200). The latter only when changing the status or headers — use both and you get "Reply was already sent" |
| testing 415 with `text/plain` vs `application/xml` | the latter. Fastify ships a `text/plain` parser by default, so it becomes a 400 |
| `Content-Type: application/json` (no body) on a `DELETE` vs no header | the latter. The former is a 400 via `FST_ERR_CTP_EMPTY_JSON_BODY` — the client sets that header only when there is a body |
| the incoming `x-request-id` vs `genReqId` | the latter. A client-chosen value is not used as the correlation key |
| `FORBIDDEN` vs `NOT_FOUND` (someone else's task) | the latter. The former only for a missing role on a resource whose existence is already known |
