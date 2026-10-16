<!-- orangekit-pack: backend/fastify v3.33.0 -->
# Error handling — one domain code yields both the status and the envelope

This file owns `src/http/errors.ts` (the status table · normalization · SQLSTATE detection). `AppError` · `ErrorCode`
(`src/http/app-error.ts`) and the envelope-emitting `errorHandler` (`src/http/error-handler.ts`) are **owned by the
seam** — because the envelope shape is a function of the wire contract. This file only supplies the axis-local
parts those two lean on.

## 1. Judgment — what does this failure go out as

| where the failure comes from | arrives as | how to tell | domain code |
| --- | --- | --- | --- |
| an `AppError` thrown by a handler or query | `AppError` | `instanceof` | as-is |
| a route schema violation | `Error` + `validation[]` | `Array.isArray(err.validation)` | `VALIDATION_FAILED` |
| broken JSON · empty JSON body | `FastifyError` | `code` `FST_ERR_CTP_INVALID_JSON_BODY` · `FST_ERR_CTP_EMPTY_JSON_BODY` | `VALIDATION_FAILED` |
| body over the limit | `FastifyError` | `FST_ERR_CTP_BODY_TOO_LARGE` | `PAYLOAD_TOO_LARGE` |
| a Content-Type with no parser | `FastifyError` | `FST_ERR_CTP_INVALID_MEDIA_TYPE` | `UNSUPPORTED_MEDIA_TYPE` |
| a unique violation | `DrizzleQueryError` | `cause.code === '23505'` | `CONFLICT` |
| a response schema mismatch · anything else | anything | — | `INTERNAL` |

<!-- verified: fastify@5.12.7 + drizzle-orm@0.45.4 — for each row, the constructor · code · statusCode · validation of the err arriving at setErrorHandler observed through inject (2026-10-15) -->

**Do not trust `err.statusCode` as-is.** Fastify's request-stage errors arrive carrying a `statusCode` (400 · 413 ·
415), but put that number in the response and the status gets decided in two places (`ERROR_STATUS` and Fastify).
Map the code string to a domain code, and let one table decide the status.

## 2. The status table and normalization (`src/http/errors.ts`)

<!-- file: src/http/errors.ts -->
```ts
// src/http/errors.ts
import { AppError, type ErrorCode } from './app-error'

// Domain code → HTTP status. The only table that decides status codes
export const ERROR_STATUS: Record<ErrorCode, number> = {
  VALIDATION_FAILED: 400,
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  PAYLOAD_TOO_LARGE: 413,
  UNSUPPORTED_MEDIA_TYPE: 415,
  INTERNAL: 500,
}

type ValidationIssue = { instancePath: string; message?: string; params?: { keys?: string[] } }

// Fastify validation error (err.validation) → field errors. For unknown keys the path is '/' and the key names are in params.keys
export function fieldErrors(issues: readonly ValidationIssue[]): Record<string, string[]> {
  const out: Record<string, string[]> = {}
  for (const i of issues) {
    const keys = i.instancePath === '/' && i.params?.keys ? i.params.keys : [i.instancePath.slice(1).replaceAll('/', '.') || '_']
    for (const k of keys) (out[k] ??= []).push(i.message ?? 'invalid')
  }
  return out
}

// Drizzle wraps driver errors in DrizzleQueryError — the SQLSTATE is on cause
function sqlState(e: unknown): string | undefined {
  const cause = (e as { cause?: { code?: unknown } } | null)?.cause
  return typeof cause?.code === 'string' ? cause.code : undefined
}

export function isUniqueViolation(e: unknown): boolean {
  return sqlState(e) === '23505'
}

// Error fields to put in the log. DrizzleQueryError carries the SQL and the **bound values** in message and stack —
// log { err } whole and user data lands in the log in plain text. For DB errors, log only the SQLSTATE
export function errorLogFields(e: unknown): Record<string, unknown> {
  const err = e as { name?: unknown; message?: unknown; stack?: unknown; cause?: { code?: unknown; constraint?: unknown; table?: unknown } } | null
  const state = sqlState(e)
  if (state) return { type: 'db', sqlState: state, constraint: err?.cause?.constraint, table: err?.cause?.table }
  return { type: err?.name, message: err?.message, stack: err?.stack }
}

// Request-stage errors Fastify throws on its own — identified by the code string (do not trust statusCode alone)
const FASTIFY_CODES: Record<string, ErrorCode> = {
  FST_ERR_CTP_INVALID_JSON_BODY: 'VALIDATION_FAILED',
  FST_ERR_CTP_EMPTY_JSON_BODY: 'VALIDATION_FAILED',
  FST_ERR_CTP_BODY_TOO_LARGE: 'PAYLOAD_TOO_LARGE',
  FST_ERR_CTP_INVALID_MEDIA_TYPE: 'UNSUPPORTED_MEDIA_TYPE',
}

// Normalize an unknown throw into an AppError. errorHandler calls this first
export function toAppError(e: unknown): AppError {
  if (e instanceof AppError) return e
  const err = e as { code?: unknown; validation?: ValidationIssue[] } | null
  if (err && Array.isArray(err.validation)) {
    return new AppError('VALIDATION_FAILED', 'Invalid input', fieldErrors(err.validation))
  }
  if (isUniqueViolation(e)) return new AppError('CONFLICT', 'Already exists')
  const mapped = typeof err?.code === 'string' ? FASTIFY_CODES[err.code] : undefined
  if (mapped) return new AppError(mapped, 'The request could not be processed')
  // The cause's message never goes in the response — a DrizzleQueryError's message is the full SQL
  return new AppError('INTERNAL', 'Internal server error')
}
```

Because `ERROR_STATUS` is typed `Record<ErrorCode, number>`, if the seam adds a code to `ErrorCode` without updating
the table it is **a compile error**. Leave it as `Record<string, number>` and a missing code silently becomes
`undefined` → 500.

## 3. The real shape of validation issues — for an unknown key the path is `/`

<!-- verified: fastify-type-provider-zod@7.0.0 — real err.validation output for the body { title: '', x: 1 } (2026-10-15) -->

```json
[
  { "keyword": "too_small", "instancePath": "/title", "message": "Too small: expected string to have >=1 characters" },
  { "keyword": "unrecognized_keys", "instancePath": "/", "message": "Unrecognized key: \"x\"", "params": { "keys": ["x"] } }
]
```

Use `instancePath` as the key as-is and every unknown key collapses into a single `""` (empty key). `fieldErrors`
spreads `params.keys` to produce `{ title: [...], x: [...] }` — for the client to attach errors to form fields, the
keys have to be field names. The "unknown key and empty title" test in `testing.md` asserts this shape.

`err.validationContext` (`body` · `querystring` · `params`) does not go in the envelope — it only matters when field
names collide, and in this pack's schemas they do not.

## 4. The SQLSTATE is on `cause` — and `message` is SQL

Drizzle 0.45 wraps driver errors in `DrizzleQueryError`. The outer object has no `code`.

<!-- verified: drizzle-orm@0.45.4 + pg@8.23.1 — err from a duplicate insert: ctor DrizzleQueryError, err.code undefined, err.cause DatabaseError code '23505' (2026-10-15) -->

```ts
// src/http/errors.ts
// ❌ Reads the outer error's code — DrizzleQueryError has none, so every unique violation becomes a 500
const dup = (e as { code?: string }).code === '23505'
// ✅ Reads it from the wrapped cause
const dup2 = isUniqueViolation(e)
```

The `message` of the same error is **the full SQL**, starting with
`Failed query: insert into "tasks" ("id", "owner_id", "title", …) values …`. That is why `toAppError` discards the
cause's message and uses a fixed phrase, and why the 409 test in `testing.md` asserts the response body contains no
`insert into`.

**Do not put `{ err }` whole into the log either.** Its message and stack carry the **bound values** along with the
SQL — a single unique violation leaves what the user sent in the log in plain text, and redact only masks header
paths. `errorLogFields` reduces a DB error to the SQLSTATE, constraint name, and table
<!-- verified: observed by intercepting the log with pino — logging { err } whole printed the bound value 'hunter2-secret', while errorLogFields did not and left only 23505 (2026-10-15) -->.

## 5. Handlers throw — failures are not written with `reply.code().send()`

```ts
// src/http/routes/tasks.ts (owned by the seam)
// ❌ The handler builds the failure envelope — the same 404 goes out in a different shape from the root envelope
if (!task) return reply.code(404).send({ message: 'not found' })
// ✅ Throw, and the root errorHandler applies the table and the envelope
if (!task) throw new AppError('NOT_FOUND', 'Task not found')
```

`setNotFoundHandler` throws too (`project-structure.md` §2) — a missing route and a missing resource share an
envelope. `reply` is used only for **the status and headers of a success response** (201 + `Location`, 204).

## 6. Do not leak existence

| situation | response | log |
| --- | --- | --- |
| a task that does not exist | 404 `NOT_FOUND` | `task missing or not owned` + `taskId` |
| someone else's task | 404 `NOT_FOUND` — **the body is byte-for-byte identical** | the same line as above |
| why authentication failed (expired token · bad signature · no account) | one 401 | distinguished per reason |

The log level is decided by **the final status**: `info` for 4xx, `error` for 5xx — a unique violation that ends as a
409 is `info`. Log 4xx as `error` and scanner traffic drowns out the alerts. The "missing or not owned" line is
logged by the route (seam) with `req.log.info` right before it throws `NOT_FOUND`.

`FASTIFY_CODES` holds only the four codes we observed. A request-stage error not in the table (a bad Content-Length
and the like) falls through to `INTERNAL` — recorded in `knownGaps` in `pack.json`.

## 7. The test that proves this file's promises (`src/test/tasks.input.test.ts`)

It asserts, by running, the 409 with no SQL exposed · field errors for unknown keys · partial updates · the 400 for
tampered cursors and NUL · the envelope for a missing route. Configuration and fixtures are in `testing.md` §2 · §3.

<!-- file: src/test/tasks.input.test.ts -->
```ts
// src/test/tasks.input.test.ts
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { buildApp, type App } from '../app'
import { pool } from '../db/client'
import { resetDb, seedTask } from './db'
import { authFor } from './auth'

let app: App
beforeAll(async () => { app = await buildApp({ logger: false }) })
afterAll(async () => { await app.close(); await pool.end() })
beforeEach(resetDb)

describe('input · error envelope', () => {
  it('create → 201 + Location, recreating the same title → 409', async () => {
    const first = await app.inject({ method: 'POST', url: '/api/tasks', headers: authFor('alice'), payload: { title: 'one' } })
    expect(first.statusCode).toBe(201)
    expect(first.headers.location).toBe(`/api/tasks/${first.json().id}`)
    const dup = await app.inject({ method: 'POST', url: '/api/tasks', headers: authFor('alice'), payload: { title: 'one' } })
    expect(dup.statusCode).toBe(409)
    expect(dup.json().error.code).toBe('CONFLICT')
    expect(dup.body).not.toContain('insert into')
  })

  it('an unknown key and an empty title are a 400 with field errors per key', async () => {
    const res = await app.inject({ method: 'POST', url: '/api/tasks', headers: authFor('alice'), payload: { title: '', priority: 1 } })
    expect(res.statusCode).toBe(400)
    expect(Object.keys(res.json().error.details).sort()).toEqual(['priority', 'title'])
  })

  it('a partial update does not change fields that were not sent', async () => {
    const t = await seedTask('alice', { title: 'unchanged', status: 'done' })
    const res = await app.inject({ method: 'PATCH', url: `/api/tasks/${t.id}`, headers: authFor('alice'), payload: { title: 'changed' } })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toMatchObject({ title: 'changed', status: 'done' })
  })

  it('a tampered cursor and a NUL character are a 400, not a 500', async () => {
    const bad = ['2030-01-01T00:00:00.000Z_notuuid', '+275760-09-13T00:00:00.000Z_00000000-0000-4000-8000-000000000000', 'garbage']
    for (const c of bad) {
      const res = await app.inject({ url: `/api/tasks?cursor=${encodeURIComponent(c)}`, headers: authFor('alice') })
      expect(res.statusCode, c).toBe(400)
    }
    const ok = await app.inject({ url: `/api/tasks?cursor=${encodeURIComponent('2030-01-01T00:00:00.000Z_00000000-0000-4000-8000-000000000000')}`, headers: authFor('alice') })
    expect(ok.statusCode).toBe(200)
    const nul = await app.inject({ method: 'POST', url: '/api/tasks', headers: authFor('alice'), payload: { title: 'a\u0000b' } })
    expect(nul.statusCode).toBe(400)
  })

  it('a missing route is a 404 in the same envelope', async () => {
    const res = await app.inject({ url: '/nope' })
    expect(res.statusCode).toBe(404)
    expect(res.json().error.code).toBe('NOT_FOUND')
  })
})
```

## Misuse list ① — Express · Prisma habits → Fastify 5 + Drizzle idioms

| old habit | current form |
| --- | --- |
| a 4-argument error middleware `(err, req, res, next)` | `app.setErrorHandler(errorHandler)` at the root — 3 arguments `(err, req, reply)` |
| telling a validation failure apart with `err instanceof ZodError` | `Array.isArray(err.validation)` — the type provider converts it to Fastify's shape on the way |
| `e.code === 'P2002'` | `e.cause.code === '23505'` |
| `res.status(err.status ?? 500)` | `ERROR_STATUS[app.code]` — one table for the status |
| `next(err)` | `throw err` — an async handler's rejection is the error path |

## Misuse list ② — confusable pairs

| often picked wrong | exact condition |
| --- | --- |
| `err.statusCode` vs `ERROR_STATUS` | the response status is always the latter. The former is only an input to the mapping |
| `err.message` vs `AppError.message` | only the latter in the response. The former goes to the log |
| `FORBIDDEN` vs `NOT_FOUND` | the latter wherever ownership must not be revealed. The former only for a missing role on a resource whose existence is already known |
| mapping `22P02` to `VALIDATION_FAILED` vs blocking at the boundary | the latter. If `22P02` shows up in the log, do not extend the mapping — find the missing `z.uuid()`. That it reached the DB is the defect |
