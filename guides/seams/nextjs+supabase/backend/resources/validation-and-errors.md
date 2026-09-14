<!-- orangekit-seam: nextjs+supabase/backend v3.12.0 -->
# Input Validation (Zod v4) & Error Handling

Two halves of one contract: what comes in is validated, what goes out is mapped.

## Where schemas live

- One file per feature: `lib/validations/<feature>.ts`
- The **same schema** is imported by the Route Handler, the Server Action, and tests — never duplicate a schema inline in a handler.
- Handlers always use `safeParse` (branch on the result). `.parse()` throws and belongs
  only in code where a failure is a programmer error, not user input.

## Zod v4 idioms (this project uses v4, not v3)

| v3 habit | v4 form used here |
| --- | --- |
| `z.string().email()` | `z.email()` |
| `z.string().uuid()` | `z.uuid()` |
| `{ message: 'Required' }` | `{ error: 'Required' }` |
| the error's flatten method | `z.flattenError(result.error)` |
| the error's format method | `z.treeifyError(result.error)` |

## Body schemas

```ts
// lib/validations/task.ts
import { z } from 'zod'

export const createTaskSchema = z.object({
  title: z.string().trim().min(1, { error: 'Title is required' }).max(200),
  content: z.string().max(10_000).default(''),
  tags: z.array(z.string().trim().min(1)).max(20).default([]),
})

// Updates: every field optional, same rules when present
export const updateTaskSchema = createTaskSchema.partial()

export type CreateTaskInput = z.infer<typeof createTaskSchema>
```

- `.trim()` before `.min(1)` — a whitespace-only title must fail.
- `.default()` makes a field optional on input while keeping the output type required.
- Unknown keys are stripped by default; use `z.strictObject({...})` when an unknown key should be a 400 instead.

## Query-param schemas

Query params arrive as strings — coerce them, and build the input with
`Object.fromEntries(request.nextUrl.searchParams)` so absent keys stay `undefined` and
defaults apply:

```ts
export const taskListQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  perPage: z.coerce.number().int().min(1).max(100).default(20),
  q: z.string().trim().max(200).optional(),
  // Sort column MUST be a whitelist, never a raw string (see below)
  sort: z.enum(['created_at', 'title']).default('created_at'),
  order: z.enum(['asc', 'desc']).default('desc'),
})
```

- Always cap `perPage` (`.max(100)`) — an uncapped page size is a self-DoS input.
- **Never pass an unvalidated string to `.order()`.** PostgREST accepts any column name, so
  `?sort=password_hash` turns error/ordering behavior into a column-existence oracle and can
  expose a column you never selected. Only enum members reach the query.
- Every declared param must have a consumer. A param the handler ignores (`q` defined but
  never applied) is a silent contract lie — either wire it up or delete it.

## FormData realities (Server Actions)

`FormData` values are only `string | File` — no booleans, no numbers, no `undefined`.
Empty inputs arrive as `''`, unchecked checkboxes are **absent**, checked ones are `'on'`.
Normalize with `z.preprocess` so `.optional()`/`.default()` behave:

```ts
// Empty string → undefined, so optional fields validate as "not provided"
const optionalText = z.preprocess((v) => (v === '' || v === null ? undefined : v),
  z.string().trim().max(500).optional())

// Checkbox: 'on' when checked, absent otherwise → boolean
const checkbox = z.preprocess((v) => v === 'on', z.boolean())

export const updateProfileSchema = z.object({
  name: z.string().trim().min(1, { error: 'Name is required' }).max(100),
  bio: optionalText,
  newsletter: checkbox,
})
```

Without the preprocess, an empty optional field fails as `""` (too short) instead of absent — a classic form-only bug that never shows up in JSON tests.

## The safeParse pattern

```ts
const parsed = createTaskSchema.safeParse(body)
if (!parsed.success) {
  return fail(400, 'validation_error', 'Invalid input',
    z.flattenError(parsed.error).fieldErrors)
}
// From here on use parsed.data ONLY — never the raw body again
```

In Server Actions the same failure becomes
`return { ok: false, fieldErrors: z.flattenError(parsed.error).fieldErrors }`.

## Advanced Zod recipes

```ts
// Variant payloads — discriminatedUnion validates exactly the fields of the chosen variant
const paymentSchema = z.discriminatedUnion('method', [
  z.object({ method: z.literal('card'), cardNumber: z.string().length(16),
             expiry: z.string().regex(/^\d{2}\/\d{2}$/) }),
  z.object({ method: z.literal('bank'), accountNumber: z.string().min(10),
             bankCode: z.string() }),
])

// Normalize then re-validate — transform feeds into pipe
const quantitySchema = z.string()
  .transform((v) => Number(v.replace(/,/g, ''))).pipe(z.number().positive())

// Cross-field rules — refine with a path so the error lands on the right field
const dateRangeSchema = z.object({ startDate: z.iso.datetime(), endDate: z.iso.datetime() })
  .refine((d) => new Date(d.startDate) < new Date(d.endDate),
    { error: 'End date must be after start date', path: ['endDate'] })
```

## DB constraint duplication (required)

Every Zod rule that protects data integrity is **duplicated as a Postgres constraint**. Zod
guards the request path; constraints guard every other path (RPC, admin client, SQL console,
future bugs). One without the other is half a defense.

| Zod rule | Postgres duplicate |
| --- | --- |
| `.min(1).max(200)` on a string | `check (char_length(title) between 1 and 200)` |
| `z.uuid()` referencing a row | `uuid` column + `references ... on delete ...` |
| `.default('')` | `not null default ''` |
| `z.email()` uniqueness per user | `unique` index on the column(s) |
| `z.enum([...])` | `check (status in (...))` or a Postgres enum type |
| `.max(20)` on an array | `check (array_length(tags, 1) is null or array_length(tags, 1) <= 20)` |

```sql
-- The DDL twin of createTaskSchema (structure per the T1 data-modeling card)
title   text  not null check (char_length(title) between 1 and 200),
content text  not null default '' check (char_length(content) <= 10000)
```

When a constraint still fires despite Zod (race, bypassed path), the error mapper
below turns it into a clean 400/409 instead of a 500.

## Environment validation — two modules, not one

"Never touch `process.env` directly" is enforced by Zod-validated modules that fail **at
boot**, not at first use in production. It takes **two** files, because public and secret
variables have different rules:

```ts
// lib/env.public.ts — importable from anywhere, server or browser
import { z } from 'zod'

// Next.js inlines NEXT_PUBLIC_* only on STATIC member access (process.env.FOO).
// Passing `process.env` wholesale gives the browser an empty object — so name each key.
export const publicEnv = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.url(),
  NEXT_PUBLIC_SUPABASE_ANON_KEY: z.string().min(1),
}).parse({
  NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
  NEXT_PUBLIC_SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
})
```

```ts
// lib/env.ts — secrets. `server-only` makes a client import a BUILD error, not a leak.
import 'server-only'
import { z } from 'zod'

// .parse (not safeParse): a bad env is a deploy error — crash loudly
export const serverEnv = z.object({
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(1), // never NEXT_PUBLIC_*
}).parse(process.env)
```

Why the split — one combined `envSchema.parse(process.env)` fails twice over: in a client
bundle `process.env` is not the real object, so the `NEXT_PUBLIC_*` keys come back undefined
and `.parse()` throws in the browser; and its schema *names* `SUPABASE_SERVICE_ROLE_KEY`, so
reaching a client graph ships that variable name in the bundle and in the Zod error.

App code imports `publicEnv`/`serverEnv` instead of reading `process.env`. The Supabase
**client-creation modules** (`lib/supabase/server.ts`, `lib/supabase/middleware.ts`) import
`publicEnv` only — they can be pulled into a browser graph, where `server-only` must not follow.

## Error envelope & helpers

```ts
// lib/api/errors.ts
import { NextResponse } from 'next/server'

export const ok = <T,>(data: T, status = 200) => NextResponse.json({ data }, { status })

export const fail = (status: number, code: string, message: string, details?: unknown) =>
  NextResponse.json(
    { error: { code, message, ...(details !== undefined && { details }) } }, { status })

const SUPABASE_ERROR_MAP: Record<string, { status: number; code: string; message: string }> = {
  '23505':  { status: 409, code: 'conflict',             message: 'Resource already exists' },
  '23503':  { status: 400, code: 'invalid_reference',    message: 'Referenced resource does not exist' },
  '23514':  { status: 400, code: 'constraint_violation', message: 'Input violates a data constraint' },
  '23502':  { status: 400, code: 'missing_field',        message: 'A required field is missing' },
  '42501':  { status: 403, code: 'forbidden',            message: 'Not allowed' },
  PGRST116: { status: 404, code: 'not_found',            message: 'Resource not found' },
}

export function fromSupabaseError(error: { code?: string; message?: string }) {
  const mapped = error.code ? SUPABASE_ERROR_MAP[error.code] : undefined
  if (mapped) return fail(mapped.status, mapped.code, mapped.message)
  console.error('[api] unexpected supabase error:', error) // full detail server-side only
  return fail(500, 'internal_error', 'Unexpected server error') // never leak error.message
}
```

## The envelope must survive unexpected throws

`fromSupabaseError` only covers failures returned **inside** a Supabase result. A null
dereference, a third-party SDK that throws, a `JSON.parse` on a bad webhook body — those
escape to Next.js's default handler, which answers with a bare/HTML 500 and breaks the
"every JSON response uses one envelope" guarantee. Wrap every Route Handler:

```ts
// lib/api/handler.ts
import { NextRequest, NextResponse } from 'next/server'
import { fail } from '@/lib/api/errors'

type Handler<C> = (request: NextRequest, context: C) => Promise<NextResponse>

export function route<C>(name: string, handler: Handler<C>): Handler<C> {
  return async (request, context) => {
    try {
      return await handler(request, context)
    } catch (error) {
      // redirect()/notFound() throw control-flow errors — rethrow them untouched
      if (error && typeof error === 'object' && 'digest' in error) throw error
      console.error(`[${name}]`, error)                             // detail: server logs
      return fail(500, 'internal_error', 'Unexpected server error') // generic: client
    }
  }
}

// app/api/tasks/route.ts
export const POST = route('POST /api/tasks', async (request) => { /* … */ })
```

- **Log the cause, return a generic message.** Never put `error.message`, a stack, or a SQL
  string in the response body — the `code` + generic `message` is all a client gets.
- Server Actions have their own version of the same rule: catch, log, and return
  `{ ok: false, formError: 'Something went wrong. Please try again.' }`.
- This is the last line of defense, not a substitute for checking each `error`.

## Error code table (this stack)

| Source code | Meaning | HTTP | `error.code` |
| --- | --- | --- | --- |
| Zod `safeParse` failure | invalid input | 400 | `validation_error` |
| `request.json()` throws | malformed JSON | 400 | `invalid_json` |
| `23502` (not_null) | missing required column | 400 | `missing_field` |
| `23503` (foreign_key) | referenced row missing | 400 | `invalid_reference` |
| `23514` (check) | CHECK constraint failed | 400 | `constraint_violation` |
| `getUser()` → null | no verified session | 401 | `unauthenticated` |
| `42501` (insufficient_privilege) | RLS rejected a write | 403 | `forbidden` |
| `PGRST116` | `.single()` matched **0 rows or more than one** | 404 | `not_found` |
| `23505` (unique) | duplicate value | 409 | `conflict` |
| anything else | unexpected | 500 | `internal_error` |

Existence must not leak: a row the user may not see returns the **same 404** as a row
that does not exist. Never turn `PGRST116` into a 403.

`PGRST116` means "not exactly one row" — it also fires when `.single()` matched **several**,
which is a data-integrity bug (missing unique constraint, over-broad filter), not a missing
resource. Do not let 404 bury it: log before responding, or read with `.limit(2)` +
`.maybeSingle()` so multiplicity surfaces as a 500 someone will investigate.

## Server Action error contract

Actions never throw domain errors — they return a discriminated result:

```ts
// lib/api/types.ts
export type ActionResult =
  | { ok: true }
  | { ok: false; formError?: string; fieldErrors?: Record<string, string[] | undefined> }
```

- Validation failure → `fieldErrors` (rendered next to inputs by `useActionState`); auth/DB/unknown failure → `formError` with a generic message, and log the real one.
- `redirect()` is the one intentional throw — keep it outside `try/catch`.

## Logging rules

- Log the full Supabase/Postgres error object server-side with a `[handler-name]` prefix.
- The client receives only `code` + generic `message` (+ Zod `fieldErrors`).
- Never include SQL, constraint names, or stack traces in a response body.
- Structured-log format, levels, and what must never be logged (PII, secrets):
  `resources/edge-and-operations.md`.
