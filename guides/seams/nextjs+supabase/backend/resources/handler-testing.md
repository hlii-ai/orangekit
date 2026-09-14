<!-- orangekit-seam: nextjs+supabase/backend v3.12.0 -->
# Handler-layer testing — Route Handlers · Server Actions

> Split out of `testing.md` in the `supabase` axis pack. Schema tests (Layer 1) and RLS integration
> tests (Layer 4) belong to the axis, but **tests that call a handler directly** depend on the shape of
> the handler, so the seam owns them.

## Layer 2 — Route Handlers with a mocked Supabase client

Import the exported `GET`/`POST` and call them with a real `NextRequest`. Mock only
the module boundary: `@/lib/supabase/server`.

**This is the canonical `queryResult` helper.** Define it once in a shared test helper
(`tests/helpers/supabase.ts`) and import it everywhere — a per-file copy that omits a
builder method breaks the moment a handler chains that method.

```ts
// tests/helpers/supabase.ts
import { vi } from 'vitest'

// Chainable, thenable builder mock — awaiting any chain resolves to `result`
export function queryResult(result: { data?: unknown; error?: unknown; count?: number }) {
  const builder: Record<string, unknown> = {}
  const methods = ['select', 'insert', 'update', 'upsert', 'delete', 'eq', 'neq', 'in', 'is',
    'ilike', 'or', 'order', 'range', 'limit', 'single', 'maybeSingle']
  for (const m of methods) builder[m] = vi.fn(() => builder)
  ;(builder as { then?: unknown }).then = (resolve: (v: unknown) => void) =>
    resolve({ data: null, error: null, count: null, ...result })
  return builder
}
```

```ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { NextRequest } from 'next/server'
import { queryResult } from '@/tests/helpers/supabase'

const { mockClient } = vi.hoisted(() => ({
  mockClient: { auth: { getUser: vi.fn() }, from: vi.fn() },
}))

vi.mock('@/lib/supabase/server', () => ({
  createClient: vi.fn(async () => mockClient),
}))

import { POST } from '@/app/api/tasks/route'

const post = (body: unknown) =>
  POST(new NextRequest('http://test/api/tasks', { method: 'POST', body: JSON.stringify(body) }))

describe('POST /api/tasks', () => {
  beforeEach(() => vi.clearAllMocks())

  it('returns 400 for an invalid body (before auth or DB work)', async () => {
    const res = await post({ title: '' })
    expect(res.status).toBe(400)
    expect(mockClient.auth.getUser).not.toHaveBeenCalled()
  })

  it('returns 401 without a verified user', async () => {
    mockClient.auth.getUser.mockResolvedValue({ data: { user: null }, error: null })
    const res = await post({ title: 'Hi' })
    expect(res.status).toBe(401)
  })

  it('creates a task for a signed-in user', async () => {
    mockClient.auth.getUser.mockResolvedValue({ data: { user: { id: 'user-1' } }, error: null })
    mockClient.from.mockReturnValue(queryResult({ data: { id: 'n1', title: 'Hi' } }))
    const res = await post({ title: 'Hi' })
    expect(res.status).toBe(201)
    expect((await res.json()).data.title).toBe('Hi')
  })

  it('maps a unique violation to 409', async () => {
    mockClient.auth.getUser.mockResolvedValue({ data: { user: { id: 'user-1' } }, error: null })
    mockClient.from.mockReturnValue(queryResult({ error: { code: '23505', message: 'dup' } }))
    const res = await post({ title: 'Hi' })
    expect(res.status).toBe(409)
  })
})
```

For dynamic routes, pass params as a resolved promise:

```ts
const res = await GET(new NextRequest('http://test/api/tasks/n1'), {
  params: Promise.resolve({ id: '6f1e...uuid' }),
})
```

## Layer 3 — Server Actions

Call the action directly with a `FormData`; mock the Next.js cache/navigation modules.

```ts
import { describe, expect, it, vi } from 'vitest'

vi.mock('next/cache', () => ({ revalidatePath: vi.fn(), revalidateTag: vi.fn() }))
vi.mock('next/navigation', () => ({
  redirect: vi.fn(() => { throw new Error('NEXT_REDIRECT') }),
}))
// plus the same '@/lib/supabase/server' mock as Layer 2

import { createTask } from '@/app/tasks/actions'

it('returns fieldErrors for an empty title', async () => {
  const fd = new FormData()
  fd.set('title', '')
  const result = await createTask(null, fd)
  expect(result.ok).toBe(false)
  if (!result.ok) expect(result.fieldErrors?.title).toBeDefined()
})
```

Assert `revalidatePath` was called on the success path — a forgotten revalidate is a
real bug class that unit tests catch for free.

