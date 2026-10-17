<!-- orangekit-pack: frontend/react-vite v3.35.0 -->
# Loading · Empty · Error States

Every screen that draws data has at least three branches. A screen that implements only the success path goes
white on a slow network, with an expired session, and on an empty account.

## 1. The three states + background refresh

```tsx
export function Component() {
  const { data, isPending, isError, error, isFetching, refetch } = useTasksQuery(filter);

  if (isPending) return <ListSkeleton rows={5} />;                    // ① no data in the cache
  if (isError) return <ErrorState error={error} onRetry={refetch} />; // ② failure

  const tasks = data.pages.flatMap((p) => p.items);   // flatten the cursor pages into one
  if (tasks.length === 0) return <EmptyState title="No tasks yet" action={<CreateTaskButton />} />;

  return (
    <>
      {isFetching && <TopProgressBar />}   {/* ④ data is present and refreshing in the background */}
      <TaskTable rows={tasks} />
    </>
  );
}
```

The order matters. Check `isError` first and the error screen stays up during a retry; check the empty state
first and "no data" flashes during loading.

A query disabled with `enabled: false` is the exception — no request has ever gone out, so `isPending` is
permanently true. Apply this rule as written and the skeleton never goes away (see the §misuse list).

## 2. Choosing how to show loading

| Situation | Presentation |
| --- | --- |
| First entry, a list/card whose layout is known | Skeleton (no layout shift) |
| First entry, an area whose size is unknown | Centered spinner + a reserved minimum height |
| A refetch where data already exists | A thin progress bar at the top, or a slight dimming — do not clear the screen |
| A mutation after a button click | Spinner inside the button + `disabled` (blocks double submits) |
| Something that finishes within 200ms | Show nothing at all (the flicker is worse) |

```tsx
// A skeleton has the same box sizes as the real layout
export const ListSkeleton = ({ rows }: { rows: number }) => (
  <div className="space-y-3" role="status" aria-label="Loading">
    {Array.from({ length: rows }, (_, i) => (
      <div key={i} className="h-16 animate-pulse rounded-card bg-surface-muted" />
    ))}
  </div>
);
```

## 3. The empty state and the error state are one shared component each

Define the two components in `src/components/common/` **exactly once** and let every screen call them with the
same props. Call them in a different shape per screen and the signature splits, and the types break first.

<!-- file: src/components/common/EmptyState.tsx -->
```tsx
// src/components/common/EmptyState.tsx
import type { ReactNode } from 'react';

export type EmptyStateProps = { title?: string; description?: string; action?: ReactNode };

export function EmptyState({ title = 'No items to display', description, action }: EmptyStateProps) {
  return (
    <div className="rounded-card border border-dashed border-surface-border p-10 text-center">
      <p className="text-sm font-medium text-slate-900">{title}</p>
      {description && <p className="mt-1 text-sm text-slate-500">{description}</p>}
      {action && <div className="mt-4 flex justify-center">{action}</div>}
    </div>
  );
}
```

<!-- file: src/components/common/ErrorState.tsx -->
```tsx
// src/components/common/ErrorState.tsx
import { ApiError } from '@/lib/api/errors';
import { toUserMessage } from '@/lib/toUserMessage';
import { Button } from '@/components/ui/Button';

export type ErrorStateProps = {
  title?: string;
  message?: string;
  error?: unknown;          // pass it and the message·request ID are pulled out here
  onRetry?: () => void;     // without it the retry button is not drawn (403/404 are those cases)
};

export function ErrorState({ title = 'Something went wrong', message, error, onRetry }: ErrorStateProps) {
  const requestId = error instanceof ApiError ? error.requestId : undefined;
  return (
    <div role="alert" className="rounded-card border border-surface-border p-10 text-center">
      <p className="text-sm font-medium text-slate-900">{title}</p>
      <p className="mt-1 text-sm text-slate-500">{message ?? toUserMessage(error)}</p>
      {onRetry && (
        <Button variant="secondary" className="mt-4" onClick={onRetry}>Try again</Button>
      )}
      {/* The only thread back to the backend logs — if the user reports this value one request can be pinpointed */}
      {requestId && <p className="mt-3 text-xs text-slate-400">Request ID: {requestId}</p>}
    </div>
  );
}
```

There are two kinds of empty state, and their wording must differ.

- **Nothing yet**: "Create your first task" + a create button
- **No results for the filter**: "No tasks match your filter" + a reset-filter button

## 4. Classifying and handling errors — branch on `code`

The backend sends failures as `{ error: { code, message, details? }, requestId }`.
**The screen branches on `code`.** Because the same status code can carry different meanings.

| `code` | Status | What the screen does |
| --- | --- | --- |
| `NETWORK_ERROR` / `TIMEOUT` | — | "Check your connection" + a retry button (a code the client makes up) |
| `UNAUTHENTICATED` | 401 | Handled by the **auth layer**, not the screen (refresh → login on failure) |
| `FORBIDDEN` | 403 | Missing role·scope. "You do not have permission" — no retry button |
| `NOT_FOUND` | 404 | **A missing resource or someone else's resource** (the backend merged the two so as not to leak existence). "Not found, or you do not have access" + a link back to the list |
| `CONFLICT` | 409 | "Someone else edited this first" + refresh |
| `VALIDATION_FAILED` | 400 | The messages from `details` **under the relevant form field**, not in a toast |
| `PAYLOAD_TOO_LARGE` | 413 | "The content is too large" — guide the user to shorten the input |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | A client bug (a non-JSON body) — the generic error screen, no retry button |
| `INTERNAL` | 500 | A generic error screen + retry. Never surface the server's raw message |
| `RATE_LIMITED` | 429 | "Try again shortly" — **no automatic retry** |

The Status column is only the default. The screen branches on `code`, so this table does not change even when it is paired with
a backend (FastAPI) that sends the same `VALIDATION_FAILED` as a 422.

```tsx
export function toUserMessage(error: unknown): string {
  if (error instanceof ApiError) {
    switch (error.code) {
      case 'NETWORK_ERROR':
      case 'TIMEOUT':      return 'The connection failed. Please check your network.';
      case 'FORBIDDEN':    return 'You do not have permission to perform this action.';
      case 'NOT_FOUND':    return 'The requested item was not found, or you do not have access to it.';
      case 'CONFLICT':     return 'It was changed elsewhere first. Refresh and try again.';
      case 'VALIDATION_FAILED': return 'Please check your input again.';
      case 'PAYLOAD_TOO_LARGE': return 'The content is too large.';
      case 'INTERNAL':     return 'Something went wrong on our end.';
      default: return error.status === 429
        ? 'Too many requests. Please try again shortly.'
        : error.message;
    }
  }
  return 'Something went wrong. Please try again shortly.';
}
```

**403·404 are not retry material.** Give them a retry button and the user keeps pressing it, dirtying the server
logs and nothing else — omit `onRetry` from `ErrorState` and the button disappears.
**429 is not retried automatically either**: throwing it again without a backoff that honours `Retry-After` hits
the rate limit harder. Exclude all 4xx from the query's `retry` (`data-fetching.md` §5 —
the two files state one policy).

## 5. Form validation errors (`VALIDATION_FAILED`)

`details` is a **field name → array of messages**. Miss the fact that the value is an array rather than a
string and `[object Object]` shows up on screen.

```tsx
const { mutate, isPending } = useCreateTaskMutation();
const [fieldErrors, setFieldErrors] = useState<FieldErrors>({});   // Record<string, string[]>

const submit = (input: CreateTaskInput) => {
  setFieldErrors({});
  mutate(input, {
    onError: (e) => {
      if (e instanceof ApiError && e.code === 'VALIDATION_FAILED' && e.details) {
        setFieldErrors(e.details);            // use the per-field messages the server gave, as they are
      } else {
        toast.error(toUserMessage(e));        // sonner
      }
    },
  });
};

<Field label="Title" htmlFor="title" error={fieldErrors.title?.[0]}>…</Field>
```

Client validation is **UX guidance up front**, and the final verdict is the server's `VALIDATION_FAILED`. Put the rule only on the
client and it is bypassed by paths that call the API directly; put it only on the server and round trips pile up — put it in both.

## 6. Error boundaries

The last net that catches exceptions thrown during render. The boundary component comes from the
**`react-error-boundary`** package (`fallbackRender`·`onReset` are its API), and it goes in three tiers.

```tsx
import { ErrorBoundary } from 'react-error-boundary';
import { QueryErrorResetBoundary } from '@tanstack/react-query';

// ① At the app root — whatever slips through, no white screen (main.tsx)
// ② Route — the errorElement of createBrowserRouter (routing.md §4)
// ③ Widget — one dashboard card can die and the rest live on
<ErrorBoundary fallback={<WidgetError />}>
  <RevenueChart />
</ErrorBoundary>
```

To raise a query error up to the boundary, turn on `throwOnError: true` for that query and
reset the query on retry with `QueryErrorResetBoundary`.

```tsx
<QueryErrorResetBoundary>
  {({ reset }) => (
    <ErrorBoundary onReset={reset} fallbackRender={({ resetErrorBoundary }) => (
      <ErrorState onRetry={resetErrorBoundary} />
    )}>
      <TaskWidget />
    </ErrorBoundary>
  )}
</QueryErrorResetBoundary>
```

What an error boundary **does not catch**: exceptions inside event handlers, `setTimeout` callbacks,
and a rejected `mutate()`. Each of those must be caught where it happens.

## Misuse list — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `isPending` vs `isFetching` | `isPending` means "there is nothing to show yet" → replace the screen with a skeleton. `isFetching` means "a request is in flight" → keep the current screen + a thin indicator |
| `isPending` vs `isLoading` (v5) | In v5 `isLoading` is `isPending && isFetching`. Use `isPending` for the first-load branch |
| A query disabled with `enabled` | A disabled query has `isPending` **permanently true**, so the skeleton never goes away → branch on `isLoading` (or `isPending && isFetching`), or draw the parameter-less state as its own guidance screen |
| `isError` vs `error !== null` | Branch on `isError`. `error` is only for pulling out the message |
| An empty array vs `undefined` | Once the `isPending` branch has been passed, `data` is defined. Mash it down with `data?.pages ?? []` and loading and empty become the same screen |
| Branching on `error.status` vs on `error.code` | Wording is chosen by `code`. A single 404 doubles as "missing" and "unauthorized", so the status code alone cannot separate them |
| An error toast vs an inline error | If the whole screen cannot come up, inline (an error screen). The failure of an action the user just pressed is a toast. Field validation goes under the field |
| ErrorBoundary vs an `isError` branch | Foreseeable failures (no permission, missing resource) go in the `isError` branch. Only unforeseen render exceptions go to the boundary |
| `throwOnError` vs the default | The default (false) is the standard. Turn it on only when you want to bundle several queries on one screen and handle the failure once |
| Handling 401 in a screen vs in the auth layer | Never handle 401 in an individual screen. Refresh·logout are the responsibility of one place, the HTTP layer |
| `role="status"` vs `role="alert"` | A loading announcement is `status` (polite). A failure announcement is `alert` (read immediately) |
