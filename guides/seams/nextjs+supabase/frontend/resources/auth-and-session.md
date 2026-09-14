<!-- orangekit-seam: nextjs+supabase/frontend v3.12.0 -->
# Auth and session — protected routes · middleware session refresh

> This file was split out of `routing.md` §6 in the `nextjs` axis pack. The routing mechanism belongs to the axis, but
> **who the authenticated principal is** is a function of the backend axis, so the seam owns it.


Three layers of defense: **middleware (first gate) → re-check in the page → RLS (the last line, backend-guide)**.

```ts
// middleware.ts (project root)
import { type NextRequest } from 'next/server'
import { updateSession } from '@/lib/supabase/middleware'

export async function middleware(request: NextRequest) {
  return await updateSession(request)
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)'],
}
```

```ts
// lib/supabase/middleware.ts — session refresh + redirect when not signed in
import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
          supabaseResponse = NextResponse.next({ request })
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options)
          )
        },
      },
    }
  )

  // Important: put no other logic between createServerClient and getUser()
  const { data: { user } } = await supabase.auth.getUser()

  const isPublic =
    request.nextUrl.pathname.startsWith('/login') ||
    request.nextUrl.pathname.startsWith('/auth')

  if (!user && !isPublic) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    return NextResponse.redirect(url)
  }

  return supabaseResponse                    // always return this response object unchanged
}
```

```tsx
// app/(main)/tasks/page.tsx — re-check inside the protected page (do not trust the middleware alone)
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'

export default async function TasksPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')
  // …
}
```

Rules:

- Identify the user **always with `getUser()`** — on the server, the user information from `getSession()` is not trusted
- Return the middleware's `supabaseResponse` unmodified — if the cookies are lost, the session breaks
- Exclude the login/callback paths from the redirect (prevents an infinite loop)


## Reading the current user on the server

`routing.md` · `typescript-standards.md` in the `nextjs` axis pack consume these two symbols. The pack does not
know the data client directly, so **the seam owns the definition of the auth layer** — change the backend
axis and only this file changes; the pack stays as it is.

```ts
// lib/auth.ts
import { createClient } from '@/lib/supabase/server'

export type AuthUser = { id: string; email: string | null }

/** Used in a Server Component · Route Handler · Server Action. Returns null when there is no session. */
export async function getCurrentUser(): Promise<AuthUser | null> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()   // not getSession() — the server always uses getUser()
  return user ? { id: user.id, email: user.email ?? null } : null
}
```

`getSession()` trusts the cookie as it stands, so it is not used on the server — `getUser()` asks the issuer to
verify it (the same rule as the auth-boundary section of backend-guide).
