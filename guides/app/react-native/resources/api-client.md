<!-- orangekit-pack: app/react-native v3.35.0 -->
# API client — `http` · `ApiError` · query hooks · outbox send

This file owns `src/api/http.ts` · `src/api/tasks.ts` · `src/api/outboxSend.ts`. Wire values (envelope · error codes ·
cursor · Bearer) follow the wire contract `http-standard@1` — if the project has its own API spec (e.g. `dev/docs/api/`), that is
the source of truth and the paths·codes here are pattern examples. **How tokens are obtained and refreshed** is owned by the auth
variant's `auth-and-session.md`; this file only calls its three functions (`getAccessToken` · `refresh` · `endSession`). The outbox itself
is owned by `data-and-offline.md`, and code → message by `toUserMessage` in `screens-and-states.md`.

## 1. Decision tree — what to do when an error code arrives

Screens branch on `code`, not on the status code. Only the query retry and outbox judgments look at `status` (some failures have no code).

| code | status | Screen | Query retry | Outbox (`sendOutboxOp`) |
| --- | --- | --- | --- | --- |
| `VALIDATION_FAILED` | 400 | Shown under the field (`details`) | No | drop |
| `UNAUTHENTICATED` | 401 | `http` refreshes once → resends once. Still 401 and it ends the session with `endSession()` and throws | No | retry |
| `FORBIDDEN` | 403 | Permission message, no retry button | No | drop |
| `NOT_FOUND` | 404 | One "missing or not yours" screen, no retry button | No | drop (sent if DELETE) |
| `CONFLICT` | 409 | Have the user fix the input | No | drop |
| `PAYLOAD_TOO_LARGE` · `UNSUPPORTED_MEDIA_TYPE` | 413 · 415 | Generic message — this is a client defect | No | drop |
| `RATE_LIMITED` | 429 | Rate-limit message | No | retry |
| `INTERNAL` | 500 | Generic message + retry button | 2 times | retry |
| `NETWORK_ERROR` · `TIMEOUT` | 0 | Connection message when offline | 2 times | retry |
| `BAD_SHAPE` | as received | Generic message — the envelope differs from the contract | Only on 5xx | drop if 4xx |

`NETWORK_ERROR` · `TIMEOUT` · `BAD_SHAPE` are codes this client makes itself. The server never sends them.
A network failure's `status` is `0` — the retry judgment in `queryClient` (`data-and-offline.md` §2) treats 0 as retryable.

## 2. `src/api/http.ts` — strip the envelope and normalize failures into `ApiError`

<!-- file: src/api/http.ts -->
```ts
// src/api/http.ts
import { config } from '@/config';
import { endSession, getAccessToken, refresh } from '@/auth/useAuth';

export type Page<T> = { items: T[]; nextCursor: string | null };
export type HttpInit = { idempotencyKey?: string; signal?: AbortSignal };
type Details = Record<string, string[]>;

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly requestId?: string;
  readonly details?: Details;
  constructor(status: number, code: string, message: string, extra: { requestId?: string; details?: Details } = {}) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.requestId = extra.requestId;
    this.details = extra.details;
  }
}

type Method = 'GET' | 'POST' | 'PATCH' | 'DELETE';
type Body = Record<string, unknown>;
const TIMEOUT_MS = 15_000;

async function send(method: Method, path: string, body: unknown, init: HttpInit, token: string | null): Promise<Response> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;
  if (init.idempotencyKey) headers['Idempotency-Key'] = init.idempotencyKey;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  const forward = () => ctrl.abort();
  if (init.signal?.aborted) ctrl.abort();
  init.signal?.addEventListener('abort', forward);
  try {
    return await fetch(`${config.apiBaseUrl}${path}`, {
      method, headers, signal: ctrl.signal, body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (e) {
    if (init.signal?.aborted) throw e; // a caller cancellation (query cancel) passes through as is — no error screen
    throw new ApiError(0, ctrl.signal.aborted ? 'TIMEOUT' : 'NETWORK_ERROR', 'request failed');
  } finally {
    clearTimeout(timer);
    init.signal?.removeEventListener('abort', forward);
  }
}

function toDetails(v: unknown): Details | undefined {
  if (typeof v !== 'object' || v === null) return undefined;
  const out: Details = {};
  for (const [k, list] of Object.entries(v)) if (Array.isArray(list)) out[k] = list.filter((m) => typeof m === 'string');
  return out;
}

async function parse<T>(res: Response, pick: (b: Body) => T | undefined): Promise<T> {
  const headerId = res.headers.get('x-request-id') ?? undefined;
  if (res.status === 204) return undefined as T;
  const raw: unknown = await res.json().catch(() => undefined);
  const b = typeof raw === 'object' && raw !== null ? (raw as Body) : undefined;
  const requestId = typeof b?.requestId === 'string' ? b.requestId : headerId;
  if (!res.ok) {
    const err = (b?.error ?? {}) as Body;
    const code = typeof err.code === 'string' ? err.code : 'BAD_SHAPE'; // e.g. a proxy's HTML 502 — carry status as is
    throw new ApiError(res.status, code, typeof err.message === 'string' ? err.message : `HTTP ${res.status}`, {
      requestId, details: toDetails(err.details),
    });
  }
  const value = b ? pick(b) : undefined;
  if (value === undefined) throw new ApiError(res.status, 'BAD_SHAPE', 'unexpected response shape', { requestId });
  return value;
}

// 401 → refresh once → resend once (contract §5). Sign-out on a failed refresh is the auth variant's job; if the resend is 401 again, call `endSession()`
async function request<T>(method: Method, path: string, body: unknown, init: HttpInit, pick: (b: Body) => T | undefined): Promise<T> {
  let res = await send(method, path, body, init, await getAccessToken());
  if (res.status === 401) {
    let renewed: boolean;
    try {
      renewed = await refresh();
    } catch {
      throw new ApiError(0, 'NETWORK_ERROR', 'token refresh failed'); // a transient failure — the session is still alive
    }
    if (renewed) {
      res = await send(method, path, body, init, await getAccessToken());
      if (res.status === 401) await endSession(); // the new token was rejected too — end the session and send the user to sign-in (contract §5)
    }
  }
  return parse(res, pick);
}

const data = <T>(b: Body): T | undefined => ('data' in b ? (b.data as T) : undefined);
const page = <T>(b: Body): Page<T> | undefined =>
  Array.isArray(b.data) && (typeof b.nextCursor === 'string' || b.nextCursor === null)
    ? { items: b.data as T[], nextCursor: b.nextCursor }
    : undefined;

export const http = {
  get: <T>(path: string, init: HttpInit = {}) => request<T>('GET', path, undefined, init, data<T>),
  getPage: <T>(path: string, init: HttpInit = {}) => request<Page<T>>('GET', path, undefined, init, page<T>),
  post: <T>(path: string, body: unknown, init: HttpInit = {}) => request<T>('POST', path, body, init, data<T>),
  patch: <T>(path: string, body: unknown, init: HttpInit = {}) => request<T>('PATCH', path, body, init, data<T>),
  delete: <T = void>(path: string, init: HttpInit = {}) => request<T>('DELETE', path, undefined, init, data<T>),
};
```

- **The resend happens exactly once.** If it is still 401 after the refresh, it ends the session with `endSession()` (`signedOut` → the sign-in screen) and then throws that 401 as an `ApiError` — loop instead and it spins forever on a revoked session.
- Resending after a 401 is safe even for a POST — a request stopped at auth was never processed, and it carries the same `Idempotency-Key` again.
- If `refresh()` **throws**, it is a transient failure (network·5xx). `false` means "the user must sign in again", and the auth variant has already done that cleanup.
- A 204 from `delete` ends as `undefined` with no body. Contract §1 fixes deletion at 204.

## 3. `src/api/tasks.ts` — query keys and hooks

<!-- file: src/api/tasks.ts -->
```ts
// src/api/tasks.ts
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { http, type ApiError } from '@/api/http';

export type Task = { id: string; title: string; status: 'open' | 'done'; createdAt: string };

export const taskKeys = {
  all: ['tasks'] as const,
  list: () => [...taskKeys.all, 'list'] as const,
  detail: (id: string) => [...taskKeys.all, 'detail', id] as const,
};

const PAGE_SIZE = 20;

export function useTasksQuery() {
  return useInfiniteQuery({
    queryKey: taskKeys.list(),
    // The cursor is an opaque string — do not interpret it, only encode it and send it back
    queryFn: ({ pageParam, signal }) =>
      http.getPage<Task>(`/api/tasks?limit=${PAGE_SIZE}${pageParam ? `&cursor=${encodeURIComponent(pageParam)}` : ''}`, { signal }),
    initialPageParam: null as string | null,
    getNextPageParam: (last) => last.nextCursor,
  });
}

export function useTaskQuery(id: string | undefined) {
  return useQuery({
    queryKey: taskKeys.detail(id ?? ''),
    queryFn: ({ signal }) => http.get<Task>(`/api/tasks/${encodeURIComponent(id ?? '')}`, { signal }),
    enabled: !!id,
  });
}

// The caller makes the key with newIdempotencyKey() the moment "Save" is pressed — never inside mutationFn
// The create response is 201 + `{ data: Task }` (contract §1). http strips the envelope on any 2xx, so 201 needs no special handling
export function useCreateTask() {
  const qc = useQueryClient();
  return useMutation<Task, ApiError, { title: string; key: string }>({
    mutationFn: ({ title, key }) => http.post<Task>('/api/tasks', { title }, { idempotencyKey: key }),
    onSuccess: () => qc.invalidateQueries({ queryKey: taskKeys.list() }),
  });
}

export function useSetTaskStatus() {
  const qc = useQueryClient();
  return useMutation<Task, ApiError, { id: string; status: Task['status']; key: string }>({
    mutationFn: ({ id, status, key }) =>
      http.patch<Task>(`/api/tasks/${encodeURIComponent(id)}`, { status }, { idempotencyKey: key }),
    onSuccess: (task) => {
      qc.setQueryData(taskKeys.detail(task.id), task);
      return qc.invalidateQueries({ queryKey: taskKeys.list() });
    },
  });
}
```

- The four fields in contract §0 are all of `Task`'s fields. Any further fields the screen needs are set by the project's API spec — do not invent them here.
- When `getNextPageParam` returns `null`, `hasNextPage` is `false`. <!-- unverified: the hasNextPage check (!= null) in query-core@5 infiniteQueryBehavior was not checked against the installed source -->
- Do not use `URLSearchParams` — assembly takes a single `encodeURIComponent`, and there is no need to weigh how much of it the RN runtime implements.

## 4. `src/api/outboxSend.ts` — response → `SendResult`

<!-- file: src/api/outboxSend.ts -->
```ts
// src/api/outboxSend.ts
import { ApiError, http } from '@/api/http';
import type { OutboxOp, SendResult } from '@/offline/outbox';

const RETRYABLE = new Set([0, 401, 408, 429]);

export async function sendOutboxOp(op: OutboxOp): Promise<SendResult> {
  const init = { idempotencyKey: op.key }; // the key made at enqueue, unchanged — the same key on every resend
  try {
    if (op.method === 'POST') await http.post(op.path, op.body, init);
    else if (op.method === 'PATCH') await http.patch(op.path, op.body, init);
    else await http.delete(op.path, init);
    return 'sent';
  } catch (e) {
    if (!(e instanceof ApiError)) return 'retry';
    if (RETRYABLE.has(e.status) || e.status >= 500) return 'retry';
    if (op.method === 'DELETE' && e.code === 'NOT_FOUND') return 'sent'; // already gone — the target state is reached
    return 'drop';
  }
}
```

- Why 401 is `retry`: `http` has already tried a refresh. If the refresh was rejected, the auth variant has already finished up to
  `outbox.clear()`, and the generation check in `outbox.flush` stops the remaining loop — pending mutations never cross an account boundary.
- "Already processed with the same key" is taken to mean the server **replays the first response** (2xx → `sent`). The contract does not
  fix the server behavior for `Idempotency-Key` — if the server ignores the key, a resent POST creates twice. Check the backend guide's idempotency handling.

## 5. Tests — prove one refresh · one resend together

```ts
// test/api/http.test.ts
import { ApiError, http } from '@/api/http';
import { endSession, getAccessToken, refresh } from '@/auth/useAuth';

jest.mock('@/auth/useAuth', () => ({ getAccessToken: jest.fn(), refresh: jest.fn(), endSession: jest.fn(async () => {}) }));
const fetchMock = jest.fn();
global.fetch = fetchMock as unknown as typeof fetch;
const res = (status: number, body: unknown) =>
  ({ status, ok: status >= 200 && status < 300, headers: { get: () => null }, json: async () => body }) as unknown as Response;
const unauth = { error: { code: 'UNAUTHENTICATED', message: 'expired' }, requestId: 'r1' };

it('on 401 refreshes and resends once with the new token, and does not resend when the refresh is rejected', async () => {
  jest.mocked(getAccessToken).mockResolvedValueOnce('old').mockResolvedValueOnce('new');
  jest.mocked(refresh).mockResolvedValueOnce(true);
  fetchMock.mockResolvedValueOnce(res(401, unauth)).mockResolvedValueOnce(res(200, { data: { id: 't1', title: 'a' } }));
  await expect(http.get('/api/tasks/t1')).resolves.toMatchObject({ id: 't1' });
  expect(fetchMock.mock.calls[1][1].headers.Authorization).toBe('Bearer new');

  jest.mocked(refresh).mockResolvedValueOnce(false);
  fetchMock.mockResolvedValueOnce(res(401, unauth));
  const err = await http.get('/api/tasks/t1').catch((e: unknown) => e);
  expect(err).toBeInstanceOf(ApiError);
  expect(err).toMatchObject({ status: 401, code: 'UNAUTHENTICATED', requestId: 'r1' });
  expect(fetchMock).toHaveBeenCalledTimes(3);
  expect(endSession).not.toHaveBeenCalled(); // when the refresh is rejected, the auth variant has already cleaned up

  jest.mocked(refresh).mockResolvedValueOnce(true);
  fetchMock.mockResolvedValue(res(401, unauth));
  await expect(http.get('/api/tasks/t1')).rejects.toMatchObject({ status: 401 });
  expect(fetchMock).toHaveBeenCalledTimes(5); // only one resend
  expect(endSession).toHaveBeenCalledTimes(1); // if the new token is rejected too, end the session
});
```

Assert only the rejection (`toHaveBeenCalledTimes(3)`) and an implementation that never resends passes too — the successful resend before it is the positive pair.
<!-- unverified: new in 3.35.0 — this author did not run it (pack-smoke target) -->

## Misuse list ① — web·old-version habits → the current shape of this client

| Old habit | Current shape |
| --- | --- |
| Retrying 401 in an `axios` interceptor | One place, `request` in `http` — one refresh · one resend |
| `router.replace('/sign-in')` on screen when `res.status === 401` | The auth variant switches the state to `signedOut` and `Stack.Protected` moves the user |
| Requesting a list by `offset`/`page` number | `cursor` — send `nextCursor` back without interpreting it |
| Printing `error.response.data.message` on screen | `toUserMessage(error)` — picks the message by `code` |
| Branching on status code (`if (status === 422)`) | Branch on `code` (`VALIDATION_FAILED`) — the contract allows framework differences in status codes |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| `http.get` vs `http.getPage` | A list envelope (a `data` array + `nextCursor`) is `getPage`. `get` strips just one `data` |
| `refresh()` returning `false` vs throwing | `false` means sign-in is needed again (cleanup done). Throwing is a transient failure — do not discard the session |
| Outbox 401 → `drop` vs `retry` | `retry`. Drop it and a single transient expiry that a refresh could fix wipes out the outbox |
| Key made inside the hook vs by the caller | By the caller, the moment it is pressed. Make it inside the hook's `mutationFn` and every retry gets a new key |
| A retry button for `NOT_FOUND` | Do not give one — resending gives the same result. Only in the DELETE outbox is "already gone = done" |
