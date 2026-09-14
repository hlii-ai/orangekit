<!-- orangekit-seam: react-vite+aws-container/frontend v3.12.0 -->
# Auth & Session (standard OIDC · Cognito as the issuer)

This project uses Cognito **only as an OIDC issuer**. It does not couple to the vendor SDK; it uses only the standard
flow (Authorization Code + PKCE, discovery, JWT access token) — moving later to a self-hosted
issuer (Keycloak and the like) must come down to swapping the `authority` URL and editing one adapter file.

## 1. The flow

```
SPA → /authorize (code_challenge)        → the issuer login screen
    ← /auth/callback?code=...&state=...   ← this path must exist in the route tree (routing.md §1)
    → /token (code + code_verifier)      → access_token · id_token · refresh_token
    → API call: Authorization: Bearer <access_token>
                                          the API verifies signature · issuer · audience · expiry · permission
```

- **Use Authorization Code + PKCE only.** The implicit flow (`response_type=token`) is deprecated
- An SPA is a public client — **it holds no client secret.** The moment it goes into the bundle it is not a secret
- The frontend only **carries** the token. It does not decode it to decide permission

## 2. Settings and UserManager (`src/auth/oidcConfig.ts`)

The `AuthProvider` of `react-oidc-context` can take a **`UserManager` instance** instead of settings props.
Creating the instance yourself lets the refresh and logout utilities work on the same session outside the hooks.

```ts
import { UserManager, WebStorageStateStore, InMemoryWebStorage,
         type UserManagerSettings } from 'oidc-client-ts';
import { config } from '@/config';         // never read import.meta.env directly

export const oidcSettings: UserManagerSettings = {
  authority: config.oidc.authority,                          // issuer URL (the base point for discovery)
  client_id: config.oidc.clientId,
  redirect_uri: `${window.location.origin}/auth/callback`,
  post_logout_redirect_uri: window.location.origin,
  response_type: 'code',
  scope: 'openid profile email',
  automaticSilentRenew: true,
  // ① where the token is kept is this one line — the default is memory
  userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
  // ② the PKCE verifier and state must survive across the redirect. Keeping them in memory
  //    makes the code exchange in the callback fail outright — their lifetime is short, so sessionStorage is right
  stateStore: new WebStorageStateStore({ store: window.sessionStorage }),
};

export const userManager = new UserManager(oidcSettings);

// strip code/state from the URL after the callback (prevents leaks through history and referrer)
export const onSigninCallback = () =>
  window.history.replaceState({}, '', window.location.pathname);
```

Do **not hard-code** issuer-specific strings (user pool ID, region, vendor-hosted UI path) here.
Move them all to environment variables → `config`, and swapping the issuer becomes a deployment-config change.

## 3. Where the token is kept

| Location | Survives refresh | Readable via XSS | Verdict |
| --- | --- | --- | --- |
| memory (`InMemoryWebStorage`) | ✗ (recovered by silent login) | only while running | **the default — this is what the §2 code does** |
| `sessionStorage` | ○ (per tab) | ○ | only where silent login is blocked |
| `localStorage` | ○ (shared across tabs and windows) | ○ (longest exposure) | not recommended |

- The default is **memory storage + silent refresh**. On refresh the token disappears and is recovered with a silent
  login against the issuer session cookie (`prompt=none` in a hidden iframe, or a refresh token).
  **Where third-party cookies are blocked this recovery fails**, so the user goes back to the login screen
- **Never put a refresh token in `localStorage`, under any circumstances.** It outlives the access token,
  so the damage from theft is larger
- Changing the storage is a decision subject to security review. It is one line of code, but the risk grade changes

## 4. The token provider — cutting the coupling to the HTTP layer

If `http.ts` imports the auth library directly, replacing the auth implementation spreads into edits of the HTTP layer.
Cut it with **one-way injection**.

```ts
// src/api/tokenProvider.ts — http.ts knows only this file
type TokenGetter = () => Promise<string | null>;
let getter: TokenGetter = async () => null;

export const setTokenGetter = (fn: TokenGetter) => { getter = fn; };
export const getAccessToken = () => getter();
```

```tsx
// src/auth/AuthWiring.tsx — the only place that calls setTokenGetter.
// If this component is missing from the Provider tree, every request goes out without an auth header.
export function AuthWiring({ children }: { children: ReactNode }) {
  const auth = useAuth();
  useEffect(() => {
    setTokenGetter(async () => {
      if (auth.user && !auth.user.expired) return auth.user.access_token ?? null;
      // read the refresh result **from the return value**. The auth.user in the closure is still the old, expired object
      const renewed = await auth.signinSilent().catch(() => null);
      return renewed?.access_token ?? auth.user?.access_token ?? null;
    });
  }, [auth]);
  return <>{children}</>;
}
```

```tsx
// src/main.tsx — keep this nesting order identical to routing.md
<AuthProvider userManager={userManager} onSigninCallback={onSigninCallback}>
  <AuthWiring>                                {/* mount the token provider — it must precede the first request */}
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </AuthWiring>
</AuthProvider>
```

The session is outermost, the token wiring inside it, the cache inside that, and the router last. Invert the order and put
`QueryClientProvider` outside, and queries mount before the token wiring, so the first request comes back 401.

## 5. Handling 401 — in one place only

```ts
// src/auth/session.ts — the only file where refresh and expiry handling live
import { userManager } from './oidcConfig';

export async function renewSession(): Promise<boolean> {
  const user = await userManager.signinSilent().catch(() => null);
  return Boolean(user?.access_token);
}

let inFlight: Promise<boolean> | null = null;
/** Single flight: even if several requests get a 401 at once, the refresh runs once */
export function refreshOnce(): Promise<boolean> {
  inFlight ??= renewSession().finally(() => { inFlight = null; });
  return inFlight;
}

export async function handleSessionExpired(): Promise<void> {
  await userManager.removeUser().catch(() => null);
  const returnTo = window.location.pathname + window.location.search;  // an internal path — not user input
  window.location.replace(`/login?returnTo=${encodeURIComponent(returnTo)}`);
}
```

The only call site is **one place**, inside `request()` in `http.ts` (`data-fetching.md` §1).

```ts
if (res.status === 401) {
  if (!retried && (await refreshOnce())) return request(method, path, opts, true);
  await handleSessionExpired();
}
```

- The retry happens **exactly once**. That guarantee comes from the `retried` parameter, not from a comment —
  calling `request()` recursively without a condition turns repeated refresh success/failure into a login loop
- Do not copy 401 handling into every screen. A screen should never have to see a 401

## 6. Logout — the order matters

```ts
export async function logout(queryClient: QueryClient) {
  queryClient.cancelQueries();      // ① cancel in-flight requests (so a response cannot revive the cache)
  queryClient.clear();              // ② discard the whole server cache — the next user must not see the previous data
  clearClientState();               // ③ reset the Zustand stores (state-management.md §6)
  await endSessionAtIssuer();       // ④ end the issuer session (this leaves the tab)
}
```

Skipping `clear()` lets the next user who signs in briefly see **the previous user's cached list**.
Measured, this is a common information disclosure, and it lingers because it is hard to reproduce.

**Logout is the one point where the issuer difference shows.** Standard RP-initiated logout sends
`id_token_hint` and `post_logout_redirect_uri` to the `end_session_endpoint`. However,
**Cognito does not expose `end_session_endpoint` in its discovery document** — that is not something to check
with a conditional branch; it is a fixed fact about this issuer. So the vendor `/logout` URL is used, and
that branch is confined to a single adapter file.

```ts
// src/auth/endSession.ts — the only file where issuer-specific code lives
import { userManager } from './oidcConfig';
import { config } from '@/config';

export async function endSessionAtIssuer(): Promise<void> {
  // the vendor /logout does not require id_token_hint, so clearing the local token first is fine.
  await userManager.removeUser();
  const url = new URL(config.oidc.logoutUrl);          // VITE_OIDC_LOGOUT_URL
  url.searchParams.set('client_id', config.oidc.clientId);
  url.searchParams.set('logout_uri', window.location.origin);
  window.location.assign(url.toString());              // this leaves the tab
}
```

If you move to an issuer that does provide `end_session_endpoint`, replace the body of this function with
**one line**, `await userManager.signoutRedirect()`. At that point the order inverts —
`signoutRedirect()` needs the stored id_token in order to attach `id_token_hint`, so
**you must not call `removeUser()` first**. Calling it first sends a logout request with no hint, the
issuer session survives, and signing in again just flashes the screen and passes straight through.

## 7. Authorization is not the frontend's responsibility

The backend has no row-level policy engine in the data layer — **the API server's explicit check is the only line
of defense**. The frontend's role stops at anticipating that ruling and tidying the UI.

This backend has no `/me` endpoint that hands over a permission list. Roles come from the group claim the issuer
put in the token — the server enforces them by **re-reading the same claim from the verified token**, and
the frontend reads the same value **for display purposes only**.

```ts
// src/auth/groups.ts — the only file where the issuer-specific claim name lives (paired with the backend normalization)
const GROUPS_CLAIM = 'cognito:groups';
export const readGroups = (profile: Record<string, unknown> | undefined): string[] => {
  const raw = profile?.[GROUPS_CLAIM];
  return Array.isArray(raw) ? raw.filter((v): v is string => typeof v === 'string') : [];
};

// src/auth/useCan.ts — a UI hint only. Even when this is true the server rules again
export type Ability = 'task:delete' | 'task:assign';
const ABILITY_GROUPS: Record<Ability, string[]> = {
  'task:delete': ['admin', 'manager'],
  'task:assign': ['admin', 'manager', 'member'],
};
export function useCan(ability: Ability): boolean {
  const { user } = useAuth();
  return readGroups(user?.profile).some((g) => ABILITY_GROUPS[ability].includes(g));
}
```

```tsx
// ✅ hide it, but respect the server's ruling as it stands
const canDelete = useCan('task:delete');
{canDelete && <DeleteButton onError={(e) => toast.error(toUserMessage(e))} />}  // ready for 403/404

// ❌ treating a read claim as "the check is done" — no signature verification, and freely bypassed from the console
if (jwtDecode<{ role: string }>(token).role === 'admin') { await http.delete(url); }
```

- Reading a claim is **for display and tidiness**. The only trust boundary is the API server, and because this backend
  has no row-level policy engine, hiding UI adds **zero** to the defense
- Access to someone else's resource comes back as **404** (so existence does not leak). 403 is used only for an insufficient role or scope —
  the wording for the two cases must differ (`loading-error-states.md` §4)
- An admin-only screen still exists as a code-split chunk — assume anyone can download it, and
  keep sensitive information out of the component and only in the API response that component calls

## 8. Issuer replacement checklist

- [ ] Do login · callback · refresh work after changing only `VITE_OIDC_AUTHORITY`
- [ ] Are issuer-specific strings confined to `endSession.ts` · `groups.ts` (`rg -i "cognito|amazonaws" src/`)
- [ ] If the new issuer exposes `end_session_endpoint`, did you change `endSession.ts` to `signoutRedirect()`
- [ ] Are the new issuer's `redirect_uri` (`/auth/callback`) and `post_logout_redirect_uri` on its allowlist
- [ ] If the group claim name changed, did you fix `groups.ts` and the backend `OIDC_GROUPS_CLAIM` together

## Misuse list — confused pairs

| Confused pair | The exact condition for each |
| --- | --- |
| `access_token` vs `id_token` | The API `Authorization` header takes the **access_token**. The id_token exists to tell the frontend "who this user is"; used for API auth its audience does not match |
| decoding a token vs verifying a token | Decoding on the frontend is **for display**. Verifying signature · issuer · audience · expiry is done only by the server. Granting access from a decode result is not verification |
| route guard vs server authorization | A guard is UX (it keeps you out of the wrong screen). The real blocking happens on the server, on every API request |
| `isLoading` vs `isAuthenticated` | Redirecting on `!isAuthenticated` while the session is being restored (`isLoading`) flashes the login screen on every refresh. Branch on loading first |
| silent refresh vs redirect re-authentication | Use `signinSilent` when expiry is near. If the refresh fails, do not postpone — send the user through a full redirect to sign in again |
| `removeUser()` vs `signoutRedirect()` | The former clears **only the local token** — the issuer session is alive, so signing in again passes straight through. A complete logout goes as far as the latter, in the order of §6 |
| reading discovery from `auth.settings` | `settings` is a plain settings object (`UserManagerSettings`). It contains no metadata service, so `auth.settings.metadataService` does not exist. If you need it, `fetch` `.well-known/openid-configuration` directly |
| `userStore` vs `stateStore` | The token goes in `userStore` (memory), the PKCE verifier and state in `stateStore` (sessionStorage). Setting both to the same value makes the memory choice break login itself |
| `clear()` vs `invalidateQueries()` on logout | Invalidation keeps the data and refetches it. Logout takes **`clear()`** — anything left behind is an information leak |
| using a `client secret` vs PKCE | An SPA has nowhere to put a secret. Unless a backend holds it on your behalf, PKCE is the only answer |
| multi-tab synchronization | Logging out in one tab must clean up the others. Send the logout signal with a `storage` event or `BroadcastChannel`, and have the receiving side run the same order as §6 |
