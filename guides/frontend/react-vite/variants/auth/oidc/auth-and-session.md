<!-- orangekit-pack: frontend/react-vite v3.36.0 -->
# Auth & Session — external IdP (OIDC Authorization Code + PKCE)

This is the **auth adapter** for the method where an external IdP issues the tokens and the API server **only verifies** them with JWKS.
It uses the standard OIDC client `oidc-client-ts`, not a specific IdP SDK — swap the issuer and only the
environment variables of this file change. What this file owns: token storage · session state · the login and callback screens · the logout order.
What it does not own: attaching the token to requests and reacting to 401 (`resources/data-fetching.md` §3),
protected routes and `safeReturnTo` (`resources/routing.md` §3), environment values (`resources/types-and-testing.md` §2).

The adapter's outer surface is **the same regardless of the auth method** — `getAccessToken` · `refresh` · `useAuth` ·
`startSession` · `authRoutes`. The http client calls only `getAccessToken` · `refresh`, plus `endSession` when the retry is also 401 (contract §5 · §6).

## 1. Decision — the flow and where things are stored

| When | Flow |
| --- | --- |
| App boot | `startSession()` → `signedIn` if the stored user is valid, `refresh()` if it expired and a refresh token exists, otherwise `signedOut` |
| Login | `signIn(returnTo)` → redirect to the IdP (PKCE) → `/auth/callback` → code exchange → navigate after `safeReturnTo` |
| 401 | the http layer calls `refresh()` = `signinSilent()` once → the original request once → if the retry is also 401, `endSession()` → `signedOut` |
| Logout | clear the cache · stores → `signoutRedirect()` (ends the IdP session) |

| User store | When to pick it |
| --- | --- |
| `sessionStorage` (this file's default) | A refresh survives without an IdP round trip. Cost: a script in the same tab (XSS) can read the whole `User` — `access_token` and **even `refresh_token`**. CSP only reduces that risk; it does not prevent it |
| `InMemoryWebStorage` | Tokens are never left on disk · in storage. Cost: every refresh redirects to the IdP |

## 2. The adapter (`src/auth/session.ts`)

<!-- file: src/auth/session.ts -->
```ts
// src/auth/session.ts — the OIDC adapter (oidc-client-ts, Authorization Code + PKCE)
import { useSyncExternalStore } from 'react';
import { UserManager, WebStorageStateStore, type User } from 'oidc-client-ts';
import { queryClient } from '@/api/queryClient';
import { config } from '@/config';
import { clearClientState } from '@/stores/clearClientState';

// config.ts does not enforce the oidc values — only an app that chose this variant fails here, at boot
if (!config.oidc.authority || !config.oidc.clientId) {
  throw new Error('Environment variables VITE_OIDC_AUTHORITY · VITE_OIDC_CLIENT_ID are not set.');
}

export type AuthStatus = 'loading' | 'signedIn' | 'signedOut';

const userManager = new UserManager({
  authority: config.oidc.authority,
  client_id: config.oidc.clientId,
  redirect_uri: `${window.location.origin}/auth/callback`,      // must equal the callback path in authRoutes
  post_logout_redirect_uri: `${window.location.origin}/login`,
  response_type: 'code',                                        // PKCE is added automatically in the code flow
  scope: 'openid profile email',
  // Caution: the whole User, refresh_token included, is stored — a single XSS reads it (the table in §1)
  userStore: new WebStorageStateStore({ store: window.sessionStorage }),
  automaticSilentRenew: false,                                  // keep refresh() as the single renewal path
  // For an issuer that does not publish end_session_endpoint in discovery
  ...(config.oidc.logoutUrl ? { metadataSeed: { end_session_endpoint: config.oidc.logoutUrl } } : {}),
});

let user: User | null = null;
let status: AuthStatus = 'loading';
// Bumped every time the local session ends. A generation number that stops an in-flight silent renew from reviving the session after it finishes
let generation = 0;
const listeners = new Set<() => void>();

function setUser(next: User | null) {
  user = next;
  status = next ? 'signedIn' : 'signedOut';
  listeners.forEach((notify) => notify());
}

let inflight: Promise<boolean> | null = null;

/** One refresh. Without a refresh token, signinSilent fails and this becomes false */
export function refresh(): Promise<boolean> {
  const gen = generation;                        // captured before the request — compared to see whether a logout happened in between
  inflight ??= userManager.signinSilent()
    .then((u) => { if (gen !== generation) return false; setUser(u); return u !== null; })
    .catch(() => { if (gen !== generation) return false; setUser(null); return false; })
    .finally(() => { inflight = null; });
  return inflight;
}

export async function getAccessToken(): Promise<string | null> {
  if (user?.expired) await refresh();          // if expiry is visible, renew first without a 401 round trip
  return user?.access_token ?? null;
}

/** Called once by main.tsx before rendering. status is 'loading' until it finishes */
export async function startSession(): Promise<void> {
  const stored = await userManager.getUser().catch(() => null);
  if (stored && !stored.expired) { setUser(stored); return; }
  if (stored?.refresh_token) { await refresh(); return; }
  setUser(null);
}

let callback: Promise<string | null> | null = null;

/** For the callback screen only — exchanges the code and returns the round-tripped returnTo **raw value** (the caller validates it) */
export function completeSignIn(): Promise<string | null> {
  // A code can be exchanged only once. So StrictMode's double effect run does not fail on a second exchange
  callback ??= userManager.signinRedirectCallback().then((u) => {
    setUser(u);
    return (u.state as { returnTo?: string } | undefined)?.returnTo ?? null;
  });
  return callback;
}

async function signIn(returnTo?: string): Promise<void> {
  await userManager.signinRedirect({ state: { returnTo: returnTo ?? '/' } });
}

async function signOut(): Promise<void> {
  generation += 1;                              // ⓪ so a silent renew still in flight cannot revive the session when it finishes
  await queryClient.cancelQueries();            // ① so in-flight requests do not refill the cache
  queryClient.clear();                          // ② the server cache
  clearClientState();                           // ③ the client stores
  try {
    await userManager.signoutRedirect();        // ④ delete the stored user + end the IdP session (leaves the page)
  } catch {
    await userManager.removeUser();             // an issuer with no logout endpoint — end the local session only
    setUser(null);
  }
}

/** For the http layer only — if the retry after a refresh is also 401, the session is over (contract §5). Clears local state only */
export function endSession(): void {
  generation += 1;
  void userManager.removeUser().catch(() => undefined);
  setUser(null);                                // RequireAuth sends the user to the login screen
  queryClient.clear();
  clearClientState();
}

const subscribe = (notify: () => void) => {
  listeners.add(notify);
  return () => { listeners.delete(notify); };
};

export function useAuth() {
  const current = useSyncExternalStore(subscribe, () => status);
  return { status: current, signIn, signOut };
}
```

- **The IdP session and the app session are different.** With only `removeUser()` the app is logged out, but the next login
  passes without a password — on a shared device `signoutRedirect()` is required
- `state` is a value that round-tripped through the IdP. Even though our code put it there, **the callback validates it again** (§3)

## 3. The login · callback screens and routes

<!-- file: src/auth/routes.tsx -->
```tsx
// src/auth/routes.tsx — routes.tsx spreads it outside RequireAuth
import type { RouteObject } from 'react-router';

export const authRoutes: RouteObject[] = [
  { path: 'login', lazy: () => import('./pages/LoginPage') },
  // The same path as redirect_uri. Without the static host's history fallback this is a 404 (routing.md §6)
  { path: 'auth/callback', lazy: () => import('./pages/AuthCallbackPage') },
];
```

<!-- file: src/auth/pages/LoginPage.tsx -->
```tsx
// src/auth/pages/LoginPage.tsx
import { useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { useAuth } from '@/auth/session';
import { PageShell } from '@/components/layout/PageShell';
import { Button } from '@/components/ui/Button';
import { safeReturnTo } from '@/lib/safeReturnTo';

export function Component() {
  const { status, signIn } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const target = safeReturnTo(params.get('returnTo'));   // validate even before sending it to the IdP

  useEffect(() => {
    if (status === 'signedIn') navigate(target, { replace: true });
  }, [status, target, navigate]);

  if (status !== 'signedOut') return null;
  return (
    <PageShell title="Log in">
      <Button onClick={() => void signIn(target)}>Log in with your organization account</Button>
    </PageShell>
  );
}
Component.displayName = 'LoginPage';
```

<!-- file: src/auth/pages/AuthCallbackPage.tsx -->
```tsx
// src/auth/pages/AuthCallbackPage.tsx
import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router';
import { completeSignIn } from '@/auth/session';
import { ErrorState } from '@/components/common/ErrorState';
import { safeReturnTo } from '@/lib/safeReturnTo';

export function Component() {
  const navigate = useNavigate();
  const [failure, setFailure] = useState<unknown>(null);

  useEffect(() => {
    completeSignIn()
      .then((raw) => navigate(safeReturnTo(raw), { replace: true }))   // a round-tripped value → re-validate
      .catch((e: unknown) => setFailure(e));
  }, [navigate]);

  if (failure) return <ErrorState title="Sign-in failed" error={failure} />;
  return null;
}
Component.displayName = 'AuthCallbackPage';
```

The header's logout button is `const { signOut } = useAuth();` followed by `onClick={() => void signOut()}`.

## 4. What is expected of the server · IdP (values to align with the backend variant)

- IdP client type: public client (no secret) + PKCE
- Allowed callback URL: `<app origin>/auth/callback` · allowed logout URL: `<app origin>/login`
- API requests: a `Bearer` access token in the `Authorization` header — the server verifies signature · issuer · audience · expiry with JWKS
- Refresh: `refresh()` succeeds only if the IdP issues a refresh token to this client. If it does not, expiry sends the user to the login screen

**Do not put a client secret in the frontend.** `VITE_*` is inlined into the bundle — if the client type needs a
secret, that IdP configuration does not fit an SPA.

## Misuse list ① — old habit → the current form

| Old habit | The current form |
| --- | --- |
| Implicit flow (`response_type: 'token'`) | `response_type: 'code'` + PKCE — the token is not carried in the URL fragment |
| `automaticSilentRenew: true` together with 401 refresh | One renewal path (`refresh()`). With two, the refreshes race |
| Wrapping the screens in an IdP-specific SDK | Standard `oidc-client-ts` + this adapter. Swapping the issuer ends with swapping environment variables |
| Navigating straight to `state.returnTo` in the callback | `navigate(safeReturnTo(raw))` — a round-tripped value is a value from outside |

## Misuse list ② — confusable pairs

| The confused pair | The exact condition for each |
| --- | --- |
| `signoutRedirect()` vs `removeUser()` | The former to end the IdP session too. The latter ends the local session only — the next login passes automatically |
| `refresh()` vs `startSession()` | Boot calls `startSession()` once. Responding to 401 is the http layer calling `refresh()` |
| `status === 'loading'` vs `'signedOut'` | Bounce on `loading` and the login screen flashes on every refresh. Decide only on `signedOut` |
| ID token vs access token | Send only the `access_token` to the API. The ID token is for the client to know the user |
| `sessionStorage` vs `InMemoryWebStorage` | The table in §1. Changing it changes the boot flow too (whether a refresh redirects) |
