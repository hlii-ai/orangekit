<!-- orangekit-seam: nextjs+supabase/frontend v3.31.0 -->
# Complete Example — Tasks (list + create)

One feature from start to finish: **reading the task list + creating a new item**.
The whole loop of Server Component fetch → Server Action mutation → `revalidatePath` refresh.

## 0. The contract this example uses

What makes the frontend and the backend see the same thing is not the schema but the **wire contract**
(`dev/docs/api/wire-contract.md` in a project). This example consumes two sections of that contract:

- Vocabulary (§0): entity `Task` · collection `tasks` · display label Task
- The Server Action boundary (§6): `ActionState` — a form error is returned in the type, not thrown

The Server Component reads the data layer directly, so this example does not consume the HTTP envelope of §1–§5.
Below is **the schema that satisfies this contract** — not a precondition but the backend-side face of the same contract,
and the table · RLS · validation design is owned by backend-guide. The screen settles first and the schema follows it.

- `tasks` table: `id uuid pk` · `user_id uuid` · `title text` · `done boolean` · `created_at timestamptz`
- RLS allows access to the caller's own rows only
- `lib/supabase/server.ts` · `middleware.ts` are already configured
  (resources/data-fetching.md and resources/routing.md respectively)

## 1. File layout

```
app/(main)/tasks/
├── page.tsx                    # Server Component — fetches the list + assembles
├── loading.tsx                 # route loading skeleton
├── error.tsx                   # route error boundary
├── actions.ts                  # Server Actions — create · delete · toggle
└── _components/
    ├── task-list.tsx           # Server Component — list + empty state
    └── new-task-form.tsx       # Client Component — form + useActionState
lib/queries/tasks.ts            # query functions + types
components/common/empty-state.tsx  # shared empty state (resources/component-patterns.md §5)
```

## 2. Query layer — `lib/queries/tasks.ts`

```ts
import { createClient } from '@/lib/supabase/server'

export interface Task {
  id: string
  title: string
  done: boolean
  created_at: string
}

export async function getTasks(): Promise<Task[]> {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('tasks')
    .select('id, title, done, created_at')
    .order('created_at', { ascending: false })
    .limit(50)

  if (error) throw error
  return data
}
```

## 3. Page — `app/(main)/tasks/page.tsx`

```tsx
import type { Metadata } from 'next'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTasks } from '@/lib/queries/tasks'
import { TaskList } from './_components/task-list'
import { NewTaskForm } from './_components/new-task-form'

export const metadata: Metadata = { title: 'Tasks' }

export default async function TasksPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')              // second check, after the middleware

  const tasks = await getTasks()             // RLS returns only the caller's rows

  return (
    <main className="mx-auto max-w-2xl space-y-6 p-6">
      <h1 className="text-2xl font-semibold">Tasks</h1>
      <NewTaskForm />
      <TaskList tasks={tasks} />
    </main>
  )
}
```

## 4. Loading and error — `loading.tsx` / `error.tsx`

```tsx
// app/(main)/tasks/loading.tsx
import { Skeleton } from '@/components/ui/skeleton'

export default function TasksLoading() {
  return (
    <div className="mx-auto max-w-2xl space-y-4 p-6">
      <Skeleton className="h-8 w-32" />
      <Skeleton className="h-10 w-full" />
      <Skeleton className="h-14 w-full" />
      <Skeleton className="h-14 w-full" />
    </div>
  )
}
```

```tsx
// app/(main)/tasks/error.tsx
'use client'

import { Button } from '@/components/ui/button'

export default function TasksError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="mx-auto max-w-2xl p-8 text-center">
      <p className="text-sm text-destructive">Could not load the list.</p>
      <Button variant="outline" onClick={reset} className="mt-4">Try again</Button>
    </div>
  )
}
```

## 5. List — `app/(main)/tasks/_components/task-list.tsx` (Server Component)

```tsx
import { EmptyState } from '@/components/common/empty-state'   // defined in: component-patterns.md §5
import { cn } from '@/lib/utils'
import type { Task } from '@/lib/queries/tasks'

interface TaskListProps {
  tasks: Task[]
}

export function TaskList({ tasks }: TaskListProps) {
  if (tasks.length === 0) {
    return (
      <EmptyState
        title="No tasks yet."
        description="Add your first item with the form above."
      />
    )
  }

  return (
    <ul className="space-y-2">
      {tasks.map((task) => (
        <li key={task.id} className="flex items-center gap-3 rounded-lg border bg-card p-4">
          <span className={cn('flex-1 text-sm', task.done && 'text-muted-foreground line-through')}>
            {task.title}
          </span>
          <time className="text-xs text-muted-foreground">
            {new Date(task.created_at).toLocaleDateString('en-US')}
          </time>
        </li>
      ))}
    </ul>
  )
}
```

## 6. Create action — `app/(main)/tasks/actions.ts`

```ts
'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export interface ActionState {
  error: string | null                       // whole-form error (matches formError in backend-guide)
  fieldErrors?: Record<string, string[] | undefined>   // per-field errors — the same shape as backend-guide
  values?: { title: string }                 // preserves the input on failure
}

export async function createTask(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const title = String(formData.get('title') ?? '').trim()
  if (!title) return { error: null, fieldErrors: { title: ['Enter a title.'] } }
  if (title.length > 200)
    return { error: null, fieldErrors: { title: ['Enter 200 characters or fewer.'] }, values: { title } }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { error: 'Sign-in required.', values: { title } }

  const { error } = await supabase.from('tasks').insert({ title, user_id: user.id })
  if (error) return { error: 'Could not save. Try again in a moment.', values: { title } }

  revalidatePath('/tasks')                   // triggers a server re-render of the list (by URL — parenthesized folders are not in the URL)
  return { error: null }
}
```

A button-style mutation uses the same contract — it is not a form, so it takes only `(id)`
(the call site is the `useTransition` section of resources/state-management.md).

```ts
export async function deleteTask(id: string): Promise<ActionState> {
  const supabase = await createClient()
  const { error } = await supabase.from('tasks').delete().eq('id', id)   // RLS checks ownership
  if (error) return { error: 'Could not delete.' }
  revalidatePath('/tasks')
  return { error: null }
}

export async function toggleTask(id: string): Promise<ActionState> { /* same, after update({ done }) */ }
```

Deeper validation (a schema validation library) and error design follow backend-guide — this file shows only the return
contract the frontend depends on. If you validate with Zod the way backend-guide prescribes,
`z.flattenError(parsed.error).fieldErrors` lands straight in the `fieldErrors` slot above, so
the form rendering code below does not need to change.

## 7. Form — `app/(main)/tasks/_components/new-task-form.tsx` (Client Component)

```tsx
'use client'

import { useActionState } from 'react'
import { createTask, type ActionState } from '../actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

const initialState: ActionState = { error: null }

export function NewTaskForm() {
  const [state, formAction, isPending] = useActionState(createTask, initialState)

  const titleError = state.fieldErrors?.title?.[0]

  return (
    <form action={formAction} className="space-y-2">
      <div className="flex gap-2">
        <Input
          name="title"
          placeholder="Enter a task"
          defaultValue={state.values?.title}
          aria-invalid={!!titleError}
          aria-describedby={titleError ? 'title-error' : undefined}
          required
          maxLength={200}
          disabled={isPending}
        />
        <Button type="submit" disabled={isPending}>
          {isPending ? 'Adding…' : 'Add'}
        </Button>
      </div>
      {/* a field error goes directly under its input */}
      {titleError && <p id="title-error" className="text-sm text-destructive">{titleError}</p>}
      {/* a whole-form error (auth · save failure) goes at the bottom of the form */}
      {state.error && <p className="text-sm text-destructive">{state.error}</p>}
    </form>
  )
}
```

React 19 resets an uncontrolled form **once the action completes, whether it succeeded or failed**.
The reset returns each input to its `defaultValue`, so re-injecting the `values` the action returned on failure
as `defaultValue` preserves the input — on success there is no `values`, so the
form empties. No separate reset code is needed.

## 8. Flow summary

```
[read]   request → middleware (session refresh · gate) → page.tsx
       → re-check getUser() → getTasks() → render TaskList
       (loading.tsx during the transition, error.tsx when the query throws)

[create] NewTaskForm submit → createTask action (server)
       → validate → getUser → insert → revalidatePath('/tasks')
       → server re-render → the new list appears automatically, the form is emptied
       (on failure it returns { error | fieldErrors, values } →
        fieldErrors inline under its input, error inline at the bottom of the form,
        the reset input preserved by defaultValue={state.values?.title})
```

## 9. Checkpoints

- [ ] Reads go through `lib/queries/` — no inline query inside a component
- [ ] `getUser()` is re-checked in the page (the middleware alone is not trusted)
- [ ] All three states exist: loading (`loading.tsx`) · empty (inside TaskList) · error (`error.tsx`)
- [ ] Mutations use a Server Action + `revalidatePath` — no client refetch code
- [ ] Form errors are inline (field errors under the input, form errors at the bottom), read errors go to the boundary — the paths differ
- [ ] The form is the only client component — everything else is a Server Component
