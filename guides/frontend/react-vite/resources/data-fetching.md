<!-- orangekit-pack: frontend/react-vite v3.35.0 -->
# Data Fetching — HTTP client · query keys · query/mutation hooks

All data is an HTTP call to your own API and passes through **four layers** (screen → hook → endpoint function → http
client). This file owns all four. Where the token comes from is owned by the auth adapter
(`resources/auth-and-session.md`), and the failure wording by `resources/loading-error-states.md` §4.
Wire values follow the standard contract `http-standard` — if the project has its own API spec (e.g. `dev/docs/api/`),
that is canonical and the paths · codes below are pattern examples.

## 1. Decision — what lives in which layer

| What you want to do | Layer | File |
| --- | --- | --- |
| Strip the envelope · attach `Authorization: Bearer` · 401 refresh | http client | `src/api/http.ts` |
| Assemble the path · query string · narrow the response (`parse`) | endpoint function | `src/features/<f>/api/<f>.api.ts` |
| Cache key · freshness · invalidation | hook | `src/features/<f>/api/<f>.queries.ts` |
| Loading · empty · error branching — **does not import `http`** | screen | `src/features/<f>/pages/` |

## 2. The error type (`src/lib/api/errors.ts`)

<!-- file: src/lib/api/errors.ts -->
```ts
// src/lib/api/errors.ts
/** Codes the server sends (contract §4) + codes the client makes itself. The only axis for branching in a screen */
export type ApiErrorCode =
  | 'VALIDATION_FAILED' | 'UNAUTHENTICATED' | 'FORBIDDEN' | 'NOT_FOUND' | 'CONFLICT'
  | 'PAYLOAD_TOO_LARGE' | 'UNSUPPORTED_MEDIA_TYPE' | 'RATE_LIMITED' | 'INTERNAL'
  | 'NETWORK_ERROR' | 'TIMEOUT' | 'BAD_SHAPE';

/** The details of VALIDATION_FAILED — field name → array of messages. A form-wide error uses the key `_` */
export type FieldErrors = Record<string, string[]>;

export class ApiError extends Error {
  readonly details?: FieldErrors;
  readonly requestId?: string;
  // (status, code, message) — the last two arguments are both strings, so only the order distinguishes them
  constructor(readonly status: number, readonly code: ApiErrorCode, message: string,
              opts: { details?: FieldErrors; requestId?: string } = {}) {
    super(message);
    this.name = 'ApiError';
    this.details = opts.details;
    this.requestId = opts.requestId;
  }
}
```

`status` 0 = no response (`NETWORK_ERROR` · `TIMEOUT`). `BAD_SHAPE` = a 2xx whose body differs from the contract (`parse` throws it).

## 3. The HTTP client (`src/api/http.ts`)

<!-- file: src/api/http.ts -->
```ts
// src/api/http.ts — the only file in which a raw fetch appears (enforced by the lint in §7)
import { config } from '@/config';
import { ApiError, type ApiErrorCode, type FieldErrors } from '@/lib/api/errors';
import { endSession, getAccessToken, refresh } from '@/auth/session';

export type Page<T> = { items: T[]; nextCursor: string | null };
type HttpInit<T> = {
  body?: unknown;
  signal?: AbortSignal;
  parse?: (v: unknown) => T;          // without it, `as T` — a field the server drops passes silently
  auth?: boolean;                     // false = no token · no 401 refresh. For /api/auth/* only
  credentials?: RequestCredentials;   // 'include' only for requests that must carry the refresh cookie
};

type Envelope = { data?: unknown; nextCursor?: string | null; requestId?: string;
                  error?: { code?: string; message?: string; details?: FieldErrors } };
// A failure that arrives without an envelope (proxy HTML · a gateway default response) folds into the same code table
const CODE_BY_STATUS: Record<number, ApiErrorCode> = {
  400: 'VALIDATION_FAILED', 401: 'UNAUTHENTICATED', 403: 'FORBIDDEN', 404: 'NOT_FOUND',
  409: 'CONFLICT', 413: 'PAYLOAD_TOO_LARGE', 415: 'UNSUPPORTED_MEDIA_TYPE', 429: 'RATE_LIMITED',
};

async function send(method: string, path: string, init: HttpInit<unknown>, retried: boolean): Promise<Envelope | null> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (init.body !== undefined) headers['Content-Type'] = 'application/json';
  if (init.auth !== false) {
    const token = await getAccessToken();
    if (token) headers.Authorization = `Bearer ${token}`;
  }
  // AbortSignal.any · timeout require Chrome 116 · Firefox 124 · Safari 17.4 or later (HUB.md "Minimum supported browsers")
  // Combine cancellation and timeout — pick just one with `??` and the timeout vanishes the moment a query passes a signal
  const signals = [AbortSignal.timeout(15_000), ...(init.signal ? [init.signal] : [])];

  let res: Response;
  try {
    res = await fetch(`${config.apiBaseUrl}${path}`, {
      method, headers, signal: AbortSignal.any(signals), credentials: init.credentials ?? 'same-origin',
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    });
  } catch (e) {
    if (init.signal?.aborted) throw e;            // query cancellation is handled by TanStack Query
    const timeout = e instanceof DOMException && e.name === 'TimeoutError';
    throw new ApiError(0, timeout ? 'TIMEOUT' : 'NETWORK_ERROR', 'Could not reach the server.');
  }

  // Contract §5: 401 → one refresh → the original request once. The depth is pinned by the retried flag, not by recursion
  if (res.status === 401 && init.auth !== false && !retried && (await refresh())) {
    return send(method, path, init, true);
  }
  // If the retry is also 401, the session is over — set the status back to signedOut so RequireAuth sends the user to login
  if (res.status === 401 && init.auth !== false && retried) endSession();
  if (res.status === 204) return null;

  const headerId = res.headers.get('x-request-id') ?? undefined;
  const payload = (await res.json().catch(() => null)) as Envelope | null;
  if (!res.ok) {
    const e = payload?.error;
    const code = (e?.code as ApiErrorCode | undefined) ?? CODE_BY_STATUS[res.status] ?? 'INTERNAL';
    throw new ApiError(res.status, code, e?.message ?? res.statusText,
      { details: e?.details, requestId: payload?.requestId ?? headerId });
  }
  if (!payload) throw new ApiError(res.status, 'BAD_SHAPE', 'The response body is not JSON.', { requestId: headerId });
  return payload;
}
async function unwrap<T>(method: string, path: string, init: HttpInit<T> = {}): Promise<T> {
  const env = await send(method, path, init as HttpInit<unknown>, false);
  return init.parse ? init.parse(env?.data) : (env?.data as T);
}
export const http = {
  get: <T>(path: string, init?: HttpInit<T>) => unwrap<T>('GET', path, init),
  post: <T>(path: string, init?: HttpInit<T>) => unwrap<T>('POST', path, init),
  patch: <T>(path: string, init?: HttpInit<T>) => unwrap<T>('PATCH', path, init),
  delete: async (path: string, init: HttpInit<void> = {}): Promise<void> => { await send('DELETE', path, init as HttpInit<unknown>, false); },
  /** Lists only — turns the `{ data: T[], nextCursor }` envelope into `Page<T>`. parse runs per row */
  getPage: async <T>(path: string, init: HttpInit<T> = {}): Promise<Page<T>> => {
    const env = await send('GET', path, init as HttpInit<unknown>, false);
    const rows: unknown = env?.data;
    if (!Array.isArray(rows)) throw new ApiError(200, 'BAD_SHAPE', 'The list response is not an array.');
    return { items: rows.map((r) => (init.parse ? init.parse(r) : (r as T))), nextCursor: env?.nextCursor ?? null };
  },
};
```

If the refresh fails, the adapter sets the status to `signedOut`; if the refresh succeeded but the retry is also 401, `endSession()` does the same. Either way a 401 `ApiError` is raised here. Screens
do not handle it — `RequireAuth` sends the user to login (`routing.md` §3).

## 4. Endpoint functions

<!-- file: src/features/tasks/api/tasks.api.ts -->
```ts
// src/features/tasks/api/tasks.api.ts — URL · query-string assembly never leaks out of this file
import { http, type Page } from '@/api/http';
import { parseTask, type CreateTaskInput, type Task, type TaskFilter, type TaskStatus } from './tasks.types';

function listQuery(filter: TaskFilter, cursor?: string): string {
  const q = new URLSearchParams({ limit: '20' });           // contract: 1–100, default 20
  if (filter.status !== 'all') q.set('status', filter.status);
  if (cursor) q.set('cursor', cursor);                      // an opaque string — sent back without being interpreted
  return q.toString();
}

export const listTasks = (filter: TaskFilter, cursor?: string, signal?: AbortSignal): Promise<Page<Task>> =>
  http.getPage<Task>(`/api/tasks?${listQuery(filter, cursor)}`, { signal, parse: parseTask });

export const getTask = (id: string, signal?: AbortSignal): Promise<Task> =>
  http.get<Task>(`/api/tasks/${encodeURIComponent(id)}`, { signal, parse: parseTask });

export const createTask = (input: CreateTaskInput): Promise<Task> =>
  http.post<Task>('/api/tasks', { body: input, parse: parseTask });

export const updateTaskStatus = (id: string, status: TaskStatus): Promise<Task> =>
  http.patch<Task>(`/api/tasks/${encodeURIComponent(id)}`, { body: { status }, parse: parseTask });
```

## 5. Query keys · query and mutation hooks

<!-- file: src/features/tasks/api/tasks.queries.ts -->
```ts
// src/features/tasks/api/tasks.queries.ts
import { keepPreviousData, useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { createTask, getTask, listTasks, updateTaskStatus } from './tasks.api';
import type { Task, TaskFilter, TaskStatus } from './tasks.types';

// Keys are made only in this factory. It is hierarchical, so one lists() invalidation covers the lists of every filter.
// The cursor does not go in the key — useInfiniteQuery gathers the pages into one cache entry
export const taskKeys = {
  all: ['tasks'] as const,
  lists: () => [...taskKeys.all, 'list'] as const,
  list: (filter: TaskFilter) => [...taskKeys.lists(), filter] as const,
  detail: (id: string) => [...taskKeys.all, 'detail', id] as const,
};

export function useTasksQuery(filter: TaskFilter) {
  return useInfiniteQuery({
    queryKey: taskKeys.list(filter),
    queryFn: ({ pageParam, signal }) => listTasks(filter, pageParam, signal),
    initialPageParam: undefined as string | undefined,          // the first request has no cursor
    getNextPageParam: (last) => last.nextCursor ?? undefined,   // null means no more
    placeholderData: keepPreviousData,                          // keep the previous list while the filter switches
  });
}

export function useTaskQuery(id: string) {
  return useQuery({ queryKey: taskKeys.detail(id), queryFn: ({ signal }) => getTask(id, signal) });
}

// The shared handling of a successful write — fill the detail from the response and invalidate the list (patching it
// with setQueryData breaks the cursor boundaries). Returning the promise keeps isPending until the refetch finishes, which blocks double submits
function useOnSaved() {
  const qc = useQueryClient();
  return (task: Task) => {
    qc.setQueryData(taskKeys.detail(task.id), task);
    return qc.invalidateQueries({ queryKey: taskKeys.lists() });
  };
}

export function useCreateTaskMutation() {
  return useMutation({ mutationFn: createTask, onSuccess: useOnSaved() });
}

export function useUpdateTaskStatusMutation() {
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: TaskStatus }) => updateTaskStatus(id, status),
    onSuccess: useOnSaved(),
  });
}
```

**A missing invalidation is the signature defect of this layer** — every time you add a mutation, write down "the keys this change makes stale".

## 6. QueryClient defaults (`src/api/queryClient.ts`)

<!-- file: src/api/queryClient.ts -->
```ts
// src/api/queryClient.ts — one for the whole app. The logout procedure clears this instance
import { QueryClient } from '@tanstack/react-query';
import { ApiError } from '@/lib/api/errors';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: (failureCount, error) => {
        // 4xx (429 included) and contract violations come out the same if sent again. Retry only connection failures (status 0) and 5xx
        if (error instanceof ApiError && (error.code === 'BAD_SHAPE' || (error.status >= 400 && error.status < 500))) return false;
        return failureCount < 2;
      },
    },
    mutations: { retry: false },   // retrying a write creates duplicates
  },
});
```

## 7. Where each code is handled · enforcing the boundary with lint

Each `ApiError.code` has **exactly one layer that handles it** — if two layers handle it, one of them becomes dead code.

| code | Handling layer | Behavior |
| --- | --- | --- |
| `UNAUTHENTICATED` | http client + adapter | one refresh → the original request once → if the retry is also 401, `endSession()` to `signedOut` |
| `VALIDATION_FAILED` | form | `details` under the fields, `details._` above the form |
| `FORBIDDEN` · `NOT_FOUND` | screen | do not pass `onRetry` to `ErrorState` |
| `RATE_LIMITED` | screen | a notice + manual retry. The query `retry` skips 4xx |
| `NETWORK_ERROR` · `TIMEOUT` · `INTERNAL` | query `retry` → screen | after 2 automatic retries, `ErrorState` + a retry button |

```js
// eslint.config.js (flat config) — turn the boundary into a build failure, not a discipline
import importPlugin from 'eslint-plugin-import';
const useClient = 'Use http from src/api/http.ts.';

export default [{
  files: ['src/**/*.{ts,tsx}'], ignores: ['src/api/**'], plugins: { import: importPlugin },
  rules: {
    'no-restricted-globals': ['error', { name: 'fetch', message: useClient }],
    'no-restricted-imports': ['error', { paths: [{ name: 'axios', message: useClient }] }],
    'import/no-restricted-paths': ['error', { zones: [{ target: './src/components', from: './src/features' }] }],
  },
}];
```

Set `build` to `tsc --noEmit && eslint . --max-warnings 0 && vite build` — a lint failure must be a deploy failure.

## Misuse list ① — TanStack Query v4 → v5 idiom table

| v4 habit | v5 form |
| --- | --- |
| `useQuery(key, fn, options)` | `useQuery({ queryKey, queryFn, ...options })` — object signature only |
| `cacheTime` | `gcTime` |
| `keepPreviousData: true` | `placeholderData: keepPreviousData` |
| `invalidateQueries(key)` | `invalidateQueries({ queryKey: key })` |
| No `initialPageParam` on `useInfiniteQuery` | Required in v5 <!-- verified: TanStack Query v5 migration guide — initialPageParam required --> |

## Misuse list ② — confusable pairs

| The confused pair | The exact condition for each |
| --- | --- |
| `http.post(path, body)` vs `http.post(path, { body })` | The body is `init.body`. The first form is a type error |
| `auth: false` vs the default | `false` is for `/api/auth/*` only. Use it on an ordinary API and a 401 comes up as is, without a refresh |
| `setQueryData` vs `invalidateQueries` | The detail (single record) gets `setQueryData` from the response. The list (cursor pages) is invalidated |
| Query `retry` vs the http refresh | The http layer retries a 401 once. If the query `retry` retries the 401 again, the refresh is duplicated |
