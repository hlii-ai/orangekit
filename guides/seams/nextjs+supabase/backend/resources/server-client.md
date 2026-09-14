<!-- orangekit-seam: nextjs+supabase/backend v3.12.0 -->
# Server client — per request · cookie-bound

> Split out of `database-patterns.md` in the `supabase` axis pack. **How** the client is built is a
> function of the host runtime (how it reaches cookies), so the seam owns it.

## Server client — per-request, cookie-bound

```ts
// lib/supabase/server.ts
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { publicEnv } from '@/lib/env.public'   // NOT lib/env.ts — that one is server-only
import type { Database } from '@/types/database'

export async function createClient() {
  const cookieStore = await cookies() // async in Next.js 15

  return createServerClient<Database>(
    publicEnv.NEXT_PUBLIC_SUPABASE_URL,
    publicEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            )
          } catch {
            // Called from a Server Component (cookies are read-only there).
            // Safe to ignore because middleware refreshes the session.
          }
        },
      },
    },
  )
}
```

Call `await createClient()` inside every handler/action — never at module scope. (Newer
Supabase projects may name the keys publishable/secret; the pattern is identical.) The URL
and anon key come from `lib/env.public.ts`, not the `server-only` `lib/env.ts`, because
client-creation modules also sit in browser graphs (`resources/validation-and-errors.md`).

