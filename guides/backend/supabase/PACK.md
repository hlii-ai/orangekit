<!-- orangekit-pack: backend/supabase v3.12.0 verified 2026-08-21 @supabase/ssr@0.12 @supabase/supabase-js@2 zod@4 vitest@4 -->

# supabase axis pack — hub fragments

These are the **axis-local fragments to insert verbatim** when building the combination hub
(`SKILL.md`). A combination that has a pre-built seam does not use this file — there the seam's `HUB.md` holds the whole hub.

> **Premise of this axis**: the data layer **has a row-level policy engine (RLS).** An
> application-layer check is UX; enforcement is RLS — use it on the premise of defense in depth.
> Moving this statement to an axis that has **no** policy engine (`aws-container`, `aws-serverless`)
> turns it into exactly the opposite guidance. On those axes a missing application-layer ownership check is a data leak.

> **This pack is thin — and that is normal.** A BaaS axis's "backend guide" is mostly about the
> host runtime (handlers, middleware, the error envelope, validation wiring), and the frontend
> axis decides that. What this axis actually owns is client usage discipline, query patterns, RLS,
> storage, realtime and generated types — nothing else. It contrasts with the thick packs of the
> self-hosted server axes (`aws-container`, `fastapi`).

<!-- pack-slot: core-principles-axis -->
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

<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
```ts
// Data access · auth (**how** the client is built is decided by the seam)
import { createServerClient, createBrowserClient } from '@supabase/ssr'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/types/database'
```
<!-- /pack-slot -->

## For the seam to fill — what is not in this pack

| hub slot | why it is a function of the combination |
| --- | --- |
| all of Quick Start | The procedure for building an endpoint depends on the handler shape (= the frontend axis) |
| Architecture Overview | Where server code lives depends on the frontend axis |
| Directory Structure | It is the host framework's layout convention |
| Core Principle "validate input" | The principle is universal, but **the shape of the parsing helper** (the request object type) depends on the host runtime. Always include this rule |
| HTTP Status Codes table · error envelope | That is the wire contract itself |
| Server Action / action boundary contract | It exists only when the frontend axis offers such a boundary |
| Navigation Guide | `pack.json` supplies the pack resource rows |
