<!-- orangekit-seam: vue+node-api v3.13.0 -->
# Data Fetching — from the HTTP client to the query composable

This file is **where the wire contract is carried into code**. Envelope parsing · error normalization · consuming the cursor ·
cache invalidation all live here. Three-state rendering is in `resources/loading-error-states.md`, the store
boundary in `resources/state-management.md`, and the app wiring in `resources/complete-example.md` §5.

There is **only one boundary** — a single HTTP hop between the SPA and a separate API server. With no Server Component there is
no accident of "a server-only module mixed into the client bundle" either. In exchange **every request must attach the auth
header itself**, and that duty has to stay confined to the single module of §3.

## 1. Where a new request goes

| What you want to do | Where it goes | Why |
| --- | --- | --- |
| Headers · timeout · error normalization | `src/api/http.ts` (§3) | One for the whole app. A second one makes the auth header diverge |
| The function that calls `/api/tasks` | `src/features/tasks/api/tasks.ts` (§4) | The path string and the query parameter assembly gather in one place |
| The list/single item a screen uses | A query composable (§5) | Vue Query owns the cache key · refetch · GC |
| Create · update · delete | A mutation composable (§6) | The mutation knows what to invalidate |
| Checking response fields | `parseTask` · `parseTaskList` in `tasks.parse.ts` | The pack owns them. The seam only calls them |
| Global retry · staleTime | `src/api/queryClient.ts` | The retry decision is a function of the error code — `complete-example.md` §5 |

Do not call `fetch` directly from a component — the token · error shape · base URL get reinvented
screen by screen. The pack's `http-in-api-layer` policy catches this ban mechanically.

## 2. The domain type and the error envelope (`src/types/task.ts` · `src/api/errors.ts`)

Contract §1 fixes the success envelope as `{ data }` (plus `nextCursor` for a list), and §2 fixes the failure envelope as
`{ error: { code, message, details? }, requestId }`.

<!-- file: src/types/task.ts -->
```ts
// src/types/task.ts
export interface Task {
  id: string;
  title: string;
  createdAt: string;              // an ISO 8601 string. The screen is where it becomes a Date
  status: 'open' | 'done';        // not optional — component-patterns.md §10 in the pack compares the value
}
```

<!-- file: src/api/errors.ts -->
```ts
// src/api/errors.ts
// the codes the server sends (contract §4) and the codes the client makes itself live in one union.
export type ApiErrorCode =
  | 'VALIDATION_FAILED' | 'UNAUTHENTICATED' | 'FORBIDDEN' | 'NOT_FOUND'
  | 'CONFLICT' | 'PAYLOAD_TOO_LARGE' | 'INTERNAL'
  | 'NETWORK_ERROR' | 'TIMEOUT' | 'BAD_SHAPE';   // ← the server never sends these three

export class ApiError extends Error {
  readonly code: string;
  readonly status: number;                        // a transport failure is 0
  readonly requestId?: string;                    // the only key that lines up with the server log
  readonly details?: Record<string, string[]>;    // carried on VALIDATION_FAILED only

  constructor(code: string, message: string,
              meta: { status?: number; requestId?: string; details?: Record<string, string[]> } = {}) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.status = meta.status ?? 0;
    this.requestId = meta.requestId;
    this.details = meta.details;
  }
}
```

Why `code` is `string` and not `ApiErrorCode`: even when a code outside the union arrives, **throwing must not
fail.** The consumer (`switch`) does the narrowing.

| Contract code | Status | What the screen does |
| --- | --- | --- |
| `VALIDATION_FAILED` | 400 | Show `details` under the field. No retry button |
| `UNAUTHENTICATED` | 401 | The screen does not handle it — the single reissue of §3 does |
| `FORBIDDEN` | 403 | Insufficient role. No retry button |
| `NOT_FOUND` | 404 | **One screen for "absent, or not mine"** (contract §5). Not distinguished from 403 |
| `CONFLICT` | 409 | Invalidate the list and have it read again |
| `PAYLOAD_TOO_LARGE` | 413 | Tell the user about the input size |
| `INTERNAL` | 500 | A generic phrase + show the `requestId`. Retryable |
| `NETWORK_ERROR` · `TIMEOUT` | — | The pack's `toUserMessage` owns the wording |
| `BAD_SHAPE` | — | A broken contract. Retrying gives the same result |

## 3. The HTTP client (`src/api/http.ts`)

The only file where `fetch` appears. It monopolizes three things: **the timeout ·
error normalization · one reissue on 401**. The single flight of the reissue belongs to `@/auth/session`
(`resources/auth-and-session.md` §2).

<!-- file: src/api/http.ts -->
```ts
// src/api/http.ts
import { config } from '@/config';
import { ApiError } from './errors';
import { getAccessToken, refreshSession, clearSession } from '@/auth/session';

const TIMEOUT_MS = 15_000;

async function send(path: string, init: RequestInit): Promise<Response> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  const token = getAccessToken();
  try {
    return await fetch(`${config.apiBaseUrl}${path}`, {
      ...init,
      signal: ctrl.signal,
      credentials: 'include',              // the reissue cookie. The server CORS has to allow it
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...init.headers,
      },
    });
  } catch {
    // fetch throws a network failure and an abort as the same exception — separate them with the signal
    throw ctrl.signal.aborted
      ? new ApiError('TIMEOUT', 'The request did not finish in time.')
      : new ApiError('NETWORK_ERROR', 'Could not connect to the server.');
  } finally {
    clearTimeout(timer);
  }
}

function toApiError(body: unknown, status: number): ApiError {
  const env = (body ?? {}) as { error?: { code?: unknown; message?: unknown; details?: unknown }; requestId?: unknown };
  const requestId = typeof env.requestId === 'string' ? env.requestId : undefined;
  if (typeof env.error?.code !== 'string') return new ApiError('BAD_SHAPE', 'The error envelope differs from the contract.', { status, requestId });
  const message = typeof env.error.message === 'string' ? env.error.message : 'The request could not be processed.';
  return new ApiError(env.error.code, message, { status, requestId, details: env.error.details as Record<string, string[]> | undefined });
}

async function request(path: string, init: RequestInit): Promise<Record<string, unknown> | null> {
  let res = await send(path, init);
  if (res.status === 401) {
    // exactly one reissue per request. No recursion — on failure the original 401 is raised as it is
    if (!(await refreshSession())) {
      clearSession();
      throw toApiError(await res.json().catch(() => null), 401);
    }
    res = await send(path, init);
  }
  if (res.status === 204) return null;                       // contract §1: a delete has no body
  const text = await res.text();
  let body: unknown = null;
  if (text !== '') {
    try { body = JSON.parse(text); }
    catch { throw new ApiError('BAD_SHAPE', 'The response is not JSON.', { status: res.status }); }
  }
  if (!res.ok) throw toApiError(body, res.status);
  if (body === null || typeof body !== 'object' || !('data' in body)) {
    throw new ApiError('BAD_SHAPE', 'The response envelope has no data.', { status: res.status });
  }
  return body as Record<string, unknown>;
}

export const http = {
  get: async (path: string, init?: RequestInit): Promise<unknown> => (await request(path, { ...init, method: 'GET' }))?.data ?? null,
  post: async (path: string, init?: RequestInit): Promise<unknown> => (await request(path, { ...init, method: 'POST' }))?.data ?? null,
  patch: async (path: string, init?: RequestInit): Promise<unknown> => (await request(path, { ...init, method: 'PATCH' }))?.data ?? null,
  delete: async (path: string, init?: RequestInit): Promise<unknown> => (await request(path, { ...init, method: 'DELETE' }))?.data ?? null,
  // the four methods unwrap the envelope, so they cannot see nextCursor. Only a list is taken envelope and all
  page: async (path: string, init?: RequestInit): Promise<{ data: unknown; nextCursor: string | null }> => {
    const env = await request(path, { ...init, method: 'GET' });
    return { data: env?.data ?? null, nextCursor: typeof env?.nextCursor === 'string' ? env.nextCursor : null };
  },
};
```

<!-- verified: run against a real node:http server — closed port→NETWORK_ERROR, 200ms delay→TIMEOUT(208ms), non-JSON body · a 200 without data · a 500 without error→all BAD_SHAPE, 400→VALIDATION_FAILED (details preserved), 204→null -->
Normalizing a transport failure into an `ApiError` is **a premise of the pack**: `toUserMessage`
has wording for `NETWORK_ERROR` · `TIMEOUT` only. Let a raw `TypeError` through and only the fallback phrase remains.

## 4. Endpoint functions and query keys (`src/features/tasks/api/tasks.ts`)

<!-- file: src/features/tasks/api/tasks.ts -->
```ts
// src/features/tasks/api/tasks.ts
import { http } from '@/api/http';
import { parseTask, parseTaskList } from './tasks.parse';   // owned by the pack (types-and-testing.md §4)
import type { Task } from '@/types/task';

export interface TaskFilter { status?: 'open' | 'done'; limit?: number }
export interface TaskPage { items: Task[]; nextCursor: string | null }

// keys are made in one place only. If a screen writes the array literal itself, invalidation quietly misses
export const taskKeys = {
  all: ['tasks'] as const,
  list: (filter: TaskFilter) => ['tasks', 'list', filter] as const,
  detail: (id: string) => ['tasks', 'detail', id] as const,
};

export async function fetchTaskPage(filter: TaskFilter, cursor?: string): Promise<TaskPage> {
  const q = new URLSearchParams();
  if (filter.status) q.set('status', filter.status);
  q.set('limit', String(filter.limit ?? 20));
  if (cursor) q.set('cursor', cursor);           // contract §3: limit · cursor (there is no page or skip)
  const page = await http.page(`/api/tasks?${q.toString()}`);
  return { items: parseTaskList(page.data), nextCursor: page.nextCursor };
}

export async function createTask(input: { title: string }): Promise<Task> {
  return parseTask(await http.post('/api/tasks', { body: JSON.stringify(input) }));
}
```

`parseTaskList` **does not unwrap the envelope** — pass it `page.data`. Pass the whole envelope and
`ApiError('BAD_SHAPE', 'The list response is not an array.')` explodes right there.

## 5. The list query — a cursor turned into a flat array (`useTasksQuery.ts`)

The contract is cursor pagination, but the pack requires `data` to be `Ref<Task[] | undefined>`.
`select` is what joins the two — `useInfiniteQuery` inside, a flat array outside.

<!-- file: src/features/tasks/api/useTasksQuery.ts -->
```ts
// src/features/tasks/api/useTasksQuery.ts
import { computed, toValue, type MaybeRefOrGetter } from 'vue';
import { useInfiniteQuery } from '@tanstack/vue-query';
import { fetchTaskPage, taskKeys, type TaskFilter } from './tasks';

export function useTasksQuery(filter?: MaybeRefOrGetter<TaskFilter>) {
  const current = computed<TaskFilter>(() => toValue(filter) ?? {});   // calling it with no argument is fine too
  return useInfiniteQuery({
    queryKey: computed(() => taskKeys.list(current.value)),   // the key has to be a ref for a filter change to refetch
    queryFn: ({ pageParam }) => fetchTaskPage(current.value, pageParam),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.nextCursor ?? undefined, // null means the last page
    select: (data) => data.pages.flatMap((p) => p.items),     // ← the screen sees Task[] only
    staleTime: 30_000,
  });
}
```

<!-- verified: run against a real server with a createApp mount — with limit=2, 5 rows arrived across 3 calls and data went ["t1","t2"]→["t1","t2","t3","t4"]→5 items, hasNextPage was false on the last one, and a filter change added exactly 1 request -->
`getNextPageParam` has to return `undefined` for `hasNextPage` to become false — return `null`
as it is and it requests "the page whose cursor is null" one more time.

## 6. The create mutation and invalidation (`useCreateTaskMutation.ts`)

<!-- file: src/features/tasks/api/useCreateTaskMutation.ts -->
```ts
// src/features/tasks/api/useCreateTaskMutation.ts
import { useMutation, useQueryClient } from '@tanstack/vue-query';
import { createTask, taskKeys } from './tasks';

export function useCreateTaskMutation() {
  const queryClient = useQueryClient();
  const m = useMutation({
    mutationFn: createTask,
    // a prefix match — taskKeys.all covers both list and detail
    onSuccess: () => { void queryClient.invalidateQueries({ queryKey: taskKeys.all }); },
  });
  return { mutate: m.mutate, isPending: m.isPending };
}
```

`mutate` **returns no value and throws nothing.** Failure arrives only through the callback of
`mutate(input, { onError })` — the pack's `onErrorCaptured` boundary cannot catch a mutation failure, so leaving
`onError` out means nobody catches it. Do not use `mutateAsync`: a rejected Promise escapes.

<!-- verified: run — the return value of mutate() is undefined, isPending is a Ref, and on a validation failure onError received ApiError(VALIDATION_FAILED, details={title:[...]}) -->
The cost of invalidation: invalidating a `useInfiniteQuery` re-reads **every loaded page**.
One create with 3 pages open became 3 list requests.

## Misuse list ① — React Query → Vue Query idiom table

The biggest risk on this axis. Port a React example and the types pass while only the reactivity dies.

| Old habit (React Query) | The current form (`@tanstack/vue-query` v5) |
| --- | --- |
| `from '@tanstack/react-query'` | `from '@tanstack/vue-query'` — the pack policy `no-react-query` blocks it mechanically |
| Reading `const { data } = useQuery(...)` as a value | `data` is a `Ref`. In script it is `data.value`; the template unwraps it automatically |
| `queryKey: ['tasks', filter]` (a plain array) | If the filter is reactive, wrap it in `computed(() => ...)`. A static array never updates |
| `enabled: !!id` | `enabled: computed(() => !!id.value)` — a boolean literal freezes at the first value |
| Calling `useQueryClient()` inside an event handler | Take it once in the setup body. A handler is not the setup context |
| `isLoading` | `isPending` (first load) · `isFetching` (includes background refresh). The names split apart in v5 <!-- verified: the object returned by @tanstack/vue-query@5.102.0 really has isPending · isFetching, run confirmed --> |

## Misuse list ② — confused pairs

| Frequently chosen wrongly | The exact condition for each |
| --- | --- |
| `http.get` vs `http.page` | Use `page` when you need `nextCursor`. A single item · create · delete use `get`/`post`/`delete` |
| `data` vs `data.pages` | The screen always uses `data` (a flat `Task[]`). Delete `select` and the pack's three-state example breaks entirely |
| `isPending` vs `isFetching` | The skeleton uses `isPending`, the background refresh bar uses `isFetching`. A query with `enabled: false` has `isPending` permanently true |
| `invalidateQueries` vs `refetch` | Invalidating broadly by key is the former; re-reading just this one screen is the latter |
| `taskKeys.all` vs `taskKeys.list(f)` | Invalidation uses `all` (prefix match), subscription uses `list(f)`. Swap them and the cache of another filter survives |
| `ApiError.status` vs `ApiError.code` | Screen branching is **always `code`**. `status` is for logs and reports |
| Treating 404 as "absent" only | In contract §5 a 404 means **absent or someone else's**. An ownership failure never arrives as 403 |
