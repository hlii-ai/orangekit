<!-- orangekit-pack: frontend/react-vite v3.35.0 -->
# Complete Example — task list · create · status transition · detail (404)

This walks one feature from start to finish. The data layer (`tasks.types` · `tasks.api` · `tasks.queries`) already exists as
complete files in `resources/data-fetching.md` and `resources/types-and-testing.md` §3 — here we write only **the three screens that consume it, and the tests**. It is independent of the auth method:
the http layer attaches the token, and a 401 never reaches a screen.

| Screen action | Wire | What the screen sees |
| --- | --- | --- |
| First page of the list | `GET /api/tasks?limit=20` | `data.pages[0].items` |
| Load more | `GET /api/tasks?limit=20&cursor=<nextCursor>` | `hasNextPage` · `fetchNextPage()` |
| Create | `POST /api/tasks` `{ title }` → 201 | success: invalidate the list · failure: `details` under the field |
| Status transition | `PATCH /api/tasks/:id` `{ status }` | success: invalidate the list |
| Detail | `GET /api/tasks/:id` → 404 `NOT_FOUND` | one screen: "missing or you have no access" |

## 1. The create form (`features/tasks/components/CreateTaskForm.tsx`)

<!-- file: src/features/tasks/components/CreateTaskForm.tsx -->
```tsx
// src/features/tasks/components/CreateTaskForm.tsx
import { useState, type FormEvent } from 'react';
import { toast } from 'sonner';
import { Field } from '@/components/common/Field';
import { Button } from '@/components/ui/Button';
import { ApiError, type FieldErrors } from '@/lib/api/errors';
import { toUserMessage } from '@/lib/toUserMessage';
import { useCreateTaskMutation } from '../api/tasks.queries';

export function CreateTaskForm() {
  const [title, setTitle] = useState('');
  const [fieldErrors, setFieldErrors] = useState<FieldErrors>({});
  const { mutate, isPending } = useCreateTaskMutation();

  const submit = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setFieldErrors({});
    mutate({ title }, {
      onSuccess: () => setTitle(''),
      onError: (err) => {
        // A validation failure goes under the field, not into a toast. Only other failures are toasted
        if (err instanceof ApiError && err.code === 'VALIDATION_FAILED' && err.details) setFieldErrors(err.details);
        else toast.error(toUserMessage(err));
      },
    });
  };

  return (
    <form onSubmit={submit} className="flex items-end gap-2" noValidate>
      <div className="flex-1">
        <Field label="Title" htmlFor="task-title" error={fieldErrors.title?.[0] ?? fieldErrors._?.[0]}>
          <input id="task-title" value={title} onChange={(e) => setTitle(e.target.value)}
                 className="h-10 w-full rounded-md border px-3 text-sm" />
        </Field>
      </div>
      <Button type="submit" disabled={isPending}>New task</Button>
    </form>
  );
}
```

- Adding client-side validation is fine, but **the final ruling is the server's `VALIDATION_FAILED`** — so there must first
  be a place to plug the server's `details` in as is
- A `details` value is an **array**. Drop the `[0]` and the array is printed on screen as is

## 2. The list screen — cursor pages · status transition

<!-- file: src/features/tasks/pages/TaskListPage.tsx -->
```tsx
// src/features/tasks/pages/TaskListPage.tsx
import { Link, useSearchParams } from 'react-router';
import { toast } from 'sonner';
import { DataTable } from '@/components/common/DataTable';
import { EmptyState } from '@/components/common/EmptyState';
import { ErrorState } from '@/components/common/ErrorState';
import { ListSkeleton } from '@/components/common/ListSkeleton';
import { PageShell } from '@/components/layout/PageShell';
import { Button } from '@/components/ui/Button';
import { toUserMessage } from '@/lib/toUserMessage';
import { useTasksQuery, useUpdateTaskStatusMutation } from '../api/tasks.queries';
import type { Task, TaskFilter } from '../api/tasks.types';
import { CreateTaskForm } from '../components/CreateTaskForm';

const STATUS_VALUES: TaskFilter['status'][] = ['all', 'open', 'done'];

export function Component() {
  const [params, setParams] = useSearchParams();
  const raw = params.get('status');
  const filter: TaskFilter = { status: STATUS_VALUES.find((s) => s === raw) ?? 'all' };   // the URL is a value from outside

  const { data, isPending, isError, error, refetch, hasNextPage, fetchNextPage, isFetchingNextPage } =
    useTasksQuery(filter);
  const toggle = useUpdateTaskStatusMutation();

  const flip = (t: Task) =>
    toggle.mutate({ id: t.id, status: t.status === 'open' ? 'done' : 'open' },
      { onError: (e) => toast.error(toUserMessage(e)) });   // on 404 the "missing or no access" message appears

  let body;
  if (isPending) body = <ListSkeleton rows={5} />;
  else if (isError) body = <ErrorState error={error} onRetry={() => void refetch()} />;
  else {
    const tasks = data.pages.flatMap((p) => p.items);
    body = (
      <>
        <DataTable
          rows={tasks}
          empty={<EmptyState title="No tasks yet" description="Create your first task above." />}
          columns={[
            { key: 'title', header: 'Title', cell: (t) => <Link to={`/tasks/${t.id}`}>{t.title}</Link> },
            { key: 'status', header: 'Status', cell: (t) => (
              <Button size="sm" variant="secondary" disabled={toggle.isPending} onClick={() => flip(t)}>
                {t.status === 'open' ? 'Mark done' : 'Reopen'}
              </Button>
            ) },
          ]}
        />
        {hasNextPage && (
          <Button variant="ghost" className="mt-4" disabled={isFetchingNextPage} onClick={() => void fetchNextPage()}>
            {isFetchingNextPage ? 'Loading…' : 'Load more'}
          </Button>
        )}
      </>
    );
  }

  return (
    <PageShell title="Tasks" actions={
      <select aria-label="Status filter" value={filter.status}
              onChange={(e) => setParams({ status: e.target.value }, { replace: true })}>
        <option value="all">All</option><option value="open">Open</option><option value="done">Done</option>
      </select>
    }>
      <CreateTaskForm />
      <div className="mt-6">{body}</div>
    </PageShell>
  );
}
Component.displayName = 'TaskListPage';
```

- The branch order is `isPending` → `isError` → empty list (`loading-error-states.md` §1). The empty list is
  drawn by `DataTable`'s `empty` slot
- **A page-number · total-count UI cannot be built.** The contract gives only a cursor — "Load more" is the only shape
- The cursor does not go in the URL. Only the filter lives in the URL (`routing.md` §5)

## 3. The detail screen — 404 means "missing or not yours"

<!-- file: src/features/tasks/pages/TaskDetailPage.tsx -->
```tsx
// src/features/tasks/pages/TaskDetailPage.tsx
import { Link, useParams } from 'react-router';
import { ErrorState } from '@/components/common/ErrorState';
import { ListSkeleton } from '@/components/common/ListSkeleton';
import { PageShell } from '@/components/layout/PageShell';
import { ApiError } from '@/lib/api/errors';
import { useTaskQuery } from '../api/tasks.queries';

export function Component() {
  const { taskId = '' } = useParams();
  const { data: task, isPending, isError, error, refetch } = useTaskQuery(taskId);

  if (isPending) return <ListSkeleton rows={1} />;
  if (isError) {
    if (error instanceof ApiError && error.code === 'NOT_FOUND') {
      // The server returns someone else's task as 404 too (so existence does not leak). Do not try to tell them apart — and no retry
      return (
        <PageShell title="Task not found">
          <p className="text-sm text-slate-500">This task does not exist or you do not have access to it.</p>
          <Link to="/tasks" className="mt-4 inline-block text-sm underline">Back to the list</Link>
        </PageShell>
      );
    }
    return <ErrorState error={error} onRetry={() => void refetch()} />;
  }
  return (
    <PageShell title={task.title}>
      <p className="text-sm text-slate-500">Status: {task.status === 'open' ? 'Open' : 'Done'}</p>
      <p className="text-xs text-slate-400">Created: {new Date(task.createdAt).toLocaleString('en-US')}</p>
    </PageShell>
  );
}
Component.displayName = 'TaskDetailPage';
```

## 4. Tests — blocking and passing in one test

<!-- file: src/features/tasks/pages/TaskListPage.test.tsx -->
```tsx
// src/features/tasks/pages/TaskListPage.test.tsx
import { screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { expect, it, vi } from 'vitest';
import { http, HttpResponse } from 'msw';
import { server } from '@/test/msw/server';
import { renderWithProviders } from '@/test/renderWithProviders';
import { Component as TaskListPage } from './TaskListPage';

it('shows the server details under the field for an empty title, and creates the corrected title', async () => {
  let created = 0;
  server.use(http.post('*/api/tasks', async ({ request }) => {
    const { title } = (await request.json()) as { title: string };
    if (title.trim().length < 2) {
      return HttpResponse.json({ error: { code: 'VALIDATION_FAILED', message: 'Invalid input',
        details: { title: ['Enter at least 2 characters.'] } }, requestId: 'req_1' }, { status: 400 });
    }
    created += 1;
    return HttpResponse.json({ data: { id: 't9', title, status: 'open',
      createdAt: '2026-10-01T00:00:00.000Z' } }, { status: 201 });
  }));
  const user = userEvent.setup();
  renderWithProviders(<TaskListPage />, { route: '/tasks' });

  await user.click(await screen.findByRole('button', { name: 'New task' }));
  expect(await screen.findByText('Enter at least 2 characters.')).toBeInTheDocument();   // blocked
  expect(created).toBe(0);

  await user.type(screen.getByLabelText('Title'), 'Write the report');
  await user.click(screen.getByRole('button', { name: 'New task' }));
  await vi.waitFor(() => expect(created).toBe(1));                                         // passes
  expect(screen.queryByText('Enter at least 2 characters.')).not.toBeInTheDocument();
});
```

With only a failure assertion, the test is green even if the handler returns 400 for everything. Only by also asserting, in the same
`it`, that the corrected input **actually goes through to creation** can you tell "blocked" apart from "all broken".

## Misuse list ① — old habit → this example's form

| Old habit | The current form |
| --- | --- |
| `useQuery` + `page` state + page-number buttons | `useInfiniteQuery` + "Load more" — the contract gives only a cursor |
| `push` the created response into the list cache | Invalidate the list. Wedge it inside the cursor boundaries and it duplicates the next page |
| Toast every failure | Validation failures under the field, only the rest as a toast |
| Split 403 · 404 into "no permission" · "not found" | One 404 screen. The server merged them on purpose |

## Misuse list ② — confusable pairs

| The confused pair | The exact condition for each |
| --- | --- |
| `isPending` vs `isFetchingNextPage` | The first load is a skeleton, the next page is shown inside the button — do not clear the list |
| Passing `onRetry` to `ErrorState` vs omitting it | Omit it for `NOT_FOUND` · `FORBIDDEN` (a retry gives the same result). Pass it only for connection · server errors |
| `details.title` vs `details._` | A field key goes under that field; `_` is a form-wide error |
| `getByText` vs `findByText` | Text that appears after a server response uses `findByText`. A disappearance assertion uses `queryByText` |
