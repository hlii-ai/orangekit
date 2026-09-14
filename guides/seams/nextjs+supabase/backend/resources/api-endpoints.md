<!-- orangekit-seam: nextjs+supabase/backend v3.12.0 -->
# API Endpoints — Route Handlers & Server Actions

Standard handler shapes and the request/response contract for this stack.

## Route Handler vs Server Action

| Use a Route Handler when... | Use a Server Action when... |
| --- | --- |
| External clients consume it (mobile, webhooks, third parties) | The mutation is triggered from your own React forms/components |
| You need full control of status codes, headers, streaming | You want progressive enhancement + `useActionState` |
| The endpoint is a GET (actions are POST-only) | The mutation should revalidate cached pages in the same call |
| You return files / redirects to external URLs / non-JSON | The payload is a `FormData` from your own UI |

Both run on the server, validate input, and call `getUser()` — neither is "more secure"; a Server Action is a public HTTP endpoint too.

## Response contract (all Route Handlers)

One envelope from the `lib/api/errors.ts` helpers: success `{ "data": … }`, failure
`{ "error": { "code": "validation_error", "message": "Invalid input", "details": { "title": ["Required"] } } }`.

- `code` is stable and machine-readable; `message` is generic — never a raw Postgres/Supabase error message (log those server-side).
- Status codes: table in SKILL.md; mapping helpers in `resources/validation-and-errors.md`.
- It holds for **every** JSON response on an `/api/*` path — the 401 middleware returns for unauthenticated API requests (`resources/auth-boundaries.md`) and the 500 from the top-level catch (`resources/validation-and-errors.md`) included.

## Collection handler — canonical shape

```ts
// app/api/tasks/route.ts
import { NextRequest } from 'next/server'
import { z } from 'zod'
import { createClient } from '@/lib/supabase/server'
import { ok, fail, fromSupabaseError } from '@/lib/api/errors'
import { createTaskSchema } from '@/lib/validations/task'

export async function POST(request: NextRequest) {
  let body: unknown
  try {
    body = await request.json()
  } catch {
    return fail(400, 'invalid_json', 'Request body must be valid JSON')
  }
  const parsed = createTaskSchema.safeParse(body)
  if (!parsed.success) {
    return fail(400, 'validation_error', 'Invalid input',
      z.flattenError(parsed.error).fieldErrors)
  }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return fail(401, 'unauthenticated', 'Sign in required')

  const { data, error } = await supabase
    .from('tasks')
    .insert({ ...parsed.data, user_id: user.id })   // ownership set on the server
    .select('id, title, content, tags, created_at')
    .single()
  if (error) return fromSupabaseError(error)

  return ok(data, 201)
}
```

The order is fixed: **parse → validate → authenticate → query → respond.** Validation
failures return before any auth or DB work. The GET (list) twin — query-param validation,
sort whitelist, pagination — follows the same order; full listing in
`resources/complete-example.md`.

## Item handler — async params (Next.js 15)

`params` is a `Promise` in Next.js 15 — always `await` it.

```ts
// app/api/tasks/[id]/route.ts
import { NextRequest } from 'next/server'
import { z } from 'zod'
import { createClient } from '@/lib/supabase/server'
import { ok, fail, fromSupabaseError } from '@/lib/api/errors'
import { updateTaskSchema } from '@/lib/validations/task'

type RouteContext = { params: Promise<{ id: string }> }

export async function GET(request: NextRequest, { params }: RouteContext) {
  const { id } = await params
  if (!z.uuid().safeParse(id).success) {
    return fail(400, 'validation_error', 'Invalid id')
  }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return fail(401, 'unauthenticated', 'Sign in required')

  const { data, error } = await supabase
    .from('tasks')
    .select('id, title, content, tags, created_at')
    .eq('id', id)
    .eq('user_id', user.id)       // reads scope by owner too — RLS is the backup, not the only guard
    .single()
  // PGRST116 (0 rows) → 404 — also when RLS hides the row. Do not leak existence.
  if (error) return fromSupabaseError(error)
  return ok(data)
}

export async function PATCH(request: NextRequest, { params }: RouteContext) {
  const { id } = await params
  let body: unknown
  try {
    body = await request.json()
  } catch {
    return fail(400, 'invalid_json', 'Request body must be valid JSON')  // same split as POST
  }
  const parsed = updateTaskSchema.safeParse(body)
  if (!parsed.success) {
    return fail(400, 'validation_error', 'Invalid input',
      z.flattenError(parsed.error).fieldErrors)
  }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return fail(401, 'unauthenticated', 'Sign in required')

  const { data, error } = await supabase
    .from('tasks')
    .update(parsed.data)
    .eq('id', id)
    .eq('user_id', user.id)       // explicit ownership filter — RLS is the backup, not the only guard
    .select('id, title, content, tags')
    .single()                     // PGRST116 (0 rows: missing or not yours) → 404
  if (error) return fromSupabaseError(error)
  return ok(data)
}

export async function DELETE(_request: NextRequest, { params }: RouteContext) {
  const { id } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return fail(401, 'unauthenticated', 'Sign in required')

  const { data, error } = await supabase
    .from('tasks')
    .delete()
    .eq('id', id)
    .eq('user_id', user.id)       // explicit ownership filter — RLS is the backup
    .select('id')                 // returns the deleted rows — [] means nothing was deleted
  if (error) return fromSupabaseError(error)
  // Missing and RLS-hidden look identical here — same 404, no existence leak
  if (!data?.length) return fail(404, 'not_found', 'Resource not found')
  return ok({ deleted: true })
}
```

Every owner-scoped query — reads included — filters by `id` **and** `user_id`: the explicit
filter keeps intent visible and survives a broken RLS policy. A delete without `.select()`
claims success even when it deleted nothing; always confirm the affected rows.
Malformed JSON is `invalid_json`, not `validation_error` — keep that split on every method
that reads a body (`.catch(() => null)` collapses the two).

## Caching behavior

- GET Route Handlers are **dynamic by default** in Next.js 15, and anything using the
  cookie-bound Supabase client stays dynamic — no extra config for authenticated endpoints.
- Public, auth-free data may opt in: `export const dynamic = 'force-static'` +
  `export const revalidate = 60`. Never on a handler that reads cookies.

## CORS, security headers, rate limiting

Same-origin apps need no CORS at all. Cross-origin routes, the `OPTIONS` preflight handler,
security headers, request ids, and rate limiting all live in
`resources/edge-and-operations.md`.

## Server Actions — canonical shape

```ts
// app/tasks/actions.ts
'use server'

import { z } from 'zod'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { createTaskSchema } from '@/lib/validations/task'
import type { ActionResult } from '@/lib/api/types'

export async function createTask(
  _prev: ActionResult | null,
  formData: FormData,
): Promise<ActionResult> {
  // 1. Validate — the client form is not a trust boundary
  const parsed = createTaskSchema.safeParse({
    title: formData.get('title'),
    content: formData.get('content') ?? '',
  })
  if (!parsed.success) {
    return { ok: false, fieldErrors: z.flattenError(parsed.error).fieldErrors }
  }

  // 2. Authenticate — actions are publicly callable HTTP endpoints
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { ok: false, formError: 'Sign in required' }

  // 3. Mutate; map DB errors to the result type — never throw
  const { error } = await supabase
    .from('tasks')
    .insert({ ...parsed.data, user_id: user.id })
  if (error) {
    if (error.code === '23505') return { ok: false, formError: 'This task already exists' }
    console.error('[createTask]', error)
    return { ok: false, formError: 'Something went wrong. Please try again.' }
  }

  // 4. Revalidate affected pages, then optionally redirect (OUTSIDE try/catch)
  revalidatePath('/tasks')
  redirect('/tasks')
}
```

### Two action shapes — pick by call site

| | Form action | Directly-called action |
| --- | --- | --- |
| Signature | `(prevState, formData) => Promise<ActionResult>` | `(id: string, …args) => Promise<ActionResult>` |
| Called from | `useActionState` / `<form action={…}>` | `onClick`, `useTransition`, an event handler |
| Input source | `FormData` — validate with the shared Zod schema | plain arguments — validate them the same way (`z.uuid().safeParse(id)`) |

Both are equally public: **arguments are client input**, so a directly-called `deleteTask(id)`
still opens with `z.uuid().safeParse(id)` → `getUser()` → `.eq('id', id).eq('user_id', user.id)`
— never "the button only renders for owners". The argument shape needs JS (no progressive
enhancement), so prefer the form shape whenever the UI is a form.

Rules that differ from Route Handlers:

- Return values must be **serializable** — plain objects only, no `Error` instances.
- `redirect()` and `notFound()` throw internally — never call them inside `try/catch`.
- Revalidate (`revalidatePath`/`revalidateTag`) after every successful mutation, or the UI shows stale cached data.
- An action used by external clients is a smell — promote it to a Route Handler.

## File-upload Server Action

`FormData` files need their own checks — existence, size, and type — before Storage:

```ts
const MAX_SIZE = 5 * 1024 * 1024 // 5MB — mirror the cap in the bucket settings
const ALLOWED_TYPES = ['image/jpeg', 'image/png', 'image/webp']

export async function uploadAvatar(_p: ActionResult | null, formData: FormData): Promise<ActionResult> {
  const file = formData.get('avatar')
  if (!(file instanceof File) || file.size === 0) return { ok: false, formError: 'No file provided' }
  if (file.size > MAX_SIZE) return { ok: false, formError: 'File too large (max 5MB)' }
  // file.type is client-supplied — a first filter, not proof; keep bucket MIME limits on
  if (!ALLOWED_TYPES.includes(file.type)) return { ok: false, formError: 'Unsupported file type' }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { ok: false, formError: 'Sign in required' }

  const path = `${user.id}/${crypto.randomUUID()}.${file.type.split('/')[1]}`
  const { error } = await supabase.storage
    .from('avatars').upload(path, file, { contentType: file.type })
  if (error) {
    console.error('[uploadAvatar]', error)   // detail stays server-side
    return { ok: false, formError: 'Upload failed. Please try again.' }
  }
  revalidatePath('/settings/profile')
  return { ok: true } // store `path` in a table row, not a signed URL (they expire)
}
```

Bucket policies and signed URLs: `resources/database-patterns.md`.

## Webhook handlers

```ts
// app/api/webhooks/<provider>/route.ts
import { NextRequest } from 'next/server'
import { createAdminClient } from '@/lib/supabase/admin'
import { ok, fail } from '@/lib/api/errors'

export async function POST(request: NextRequest) {
  // 1. Read the RAW body first — signatures are computed over exact bytes
  const raw = await request.text()
  const signature = request.headers.get('x-provider-signature')
  // verifySignature must compare digests in CONSTANT TIME (below)
  if (!signature || !(await verifySignature(raw, signature))) {
    return fail(401, 'invalid_signature', 'Signature verification failed')
  }

  // 2. No user cookie exists here — service-role admin client
  //    (rules in resources/auth-boundaries.md); still validate the payload
  const event = JSON.parse(raw)
  const supabase = createAdminClient()
  // ... idempotent processing keyed by the provider's event id ...
  return ok({ received: true })
}
```

Verify **before** acting; make processing idempotent (providers retry); return 200 fast and queue slow work.
Compare digests in **constant time** — `expected === received` leaks the first differing byte
and is forgeable byte-by-byte. Use the provider SDK's verify helper, or Node's
`crypto.timingSafeEqual` on equal-length buffers (unequal length = immediate reject).
This handler needs the Node runtime; middleware cannot do it (`resources/edge-and-operations.md`).
