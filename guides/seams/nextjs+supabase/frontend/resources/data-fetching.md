<!-- orangekit-seam: nextjs+supabase/frontend v3.12.0 -->
# Data Fetching

The standard fetching layer and its boundaries, Next.js 15 caching behavior, and the refresh-after-mutation pattern.

## 1. The standard fetching layer

```
Server Component (page.tsx · server-side child components)
  └→ lib/queries/*.ts        ← the single query entry point
       └→ lib/supabase/server.ts (createServerClient)
            └→ Supabase (PostgreSQL)
```

**Forbidden boundary (no direct call from a component):**

- No inline `supabase.from(…)` call in a component (server or client) — always go through `lib/queries/`
- No server-data query from a client component — server data is fetched by a Server Component
  and passed down as props (the exception is §9: realtime subscription · auth-state UI)
- Do not add a separate client fetching library — the standard for this stack is Server Component fetching

**Clarifying the scope of the ban — an auth check is not a data query.** What is banned is a **row query** (`supabase.from(…)`).
Checking the session with `createClient()` + `auth.getUser()` **may be called directly** in a page, layout or
Server Action — it is not wrapped in the query layer (deciding to redirect is the route's responsibility).

## 2. The Supabase server client

```ts
// lib/supabase/server.ts
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'

export async function createClient() {
  const cookieStore = await cookies()          // Next.js 15: cookies() is async

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options))
          } catch {
            // When called from a Server Component writing is impossible — it is safe to ignore.
            // Session refresh is the middleware's job (resources/routing.md)
          }
        },
      },
    }
  )
}
```

- The server client is **created anew for every request** — no caching in a global (risk of mixing sessions)
- Identify the user always with `supabase.auth.getUser()` — `getSession()` is not trusted on the server

## 3. Query function conventions (`lib/queries/`)

```ts
// lib/queries/tasks.ts
import { createClient } from '@/lib/supabase/server'

export interface Task { id: string; title: string; done: boolean; created_at: string }

export async function getTasks(): Promise<Task[]> {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('tasks')
    .select('id, title, done, created_at')   // name only the columns you need (avoid select('*'))
    .order('created_at', { ascending: false })
    .limit(50)

  if (error) throw error                      // the error.tsx boundary handles it
  return data
}
```

- Split files by domain: `lib/queries/tasks.ts`, `lib/queries/profiles.ts`
- State the return type explicitly and export it so components can reuse it
- Errors are thrown — do not try/catch in a component (form errors are the only exception, §7)
- Table design and RLS policies are owned by backend-guide — this file covers query patterns only

## 4. Use from a page: parallel fetching and per-request dedupe

```tsx
// Sequential awaits create a waterfall — run independent queries in parallel
const [tasks, profile] = await Promise.all([getTasks(), getProfile()])
```

```ts
// Queries several components call within the same request are deduped with React cache()
import { cache } from 'react'

export const getProfile = cache(async (): Promise<Profile | null> => {/* … */})
```

## 5. Search · filter · pagination — translating `searchParams` into a server query

The URL is the state (see the URL-state section of resources/state-management.md). The page awaits
`searchParams` and passes it as a query argument, and the query function turns that into Supabase conditions.

```ts
// lib/queries/tasks.ts
export interface TaskPage { tasks: Task[]; total: number; totalPages: number }

const PAGE_SIZE = 20

export async function searchTasks(query: string, page: number): Promise<TaskPage> {
  const supabase = await createClient()
  const offset = (page - 1) * PAGE_SIZE

  let builder = supabase
    .from('tasks')
    .select('id, title, done, created_at', { count: 'exact' })   // count fetches the total at the same time
    .order('created_at', { ascending: false })
    .range(offset, offset + PAGE_SIZE - 1)                       // the end index is inclusive

  if (query) builder = builder.ilike('title', `%${query}%`)      // partial-match search

  const { data, count, error } = await builder
  if (error) throw error

  const total = count ?? 0
  return { tasks: data, total, totalPages: Math.max(1, Math.ceil(total / PAGE_SIZE)) }
}
```

```tsx
// app/(main)/tasks/page.tsx — searchParams is a Promise (Next.js 15)
interface TasksPageProps { searchParams: Promise<{ q?: string; page?: string }> }

export default async function TasksPage({ searchParams }: TasksPageProps) {
  const { q = '', page = '1' } = await searchParams
  const { tasks, totalPages } = await searchTasks(q, Number(page) || 1)
  return <TaskList tasks={tasks} /* pass totalPages to the pagination UI */ />
}
```

- `count: 'exact'` counts the whole table on every request — if that is slow on a large table, switch to `'planned'` (an estimate)
  or to infinite scroll (which only checks whether a next page exists)
- Going past the last page returns an empty array — treat it as an empty state, not an error
- Pass user input **as a value** to builder methods such as `ilike` · `eq` (never concatenate raw strings).
  The URL-writing side is `useQueryParams` (state-management), debouncing is performance

## 6. Next.js 15 caching behavior

- A query through the Supabase client is **dynamic** — it runs on every request (because it touches cookies)
- `fetch()` is also **no-store** by default from Next.js 15 — opt in explicitly to cache it
- Refresh after a mutation happens on the server: `revalidatePath('/tasks')` or `revalidateTag(…)` inside the Server Action
- Manual refresh from the client is `router.refresh()` — it re-runs the server components of the current route
  (client state is kept)

## 7. Mutations (the frontend contract)

Mutations go through a **Server Action**. Form → `useActionState` → action →
`revalidatePath` → server re-render is the standard loop. No client refetch code is needed.

```tsx
// app/(main)/tasks/_components/new-task-form.tsx
'use client'

import { useActionState } from 'react'
import { createTask, type ActionState } from '../actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

const initialState: ActionState = { error: null }

export function NewTaskForm() {
  const [state, formAction, isPending] = useActionState(createTask, initialState)

  return (
    <form action={formAction} className="flex gap-2">
      <Input name="title" placeholder="Task" required disabled={isPending} />
      <Button type="submit" disabled={isPending}>{isPending ? 'Adding…' : 'Add'}</Button>
      {state.error && <p className="text-sm text-destructive">{state.error}</p>}
    </form>
  )
}
```

- Show the submitting state with `isPending` — disabling the button is required
- Receive failure as the action's **return value** and show it inline (throwing sends it to error.tsx)
- Once the action completes the uncontrolled form is reset regardless of success or failure — for preserving input on failure (`values` →
  re-injected as `defaultValue`) and per-field errors (`fieldErrors`) see resources/complete-example.md
- Button-style mutations (delete · toggle) use `useTransition` — resources/state-management.md
- Validation, permissions and error design inside the action are owned by backend-guide — the frontend knows only the call contract

## 8. Optimistic UI — `useOptimistic`

Draw the result **first**, without waiting for the server round trip (action + revalidate + re-render). When the action
finishes, React discards the optimistic value and falls back to the real list the server gave — no rollback code is needed.

```tsx
// app/(main)/tasks/_components/task-list-optimistic.tsx
'use client'

import { useOptimistic, useTransition } from 'react'
import { toggleTask } from '../actions'
import type { Task } from '@/lib/queries/tasks'

export function TaskListOptimistic({ tasks }: { tasks: Task[] }) {
  const [, startTransition] = useTransition()
  const [optimisticTasks, toggleOptimistic] = useOptimistic(
    tasks,                                       // the real list from the server is always the baseline
    (current: Task[], id: string) =>             // the optimistic update rule
      current.map((t) => (t.id === id ? { ...t, done: !t.done } : t))
  )

  const handleToggle = (id: string) => {
    startTransition(async () => {
      toggleOptimistic(id)                       // applied immediately (callable only inside a transition)
      await toggleTask(id)                       // the action refreshes the real list via revalidatePath
    })
  }

  return (
    <ul className="space-y-2">
      {optimisticTasks.map((task) => (
        <li key={task.id}>
          <button onClick={() => handleToggle(task.id)}>{task.done ? '✓' : '○'} {task.title}</button>
        </li>
      ))}
    </ul>
  )
}
```

- The first argument of `useOptimistic` must be **the server data received through props** — copying it with `useState`
  means the revalidate result never shows up
- The update function is called only inside `startTransition` (or a form action)
- If the action fails the optimistic value disappears and the UI returns to its original state — the user has to be told,
  so show the failure message separately from the action return value

## 9. Permitted uses of the browser client

```ts
// lib/supabase/client.ts
import { createBrowserClient } from '@supabase/ssr'

export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  )
}
```

There are only two cases for using the browser client in a client component.
① **Auth UI**: sign-in/sign-out calls, `onAuthStateChange` subscription.
② **Realtime subscription**: receiving change notifications to trigger `router.refresh()`.

```tsx
// app/(main)/tasks/_components/tasks-realtime.tsx
'use client'                                   // Realtime is a "notification" only — the server does the re-query

import { useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

export function TasksRealtime() {
  const router = useRouter()

  useEffect(() => {
    const supabase = createClient()
    const channel = supabase
      .channel('tasks-changes')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'tasks' },
        () => router.refresh())
      .subscribe()
    return () => { supabase.removeChannel(channel) }
  }, [router])

  return null                                  // nothing to render — a subscription-only leaf component
}
```

Any data query outside these two cases follows the forbidden boundary of §1.

## 10. Streaming — split a slow query behind Suspense

```tsx
// Awaiting every query at the top level lets the slowest query block everything —
// move the slow part into a server child component and wrap it in Suspense so the shell paints first.
export default async function DashboardPage() {
  const profile = await getProfile()          // the fast query runs immediately
  return (
    <main>
      <ProfileHeader profile={profile} />
      <Suspense fallback={<Skeleton className="h-40 w-full" />}>
        <SlowStatsPanel />                    {/* awaits getStats() internally */}
      </Suspense>
    </main>
  )
}
```
