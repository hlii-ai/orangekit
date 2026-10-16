<!-- orangekit-pack: frontend/nextjs v3.12.0 -->
# Routing

App Router route definitions·nested layouts·navigation·metadata. Protected routes and session refresh live in `resources/auth-and-session.md`.

## 1. File conventions

| File | Role |
| --- | --- |
| `page.tsx` | The route's UI — the URL is reachable only if this file exists |
| `layout.tsx` | Shared UI wrapping the child segments — does not re-render between navigations |
| `loading.tsx` | Segment loading UI (an implicit Suspense boundary) |
| `error.tsx` | Segment error boundary (`'use client'` required) |
| `not-found.tsx` | The UI shown when `notFound()` is called |
| `template.tsx` | Like a layout, but remounted on every navigation (entry animations and the like) |
| `route.ts` | Route Handler (API) — owned by backend-guide |

## 2. Dynamic routes — `params`·`searchParams` are Promises

```tsx
// app/(main)/tasks/[id]/page.tsx — URL: /tasks/<id>
import { notFound } from 'next/navigation'
import { getTask } from '@/lib/queries/tasks'

interface PageProps {
  params: Promise<{ id: string }>
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>
}

export default async function TaskDetailPage({ params }: PageProps) {
  const { id } = await params            // Next.js 15: await is mandatory
  const task = await getTask(id)
  if (!task) notFound()
  return <TaskDetail task={task} />
}
```

- `[id]` — a single segment, `[...slug]` — catch-all, `[[...slug]]` — optional catch-all
- For a resource that does not exist, call `notFound()` → the nearest `not-found.tsx` is shown

## 3. Route groups and private folders

```
app/
├── (auth)/                        # parentheses = not in the URL, used to split layouts per group
│   ├── layout.tsx                 # auth-only layout (no app chrome)
│   └── login/page.tsx             # URL: /login
└── (main)/
    ├── layout.tsx                 # app-only layout (header·sidebar)
    └── tasks/
        ├── page.tsx               # URL: /tasks
        └── _components/           # underscore prefix = excluded from routing (for colocation)
```

- Route group `(name)`: splits the layout boundary without changing the URL structure
- Private folder `_name`: keeps route-only components·utilities next to the route while excluding them from the URL

## 4. Nested layouts

```tsx
// app/(main)/layout.tsx — shared by every page in the (main) group
import { AppSidebar } from '@/components/layout/app-sidebar'
import { AppHeader } from '@/components/layout/app-header'

export default function MainLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen">
      <AppSidebar />
      <div className="flex-1">
        <AppHeader />
        {children}
      </div>
    </div>
  )
}
```

- Layouts nest: root layout → group layout → page
- A layout keeps its state between navigations and does not re-render —
  UI that depends on the current page (highlighting the active menu) is split into a client leaf using `usePathname`

### An auth-conditional header — branch on the server

A header that shows a user menu or a login button depending on sign-in state is built as a **Server Component**.
Query the session on the client and the login button flashes on the first render before it switches (a flicker).

<!-- file: components/layout/app-header.tsx -->
```tsx
// components/layout/app-header.tsx (Server Component — no 'use client')
import Link from 'next/link'
import { getCurrentUser } from '@/lib/auth'    // the auth layer — implemented by the backend axis
import { Button } from '@/components/ui/button'
import { UserMenu } from './user-menu'          // 'use client' — dropdown·logout button

export async function AppHeader() {
  const user = await getCurrentUser()          // checked on the server — a client query creates the flicker

  return (
    <header className="flex h-14 items-center justify-between border-b px-4">
      <Link href="/" className="font-semibold">Tasks</Link>
      {user ? (
        <UserMenu email={user.email ?? ''} /* pass only serializable values */ />
      ) : (
        <Button asChild size="sm"><Link href="/login">Log in</Link></Button>
      )}
    </header>
  )
}
```

- Do not hand the whole `user` object to the client; pass down only the fields you need as props
- Base a role·permission display on the profile row queried on the server, not on `user.user_metadata`
  (`user_metadata` is editable by the user — never use it for authorization, owned by backend-guide)

## 5. Navigation

```tsx
// Declarative navigation — the default
<Link href="/tasks" className="underline-offset-4 hover:underline">Tasks</Link>

// Programmatic navigation from a client component
const router = useRouter()
router.push('/tasks')       // pushes history
router.replace('/login')    // replaces history
router.refresh()            // re-runs the server components of the current route

// From server code (Server Component·Server Action)
redirect('/login')          // throw-based — code after the call does not run
```

- Never navigate internally with an `<a>` tag — always `<Link>`
- The current path is `usePathname()`, the query is `useSearchParams()` (both are client hooks)

## 6. Metadata

```tsx
// Static
import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'Tasks',
  description: 'Task list',
}

// Dynamic — data-driven
export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { id } = await params
  const task = await getTask(id)
  return { title: task?.title ?? 'Task' }
}
```

- Put `title.template` (`'%s | Service name'`) in the root `layout.tsx` and each page only has to fill in its title
