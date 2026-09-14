<!-- orangekit-pack: backend/supabase v3.12.0 -->
# Data Access — Supabase Client & Query Patterns

> **Table design is out of scope for this file.** Columns, keys, indexes, naming, and
> relationships are owned by the **T1 data-modeling card** at
> **`.claude/rules/data-modeling.md`**. It auto-loads only on DB paths (`supabase/**`,
> `**/migrations/**`, `db/**`, `prisma/**`, `drizzle/**`) — under `app/api/**` it will
> **not** be in context, so open that file directly before creating or altering a table,
> and do not copy its content here. This file covers clients and query patterns only.

## Client matrix

| Client | File | Key | RLS | Use in |
| --- | --- | --- | --- | --- |
| Server client | `lib/supabase/server.ts` | anon | enforced | Route Handlers, Server Actions, Server Components |
| Admin client | `lib/supabase/admin.ts` | service role | **bypassed** | Webhooks, cron, admin tasks only — see `auth-boundaries.md` |
| Browser client | (frontend guide) | anon | enforced | Client Components only |

## Typed queries

Regenerate types after every migration and pass them to the client (`<Database>` — the client is created in `resources/server-client.md`) —
then `data` rows, `insert()` payloads, and column names are all checked at compile time:

```bash
npx supabase gen types typescript --local > types/database.ts
```

## Read patterns

```ts
const supabase = await createClient()

// Always list columns explicitly — never select('*') in handlers
const { data, error } = await supabase
  .from('tasks')
  .select('id, title, created_at')
  .order('created_at', { ascending: false })
  .limit(20)
if (error) return fromSupabaseError(error)

// Exactly one row expected → single(): PGRST116 when it does not match exactly one row
const { data: task, error: taskError } = await supabase
  .from('tasks').select('id, title, content').eq('id', id).eq('user_id', user.id).single()
if (taskError) return fromSupabaseError(taskError)

// Zero-or-one expected → maybeSingle(): data is null on 0 rows, no error
const { data: maybe, error: maybeError } = await supabase
  .from('tasks').select('id').eq('slug', slug).maybeSingle()
if (maybeError) return fromSupabaseError(maybeError)

// Pagination: range is inclusive; count comes back alongside data
const from = (page - 1) * perPage
const { data: pageRows, error: pageError, count } = await supabase
  .from('tasks').select('id, title', { count: 'exact' })
  .range(from, from + perPage - 1)
if (pageError) return fromSupabaseError(pageError)

// Count only, no rows
const { count: total, error: countError } = await supabase
  .from('tasks').select('id', { count: 'exact', head: true })
if (countError) return fromSupabaseError(countError)
```

## Filter cheatsheet (the ones that get misused)

The snippets below omit error handling to keep the focus on filter shape — real code always
destructures and checks `error` (Core Principle 5 in SKILL.md).

```ts
.eq('status', 'published')   .neq('status', 'draft')       // equality
.gt/.gte/.lt/.lte('view_count', n)                              // comparisons — chain two for a range
.in('status', ['published', 'featured'])                   // value is in a list
.like('title', '%plan%')     .ilike('title', '%plan%')     // ilike = case-insensitive (usually what you want)
.is('deleted_at', null)                                    // NULL check — .eq(col, null) matches nothing
.contains('tags', ['ts', 'api'])                           // array/jsonb column contains ALL of these
.containedBy('tags', allowed)                              // column is a subset of the list
.or('status.eq.draft,status.eq.review')                    // OR — one PostgREST filter string
```

Full-text search takes a **query syntax that must match the chosen `type`** — mixing them
silently searches for the wrong thing:

```ts
// Operator syntax (to_tsquery): & | ! <-> — for queries YOU build. Omit `type`.
.textSearch('title', "'task' & 'api'")
// User-typed input (websearch_to_tsquery): natural language, quoted phrases, `or`, `-word`
.textSearch('title', 'task api or "rate limit" -draft', { type: 'websearch' })
```

`websearch` never parses `&`/`|` — it treats them as noise. Use it for anything a user typed
(it cannot raise a syntax error), the operator form only for queries you build. Either way
the column needs a `tsvector` + GIN index.

Frequent mistakes: `.eq(col, null)` instead of `.is()`; `.like` when you meant
case-insensitive `.ilike`; `.contains` ("has all of") confused with `.in` ("is one of").

## Relational reads (embedded selects)

Foreign-key relationships can be embedded instead of hand-written joins:

```ts
// task + its author's profile (FK: tasks.user_id → profiles.id)
const { data, error } = await supabase
  .from('tasks')
  .select('id, title, author:profiles(id, display_name)')
if (error) return fromSupabaseError(error)

// one-to-many: profile with its tasks, newest first
const { data: profile, error: profileError } = await supabase
  .from('profiles')
  .select('id, display_name, tasks(id, title, created_at)')
  .eq('id', userId)
  .order('created_at', { referencedTable: 'tasks', ascending: false })
  .single()
if (profileError) return fromSupabaseError(profileError)
```

Embedding requires a real FK between the tables (design per the T1 card).

## N+1 prevention & indexes

```ts
// Bad — one query per row (N+1): listing 50 tasks fires 51 queries
const { data: tasks } = await supabase.from('tasks').select('id, title, user_id')
for (const task of tasks ?? []) {
  await supabase.from('profiles').select('display_name').eq('id', task.user_id).single()
}

// Good — one round trip with an embedded select (previous section)
const { data, error } = await supabase
  .from('tasks')
  .select('id, title, author:profiles(display_name)')
if (error) return fromSupabaseError(error)
```

Indexes make these queries hold up — DDL lives in migrations (design per the T1 card;
the `tasks` schema these examples assume is in `resources/complete-example.md`):

```sql
-- Composite: FK + the sort order the list endpoint uses
create index tasks_user_id_created_at_idx on tasks (user_id, created_at desc);

-- Partial: index only the rows a hot filter actually touches
create index tasks_active_idx on tasks (created_at desc) where archived_at is null;
```

Every FK column gets an index (joins and cascade deletes scan it); a partial index stays
small and serves a filter like `where archived_at is null` exactly.

## Write patterns

```ts
// Insert and read back the created row in one round trip
const { data: created, error: insertError } = await supabase
  .from('tasks').insert({ title, content, user_id: user.id })
  .select('id, title, created_at').single()
if (insertError) return fromSupabaseError(insertError)

// Update: scope by id AND the verified owner — RLS is a backup, not the only defense
const { data: updated, error: updateError } = await supabase
  .from('tasks').update({ title: newTitle })
  .eq('id', id).eq('user_id', user.id)
  .select('id, title').single()          // PGRST116 (missing or not yours) → 404
if (updateError) return fromSupabaseError(updateError)

// Delete: same owner filter + .select(), so "deleted" differs from "matched nothing"
const { data: deleted, error: deleteError } = await supabase
  .from('tasks').delete().eq('id', id).eq('user_id', user.id).select('id')
if (deleteError) return fromSupabaseError(deleteError)
if (!deleted?.length) return fail(404, 'not_found', 'Resource not found')

// Upsert on a unique column
const { error: upsertError } = await supabase
  .from('user_settings').upsert({ user_id: user.id, theme: 'dark' }, { onConflict: 'user_id' })
if (upsertError) return fromSupabaseError(upsertError)
```

Set ownership columns (`user_id`) from `user.id` on the server — never from the request
body — and filter every mutation by that owner. RLS is the backup, not the only defense: a
`delete()` without `.select()` reports success even when it removed nothing.

## Multi-step mutations → RPC (Postgres functions)

supabase-js has **no transaction API**. Any mutation that must be atomic across
statements belongs in a Postgres function called via `.rpc()`:

```sql
-- supabase/migrations/xxxx_archive_task.sql
create or replace function archive_task(p_task_id uuid)
returns void
language plpgsql
security invoker            -- keeps RLS applied as the calling user
set search_path = ''        -- required: resolve every object by schema (see below)
as $$
begin
  update public.tasks set archived_at = now() where id = p_task_id;
  insert into public.task_events (task_id, kind) values (p_task_id, 'archived');
end;
$$;
```

```ts
const { error } = await supabase.rpc('archive_task', { p_task_id: id })
if (error) return fromSupabaseError(error)
```

Default to `security invoker`. `security definer` bypasses RLS — treat it like the
service-role key: only with an explicit reason, documented at the definition site.

**Every function gets `set search_path = ''`** (Supabase's `function_search_path_mutable`
lint). A mutable `search_path` lets a caller prepend a schema they control and shadow
`tasks` or `auth.uid()` with their own object — under `security definer` that runs as the
function owner. Empty `search_path` means unqualified names resolve to nothing, so qualify
everything: `public.tasks`, `auth.uid()`, `extensions.gen_random_uuid()`.

## Storage — server-side file handling

Buckets are private by default; access control on `storage.objects` is RLS.

```ts
const supabase = await createClient()

// Upload under a user-id prefix so storage policies can match the folder
const path = `${user.id}/${crypto.randomUUID()}.pdf`
const { error: upErr } = await supabase.storage
  .from('attachments').upload(path, file, { contentType: 'application/pdf', upsert: false })

// Time-limited access to a private object, then removal
const { data: signed, error: signErr } = await supabase.storage
  .from('attachments').createSignedUrl(path, 60 * 10) // 10 minutes
const { error: rmErr } = await supabase.storage.from('attachments').remove([path])
```

```sql
-- Storage policy: users touch only their own folder in this bucket
create policy "own_folder" on storage.objects for all
  using (bucket_id = 'attachments'
         and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'attachments'
         and (storage.foldername(name))[1] = (select auth.uid())::text);
```

Store the object `path` in your table, not a signed URL — signed URLs expire. Storage calls
return `{ data, error }` too and every one must be checked; a `StorageError` carries no
Postgres `code`, so map it explicitly rather than via `fromSupabaseError`.

## Realtime — backend responsibilities

Subscribing happens in the frontend; the backend makes events available and keeps them
access-controlled:

```sql
-- Migration: emit change events for a table
alter publication supabase_realtime add table tasks;
```

- `postgres_changes` deliveries respect the table's RLS — clients receive only rows they may
  `select`. RLS off = broadcast to everyone; never replicate a table without RLS.
- Mutations through your handlers/actions are picked up automatically — no extra server code "sends" a change event.
- For high-fanout or derived events, prefer Realtime Broadcast over `postgres_changes`.

## Generated types (DB schema → TypeScript)

> Moved here from `typescript-standards.md` §7 of the `nextjs` axis pack (v3.12.0) — generating
> types from a schema is this axis's knowledge, not the frontend's.
```bash
npx supabase gen types typescript --project-id <id> > types/database.ts
```

```ts
import type { Database } from '@/types/database'

// Table Row / Insert / Update types
type Task = Database['public']['Tables']['tasks']['Row']
type InsertTask = Database['public']['Tables']['tasks']['Insert']
type UpdateTask = Database['public']['Tables']['tasks']['Update']
```

- Passing the generic to the client factory types query results automatically:
  `createServerClient<Database>(…)`, `createBrowserClient<Database>(…)`
- After a schema change, rerun the generate command to resync the types
- For types exposed to components, prefer what `lib/queries/` shapes and exports

