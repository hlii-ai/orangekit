---
name: backend-guide
description: "[Preset: nextjs-supabase] Next.js App Router backend guide. Covers Route Handlers, Server Actions, Supabase data access, RLS policies, SQL migrations, RPC functions, Zod validation, middleware, and error handling. Use when creating or modifying Route Handlers, Server Actions, Supabase queries, RLS policies, migrations, input validation, middleware, webhooks, backend testing, or any server-side logic. Use ONLY when the active preset matches."
---
<!-- orangekit-guide-baseline: verified 2026-08-21 next@15 react@19 typescript@5 zod@4 @supabase/ssr@0.12 @supabase/supabase-js@2 vitest@4 -->

# Backend Development Guide

## Quick Start

> If `dev/docs/api/wire-contract.md` exists, that file is canonical for the envelope, error codes and pagination. If it does not exist and you are building the frontend and backend together from scratch, do steps 1 and 2 of "Inner Order Within One Feature" in `workflow-routing.md` first.

**New Route Handler:**

- [ ] Define/extend the Zod schema in `lib/validations/<feature>.ts`
- [ ] Confirm the table and constraints exist (design them per the T1 data-modeling card)
- [ ] Create `app/api/<resource>/route.ts` (collection) or `app/api/<resource>/[id]/route.ts` (item — `params` is a Promise in Next.js 15)
- [ ] `safeParse` the body/query before any DB call — return 400 with `fieldErrors` on failure
- [ ] Auth: `const { data: { user } } = await supabase.auth.getUser()` → 401 if `null`
- [ ] Query through the per-request server client; check the returned `error` explicitly
- [ ] Respond with the `{ data }` / `{ error }` envelope and the correct status code
- [ ] Add a Vitest test: happy path + validation failure + unauthenticated

**New Server Action:**

- [ ] Create `actions.ts` colocated with the feature, `'use server'` at the top
- [ ] Pick the shape: form action `(prevState, formData)` for `useActionState`, or a directly-called action `(id, …args)` for button handlers (`resources/api-endpoints.md`) — both need their own auth check
- [ ] Validate `formData` with the shared Zod schema — never trust the client form
- [ ] Auth-check with `getUser()` inside the action (actions are public HTTP endpoints)
- [ ] Mutate via the server client; map DB errors into the typed `ActionResult`
- [ ] `revalidatePath`/`revalidateTag` after a successful mutation
- [ ] Call `redirect()` outside `try/catch` (it works by throwing)
- [ ] Return a serializable `{ ok, fieldErrors?, formError? }` — never throw across the boundary

## Architecture Overview

```
Request
  │
  ├─ middleware.ts ──────────── session refresh (updateSession) + coarse route gating
  │                             * refresh only — authorization does NOT live here
  │
  ├─ Route Handler ──────────── external-facing JSON API (app/api/**/route.ts)
  │   or Server Action          form mutations from your own React tree
  │       │
  │       ├─ Zod v4 schema ──── validate BEFORE auth/DB work (lib/validations/)
  │       ├─ getUser() ───────── verified identity + app-level authorization
  │       └─ Supabase client ── per-request, cookie-bound (lib/supabase/server.ts)
  │
  └─ Supabase PostgreSQL ────── RLS enforces access as the FINAL defense;
                                DB constraints duplicate every Zod rule
```

Responsibility boundaries:

- **Middleware** refreshes the auth token and redirects signed-out visitors — except on
  `/api/*`, which gets a 401 envelope, never a login page. It runs on the Edge Runtime and
  never decides *what* a user may touch.
- **Handlers/Actions** own validation, authorization, business logic, and the response
  contract. They are the only place that talks to Supabase.
- **Postgres (RLS + constraints)** is the enforcement layer that holds even when
  application code has a bug.
- **Storage** (file uploads, signed URLs) and **Realtime** (change events) are accessed
  through the same server client; their access control is also RLS.

## Directory Structure

```
app/
  api/
    <resource>/route.ts          # collection: GET (list), POST (create)
    <resource>/[id]/route.ts     # item: GET, PATCH, DELETE
    webhooks/<provider>/route.ts # signature-verified, service-role client
  <feature>/
    actions.ts                   # Server Actions colocated with the feature
middleware.ts                    # delegates to updateSession
lib/
  supabase/
    server.ts                    # createClient — per-request, anon key, RLS on
    admin.ts                     # createAdminClient — service role, restricted
    middleware.ts                # updateSession (token refresh)
  validations/
    <feature>.ts                 # Zod schemas shared by handlers and actions
  env.ts                         # server-only secrets (Zod-validated, `import 'server-only'`)
  env.public.ts                  # NEXT_PUBLIC_* (static member access — browser-safe)
  api/
    errors.ts                    # ok / fail / fromSupabaseError helpers
    types.ts                     # ActionResult, envelope types
types/
  database.ts                    # generated: supabase gen types typescript
supabase/
  migrations/*.sql               # DDL, constraints, RLS policies, functions
  seed.sql                       # local/dev seed data
```

Table/schema design itself is owned by the T1 data-modeling card — do not restate it here.

## Core Principles (6 Key Rules)

### 1. Validate every input with Zod before it touches the database

```ts
// Bad — raw request body straight into the DB
const body = await request.json()
await supabase.from('tasks').insert(body)
```

```ts
// Good — safeParse first, 400 with field errors on failure
const parsed = createTaskSchema.safeParse(await request.json())
if (!parsed.success) {
  return fail(400, 'validation_error', 'Invalid input', z.flattenError(parsed.error).fieldErrors)
}
await supabase.from('tasks').insert({ ...parsed.data, user_id: user.id })
```

### 2. Authorize with getUser(), never getSession(), on the server

`getSession()` reads the cookie without verifying it — it can be spoofed.
`getUser()` revalidates the JWT against Supabase Auth on every call.

```ts
// Bad — trusts an unverified cookie
const { data: { session } } = await supabase.auth.getSession()
if (!session) return fail(401, 'unauthenticated', 'Sign in required')
```

```ts
// Good — verified identity
const { data: { user } } = await supabase.auth.getUser()
if (!user) return fail(401, 'unauthenticated', 'Sign in required')
```

### 3. Create the Supabase client per request — never a module-level singleton

```ts
// Bad — one client at import time; cookies from one request leak into another
export const supabase = createServerClient(url, key, { cookies: staticCookies })
```

```ts
// Good — a fresh cookie-bound client inside every handler/action
export async function POST(request: NextRequest) {
  const supabase = await createClient()
  // ...
}
```

### 4. Enable RLS on every table — app checks are UX, RLS is enforcement

```sql
-- Bad: no RLS — anyone holding the anon key can read/write every row
create table tasks ( ... );
```

```sql
-- Good: RLS on + owner policy; handlers still filter, Postgres enforces
alter table tasks enable row level security;
create policy "tasks_owner_all" on tasks for all
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
```

### 5. Never ignore the error returned by a Supabase query

supabase-js does not throw — every call returns `{ data, error }` and `data` may be `null`.

```ts
// Bad — error silently discarded; returns null data as success
const { data } = await supabase.from('tasks').select('id, title')
return ok(data)
```

```ts
// Good — every query checks error and maps it to a status
const { data, error } = await supabase.from('tasks').select('id, title')
if (error) return fromSupabaseError(error)
return ok(data)
```

### 6. Server Actions return typed results — never throw domain errors across the boundary

```ts
// Bad — in production the client sees only an opaque error digest
export async function createTask(formData: FormData) {
  'use server'
  if (!formData.get('title')) throw new Error('Title is required')
}
```

```ts
// Good — serializable result + revalidation on success
export async function createTask(prev: ActionResult | null, formData: FormData): Promise<ActionResult> {
  'use server'
  // validate → getUser → insert (see resources/api-endpoints.md)
  revalidatePath('/tasks')
  return { ok: true }
}
```

## Common Imports

```ts
// Route Handlers
import { NextRequest, NextResponse } from 'next/server'
import { z } from 'zod'
import { createClient } from '@/lib/supabase/server'
import { ok, fail, fromSupabaseError } from '@/lib/api/errors'

// Server Actions ('use server' at the top of the file)
import { revalidatePath, revalidateTag } from 'next/cache'
import { redirect } from 'next/navigation'
import type { ActionResult } from '@/lib/api/types'

// Middleware / SSR clients
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'

// Admin (service role — webhooks, cron, admin tasks only)
import { createAdminClient } from '@/lib/supabase/admin'

// Generated DB types
import type { Database } from '@/types/database'
```

## HTTP Status Codes + Anti-Patterns

| Status | When | `error.code` |
| --- | --- | --- |
| 200 | successful read / update / delete | — |
| 201 | resource created | — |
| 400 | Zod failure, malformed JSON, FK/CHECK violation | `validation_error`, `invalid_json` |
| 401 | no verified user (`getUser()` → null) | `unauthenticated` |
| 403 | signed in but not allowed (RLS `42501`) | `forbidden` |
| 404 | missing — or hidden by RLS (`PGRST116`); don't leak existence | `not_found` |
| 409 | unique conflict (`23505`) | `conflict` |
| 429 | rate limited (external store, never in-memory) | `rate_limited` |
| 500 | unexpected — top-level catch logs internals, returns a generic message | `internal_error` |

**Anti-patterns (never do):**

- `getSession()` as an authorization check on the server
- Module-scope Supabase client in server code
- Service-role key in a `NEXT_PUBLIC_*` env var or any client-reachable path
- Reading roles from `user_metadata` (user-editable) — use `app_metadata` or a profiles row
- Skipping Zod because "the form already validates"
- Ignoring the `error` half of a Supabase result
- `select('*')` in handlers — list columns explicitly
- `redirect()` inside `try/catch`
- Throwing domain errors across the Server Action boundary
- A table without RLS enabled
- Multi-statement mutations without an RPC (supabase-js has no transactions)
- Returning raw Postgres/Supabase error messages (`error.message`) to the client
- Direct `process.env` access in app code — import `serverEnv` (`lib/env.ts`, `server-only`) or `publicEnv` (`lib/env.public.ts`)
- Redirecting to a user-supplied URL without parsing it and comparing origins (prefix checks alone are bypassable)
- Middleware that answers an `/api/*` request with an HTML redirect instead of a 401 envelope
- An in-memory (module-scope `Map`) rate limiter — Edge isolates share no memory
- `security definer` / any Postgres function without `set search_path = ''`
- Passing an unvalidated `sort`/`order` query param to `.order()`

## Navigation Guide

| If you need to... | Read |
| --- | --- |
| Create/modify a Route Handler; handler vs action; webhooks + signature verification; caching | `resources/api-endpoints.md` |
| Write a Server Action — form action vs directly-called action, revalidation, redirect, file upload | `resources/api-endpoints.md` |
| Query/insert/update/delete via Supabase; filters; pagination; RPC transactions | `resources/database-patterns.md` |
| Upload files or issue signed URLs (Storage); avoid N+1; index queries | `resources/database-patterns.md` |
| Enable table change events (Realtime) | `resources/database-patterns.md` |
| Design or alter a table schema | **T1 data-modeling card** at `.claude/rules/data-modeling.md` — auto-loads only on DB paths (`supabase/**`, `**/migrations/**`, `db/**`, `prisma/**`, `drizzle/**`); from `app/api/**` open it by path. Not duplicated in this skill |
| Define validation schemas; FormData quirks; duplicate rules as DB constraints | `resources/validation-and-errors.md` |
| Validate env vars (`lib/env.ts` + `lib/env.public.ts` split); advanced Zod recipes | `resources/validation-and-errors.md` |
| Map errors to status codes; error envelope; Supabase error code table; the top-level `route()` catch that guarantees a JSON 500 | `resources/validation-and-errors.md` |
| Middleware/session refresh; authorization; RLS policies; service-role client | `resources/auth-boundaries.md` |
| Build the auth flow (sign-in/up/out actions, post-login redirect) | `resources/auth-boundaries.md` |
| Know what may run in middleware (Edge Runtime limits); rate limiting; security headers; CORS; request ids; structured logging | `resources/edge-and-operations.md` |
| Write schema tests and RLS integration tests (local Supabase) | `resources/testing.md` |
| Test Route Handlers and Server Actions directly (handler layer) | `resources/handler-testing.md` |
| Create the per-request Supabase client (cookie-bound) | `resources/server-client.md` |
| See one endpoint end-to-end (validate → process → respond); the canonical `tasks` schema | `resources/complete-example.md` |
