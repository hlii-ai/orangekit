<!-- orangekit-seam: nextjs+supabase/backend v3.12.0 -->
# Complete Example — Tasks Endpoint, End to End

One feature ("tasks": list + create, plus item update/delete) traced through every
layer: migration → schema → Route Handler → Server Action → test.
The flow to internalize: **validate → authenticate → process → respond.**

## 1. Migration — table, constraints, RLS, realtime

Structural design (columns, keys, naming) follows the **T1 data-modeling card** at
`.claude/rules/data-modeling.md`; shown here is only what this example needs. This is the
canonical `tasks` schema the other resource files' snippets assume.

```sql
-- supabase/migrations/20260821000000_create_tasks.sql
create table tasks (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  title       text not null check (char_length(title) between 1 and 200),
  content     text not null default '' check (char_length(content) <= 10000),
  tags        text[] not null default '{}'
              check (array_length(tags, 1) is null or array_length(tags, 1) <= 20),
  archived_at timestamptz,
  created_at  timestamptz not null default now()
);

-- Audit trail written by the archive_task RPC (resources/database-patterns.md)
create table task_events (
  id         bigint generated always as identity primary key,
  task_id    uuid not null references tasks (id) on delete cascade,
  kind       text not null check (kind in ('archived', 'restored')),
  created_at timestamptz not null default now()
);

create index tasks_user_id_created_at_idx on tasks (user_id, created_at desc);
create index tasks_active_idx on tasks (created_at desc) where archived_at is null;
create index task_events_task_id_idx on task_events (task_id);

alter table tasks enable row level security;
alter table task_events enable row level security;

create policy "tasks_select_own" on tasks for select
  using ((select auth.uid()) = user_id);
create policy "tasks_insert_own" on tasks for insert
  with check ((select auth.uid()) = user_id);
create policy "tasks_update_own" on tasks for update
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "tasks_delete_own" on tasks for delete
  using ((select auth.uid()) = user_id);

-- Events are readable through ownership of the parent task; writes go through the RPC
create policy "task_events_select_own" on task_events for select
  using (exists (select 1 from tasks n
                 where n.id = task_events.task_id and n.user_id = (select auth.uid())));

alter publication supabase_realtime add table tasks;
```

Every Zod rule below has a constraint twin here (title 1–200, content ≤10000, tags ≤20) —
the DB-constraint-duplication rule in action. Then regenerate types:
`npx supabase gen types typescript --local > types/database.ts`

## 2. Validation schema (shared by handler, action, tests)

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

export const taskListQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  perPage: z.coerce.number().int().min(1).max(100).default(20),
  q: z.string().trim().min(1).max(200).optional(),   // consumed by the GET below
  sort: z.enum(['created_at', 'title']).default('created_at'),  // whitelist, never raw input
  order: z.enum(['asc', 'desc']).default('desc'),
})

export type CreateTaskInput = z.infer<typeof createTaskSchema>
```

## 3. Route Handler

Uses the `ok`/`fail`/`fromSupabaseError` helpers from `lib/api/errors.ts`
(full source in `resources/validation-and-errors.md`).

```ts
// app/api/tasks/route.ts
import { NextRequest } from 'next/server'
import { z } from 'zod'
import { createClient } from '@/lib/supabase/server'
import { ok, fail, fromSupabaseError } from '@/lib/api/errors'
import { createTaskSchema, taskListQuerySchema } from '@/lib/validations/task'

export async function GET(request: NextRequest) {
  // validate
  const parsed = taskListQuerySchema.safeParse(Object.fromEntries(request.nextUrl.searchParams))
  if (!parsed.success) {
    return fail(400, 'validation_error', 'Invalid query parameters',
      z.flattenError(parsed.error).fieldErrors)
  }

  // authenticate
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return fail(401, 'unauthenticated', 'Sign in required')

  // process (RLS scopes rows to this user; the eq() makes intent explicit)
  const { page, perPage, q, sort, order } = parsed.data
  const from = (page - 1) * perPage
  let query = supabase
    .from('tasks').select('id, title, tags, created_at', { count: 'exact' })
    .eq('user_id', user.id).is('archived_at', null)
  // Search: applied only when provided; escape LIKE wildcards the user may have typed
  if (q) query = query.ilike('title', `%${q.replace(/[%_]/g, '\\$&')}%`)
  // Sort: enum members only — a raw string here would let a caller probe columns
  const { data, error, count } = await query
    .order(sort, { ascending: order === 'asc' })
    .range(from, from + perPage - 1)
  if (error) return fromSupabaseError(error)

  // respond
  return ok({ items: data, page, perPage, total: count })
}

export async function POST(request: NextRequest) {
  // validate
  let body: unknown
  try { body = await request.json() }
  catch { return fail(400, 'invalid_json', 'Request body must be valid JSON') }
  const parsed = createTaskSchema.safeParse(body)
  if (!parsed.success) {
    return fail(400, 'validation_error', 'Invalid input',
      z.flattenError(parsed.error).fieldErrors)
  }

  // authenticate
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return fail(401, 'unauthenticated', 'Sign in required')

  // process — ownership comes from the verified user, never the body
  const { data, error } = await supabase
    .from('tasks').insert({ ...parsed.data, user_id: user.id })
    .select('id, title, content, tags, created_at').single()
  if (error) return fromSupabaseError(error)

  // respond
  return ok(data, 201)
}
```

### Item routes — PATCH / DELETE with the ownership double defense

```ts
// app/api/tasks/[id]/route.ts (imports as above, plus updateTaskSchema)
type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: NextRequest, { params }: RouteContext) {
  const { id } = await params
  let body: unknown
  try { body = await request.json() }
  // malformed JSON stays distinct from a Zod failure
  catch { return fail(400, 'invalid_json', 'Request body must be valid JSON') }
  const parsed = updateTaskSchema.safeParse(body)
  if (!parsed.success) {
    return fail(400, 'validation_error', 'Invalid input', z.flattenError(parsed.error).fieldErrors)
  }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return fail(401, 'unauthenticated', 'Sign in required')

  const { data, error } = await supabase
    .from('tasks').update(parsed.data)
    .eq('id', id).eq('user_id', user.id)  // ownership filter — RLS is the backup, not the only guard
    .select('id, title, content, tags').single()  // PGRST116 (missing or not yours) → 404
  if (error) return fromSupabaseError(error)
  return ok(data)
}

export async function DELETE(_request: NextRequest, { params }: RouteContext) {
  const { id } = await params
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return fail(401, 'unauthenticated', 'Sign in required')

  const { data, error } = await supabase
    .from('tasks').delete().eq('id', id).eq('user_id', user.id)
    .select('id')             // confirm what was deleted — [] means nothing was
  if (error) return fromSupabaseError(error)
  if (!data?.length) return fail(404, 'not_found', 'Resource not found') // missing or hidden: same 404
  return ok({ deleted: true })
}
```

## 4. Server Action (same mutation, form-facing)

```ts
// app/tasks/actions.ts
'use server'

import { z } from 'zod'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { createTaskSchema } from '@/lib/validations/task'
import type { ActionResult } from '@/lib/api/types'

export async function createTask(_prev: ActionResult | null, formData: FormData): Promise<ActionResult> {
  const parsed = createTaskSchema.safeParse({
    title: formData.get('title'),
    content: formData.get('content') ?? '',
  })
  if (!parsed.success) return { ok: false, fieldErrors: z.flattenError(parsed.error).fieldErrors }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { ok: false, formError: 'Sign in required' }

  const { error } = await supabase.from('tasks').insert({ ...parsed.data, user_id: user.id })
  if (error) {
    console.error('[createTask]', error)
    return { ok: false, formError: 'Something went wrong. Please try again.' }
  }

  revalidatePath('/tasks')
  return { ok: true }
}
```

The consuming form wires this through `useActionState(createTask, null)` —
component patterns belong to the frontend guide.

## 5. Test

The chainable `queryResult` builder mock is defined once in `resources/testing.md`
(Layer 2) — import it from a shared test helper rather than re-declaring a narrower copy
per test file.

```ts
// app/api/tasks/route.test.ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { NextRequest } from 'next/server'
import { queryResult } from '@/tests/helpers/supabase' // canonical: resources/testing.md

const { mockClient } = vi.hoisted(() => ({
  mockClient: { auth: { getUser: vi.fn() }, from: vi.fn() },
}))
vi.mock('@/lib/supabase/server', () => ({ createClient: vi.fn(async () => mockClient) }))

import { POST } from '@/app/api/tasks/route'

const post = (body: unknown) =>
  POST(new NextRequest('http://test/api/tasks', { method: 'POST', body: JSON.stringify(body) }))

describe('POST /api/tasks', () => {
  beforeEach(() => vi.clearAllMocks())

  it('400: invalid body never reaches auth or DB', async () => {
    expect((await post({ title: '' })).status).toBe(400)
    expect(mockClient.auth.getUser).not.toHaveBeenCalled()
  })

  it('401: no verified user', async () => {
    mockClient.auth.getUser.mockResolvedValue({ data: { user: null }, error: null })
    expect((await post({ title: 'Hi' })).status).toBe(401)
  })

  it('201: creates and returns the task', async () => {
    mockClient.auth.getUser.mockResolvedValue({ data: { user: { id: 'user-1' } }, error: null })
    mockClient.from.mockReturnValue(queryResult({ data: { id: 'n1', title: 'Hi' } }))
    const res = await post({ title: 'Hi' })
    expect(res.status).toBe(201)
    expect((await res.json()).data.id).toBe('n1')
  })
})
```

## Recap checklist

- [ ] Migration: constraints duplicate every Zod rule; RLS enabled on **every** table
- [ ] One schema file feeds the handler, the action, and the tests
- [ ] Handler order: validate → authenticate → process → respond
- [ ] Ownership (`user_id`) always from `getUser()`, never from input
- [ ] Every query scopes by `id` **and** `user_id`; DELETE confirms rows via `.select()`
- [ ] Every declared query param is consumed; `sort` is an enum, never a raw string
- [ ] Malformed JSON → `invalid_json`; Zod failure → `validation_error`
- [ ] Errors mapped through `fromSupabaseError`, with the top-level `route()` catch behind it
- [ ] Action returns `ActionResult` and revalidates; handler returns the envelope
- [ ] Tests cover 400 / 401 / 201 (+ RLS integration per `resources/testing.md`)
