<!-- orangekit-seam: react-vite+aws-container/backend v3.12.0 -->
# Authentication and permissions (OIDC/JWKS + application-layer ownership)

Cognito is only the **token issuer**. The backend does standard OIDC verification only, so swapping the issuer for Keycloak
or another changes just three values: `OIDC_ISSUER` / `OIDC_JWKS_URL` / `OIDC_AUDIENCE`.

## Token flow

```
SPA ──(Authorization Code + PKCE)──► Cognito Hosted UI ──► access token / id token
SPA ──(Authorization: Bearer <access token>)──► ALB ──► Hono: signature verified against JWKS
```

- The backend receives **the access token only**. It neither issues tokens nor stores sessions (stateless)
- The token arrives in the `Authorization` header only. **A token in the query string is rejected** — URLs remain in
  ALB access logs · browser history · referrers
- The SPA keeps the token in memory and renews it with a refresh. `localStorage` gives everything away in one XSS

## `requireAuth` (`src/http/auth.ts`)

Use **one factory that takes the key source as an injection**. Production gets remote JWKS, tests get local JWKS, so
the verification path runs the same way in tests (`resources/testing.md`).

```ts
import { createMiddleware } from 'hono/factory'
import { createRemoteJWKSet, jwtVerify, type JWTPayload, type JWTVerifyGetKey } from 'jose'
import { env } from '@/config/env'
import { AppError } from '@/http/errors'
import type { AppEnv } from '@/http/types'

export type AuthUser = { sub: string; email?: string; groups: string[] }
export type TokenVerifier = (token: string) => Promise<AuthUser>

// the reason for failure is not distinguished — expiry · signature mismatch · issuer mismatch all get the same response
const unauthorized = () => new AppError(401, 'UNAUTHORIZED', 'Authentication required')

export const makeJwksVerifier = (keys: JWTVerifyGetKey): TokenVerifier => async (token) => {
  const { payload } = await jwtVerify(token, keys, {
    issuer: env.OIDC_ISSUER,
    algorithms: ['RS256'],            // fixed allowed algorithms (blocks alg confusion attacks)
    clockTolerance: 5,
  })
  if (!isIntendedAudience(payload) || !payload.sub) throw unauthorized()
  return {
    sub: payload.sub,
    email: typeof payload.email === 'string' ? payload.email : undefined,
    groups: readGroups(payload),
  }
}

export const makeRequireAuth = (verify: TokenVerifier) =>
  createMiddleware<AppEnv>(async (c, next) => {
    const header = c.req.header('Authorization')
    const token = header?.startsWith('Bearer ') ? header.slice(7).trim() : undefined
    if (!token) throw unauthorized()
    let user: AuthUser
    try {
      user = await verify(token)
    } catch {
      throw unauthorized()            // every reason is folded into one right here
    }
    c.set('user', user)
    await next()
  })

// production default: the remote JWKS is created once at module scope (public key cache + auto refresh)
export const verifyWithJwks = makeJwksVerifier(createRemoteJWKSet(new URL(env.OIDC_JWKS_URL)))
export const requireAuth = makeRequireAuth(verifyWithJwks)
```

### Checking the audience — the claim differs per issuer

**A Cognito access token has no `aud`.** The client identifier sits in `client_id`, and
`aud` exists only on the ID token. Another IdP (Keycloak and the like) puts `aud` on the access token too.
So accept both names, but **always require a match**.

```ts
function isIntendedAudience(p: JWTPayload): boolean {
  const claim = p.aud ?? (p as Record<string, unknown>).client_id
  const ok = Array.isArray(claim) ? claim.includes(env.OIDC_AUDIENCE) : claim === env.OIDC_AUDIENCE
  if (!ok) return false
  // Cognito distinguishes the token kind with token_use. Some issuers do not have it, so check it only when present.
  const use = (p as Record<string, unknown>).token_use
  return typeof use === 'string' ? use === 'access' : true
}
```

Skipping the `aud`/`client_id` check lets **a token issued to another app in the same user pool** pass
straight through this API.

### Normalize the role claim in one adapter

```ts
function readGroups(p: JWTPayload): string[] {
  const raw = (p as Record<string, unknown>)[env.OIDC_GROUPS_CLAIM]   // default 'cognito:groups'
  return Array.isArray(raw) ? raw.filter((v): v is string => typeof v === 'string') : []
}

export const requireGroup = (group: string) =>
  createMiddleware<AppEnv>(async (c, next) => {
    if (!c.get('user').groups.includes(group)) {
      throw new AppError(403, 'FORBIDDEN', 'You do not have the permission this action requires')
    }
    await next()
  })
```

Put the issuer-specific claim name in `env`. Keycloak nests it as `realm_access.roles`, so a migration
fixes **this one function** only.

## A 401 is JSON; there is no redirect

The only client is an SPA, so this backend has no page paths. An unauthenticated response is always
the authentication error envelope. Whether to send the user to a login screen is decided **by the SPA** from the 401.

The standard challenge header (`WWW-Authenticate: Bearer`) is attached on a 401 only. That branch lives **inside
`onError` alone** (`src/http/errors.ts` in `resources/api-endpoints.md`) — attaching the header separately in a
middleware or handler splits the 401 response path in two.

## Rule on permission in the service layer, filter in the query

This stack has no row-level policy engine. **The application layer is the only boundary.**

```ts
// src/services/tasks.ts
export async function updateTask(ownerId: string, id: string, patch: UpdateTaskInput) {
  const updated = await updateOwnedTask(ownerId, id, patch)   // ownership is in the WHERE
  if (!updated) throw new AppError(404, 'NOT_FOUND', 'Task not found')
  return updated
}
```

```ts
// ❌ this leaks existence — sweeping ids builds a list of other people's resources
const task = await findTask(id)
if (!task) throw new AppError(404, 'NOT_FOUND', '...')
if (task.ownerId !== ownerId) throw new AppError(403, 'FORBIDDEN', '...')
```

- **Absent and unauthorized are the same 404.** 403 is only for a non-ownership axis (an admin-only endpoint and the like)
- The owner is always the `sub` of a verified token. An `ownerId` in the body · query · header is never read

If an admin read is needed, split it into **a separate function in a separate file** instead of dropping the `ownerId` condition.
Do not add an `isAdmin` flag to the same function — one flag arriving wrongly opens the whole table.

```ts
// src/db/queries/admin-tasks.ts — the only file with no owner condition (isolated per file)
export async function findAnyTask(id: string) {
  const [row] = await db.select().from(tasks).where(eq(tasks.id, id)).limit(1)
  return row ?? null
}

// src/routes/admin.ts — this entire sub-app sits behind requireGroup('admin')
export const adminRoutes = new Hono<AppEnv>()
adminRoutes.use('*', requireGroup('admin'))
adminRoutes.get('/tasks/:id', async (c) => {
  const task = await findAnyTask(pathParam(c, TaskIdParam).id)
  if (!task) throw new AppError(404, 'NOT_FOUND', 'Task not found')   // absent and unauthorized both 404
  return c.json({ data: task })
})
```

`grep -rn "admin-tasks" src/` is the audit list — `queries/tasks.ts` must contain **not one** function without an owner argument.

## Login · sign-up · logout · return path

The Cognito Hosted UI owns the auth screens, and the backend only **builds the URL**.
This is exactly where an open redirect appears.

```ts
// src/routes/auth.ts — a public route. Mount it in app.ts **before** requireAuth:
//   app.route('/api/auth', authRoutes)   →   app.use('/api/*', requireAuth)
import { createHmac, timingSafeEqual } from 'node:crypto'
import { Hono } from 'hono'
import { env } from '@/config/env'
import { AppError } from '@/http/errors'
import { safeReturnPath } from '@/http/return-path'
import type { AppEnv } from '@/http/types'

export const authRoutes = new Hono<AppEnv>()

authRoutes.get('/login-url', (c) => {
  const returnTo = safeReturnPath(c.req.query('returnTo'))     // ← must be validated on the server
  const url = new URL('/oauth2/authorize', env.OIDC_AUTHORIZE_BASE)
  url.searchParams.set('response_type', 'code')
  url.searchParams.set('client_id', env.OIDC_AUDIENCE)
  url.searchParams.set('redirect_uri', env.SPA_CALLBACK_URL)   // a fixed value — never taken from input
  url.searchParams.set('scope', 'openid email')
  url.searchParams.set('state', signState({ returnTo }))       // signed to prevent forgery
  return c.json({ data: { url: url.toString(), returnTo } })
})

// the callback hands state back — the return path only appears if the signature matches
authRoutes.get('/return-path', (c) => {
  const claims = verifyState(c.req.query('state'))
  if (!claims) throw new AppError(400, 'BAD_REQUEST', 'The state is not valid')
  return c.json({ data: { returnTo: claims.returnTo } })
})
```

**`signState` must always have a matching verification.** Signing without checking it in the callback makes the signature
decoration. The SPA exchanges the token itself with PKCE, so this pair is the backend's entire share.

```ts
// src/routes/auth.ts (continued)
const mac = (payload: string) =>
  createHmac('sha256', env.AUTH_STATE_SECRET).update(payload).digest('base64url')

export function signState(claims: { returnTo: string }): string {
  const payload = Buffer.from(JSON.stringify({ ...claims, iat: Date.now() })).toString('base64url')
  return `${payload}.${mac(payload)}`
}

export function verifyState(raw: string | undefined, maxAgeMs = 10 * 60_000) {
  const [payload, sig] = (raw ?? '').split('.')
  if (!payload || !sig) return null
  const expected = Buffer.from(mac(payload))
  const got = Buffer.from(sig)
  // match the lengths first — timingSafeEqual throws when they differ
  if (got.length !== expected.length || !timingSafeEqual(got, expected)) return null
  try {
    const c = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'))
    if (typeof c.iat !== 'number' || Date.now() - c.iat > maxAgeMs) return null   // narrow the replay window
    return { returnTo: safeReturnPath(c.returnTo) }        // re-validate the path even after decoding
  } catch {
    return null
  }
}
```

- The comparison is `timingSafeEqual`, not `===` — a string comparison leaks the matching length through time
- **Re-validate the value inside the signature after taking it out.** A signature proves only "we made it", not that the value
  is still a safe path today (the validation rule may be tightened later)

`signUp` uses the same authorize URL with only the path changed to `/signup`, so the rules above apply unchanged.
**Logout is different.** Cognito `/logout` takes only `client_id` and `logout_uri` —
it does not use `response_type` · `redirect_uri` · `state`, and `logout_uri` must **match exactly a sign-out URL
pre-registered on the app client**.

```ts
authRoutes.get('/logout-url', (c) => {
  const url = new URL('/logout', env.OIDC_AUTHORIZE_BASE)
  url.searchParams.set('client_id', env.OIDC_AUDIENCE)
  url.searchParams.set('logout_uri', env.SPA_LOGOUT_URL)   // a registered fixed value — not input
  return c.json({ data: { url: url.toString() } })
})
```

Do not carry the return path in `logout_uri`. An input value is not in the registration list and is rejected, and registering
all of those URLs amounts to building an open-redirect list at the IdP — the SPA remembers the return path locally.

```ts
// src/http/return-path.ts
const CONTROL_CHARS = /[\u0000-\u001F\u007F]/

export function safeReturnPath(raw: string | undefined, fallback = '/'): string {
  if (!raw) return fallback
  if (CONTROL_CHARS.test(raw)) return fallback        // the browser strips newlines and tabs and re-parses
  if (!raw.startsWith('/')) return fallback           // reject absolute URLs and scheme-relative ones
  try {
    const u = new URL(raw, 'https://internal.invalid')
    if (u.origin !== 'https://internal.invalid') return fallback   // catches //host and /\host
    // the origin check alone is not enough: `/..//evil.example` becomes a protocol-relative
    // path again after normalization. Validate the **output**, not the input.
    const p = u.pathname
    if (!p.startsWith('/') || p.startsWith('//') || p.startsWith('/\\')) return fallback
    return p + u.search + u.hash
  } catch {
    return fallback
  }
}
```

**A string prefix check alone is not enough.** `//evil.com` and `/\evil.com` start with `/` but the browser parses them
as external URLs (`\` equals `/` in a special scheme). They are caught only by checking **whether the origin survives parsing**,
and inserted control characters such as `%09` · `%0A` are filtered first for the same reason.

Generalize the authentication failure response: telling a missing account apart from a wrong password enumerates account existence.
That screen belongs to the Hosted UI, and the backend keeps the same principle by **not distinguishing the reason a token failed verification**.

## Misuse list (confused pairs)

| Frequently chosen wrongly | The exact condition for each |
| --- | --- |
| ID token vs access token | An API call takes the **access token**. The ID token is what the SPA uses to display the user, and is not used for API authorization |
| `aws-jwt-verify` vs `jose` | Standard OIDC verification is `jose` — the issuer stays replaceable. The former is Cognito-only and breaks the portability boundary |
| `decodeJwt()` vs `jwtVerify()` | `decodeJwt` **does not check the signature**. Never use it for an authorization decision (debugging only) |
| `createRemoteJWKSet` vs hard-coded keys | The issuer rotates keys. Use remote JWKS + cache, and `createLocalJWKSet` only for offline tests |
| Creating the middleware per request | `createRemoteJWKSet` goes at module scope, once — build it inside a handler and every request fetches the keys again |
| `app.use('*', requireAuth)` | Even `/healthz` becomes a 401 and the ALB cycles the task → attach it to `/api/*` only, after the public routes are registered |
| Treating the logout URL by the same rules as authorize | Cognito `/logout` takes only `client_id` + `logout_uri`. `redirect_uri` · `state` · `response_type` are ignored, and `logout_uri` must match the pre-registered value exactly |
| 401 vs 403 | 401 is "we do not know who you are", 403 is "we know you but the role is insufficient". **An ownership failure is neither; it is 404** |
| Treating `c.get('user')` as optional | Behind `requireAuth` it always exists. Wrapping it in `?.` hides the fact that it was attached to an unauthenticated path |
| Comparing `exp` by hand | `jwtVerify` already verifies it. A separate comparison diverges from clockTolerance and creates two standards |
| Trusting `userId` from the request body | The owner is `c.get('user').sub` and nothing else. A value from the body is account impersonation |
