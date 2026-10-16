<!-- orangekit-seam: react-vite+aws-container/frontend v3.34.0 -->
# Complete example — the Tasks feature (list + create)

This shows how one feature runs from type declaration to screen, in file order.
When building a new feature, follow this order exactly (types → request function → keys → hooks → screen → route).
The backend contract (the `{ data }` envelope, cursor pagination, branching on `code`) is in `data-fetching.md` §0.

```
src/features/tasks/
├── api/
│   ├── tasks.types.ts     # request/response contract + boundary narrowing
│   ├── tasks.api.ts       # endpoint functions
│   ├── tasks.keys.ts      # query key factory
│   └── tasks.hooks.ts     # useInfiniteQuery / useMutation
├── components/
│   ├── TaskTable.tsx
│   └── CreateTaskDialog.tsx
└── pages/
    └── TaskListPage.tsx
```

## 1. The contract (`api/tasks.types.ts`)

```ts
import { ApiError } from '@/api/http';

export type TaskStatus = 'open' | 'in_progress' | 'done';

export type Task = {
  id: string;
  title: string;
  status: TaskStatus;
  assigneeName: string | null;
  createdAt: string;      // ISO 8601 — convert to Date only just before display
};

/** The filter the screen owns. There is no `page` — the backend gives a cursor only */
export type TaskFilter = { status: TaskStatus | 'all'; limit?: number };
export type CreateTaskInput = { title: string; assigneeId?: string };

/** Boundary narrowing — passed to the `parse` option of the http client (types-and-testing.md §3) */
export function assertTask(v: unknown): asserts v is Task {
  const t = v as Record<string, unknown> | null;
  if (!t || typeof t.id !== 'string' || typeof t.title !== 'string') {
    throw new ApiError(500, 'BAD_SHAPE', 'The response shape differs from the contract.');
  }
}
export const parseTask = (v: unknown): Task => { assertTask(v); return v; };
```

Do not build a separate list-response type. `http.getPage` parses the envelope, and the screen sees only
`Page<Task>` (= `{ items, nextCursor }`).

## 2. Endpoint functions (`api/tasks.api.ts`)

```ts
import { http, type Page } from '@/api/http';
import { parseTask } from './tasks.types';
import type { CreateTaskInput, Task, TaskFilter } from './tasks.types';

const toQuery = (f: TaskFilter, cursor?: string) => {
  const q = new URLSearchParams();
  if (f.status !== 'all') q.set('status', f.status);
  q.set('limit', String(f.limit ?? 20));
  if (cursor) q.set('cursor', cursor);        // not attached on the first page
  return q.toString();
};

export const listTasks = (f: TaskFilter, cursor?: string, signal?: AbortSignal): Promise<Page<Task>> =>
  http.getPage<Task>(`/tasks?${toQuery(f, cursor)}`, { signal, parse: parseTask });

export const createTask = (input: CreateTaskInput) =>
  http.post<Task>('/tasks', input, { parse: parseTask });
```

URL assembly never leaks out of this file. The screen knows neither `/tasks` nor the name `cursor`.

## 3. Query keys (`api/tasks.keys.ts`)

```ts
import type { TaskFilter } from './tasks.types';

export const taskKeys = {
  all: ['tasks'] as const,
  lists: () => [...taskKeys.all, 'list'] as const,
  list: (f: TaskFilter) => [...taskKeys.lists(), f] as const,
  details: () => [...taskKeys.all, 'detail'] as const,
  detail: (id: string) => [...taskKeys.details(), id] as const,
};
```

**The same file with the same content** as `data-fetching.md` §2. Two copies of the factory let the invalidation key and
the query key drift apart silently. The cursor does not go in the key — the pages gather inside one cache entry.

## 4. Hooks (`api/tasks.hooks.ts`)

```ts
import { keepPreviousData, useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { createTask, listTasks } from './tasks.api';
import { taskKeys } from './tasks.keys';
import type { TaskFilter } from './tasks.types';

export function useTasksQuery(filter: TaskFilter) {
  return useInfiniteQuery({
    queryKey: taskKeys.list(filter),
    queryFn: ({ pageParam, signal }) => listTasks(filter, pageParam, signal),
    initialPageParam: undefined as string | undefined,      // required in v5
    getNextPageParam: (last) => last.nextCursor ?? undefined,  // null means the last page
    staleTime: 30_000,
    placeholderData: keepPreviousData,   // the list does not vanish when the filter changes
  });
}

export function useCreateTaskMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: createTask,
    onSuccess: (created) => {
      // the keys this mutation makes stale: every list query (whatever the filter)
      qc.invalidateQueries({ queryKey: taskKeys.lists() });
      qc.setQueryData(taskKeys.detail(created.id), created);
    },
  });
}
```

## 5. The screen (`pages/TaskListPage.tsx`)

```tsx
import { useState } from 'react';
import { useSearchParams } from 'react-router';
import { PageShell } from '@/components/layout/PageShell';
import { Button } from '@/components/common/Button';
import { EmptyState } from '@/components/common/EmptyState';
import { ErrorState } from '@/components/common/ErrorState';
import { ListSkeleton } from '@/components/common/ListSkeleton';
import { useTasksQuery } from '../api/tasks.hooks';
import type { TaskFilter } from '../api/tasks.types';
import { CreateTaskDialog } from '../components/CreateTaskDialog';
import { TaskTable } from '../components/TaskTable';

export function Component() {
  const [params, setParams] = useSearchParams();
  const [isDialogOpen, setDialogOpen] = useState(false);

  // the URL owns the filter (sharing · refresh · back come free). The cursor is not put there — it is an opaque value
  const filter: TaskFilter = { status: (params.get('status') as TaskFilter['status']) ?? 'all' };
  const query = useTasksQuery(filter);
  const setStatus = (status: TaskFilter['status']) => setParams({ status }, { replace: true });

  return (
    <PageShell title="Tasks" actions={<Button onClick={() => setDialogOpen(true)}>New task</Button>}>
      <StatusTabs value={filter.status} onChange={setStatus} />
      <TaskListBody query={query} filter={filter}
        onCreate={() => setDialogOpen(true)} onResetFilter={() => setStatus('all')} />
      <CreateTaskDialog open={isDialogOpen} onClose={() => setDialogOpen(false)} />
    </PageShell>
  );
}
Component.displayName = 'TaskListPage';

// further down the same file — a child component nothing outside uses does not get its own file.
// gathering the three-state branch here narrows the type through early returns, so `data?.pages ?? []` is unnecessary
function TaskListBody({ query, filter, onCreate, onResetFilter }: {
  query: ReturnType<typeof useTasksQuery>;
  filter: TaskFilter;
  onCreate: () => void;
  onResetFilter: () => void;
}) {
  const { data, isPending, isError, error, isFetching, refetch,
          fetchNextPage, hasNextPage, isFetchingNextPage } = query;

  if (isPending) return <ListSkeleton rows={5} />;
  if (isError) return <ErrorState error={error} onRetry={refetch} />;

  const tasks = data.pages.flatMap((p) => p.items);      // flatten the cursor pages into one
  if (tasks.length === 0) {
    return filter.status === 'all' ? (
      <EmptyState title="No tasks yet" description="Create a new task to get started."
        action={<Button onClick={onCreate}>New task</Button>} />
    ) : (
      <EmptyState title="No tasks match this filter"
        action={<Button variant="secondary" onClick={onResetFilter}>Reset filter</Button>} />
    );
  }
  return (
    <>
      {isFetching && !isFetchingNextPage && <TopProgressBar />}
      <TaskTable rows={tasks} />
      {/* not page numbers but "Load more" — all the backend gives is nextCursor */}
      {hasNextPage && (
        <Button variant="secondary" className="mt-4 w-full"
          disabled={isFetchingNextPage} onClick={() => fetchNextPage()}>
          {isFetchingNextPage ? 'Loading…' : 'Load more'}
        </Button>
      )}
    </>
  );
}
```

## 6. The create form (`components/CreateTaskDialog.tsx`)

```tsx
export function CreateTaskDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [title, setTitle] = useState('');
  const [fieldErrors, setFieldErrors] = useState<FieldErrors>({});   // Record<string, string[]>
  const { mutate, isPending } = useCreateTaskMutation();

  const submit = (e: FormEvent) => {
    e.preventDefault();
    setFieldErrors({});
    // client validation is only an early hint — the final ruling is the server's VALIDATION_FAILED
    if (title.trim().length < 2) {
      setFieldErrors({ title: ['The title must be at least 2 characters.'] });
      return;
    }
    mutate(
      { title: title.trim() },
      {
        onSuccess: () => { setTitle(''); onClose(); },   // invalidation is already handled by the hook's onSuccess
        onError: (err) => {
          if (err instanceof ApiError && err.code === 'VALIDATION_FAILED' && err.details) {
            setFieldErrors(err.details);                 // field → **array** of messages
          } else {
            toast.error(toUserMessage(err));             // includes 403/404 — hiding is UX, the ruling is the server's
          }
        },
      },
    );
  };

  if (!open) return null;
  return (
    <Dialog onClose={onClose} title="New task">
      <form onSubmit={submit} className="space-y-4">
        <Field label="Title" htmlFor="title" error={fieldErrors.title?.[0]}>
          <input id="title" value={title} onChange={(e) => setTitle(e.target.value)}
            className="h-10 w-full rounded-md border border-surface-border px-3 text-sm"
            aria-invalid={Boolean(fieldErrors.title)} autoFocus />
        </Field>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="secondary" onClick={onClose}>Cancel</Button>
          {/* without disabled, a double click creates two records */}
          <Button type="submit" disabled={isPending}>{isPending ? 'Saving…' : 'Save'}</Button>
        </div>
      </form>
    </Dialog>
  );
}
```

## 7. Route registration (`src/routes/routes.tsx`)

```tsx
{ element: <RequireAuth />, children: [    // the auth gate — a UX device; the server does the security
  { path: 'tasks', lazy: () => import('@/features/tasks/pages/TaskListPage') },
] }
```

## 8. Flow summary

```
URL(?status=open)
  → filter object                  (the cursor is not in the URL)
  → taskKeys.list(filter)          the query key
  → useTasksQuery                  cache lookup / GET /tasks?status=open&limit=20 when needed
  → http.getPage                   attaches the Bearer token · parses the { data, nextCursor } envelope · parseTask
  → three-state render             skeleton / error / empty / table
  → [Load more] fetchNextPage      GET /tasks?...&cursor=<nextCursor>

[Save clicked]
  → useCreateTaskMutation          POST /tasks → { data: Task }
  → onSuccess                      invalidateQueries(taskKeys.lists())
  → the list query mounted on the screen refetches → the new row appears
```

## Misuse list — the points where this example actually goes wrong

| The wrong form | Why it is a problem / the right form |
| --- | --- |
| Calling `fetch('/tasks')` directly from a screen | Token attachment · error normalization · base URL diverge screen by screen → go through the request function + hook |
| Implementing pagination with `page`/`total` | The backend gives only `nextCursor`. A total-count or page-number UI cannot be built → "Load more" or infinite scroll |
| Using the response as-is without `res.data` | The success envelope is `{ data }`. Unwrapping happens in `http.ts` alone |
| Expecting flat field errors such as `err.fieldErrors` | The failure envelope is `{ error: { code, message, details } }`, `details` appears on `VALIDATION_FAILED` only, and its values are **arrays** |
| Writing `queryKey: ['tasks', filter]` directly in a screen | It diverges from the invalidation key and the list never refreshes → always the `taskKeys` factory |
| Missing `invalidateQueries` after a create | The save succeeded but the list is unchanged. This is what "it shows up if you refresh" really is |
| `invalidateQueries({ queryKey: taskKeys.list(filter) })` | Only the current filter's list refreshes. Move to another tab and the list is stale → invalidate by prefix with `taskKeys.lists()` |
| Missing `initialPageParam` | It is required by `useInfiniteQuery` in v5. Without it the first request never starts |
| `setTasks([...tasks, created])` after a successful create | That duplicates the server cache into local state. Query already does this |
| Writing the success callback in both the hook and the screen | Invalidation belongs to the hook's `onSuccess` (always needed), closing the screen to the call site's `onSuccess` (that screen only) — split the responsibility |
| Keeping the filter in `useState` | It disappears on refresh · link sharing · back → `useSearchParams` |
| `data?.pages ?? []` with no loading branch | Loading and "no results" become the same screen → narrow it with an early return |
| Switching filters without `placeholderData` | On every switch the list disappears and is redrawn, so it flickers |
| Hiding only the button while ignoring 403/404 responses | Hiding is only UX and is bypassable. Someone else's resource comes back as 404, so prepare that wording too |
