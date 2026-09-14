<!-- orangekit-seam: vue+node-api v3.13.0 -->
# Auth & Session — where the token is kept · reissue · return path · disposal

The **method** of authentication is a function of the backend axis. This file pins that method on the frontend: where the token
is kept · who handles a 401 · what logout empties · where you return to after logging in.

The **place and shape** of the router guard is owned by the pack (`resources/routing.md` §4), and this file provides the
`useAuth` that guard calls. The return path **validation function** (`safeReturnTo`) is also owned by the pack —
it is not redefined here; §5 only **consumes** it.

> **Values the contract does not carry**: the wire contract (`contract.md`) fixes only the envelope · pagination · error codes ·
> the surface of authorization failure. **The login · reissue · logout endpoints and how the token travels are not in the contract.**
> What follows is this combination's default and must be matched with the backend. <!-- unverified: the contract document has no such section — this is a value the project decides -->

## 1. Where the token is kept

| Storage | Stealable by XSS | Exposed to CSRF | Survives a refresh | Verdict |
| --- | --- | --- | --- | --- |
| `localStorage` | **yes** — a script can read it | no | yes | not used |
| `sessionStorage` | **yes** | no | per tab | not used |
| a JavaScript variable (memory) | only within the running process | no | no | **the access token** |
| an `httpOnly` cookie | no | yes — blocked with `SameSite` | yes | **the reissue token** |

**The access token in memory, the reissue token in an `httpOnly` cookie.** On refresh the access token
disappears, but `refreshSession()` in §2 restores it immediately from the cookie — this is why the pack guard calls
`await auth.ensureReady()`. Rule before the restore finishes and every refresh bounces the user
to the login screen.

Do not put a token or a signing key in a `VITE_*` environment variable. It is inlined as a bundle string at build time and
is public (the pack's `no-secret-env-prefix` policy).

## 2. The session module (`src/auth/session.ts`)

The owner of the token. Both `http.ts` and `useAuth.ts` touch the token only through this module.
The reissue request itself uses a raw `fetch` — calling `http.ts` would make 401 handling call itself.

<!-- file: src/auth/session.ts -->
```ts
// src/auth/session.ts
import { config } from '@/config';

let accessToken: string | null = null;
let refreshing: Promise<boolean> | null = null;

export function getAccessToken(): string | null {
  return accessToken;
}

export function setAccessToken(next: string | null): void {
  accessToken = next;
}

export function clearSession(): void {
  accessToken = null;
  refreshing = null;
}

// single flight: if N requests that got a 401 at the same time each run a reissue, a server that rotates
// the reissue token lets a late response invalidate the earlier token and the user is bounced at random.
// Only the first call makes a real request; the rest await the same Promise.
export function refreshSession(): Promise<boolean> {
  refreshing ??= runRefresh().finally(() => { refreshing = null; });
  return refreshing;
}

async function runRefresh(): Promise<boolean> {
  try {
    const res = await fetch(`${config.apiBaseUrl}/api/auth/refresh`, {
      method: 'POST',
      credentials: 'include',        // carries the httpOnly reissue cookie
    });
    if (!res.ok) return false;       // failure is not thrown — the caller branches on a boolean
    const body = (await res.json()) as { data?: { accessToken?: unknown } };
    const token = body.data?.accessToken;
    if (typeof token !== 'string' || token === '') return false;
    accessToken = token;
    return true;
  } catch {
    return false;                    // a network failure is also "could not reissue"
  }
}
```

Why `runRefresh` does not throw: its callers are only the 401 branch of `http.ts` and `ensureReady` in the guard,
and what both need is not an exception but **true/false**. Throw here and "there is no session" takes the same shape as
"the request failed", so the screen draws an error instead of the login page.

## 3. One reissue on 401 — the wiring and its boundary

The wiring is in `request()` in `http.ts` (`resources/data-fetching.md` §3). Three rules:

1. **Do not recurse.** The retry calls `send()` one more time; it does not call `request()`
   again. Recursion becomes an infinite loop for as long as the server keeps returning 401
2. **When the reissue fails, call `clearSession()` and raise the original 401 as it is.** Building a new error loses
   the `requestId` and it can no longer be lined up with the server log
3. **Screens do not handle 401.** Putting a refresh/logout branch in an individual screen creates the same logic
   once per screen (the same rule as `loading-error-states.md` §4 in the pack)

<!-- verified: measured by running against a real node:http server with a 40ms delayed reissue — the three rows below are that output -->

| Scenario | Reissue requests | Resource requests | Result |
| --- | --- | --- | --- |
| two requests get a 401 **at the same time** | **1** | 4 (each 401 + retry) | both succeed |
| a repeat request with a valid token | 0 | 1 | success |
| the reissue returns 401 | 1 | 1 (no recursion) | `ApiError('UNAUTHENTICATED')`, `requestId` preserved |

Run the same trial against a defect fixture with `refreshing ??=` removed and two simultaneous 401s make the reissue run
**twice**, breaking the assertion of the first row — proof that this device really blocks something.

## 4. `useAuth` (`src/auth/useAuth.ts`)

The pack guard calls `useAuth().ensureReady()` and `.isAuthenticated.value`. Change the shape and
the guard breaks. Not using `useQueryClient()` matters — a guard is not a component setup,
so it cannot receive an injection. That is why the module-global `queryClient` is imported directly.

<!-- file: src/auth/useAuth.ts -->
```ts
// src/auth/useAuth.ts
import { ref, type Ref } from 'vue';
import { http } from '@/api/http';
import { queryClient } from '@/api/queryClient';
import { clearClientState } from '@/stores/clearClientState';       // owned by the pack
import { getAccessToken, setAccessToken, clearSession, refreshSession } from './session';

// module-global — create new state per component and the header and the guard see different values
const isAuthenticated = ref(getAccessToken() !== null);
let ready: Promise<void> | null = null;

export function useAuth(): {
  isAuthenticated: Ref<boolean>;
  ensureReady: () => Promise<void>;
  login: (input: { email: string; password: string }) => Promise<void>;
  logout: () => Promise<void>;
} {
  return { isAuthenticated, ensureReady, login, logout };
}

// awaited on every guard entry — reusing the same Promise makes duplicate calls safe
function ensureReady(): Promise<void> {
  ready ??= (async () => { isAuthenticated.value = await refreshSession(); })();
  return ready;
}

async function login(input: { email: string; password: string }): Promise<void> {
  const data = await http.post('/api/auth/login', { body: JSON.stringify(input) });
  const token = (data as { accessToken?: unknown } | null)?.accessToken;
  if (typeof token !== 'string') throw new Error('The login response has no accessToken.');
  setAccessToken(token);
  isAuthenticated.value = true;
}

async function logout(): Promise<void> {
  // even if the server call fails the local side must be emptied — finally is that guarantee
  try { await http.post('/api/auth/logout'); } finally {
    isAuthenticated.value = false;
    clearSession();          // ① drop the token first — after this no repeat request is authenticated
    queryClient.clear();     // ② the server cache (so the next user does not see the previous user's list)
    clearClientState();      // ③ client stores + localStorage (owned by the pack)
  }
}
```

<!-- verified: run in a real app with pinia + VueQueryPlugin installed — calling ensureReady 4 times made only 1 reissue request, an authenticated request succeeded after login, and after logout the cache was undefined, density was reset, localStorage was null and a following request was UNAUTHENTICATED -->
**The order is the contract.** Do ② before ①, and the moment the cache is emptied a query still on screen
sends a repeat request with a still-valid token and refills the cache. Empty **both** the server cache (`queryClient`) and
the client stores (`clearClientState`) — empty only one and the next user sees
a fragment of the previous user's screen.

## 5. The login screen and the return path (`src/features/auth/pages/LoginPage.vue`)

The guard puts the path it blocked into `query.returnTo`. That value **came from outside, through the URL**, so only the
result of passing it through the pack's `safeReturnTo` goes to `router.replace`.

```vue
<script setup lang="ts">
// src/features/auth/pages/LoginPage.vue
import { ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAuth } from '@/auth/useAuth';
import { safeReturnTo } from '@/lib/safeReturnTo';     // owned by the pack — not rebuilt here
import { toUserMessage } from '@/lib/toUserMessage';   // owned by the pack
import Button from '@/components/common/Button.vue';

const route = useRoute();
const router = useRouter();
const { login } = useAuth();
const email = ref(''), password = ref(''), isPending = ref(false), message = ref('');

async function onSubmit() {
  isPending.value = true; message.value = '';
  try {
    await login({ email: email.value, password: password.value });
    await router.replace(safeReturnTo(route.query.returnTo));   // ← the validation happens here, once
  } catch (e) {
    message.value = toUserMessage(e);     // the reason for failure is not distinguished (it would leak account existence)
  } finally {
    isPending.value = false;
  }
}
</script>

<template>
  <form class="mx-auto max-w-sm space-y-4" @submit.prevent="onSubmit">
    <input v-model="email" type="email" autocomplete="username" class="w-full rounded border px-3 py-2" />
    <input v-model="password" type="password" autocomplete="current-password" class="w-full rounded border px-3 py-2" />
    <p v-if="message" class="text-sm text-red-600" role="alert">{{ message }}</p>
    <Button :disabled="isPending" variant="primary" size="md">Sign in</Button>
  </form>
</template>
```

This is the result of running the 12 vectors of `security-vectors.md` section A **against the code of this screen as it stands**.

<!-- verified: happy-dom (origin=https://app.example) + a real vue-router, run all the way through replace. The table below is that output -->

| Input | `safeReturnTo` returns | Route reached | Verdict |
| --- | --- | --- | --- |
| `//evil.example` · `/\evil.example` · `https://evil.example` | `/tasks` | tasks | blocked |
| `javascript:alert(1)` · `\tjavascript:alert(1)` | `/tasks` | tasks | blocked |
| `/..//evil.example` · `/../..//evil.example` | `/tasks` | tasks | blocked |
| `''` · `null` · `42` | `/tasks` | tasks | blocked |
| `%2f%2fevil.example` | `/%2f%2fevil.example` | not-found | no external navigation (below) |
| `/tasks\n\rSet-Cookie: x=1` | `/tasksSet-Cookie:%20x=1` | not-found | no external navigation (below) |
| `/tasks?filter=open#top` · `/tasks/123` | the input unchanged | tasks | **passes — a legitimate value** |

The last two vectors do not fall through to the fallback. `%2f` is not decoded in `pathname` and
a control character is stripped by the URL parser, so the result becomes **a non-existent path on the same origin** and lands on
the 404 screen — after `replace`, `location.href` never left `app.example`. <!-- verified: location.href was printed and compared for every vector in the run above -->
If the value had gone to `window.location` or to a server `Location` header instead of `router.replace`,
the verdict would differ — that is why the pack pins the caller obligation (pass it only to `router.replace`/`push`).

## 6. Authorization UI is not a trust boundary

The backend of this combination has **no data-layer policy engine.** Ownership is enforced solely by the server's application
layer, and everything the frontend does is UX. So two things have to be present together.

- **Hiding comes with failure handling.** If you hid a button, you also have to handle the response that action gets
  when it is called directly against the API. With only hiding and no failure handling the user faces a screen
  that does nothing
- **Handle 404 in one screen.** In contract §5 an ownership failure arrives as **404**, not 403.
  A single `NOT_FOUND` branch covers both "a task that does not exist" and "someone else's task" — try to separate them and you fail,
  because the response carries no information to separate them by

```ts
// the branch in a detail screen — it does not separate absent from someone else's
const notFound = computed(() => (error.value as ApiError | null)?.code === 'NOT_FOUND');
```

## Misuse list ① — session idiom table

| Old habit | The current form (this combination) |
| --- | --- |
| `localStorage.setItem('token', ...)` | The access token in memory (`session.ts`), the reissue token in an `httpOnly` cookie |
| Each screen catching 401 and sending the user to login | One place, `http.ts`. Screens know nothing of 401 |
| Reissuing on every 401 and calling `request()` recursively | Call `send()` one more time. Recursion becomes an infinite loop |
| `localStorage.clear()` on logout | The order `clearSession()` → `queryClient.clear()` → `clearClientState()` |
| `if (!token) redirect` in the guard | Look at `isAuthenticated.value` **after** `await ensureReady()` |
| Distinguishing a login failure as "no such account" vs "wrong password" | Generalize to one phrase — distinguishing leaks account existence |
| Checking `returnTo` with `startsWith('/')` | `safeReturnTo()` — a prefix check lets `//host` through |

## Misuse list ② — confused pairs

| Frequently chosen wrongly | The exact condition for each |
| --- | --- |
| `ensureReady()` vs `isAuthenticated` | The former is **to await** (the guard), the latter is **to read** (the screen). Look only at the latter in the guard and every refresh bounces |
| `isAuthenticated` vs `isAuthenticated.value` | The template takes the former (auto-unwrap), script takes the latter. Use the former in script and it is a Ref object, so always truthy |
| `clearSession()` vs `clearClientState()` | The former is the token (the seam), the latter the UI stores and localStorage (the pack). Both are needed |
| `queryClient.clear()` vs `invalidateQueries()` | Logout uses `clear()` (discard), a data change uses `invalidateQueries()` (refetch) |
| 401 `UNAUTHENTICATED` vs 403 `FORBIDDEN` | The former is a token problem (a reissue target), the latter an insufficient role (a reissue changes nothing) |
| 403 `FORBIDDEN` vs 404 `NOT_FOUND` | Insufficient role is the former, **an ownership failure is the latter**. Handling ownership with 403 diverges from the contract |
| Route guard vs server authorization | The guard is UX, the ruling is the server. Even without passing the guard the API can still be called |
