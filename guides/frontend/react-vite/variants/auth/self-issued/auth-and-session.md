<!-- orangekit-pack: frontend/react-vite v3.36.0 -->
# Auth & Session — self-issued tokens (email · password + httpOnly refresh cookie)

This is the **auth adapter** for the method where the API server handles login · refresh · logout itself under `/api/auth`.
What this file owns: token storage · session state · the login screen · the logout order. What it does not own:
attaching the token to requests and reacting to 401 (`resources/data-fetching.md` §3), protected routes
(`resources/routing.md` §3), the return-path validation function `safeReturnTo` (`resources/routing.md` §3).

The adapter's outer surface is **the same regardless of the auth method** — `getAccessToken` · `refresh` · `useAuth` ·
`startSession` · `authRoutes`. The http client calls only `getAccessToken` · `refresh`, plus `endSession` when the retry is also 401 (contract §5 · §6).

## 1. Decision — what goes where

| Value | Location | Why |
| --- | --- | --- |
| Access token (short-lived) | **a module variable (memory)** | `localStorage` · `sessionStorage` are read as is by a single XSS |
| Refresh token | httpOnly cookie `rt` (`Path=/api/auth`) | Scripts cannot read it, and it is carried only on refresh · logout requests |
| Session state | module variable + `useSyncExternalStore` | Without a Provider, code outside React (the http layer) and inside (screens) see the same value |

| When | Flow |
| --- | --- |
| App boot | `startSession()` → `POST /api/auth/refresh` → `signedIn` on success, `signedOut` on 401 |
| Login | form → `POST /api/auth/login` `{ email, password }` → `{ data: { accessToken } }` + the `rt` cookie |
| 401 | the http layer calls `refresh()` once → the original request once → if the retry is also 401, `endSession()` → `signedOut` → `RequireAuth` sends the user to login |
| Logout | `POST /api/auth/logout` → discard the token → clear the cache · stores (§4) |

A refresh wipes the in-memory token. That is normal — the refresh at boot restores the session from the cookie.

## 2. The adapter (`src/auth/session.ts`)

<!-- file: src/auth/session.ts -->
```ts
// src/auth/session.ts — the self-issued adapter. The access token exists only in this module's variable
import { useSyncExternalStore } from 'react';
import { useNavigate } from 'react-router';
import { http } from '@/api/http';
import { queryClient } from '@/api/queryClient';
import { ApiError } from '@/lib/api/errors';
import { clearClientState } from '@/stores/clearClientState';

export type AuthStatus = 'loading' | 'signedIn' | 'signedOut';
type TokenBody = { accessToken: string };

let accessToken: string | null = null;
let status: AuthStatus = 'loading';
// Bumped every time the local session ends. A generation number that stops an in-flight refresh from reviving the session after it finishes
let generation = 0;
const listeners = new Set<() => void>();

function setSession(token: string | null) {
  accessToken = token;
  status = token ? 'signedIn' : 'signedOut';
  listeners.forEach((notify) => notify());
}

function parseToken(v: unknown): TokenBody {
  const t = v as Partial<TokenBody> | null;
  if (!t || typeof t.accessToken !== 'string') throw new ApiError(200, 'BAD_SHAPE', 'The token response shape differs from the contract.');
  return { accessToken: t.accessToken };
}

export async function getAccessToken(): Promise<string | null> {
  return accessToken;
}

let inflight: Promise<boolean> | null = null;

/** Takes the lock and refreshes. Both success and failure are applied to the session, and it never throws */
async function lockedRefresh(): Promise<boolean> {
  const gen = generation;                          // captured before the request — compared to see whether a logout · session end happened in between
  try {
    // request holds the lock until the Promise the callback returned settles, and resolves with its value.
    // The DOM types do not unwrap that one layer (Promise<Promise<T>>), so **unwrap it with await** to get the token
    const body = await navigator.locks.request('orangekit-auth-refresh', () =>
      http.post<TokenBody>('/api/auth/refresh', { auth: false, credentials: 'include', parse: parseToken }));
    if (gen !== generation) return false;          // a logout finished first — do not revive the session with a late token
    setSession(body.accessToken);
    return true;
  } catch {
    if (gen !== generation) return false;
    setSession(null);
    return false;
  }
}

/** One refresh. Within a tab inflight, and across tabs Web Locks, reduce the requests to one */
export function refresh(): Promise<boolean> {
  inflight ??= lockedRefresh().finally(() => { inflight = null; });
  return inflight;
}

/** Called once by main.tsx before rendering. status is 'loading' until it finishes */
export async function startSession(): Promise<void> {
  await refresh();
}

/** For the login form only. On failure it rethrows the ApiError as is (UNAUTHENTICATED · VALIDATION_FAILED) */
export async function login(email: string, password: string): Promise<void> {
  const r = await http.post<TokenBody>('/api/auth/login', {
    body: { email, password }, auth: false, credentials: 'include', parse: parseToken,
  });
  setSession(r.accessToken);
}

async function signOut(): Promise<void> {
  generation += 1;                                      // ⓪ so a refresh still in flight cannot revive the session when it finishes
  await queryClient.cancelQueries();                    // ① so in-flight requests do not refill the cache
  await http.post<void>('/api/auth/logout', { auth: false, credentials: 'include' })
    .catch((e: unknown) => {                            // ② keep cleaning up locally even if the server fails — but do not swallow it silently
      console.warn('Logout request failed — the rt cookie may remain and log the user back in on next boot', e);
    });
  setSession(null);                                     // ③ RequireAuth sends the user to the login screen
  queryClient.clear();                                  // ④ the server cache
  clearClientState();                                   // ⑤ the client stores
}

/** For the http layer only — if the retry after a refresh is also 401, the session is over (contract §5). Clears local state only */
export function endSession(): void {
  generation += 1;
  setSession(null);                                     // RequireAuth sends the user to the login screen
  queryClient.clear();
  clearClientState();
}

const subscribe = (notify: () => void) => {
  listeners.add(notify);
  return () => { listeners.delete(notify); };
};

export function useAuth() {
  const current = useSyncExternalStore(subscribe, () => status);
  const navigate = useNavigate();
  return {
    status: current,
    // With self-issued tokens, "starting a login" means going to the login screen — that screen's form takes the credentials
    signIn: async (returnTo?: string) => { navigate(`/login?returnTo=${encodeURIComponent(returnTo ?? '/')}`); },
    signOut,
  };
}
```

- **Refresh must be single-flight.** The server rotates the refresh token every time, and when an already-used token comes
  back it invalidates that whole family (reuse detection). If three requests that got a 401 at once each refresh, the second
  request is judged a "reuse" and **a legitimate user is logged out.** Two tabs are the same — hence Web Locks
- `useAuth()` uses `useNavigate`, so call it only inside the router (under `RouterProvider`)

## 3. The login screen and routes

<!-- file: src/auth/routes.tsx -->
```tsx
// src/auth/routes.tsx — routes.tsx spreads it outside RequireAuth
import type { RouteObject } from 'react-router';

export const authRoutes: RouteObject[] = [
  { path: 'login', lazy: () => import('./pages/LoginPage') },
];
```

<!-- file: src/auth/pages/LoginPage.tsx -->
```tsx
// src/auth/pages/LoginPage.tsx
import { useState, type FormEvent } from 'react';
import { Navigate, useNavigate, useSearchParams } from 'react-router';
import { login, useAuth } from '@/auth/session';
import { Field } from '@/components/common/Field';
import { Button } from '@/components/ui/Button';
import { ApiError, type FieldErrors } from '@/lib/api/errors';
import { safeReturnTo } from '@/lib/safeReturnTo';
import { toUserMessage } from '@/lib/toUserMessage';

export function Component() {
  const { status } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const [errors, setErrors] = useState<FieldErrors>({});
  const [pending, setPending] = useState(false);

  if (status === 'signedIn' && !pending) return <Navigate to={safeReturnTo(params.get('returnTo'))} replace />;

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    setErrors({});
    setPending(true);
    try {
      await login(String(form.get('email') ?? ''), String(form.get('password') ?? ''));
      navigate(safeReturnTo(params.get('returnTo')), { replace: true });   // a value from outside → validate, then navigate
    } catch (err) {
      if (err instanceof ApiError && err.code === 'VALIDATION_FAILED' && err.details) setErrors(err.details);
      // Do not say which one was wrong — saying so lets registered emails be enumerated
      else if (err instanceof ApiError && err.code === 'UNAUTHENTICATED') setErrors({ _: ['Incorrect email or password.'] });
      else setErrors({ _: [toUserMessage(err)] });
      setPending(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="mx-auto mt-16 max-w-sm space-y-4" noValidate>
      {errors._ && <p role="alert" className="text-sm text-danger-600">{errors._[0]}</p>}
      <Field label="Email" htmlFor="email" error={errors.email?.[0]}>
        <input id="email" name="email" type="email" autoComplete="username" className="h-10 w-full rounded-md border px-3 text-sm" />
      </Field>
      <Field label="Password" htmlFor="password" error={errors.password?.[0]}>
        <input id="password" name="password" type="password" autoComplete="current-password" className="h-10 w-full rounded-md border px-3 text-sm" />
      </Field>
      <Button type="submit" className="w-full" disabled={pending}>Log in</Button>
    </form>
  );
}
Component.displayName = 'LoginPage';
```

The header's logout button is `const { signOut } = useAuth();` followed by `onClick={() => void signOut()}`.

## 4. Why the logout order matters

In §2 `signOut`, ⓪ (bumping the generation number) and the five steps are an ordering contract. Drop ⓪ and a refresh that finishes
mid-logout **revives the session** with `setSession(token)`. Drop ① and a request still in flight receives its response and
**refills the cleared cache with the previous user's data.** Why ③ comes before ④: the status must become `signedOut` first so the
protected screens unmount, and after that no screen is left to re-fetch into the cleared cache.
`clearClientState()` clears only the stores — discarding the server cache is owned by this procedure (`state-management.md` §6).

**Limitation: if the logout request fails on the network, the server cannot discard `rt`, and a script cannot delete an
httpOnly cookie.** Local cleanup finishes, but `startSession()` on the next boot silently logs back in with that cookie.
That is why the failure is left as a `console.warn`. If shared devices must be guaranteed too, the server has to handle cookie
expiry and family revocation together (§5), and that is not something this adapter can do.

## 5. What is expected of the server (values to align with the backend variant)

- Paths: `POST /api/auth/login` · `POST /api/auth/refresh` · `POST /api/auth/logout`
- Login · refresh response: `{ data: { accessToken } }`, with the refresh token as `Set-Cookie: rt=…; HttpOnly; Secure; SameSite=Lax; Path=/api/auth`
- After a failed refresh · logout: 401 `UNAUTHENTICATED`, cookie deleted
- CORS (when the origins differ): name this app's single origin explicitly with `Access-Control-Allow-Credentials: true` — `*` cannot be combined with credentials

**Put the SPA and the API on the same site (registrable domain)** — `app.example.com` and `api.example.com` are
the same site, so a `SameSite=Lax` cookie is carried. On different domains `SameSite=None` becomes necessary and
the refresh endpoint is opened to cross-site requests.

## Misuse list ① — old habit → this adapter's form

| Old habit | The current form |
| --- | --- |
| `localStorage.setItem('token', …)` | A module variable. A page refresh is restored by the boot refresh |
| An axios interceptor refreshes on every 401 | Once, via the `retried` flag in `http.ts`. The refresh itself is the single-flight `refresh()` |
| `credentials: 'include'` on every request | Only on `/api/auth/*` calls. The ordinary API uses Bearer and needs no cookie |
| The refresh token in the login response body | The browser receives it as an httpOnly cookie. Returning it in the body is only for app clients (`client: 'app'`) |
| Wrapping the app in `<AuthProvider>` | No Provider. `useSyncExternalStore` subscribes to the module state |

## Misuse list ② — confusable pairs

| The confused pair | The exact condition for each |
| --- | --- |
| `refresh()` vs `startSession()` | Boot calls `startSession()` once. Responding to 401 is the http layer calling `refresh()` — a screen never calls it directly |
| `signIn(returnTo)` vs `login(email, password)` | `signIn` sends the user to the login screen (the surface common to every method). Only the login form's `login` exchanges credentials |
| `status === 'loading'` vs `'signedOut'` | Bounce on `loading` and the login screen flashes on every refresh. Decide only on `signedOut` |
| Branching the UNAUTHENTICATED message vs a single message | A login failure gets a single message. Splitting "unknown email" · "wrong password" enables account enumeration |
| `navigate(returnTo)` vs `navigate(safeReturnTo(returnTo))` | The `returnTo` in the query is a value from outside. Always the latter form |
