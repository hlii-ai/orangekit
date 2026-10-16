<!-- orangekit-seam: react-vite+aws-container/frontend v3.34.0 -->
# Data Fetching (REST API + TanStack Query v5)

An SPA has no server runtime. All data is an HTTP call to a REST API you operate yourself, and
that call passes through **exactly three layers**.

```
component → query/mutation hook → endpoint function → http client → API
(screen)    (cache policy)        (URL · body contract)  (envelope parsing · error normalization)
```

## 0. The backend response contract (the premise of this whole file)

| Kind | Body |
| --- | --- |
| single success | `{ "data": { … } }` |
| list success | `{ "data": [ … ], "nextCursor": "<cursor>" \| null }` |
| delete success | 204, no body |
| failure | `{ "error": { "code", "message", "details"? }, "requestId" }` |

- Pagination is **cursor**-based. `limit`/`cursor` on the request, `nextCursor` on the response (`null` means the last page).
  Neither `total` nor `page` **exists** — a total-count or page-number UI cannot be built against this backend
- `details` arrives **on `VALIDATION_FAILED` only** and its value is a **string array per field** (`{ "title": ["at least 2 characters"] }`)
- The screen branches on `code` (`status` is for logging). **Unauthorized access arrives as 404** (so existence does not leak) —
  403 is used only for an insufficient role or scope

## 1. The HTTP client (`src/api/http.ts`)

```ts
import { config } from '@/config';
import { getAccessToken } from './tokenProvider';
import { refreshOnce, handleSessionExpired } from '@/auth/session';

/** 1:1 with the backend error code table + client-only codes. The single axis for screen branching */
export type ApiErrorCode =
  | 'VALIDATION_FAILED' | 'UNAUTHENTICATED' | 'FORBIDDEN' | 'NOT_FOUND' | 'CONFLICT'
  | 'PAYLOAD_TOO_LARGE' | 'UNSUPPORTED_MEDIA_TYPE' | 'RATE_LIMITED' | 'INTERNAL' // ← values the server sends
  | 'NETWORK_ERROR' | 'TIMEOUT' | 'BAD_SHAPE';                // ← values the client makes

/** The shape of `details` on a `VALIDATION_FAILED`: field name → array of messages */
export type FieldErrors = Record<string, string[]>;
export type Page<T> = { items: T[]; nextCursor: string | null };

export class ApiError extends Error {
  readonly details?: FieldErrors;   // the per-field messages of a VALIDATION_FAILED
  readonly requestId?: string;      // shown on the error screen — the only thread back to the server log
  constructor(readonly status: number, readonly code: ApiErrorCode, message: string,
              opts: { details?: FieldErrors; requestId?: string } = {}) {
    super(message);
    this.name = 'ApiError';
    this.details = opts.details;
    this.requestId = opts.requestId;
  }
}

type RequestOptions<T> = {
  body?: unknown; signal?: AbortSignal; auth?: boolean;
  /** Narrowing at the boundary. Without it this is `as T`, and a broken contract explodes deep inside a screen */
  parse?: (u: unknown) => T;
};

type Envelope = { data?: unknown; nextCursor?: string | null; requestId?: string;
                  error?: { code?: string; message?: string; details?: FieldErrors } };

async function request(method: string, path: string, opts: RequestOptions<unknown> = {},
                       retried = false): Promise<Envelope | null> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
  // the token is read from the provider the auth module injected — http does not import the auth implementation
  if (opts.auth !== false) {
    const token = await getAccessToken();
    if (token) headers.Authorization = `Bearer ${token}`;
  }

  // **Combine** cancellation and timeout. Choosing with `??` kills the timeout whenever a query passes a signal
  const signal = AbortSignal.any(
    [opts.signal, AbortSignal.timeout(15_000)].filter(Boolean) as AbortSignal[]);

  const res = await fetch(`${config.apiBaseUrl}${path}`, {
    method, headers, signal,
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  }).catch((e: unknown) => {
    const timeout = e instanceof DOMException && e.name === 'TimeoutError';
    throw new ApiError(0, timeout ? 'TIMEOUT' : 'NETWORK_ERROR', 'The connection failed.');
  });

  if (res.status === 204) return null;                     // delete succeeded — there is no body
  const payload = (await res.json().catch(() => null)) as Envelope | null;

  if (res.status === 401) {
    // the signature enforces the retry depth — exactly once, not recursion (auth-and-session.md §5)
    if (!retried && (await refreshOnce())) return request(method, path, opts, true);
    await handleSessionExpired();
  }
  if (!res.ok) {
    const e = payload?.error;
    throw new ApiError(res.status, (e?.code as ApiErrorCode) ?? 'INTERNAL',
      e?.message ?? res.statusText, { details: e?.details, requestId: payload?.requestId });
  }
  return payload ?? {};
}

async function unwrap<T>(method: string, path: string, opts: RequestOptions<T> = {}): Promise<T> {
  const env = await request(method, path, opts as RequestOptions<unknown>);
  return opts.parse ? opts.parse(env?.data) : (env?.data as T);
}

export const http = {
  get: <T>(p: string, o?: RequestOptions<T>) => unwrap<T>('GET', p, o),
  /** Lists only — turns the `{ data, nextCursor }` envelope into a `Page<T>` */
  getPage: async <T>(p: string, o?: RequestOptions<T>): Promise<Page<T>> => {
    const env = await request('GET', p, o as RequestOptions<unknown>);
    const rows = Array.isArray(env?.data) ? env.data : [];
    return { items: o?.parse ? rows.map(o.parse) : (rows as T[]), nextCursor: env?.nextCursor ?? null };
  },
  post: <T>(p: string, body: unknown, o?: RequestOptions<T>) => unwrap<T>('POST', p, { ...o, body }),
  patch: <T>(p: string, body: unknown, o?: RequestOptions<T>) => unwrap<T>('PATCH', p, { ...o, body }),
  delete: async (p: string, o?: RequestOptions<void>): Promise<void> => { await request('DELETE', p, o); },
};
```

- **Envelope parsing lives only in this file.** Screens and hooks see only the unwrapped `data` value and `Page<T>`
- Errors are normalized into a single `ApiError` and `requestId` is preserved — a screen only has to look at `e.code`, and
  when a user reports the request ID shown on screen you can find that one request in the server log

## 2. Endpoint functions and query keys

```ts
// features/tasks/api/tasks.api.ts — URL and query-string assembly never leaks out of this file.
// toQuery(f, cursor) assembles status · limit · cursor (the full implementation is in complete-example.md §2)
export const listTasks = (f: TaskFilter, cursor?: string, signal?: AbortSignal): Promise<Page<Task>> =>
  http.getPage<Task>(`/tasks?${toQuery(f, cursor)}`, { signal, parse: parseTask });

export const createTask = (input: CreateTaskInput) =>
  http.post<Task>('/tasks', input, { parse: parseTask });   // parse narrows at the boundary
```

```ts
// features/tasks/api/tasks.keys.ts — keys are made in the factory and nowhere else
export const taskKeys = {
  all: ['tasks'] as const,
  lists: () => [...taskKeys.all, 'list'] as const,
  list: (f: TaskFilter) => [...taskKeys.lists(), f] as const,
  details: () => [...taskKeys.all, 'detail'] as const,
  detail: (id: string) => [...taskKeys.details(), id] as const,
};
```

Why the keys are hierarchical: one `invalidateQueries({ queryKey: taskKeys.lists() })` invalidates every list query,
whatever the filter. Scatter the keys as strings and this prefix matching becomes impossible.
The cursor does not go in the key — `useInfiniteQuery` gathers the pages inside one cache entry.

## 3. Query hooks — a list is a cursor infinite query

```ts
export function useTasksQuery(filter: TaskFilter) {
  return useInfiniteQuery({
    queryKey: taskKeys.list(filter),
    queryFn: ({ pageParam, signal }) => listTasks(filter, pageParam, signal),
    initialPageParam: undefined as string | undefined,   // no cursor on the first request
    getNextPageParam: (last) => last.nextCursor ?? undefined,  // null means there is no more
    staleTime: 30_000,            // within 30 seconds, returning to the screen does not refetch
    placeholderData: keepPreviousData, // keep the previous list while the filter changes (no flicker)
  });
}
```

A single item is a plain `useQuery`, and the unwrapped value is `data` itself. Flattening the items on a list screen
is one line too: `const tasks = data.pages.flatMap((p) => p.items)`.

`staleTime` baselines:

| Nature of the data | staleTime | Example |
| --- | --- | --- |
| almost never changes | `Infinity` or 1 hour | code lists, permission definitions |
| a person edits it occasionally | 30 seconds–5 minutes | project settings, list screens |
| close to real time | 0 + `refetchInterval` | dashboard counters |

`gcTime` (5 minutes by default) is **the time until the cache is discarded after it leaves the screen**.
Do not confuse it with `staleTime` (freshness); they are different axes.

## 4. Mutations and invalidation

```ts
// the onSuccess of useMutation (the full hook is in complete-example.md §4)
onSuccess: (created) => {
  qc.invalidateQueries({ queryKey: taskKeys.lists() });   // invalidate every list
  qc.setQueryData(taskKeys.detail(created.id), created);  // the detail is filled immediately from the response
},
```

- **A missing invalidation is the signature defect of this layer.** Every time you add a create/update/delete,
  write down "which query keys does this mutation make stale" and invalidate all of them
- When the server returns the changed resource in the response, `setQueryData` saves one refetch
- An optimistic update is `cancelQueries` → snapshot → `setQueryData` in `onMutate`, restore in `onError`,
  invalidate in `onSettled` — if you are not going to implement all four steps, do not do it at all

## 5. QueryClient defaults (`src/main.tsx`)

```ts
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: (failureCount, error) => {
        // a 4xx gives the same result on retry. 429 included — automatic retry only grows the stampede
        if (error instanceof ApiError && error.status >= 400 && error.status < 500) return false;
        return failureCount < 2;    // retry only network failures (status 0) and 5xx
      },
      refetchOnWindowFocus: true,
    },
    mutations: { retry: false },   // retrying a write creates duplicates
  },
});
```

**Do not retry a 429 automatically.** Throwing it again without a backoff that respects `Retry-After` hits the rate
limit even harder — tell the user and give them a manual retry button
(the same policy as `loading-error-states.md` §4. The two files must not diverge).

## 6. Enforce the boundary with lint

Because there is no escape hatch called a "server-only module" — there is one bundle and all of it is public — the boundary is
enforced **by a build failure, not by discipline**.

```js
// eslint.config.js (flat config)
import importPlugin from 'eslint-plugin-import';  // using the rules without registering the plugin makes loading the config itself fail
const useClient = 'Use the client in src/api/http.ts.';

export default [
  {
    files: ['src/**/*.{ts,tsx}'],
    ignores: ['src/api/**'],
    plugins: { import: importPlugin },
    rules: {
      // ① no raw fetch — this catches the global identifier only
      'no-restricted-globals': ['error', { name: 'fetch', message: useClient }],
      // ② no HTTP libraries — the globals rule cannot block an import
      'no-restricted-imports': ['error', { paths: [{ name: 'axios', message: useClient }] }],
      // ③ direction rules: the shared layer knows nothing of features + features do not cross-import
      //    (add one zone of the last form for every feature you add)
      'import/no-restricted-paths': ['error', { zones: [
        { target: './src/components', from: './src/features' },
        { target: './src/lib', from: './src/features' },
        { target: './src/features/tasks', from: './src/features', except: ['./tasks'] },
      ] }],
    },
  },
];
```

```jsonc
// package.json — make a lint failure a build failure
{ "scripts": { "build": "npm run typecheck && eslint . --max-warnings 0 && vite build" } }
```

On top of that, block secrets from entering in CI — fail the moment these names appear in the source.

```bash
! rg -n "VITE_[A-Z_]*(SECRET|PASSWORD|PRIVATE|TOKEN|CREDENTIAL)" src/
```

## 7. What not to do

- **Do not fetch data in a router loader.** TanStack Query is the one cache (`routing.md`)
- **Do not use `useEffect` + `fetch` + `useState`.** You end up implementing cancellation · race conditions ·
  duplicate requests · retries by hand
- **Do not read `import.meta.env` directly.** Environment values are read in `src/config.ts` alone, typed
  and exported (`types-and-testing.md` §2). `http.ts` and `oidcConfig` are no exception
- **Do not use `page`/`total`.** The backend gives a cursor only — numbered pagination cannot be built

## Misuse list ① — v4 → v5 idiom table

| v4 habit | v5 form |
| --- | --- |
| `useQuery(key, fn, options)` | `useQuery({ queryKey, queryFn, ...options })` — the object signature only |
| `cacheTime` | `gcTime` |
| Deciding "no data" with `isLoading` | `isPending` (in v5 `isLoading` is `isPending && isFetching`) · `status: 'loading'` → `'pending'` |
| `onSuccess`/`onError`/`onSettled` on `useQuery` | **Removed.** Handle side effects in the component from `data`/`error`, or move them to a mutation |
| `keepPreviousData: true` | `placeholderData: keepPreviousData` (import the function and pass it) |
| `useErrorBoundary: true` | `throwOnError: true` |
| `invalidateQueries(key)` | `invalidateQueries({ queryKey: key })` — filters as an object only |
| `query.remove()` | `queryClient.removeQueries({ queryKey })` |
| `useInfiniteQuery` without `initialPageParam` | **Required** in v5. Without it the first page request never starts |

## Misuse list ② — confused pairs

| Confused pair | The exact condition for each |
| --- | --- |
| `isPending` vs `isFetching` vs `isRefetching` | `isPending` means there is no data in the cache yet (first load → skeleton). `isFetching` means a request is in flight (background refresh → a thin indicator at the top). `isRefetching` is a refetch while data already exists |
| `isPending` on a query with `enabled: false` | An inactive query has `isPending` **permanently true**. Applying the rule "branch on `isPending` first" leaves the skeleton forever → branch on `isLoading` (= `isPending && isFetching`) or draw the inactive state separately first |
| `invalidateQueries` vs `refetchQueries` | Invalidation only marks data "stale" and refetches **only the queries mounted on screen** (by default). `refetchQueries` forces even inactive queries — in most cases invalidation is the right one |
| `setQueryData` vs `invalidateQueries` | If the server response is the final form of that resource, `setQueryData`. If the server may have changed other fields too, invalidate |
| `resetQueries` vs `removeQueries` | `reset` returns to the initial state and refetches active queries. `remove` deletes from the cache (on logout use `queryClient.clear()`) |
| `enabled: false` vs calling the hook conditionally | A hook cannot be called conditionally. When a parameter is not ready, use `enabled: !!id` |
| `placeholderData` vs `initialData` | `initialData` is **stored in the cache as real data** and starts the freshness timer. `placeholderData` is temporary display data that is not stored in the cache |
| `mutate` vs `mutateAsync` | The default is `mutate` + `onSuccess`/`onError` callbacks. Use `mutateAsync` only when you need to `await`, and **always wrap it in try/catch** (an uncaught one is an unhandled rejection) |
| a filter object in the query key vs a serialized string | Put the object in as it is. Query compares with a structural hash, so key order does not matter. Doing `JSON.stringify` yourself breaks prefix invalidation |
| branching on `error.status` vs on `error.code` | Branch on **`code`**. The same 404 means both "a resource that does not exist" and "someone else's resource", so the status code alone cannot choose the wording |
