<!-- orangekit-pack: backend/supabase v3.12.0 -->
# Backend Testing

Tooling: **Vitest** for unit/handler/action tests, the **Supabase CLI local stack**
for integration and RLS tests.

## Setup

```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config'
import path from 'node:path'

export default defineConfig({
  test: { environment: 'node' }, // backend tests run in node, not jsdom
  resolve: { alias: { '@': path.resolve(__dirname, '.') } },
})
```

Test files live next to the code (`route.test.ts`, `actions.test.ts`) or under
`tests/` mirroring the source tree — follow the project's existing convention.

## Layer 1 — Zod schemas (pure, no mocks)

The cheapest tests with the highest defect yield. Cover: valid input, each rule's
failure, defaults, and trimming.

```ts
import { describe, expect, it } from 'vitest'
import { createTaskSchema } from '@/lib/validations/task'

describe('createTaskSchema', () => {
  it('accepts a valid payload and applies defaults', () => {
    const result = createTaskSchema.safeParse({ title: 'Hello' })
    expect(result.success).toBe(true)
    if (result.success) {
      expect(result.data.content).toBe('')
      expect(result.data.tags).toEqual([])
    }
  })

  it('rejects a whitespace-only title', () => {
    expect(createTaskSchema.safeParse({ title: '   ' }).success).toBe(false)
  })

  it('rejects a title over 200 chars', () => {
    expect(createTaskSchema.safeParse({ title: 'x'.repeat(201) }).success).toBe(false)
  })
})
```

## Layer 4 — RLS integration tests (local Supabase)

Policies are security code; test them against a real database. Requires
`supabase start` (local stack) and seeded test users in `supabase/seed.sql`.

```ts
// tests/rls/tasks.test.ts — run with the local stack up
import { createClient } from '@supabase/supabase-js'
import { describe, expect, it } from 'vitest'

const url = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321'
const anonKey = process.env.SUPABASE_ANON_KEY!

async function signIn(email: string) {
  const client = createClient(url, anonKey)
  const { error } = await client.auth.signInWithPassword({ email, password: 'password123' })
  if (error) throw error
  return client
}

describe('tasks RLS', () => {
  it('a user reads only their own tasks', async () => {
    const alice = await signIn('alice@test.local')
    const { data: { user } } = await alice.auth.getUser()
    const { data } = await alice.from('tasks').select('id, user_id')
    expect(data?.every((n) => n.user_id === user!.id)).toBe(true)
  })

  it('inserting as another user is rejected (42501)', async () => {
    const alice = await signIn('alice@test.local')
    const { error } = await alice
      .from('tasks')
      .insert({ title: 'spoof', user_id: '00000000-0000-0000-0000-000000000099' })
    expect(error?.code).toBe('42501')
  })
})
```

SQL-level alternative: the Supabase CLI runs pgTAP tests from `supabase/tests/` via
`supabase test db` — useful for asserting policies/constraints without a JS harness.

## What NOT to test

- Supabase/PostgREST internals (query building, cookie plumbing) — test your mapping
  of their results, not their behavior.
- Next.js routing itself — invoking the exported handler function is enough.
- Schemas re-tested through every handler test — one schema suite + handler tests for
  the 400 branch is sufficient.
