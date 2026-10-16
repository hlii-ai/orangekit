<!-- orangekit-pack: app/react-native v1.0.0 -->
# Data and offline — server cache · idempotency keys · the mutation queue

This file owns `src/lib/queryClient.ts` · `src/lib/idempotency.ts` · `src/offline/outbox.ts` · `src/offline/useOutboxSync.ts`.
The outbox's `send` implementation (`sendOutboxOp` — envelope parsing · error code → `SendResult` · the `Idempotency-Key` header) and the
query hooks·query keys are functions of the wire contract, so the seam's `api-client.md` owns them; the position of `queryClient.clear()`
in sign-out is owned by `auth-and-session.md`.

## 1. Decision tree — what goes where

| Data | Where it goes | Why |
| --- | --- | --- |
| Lists·details whose source of truth is the server (`Task`) | The `queryClient` cache | The cache owns revalidation·deduplication·retries. Copy it into a store and there are two sources of truth |
| UI state shared between screens (filters · selection · sheet open) | Zustand (`src/stores/`) | These are values the server does not have. No server data goes in |
| Mutations made offline (create · update · delete) | `outbox` (persisted in AsyncStorage) | They must survive the app being killed |
| Tokens · secrets | `tokenStore` (`secure-storage.md`) | AsyncStorage is not encrypted — they do not go in the outbox `body` either |

The order of judgment: **is the server the source of truth?** → if yes, the cache. **Is it a write that must reach the server even
after the app is killed?** → if yes, the outbox. If neither, the store. `useMutation` alone is not enough — a mutation started offline is
only **paused in memory** under `networkMode: 'online'` (the default), and it vanishes when the app dies. <!-- verified: @tanstack/query-core@5.104.3 build/modern/retryer.js:19-20 canFetch · mutation.js:170 networkMode -->

## 2. QueryClient for RN (`src/lib/queryClient.ts`)

The web's default detection (`visibilitychange` · `online`/`offline` on `window`) registers nothing in RN, which has no
`window.addEventListener` — bind focus to `AppState` and online to NetInfo directly. <!-- verified: the window.addEventListener guard in the constructors of @tanstack/query-core@5.104.3 build/modern/onlineManager.js · focusManager.js -->

<!-- file: src/lib/queryClient.ts -->
```ts
// src/lib/queryClient.ts
import { AppState } from 'react-native';
import NetInfo from '@react-native-community/netinfo';
import { QueryClient, focusManager, onlineManager } from '@tanstack/react-query';

// Up to 2 times, only for network failures (no numeric status) and 5xx. Reads status by duck typing instead of importing ApiError
function shouldRetry(failureCount: number, error: unknown): boolean {
  if (failureCount >= 2) return false;
  const status = (error as { status?: unknown } | null)?.status;
  return typeof status !== 'number' || status >= 500; // a 4xx comes back the same however often you resend
}

export const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: shouldRetry } },
});

export function wireQueryManagers(): () => void {
  focusManager.setEventListener((setFocused) => {
    const sub = AppState.addEventListener('change', (state) => setFocused(state === 'active'));
    return () => sub.remove();
  });
  onlineManager.setEventListener((setOnline) =>
    NetInfo.addEventListener((state) => setOnline(!!state.isConnected)),
  );
  // Replacing with an empty setup makes each manager call its previous cleanup (sub.remove · NetInfo unsubscribe)
  return () => (focusManager.setEventListener(() => undefined), onlineManager.setEventListener(() => undefined));
}
```

- The `failureCount` of the `retry` function is 0 on the first failure — stop at `>= 2` and there are exactly 2 retries. <!-- verified: query-core@5.104.3 retryer.js:67,132,137 + a real QueryClient run: 503·network error tried 3 times · 404·401 once -->
- If the app goes to the background while waiting to retry, the retry stops too — the resume condition is `focusManager.isFocused()`. <!-- verified: query-core@5.104.3 retryer.js:91 canContinue -->
- **Wiring obligation**: exactly once, in the `useEffect(() => wireQueryManagers(), [])` of the root layout (`src/app/_layout.tsx`).
  Call it in the render body and the subscriptions are torn down and re-registered on every render. Hand the return value back as the effect's cleanup. <!-- verified: query-core@5.104.3 onlineManager.js setEventListener calls the previous cleanup · ran with AppState/NetInfo stubs and counted unsubscribes on rewire·teardown -->

## 3. Idempotency keys (`src/lib/idempotency.ts`)

<!-- file: src/lib/idempotency.ts -->
```ts
// src/lib/idempotency.ts
import { randomUUID } from 'expo-crypto';

// Call once, when the mutation is "created". Make a new one on resend and the server applies the same mutation twice
export function newIdempotencyKey(): string {
  return randomUUID();
}
```

`randomUUID()` in `expo-crypto` synchronously returns a UUIDv4 string made from cryptographic randomness. <!-- verified: expo-crypto@57.0.4 build/Crypto.d.ts:57-67 -->
`Math.random` is predictable — if a key can be guessed, someone else's mutation result can be replayed. The server-side check is owned by the idempotent-ingestion slot of the backend guide.

## 4. The offline mutation queue (`src/offline/outbox.ts`)

<!-- file: src/offline/outbox.ts -->
```ts
// src/offline/outbox.ts
import AsyncStorage from '@react-native-async-storage/async-storage';
import { newIdempotencyKey } from '@/lib/idempotency';

export type OutboxOp = {
  key: string;
  method: 'POST' | 'PATCH' | 'DELETE';
  path: string;
  body?: unknown; // a plaintext store — no tokens·secrets
  createdAt: number;
};
export type SendResult = 'sent' | 'retry' | 'drop';
type FlushReport = { sent: number; kept: number; dropped: number };

const STORAGE_KEY = 'outbox.v1';
let chain: Promise<unknown> = Promise.resolve();
let inFlight: Promise<FlushReport> | null = null;
let generation = 0; // bumped by clear() — a flush loop from an older generation does not send the next op

// Serialize the read-modify-write section — so enqueue and flush's removal never overwrite each other
function locked<T>(fn: () => Promise<T>): Promise<T> {
  const next = chain.then(fn, fn);
  chain = next.catch(() => undefined);
  return next;
}

const METHODS: readonly unknown[] = ['POST', 'PATCH', 'DELETE'];
function isOp(v: unknown): v is OutboxOp {
  const o = v as Partial<Record<keyof OutboxOp, unknown>> | null;
  return typeof o?.key === 'string' && typeof o.path === 'string' && typeof o.createdAt === 'number' && METHODS.includes(o.method);
}

async function load(): Promise<OutboxOp[]> {
  const raw = await AsyncStorage.getItem(STORAGE_KEY);
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter(isOp) : []; // discard per element so one broken element does not block the head
  } catch {
    return [];
  }
}

const save = (ops: OutboxOp[]) => AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(ops));

async function run(send: (op: OutboxOp) => Promise<SendResult>): Promise<FlushReport> {
  const gen = generation;
  let sent = 0;
  let dropped = 0;
  for (;;) {
    const head = (await locked(load))[0];
    if (!head || gen !== generation) break;
    let result: SendResult;
    try {
      result = await send(head);
    } catch {
      result = 'retry';
    }
    if (result === 'retry' || gen !== generation) break; // retry: sending a later one first flips the order
    await locked(async () => save((await load()).filter((op) => op.key !== head.key)));
    if (result === 'sent') sent += 1;
    else dropped += 1;
  }
  return { sent, kept: (await locked(load)).length, dropped };
}

export const outbox = {
  async enqueue(input: Omit<OutboxOp, 'key' | 'createdAt'>): Promise<OutboxOp> {
    const op: OutboxOp = { ...input, key: newIdempotencyKey(), createdAt: Date.now() };
    await locked(async () => save([...(await load()), op]));
    return op;
  },
  flush(send: (op: OutboxOp) => Promise<SendResult>): Promise<FlushReport> {
    if (inFlight) return inFlight; // concurrent calls share the one in progress — prevents double sends
    const p = run(send).finally(() => void (inFlight === p && (inFlight = null)));
    inFlight = p;
    return p;
  },
  async clear(): Promise<void> {
    generation += 1; // a loop in progress sees the generation change and stops — a new user's op is never sent with the old send
    inFlight = null; // the next flush does not share; it starts a new loop with the new send
    await locked(() => AsyncStorage.removeItem(STORAGE_KEY)).catch(() => undefined);
  },
};
```

- The lock wraps only storage reads·writes (lock the send too and `enqueue` holds up the screen). Removal is by `key`, so an op that arrives mid-flush is not lost either.
- The second `send` of a concurrent call is never used; it receives the in-progress result as is. A corrupted stored value is treated as an empty queue, and a malformed element as discarded. <!-- verified: ran on top of AsyncStorage's official jest mock (async-storage@2.2.0) — concurrent flush gets the same Promise·send once · enqueue during flush preserved · continues after drop · throw=retry stops · corrupted value -->
- `clear()` must be in the sign-out cleanup order (owned by the seam's `useAuth().signOut`). It bumps the generation to stop a loop in progress, so
  ops a new user enqueues after the clear do not go out through the previous user's flush. One op already in transit cannot be taken back. <!-- verified: ran the §7 tests with jest-expo@57 + AsyncStorage's official mock — a mutant without the generation counter fails because the old flush sends /b, enqueued after clear -->

## 5. When to call flush (`src/offline/useOutboxSync.ts`)

<!-- file: src/offline/useOutboxSync.ts -->
```ts
// src/offline/useOutboxSync.ts
import { useEffect } from 'react';
import { AppState } from 'react-native';
import { onlineManager } from '@tanstack/react-query';
import { sendOutboxOp } from '@/api/outboxSend';
import { queryClient } from '@/lib/queryClient';
import { outbox } from '@/offline/outbox';

function flushNow(): void {
  if (!onlineManager.isOnline()) return;
  outbox
    .flush(sendOutboxOp)
    .then((r) => (r.sent > 0 ? queryClient.invalidateQueries() : undefined))
    .catch(() => undefined); // storage error — the next trigger tries again
}

export function useOutboxSync(ready: boolean): void {
  useEffect(() => {
    if (!ready) return; // before the auth verdict·signed out: sending without a token only piles up 401s
    flushNow(); // cold start·right after sign-in: the queue left over from the last run
    const offOnline = onlineManager.subscribe((online) => void (online && flushNow()));
    const sub = AppState.addEventListener('change', (s) => void (s === 'active' && flushNow()));
    return () => (offOnline(), sub.remove());
  }, [ready]);
}
```

**Caller's obligation: `useOutboxSync(status === 'signedIn')` once, in the root layout** — the root layout file is owned by `navigation.md` and the call goes there.
`sendOutboxOp` (`src/api/outboxSend.ts`) is implemented by the seam's `api-client.md` — it sends `op.key` as `Idempotency-Key`, and maps
2xx·"already processed with the same key" → `'sent'`, network failure·5xx·429·401·408 → `'retry'` (401 means waiting for the token refresh — if the refresh fails the seam hands off to `signOut` and `outbox.clear()` discards the queue. Nothing is resent after re-sign-in — pending mutations do not cross an account boundary), any other 4xx → `'drop'`.
`onlineManager.subscribe` receives the value bound to NetInfo in §2. **Background resending while the app is closed is out of scope.**

## 6. Optimistic updates and the outbox

The outbox guarantees **that it reaches the server**; an optimistic update guarantees **that the screen does not wait**. Invalidation after flush (§5) reconciles the two.
| Situation | What to do |
| --- | --- |
| An update made offline | Fix the cache first with `setQueryData`, then `outbox.enqueue` — the query keys are seam-owned, so do it inside the seam's hook |
| Updating the same item right after creating it | The `POST`'s server id does not exist yet. Whether the server accepts a client-generated id is the wire contract, so the seam decides |
| An op that was `drop`ped | The optimistic value turned out false — roll it back with `invalidateQueries()` and tell the user |

## 7. Tests — prove order preservation and the retry stop together

```ts
// src/offline/outbox.test.ts
import AsyncStorage from '@react-native-async-storage/async-storage';
import { outbox, type OutboxOp, type SendResult } from '@/offline/outbox';

jest.mock('@react-native-async-storage/async-storage', () =>
  require('@react-native-async-storage/async-storage/jest/async-storage-mock'),
);
jest.mock('expo-crypto', () => ({ randomUUID: (() => { let n = 0; return () => `key-${++n}`; })() })); // randomUUID in jest-expo's default mock returns undefined

beforeEach(() => AsyncStorage.clear());

it('does not send later ops when the head is retry, and resends in order with the same keys', async () => {
  const a = await outbox.enqueue({ method: 'POST', path: '/tasks', body: { title: 'a' } });
  const b = await outbox.enqueue({ method: 'PATCH', path: '/tasks/1', body: { title: 'b' } });
  const seen: string[] = [];
  const sendAs = (r: 'sent' | 'retry') => async (op: OutboxOp) => (seen.push(op.key), r);

  expect(await outbox.flush(sendAs('retry'))).toEqual({ sent: 0, kept: 2, dropped: 0 });
  expect(seen).toEqual([a.key]);

  expect(await outbox.flush(sendAs('sent'))).toEqual({ sent: 2, kept: 0, dropped: 0 });
  expect(seen).toEqual([a.key, a.key, b.key]);
});

it('after clear, an op from the new user does not go out through the old flush, but does through a new flush', async () => {
  await outbox.enqueue({ method: 'POST', path: '/a' });
  let release!: (r: SendResult) => void;
  const gate = new Promise<SendResult>((r) => (release = r));
  const oldSent: string[] = [];
  const old = outbox.flush(async (op) => (oldSent.push(op.path), op.path === '/a' ? gate : 'sent'));
  await new Promise((r) => setTimeout(r, 10)); // /a in transit
  await outbox.clear(); // sign-out
  await outbox.enqueue({ method: 'POST', path: '/b' }); // the next user
  release('sent');
  await old;
  expect(oldSent).toEqual(['/a']);

  const newSent: string[] = [];
  expect(await outbox.flush(async (op) => (newSent.push(op.path), 'sent' as const))).toEqual({ sent: 1, kept: 0, dropped: 0 });
  expect(newSent).toEqual(['/b']);
});
```

Assert only the stop and an implementation that sends nothing passes too. The second half of each `it` (everything, in order, with the same keys · `/b` goes out through a new flush) is the positive pair. <!-- verified: ran with the jest-expo@57 runner — 2 passing. Mutants: removing the generation check fails because /b lands in oldSent, removing the generation bump fails. That randomUUID() in jest-expo's default mock is undefined was confirmed in the same runner -->

## Misuse list ① — web·old-version habits → the current shape in RN + TanStack Query v5

| Old habit | Current shape |
| --- | --- |
| Expecting `refetchOnWindowFocus` to work when the app comes back | It works only once bound to `AppState` with `focusManager.setEventListener` (§2) |
| The `cacheTime` option | `gcTime` <!-- verified: 0 occurrences of cacheTime in @tanstack/query-core@5.104.3 build/modern/*.d.ts · gcTime?: number present --> |
| A paused `useMutation` = offline support | It is only paused in memory. A write that must survive the app being killed goes in the outbox |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| Generating the key at `enqueue` vs at `send` | Once, at `enqueue`. Make it in `send` and every resend gets a new key |
| `!!state.isConnected` vs `isInternetReachable` | Judge online with `isConnected`. `isInternetReachable` is `null` before it is determined, so folding it with `!!` makes you offline even when connected <!-- verified: @react-native-community/netinfo@12.0.1 lib/typescript/src/internal/types.d.ts:33,47 --> |
| Query retries vs outbox resends | A failed read is retried twice by the query. Writes get no `retry` policy; the outbox resends them on the next trigger |
| `queryClient.invalidateQueries()` vs `outbox.clear()` | After a flush, invalidate (fetch again). `outbox.clear()` only in sign-out cleanup — it discards mutations that have not gone out yet |
