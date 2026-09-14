<!-- orangekit-seam: vue+node-api v3.13.0 -->
# The auth/middleware boundary — bearer tokens and reissue

This file owns three code files: `src/http/tokens.ts` · `src/http/require-auth.ts` ·
`src/http/routers/auth.ts`. It also provides the test auth header `authFor` (`src/test/auth.ts`).
The envelope · `errorHandler` · CORS are owned by `resources/api-endpoints.md`, ownership queries by
`resources/data-access.md`, and the status mapping table by `resources/error-handling.md`.

> **This axis has no data-layer policy engine.** The application connects to PostgreSQL with a trusted connection,
> so the middleware in this file and the `where` of the queries are **the only boundary.** "The data layer backs us up,
> so it is double defense" is false here, and writing it that way creates the illusion of safety.

## 1. The decision — why a bearer token and not a session cookie

The backend axis does not decide the authentication method. **Whether the frontend axis has a server runtime** decides it. The frontend of this
combination is a Vue SPA — the browser hits this API origin **directly**, and there is no intermediate runtime to
hide the credentials.

| Axis condition | The natural method | Why |
| --- | --- | --- |
| The frontend has a server runtime (SSR · BFF) | a session cookie | the cookie stays inside the same origin |
| **The frontend is an SPA on a different origin (this combination)** | **a bearer token** | using a session cookie would require cross-site cookies plus a full CSRF defense |
| Server-to-server calls | a signed service token | there is no browser |

The advantage of a bearer token is that **CSRF does not exist at the root**. The browser does not attach `Authorization`
by itself, so a request from an attacker's page carries no token. The price sits on the other side — the JS has to
hold the token, so one XSS leaks it. That is why it is split in two: **the access token lives briefly (15 minutes)
and the reissue token sits in an httpOnly cookie the JS cannot see.** Where the frontend keeps the access token
is owned by the frontend seam.

## 2. The access token (`src/http/tokens.ts`)

An HS256 JWT is issued in-house. `node:crypto` does the signing and hashing, and what this file writes is **the encoding and
the order of the checks**. If RS256 · JWKS · an external IdP become necessary, swap this file for a verification library —
the only surface `requireAuth` sees is `verifyAccessToken`, so that replacement stays local.

First add three lines to the `EnvSchema` in `src/env.ts`. Secrets do not live in code.

```ts
// src/env.ts — the lines added to EnvSchema (excerpt)
  AUTH_JWT_SECRET: z.string().min(32, 'must be at least 32 characters'),
  AUTH_ACCESS_TTL_SEC: z.coerce.number().int().min(60).max(3600).default(900),
  WEB_ORIGINS: z.string().min(1).transform((s) => s.split(',').map((o) => o.trim())).pipe(z.array(z.url()).min(1)),
```

<!-- file: src/http/tokens.ts -->
```ts
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { AppError } from './app-error';
import { env } from '../env';

export type AccessClaims = { sub: string; roles: string[]; iat: number; exp: number };

// the header is frozen as a constant. The alg the token carried is never read for branching, so alg=none and
// algorithm confusion have no reach path at all.
const HEADER = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
const deny = () => new AppError('UNAUTHENTICATED', 'Authentication failed');

function mac(data: string): Buffer {
  return createHmac('sha256', env.AUTH_JWT_SECRET).update(data).digest();
}

export function signAccessToken(sub: string, roles: string[] = []): string {
  const iat = Math.floor(Date.now() / 1000);
  const claims: AccessClaims = { sub, roles, iat, exp: iat + env.AUTH_ACCESS_TTL_SEC };
  const data = `${HEADER}.${Buffer.from(JSON.stringify(claims)).toString('base64url')}`;
  return `${data}.${mac(data).toString('base64url')}`;
}

export function verifyAccessToken(token: string): AccessClaims {
  const [h, p, s, ...rest] = token.split('.');
  if (!h || !p || !s || rest.length > 0) throw deny();
  if (h !== HEADER) throw deny();
  const got = Buffer.from(s, 'base64url');
  const want = mac(`${h}.${p}`);
  // why the length is checked first: timingSafeEqual throws a RangeError when the lengths differ.
  // HMAC-SHA256 is always 32 bytes, so a length mismatch is forgery in itself, and nothing
  // leaks here. The value comparison is done in constant time.
  if (got.length !== want.length || !timingSafeEqual(got, want)) throw deny();
  let c: AccessClaims;
  try { c = JSON.parse(Buffer.from(p, 'base64url').toString('utf8')) as AccessClaims; }
  catch { throw deny(); }
  if (typeof c.sub !== 'string' || c.sub === '') throw deny();
  if (typeof c.exp !== 'number' || c.exp * 1000 <= Date.now()) throw deny();
  return { sub: c.sub, roles: Array.isArray(c.roles) ? c.roles : [], iat: c.iat, exp: c.exp };
}

export function newRefreshToken(): { token: string; hash: string } {
  const token = randomBytes(32).toString('base64url');   // CSPRNG. Math.random is not used
  return { token, hash: hashRefreshToken(token) };
}

export function hashRefreshToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}
```

<!-- verified: node v24.7.0 + express@5.2.1 + supertest@7.2.2 run — signature round trip, tampered payload, header swapped to alg=none, an expired token, a wrong scheme (`Basic`) and a `Bearer` with no token: all six inputs were sent as real requests and all returned 401 UNAUTHENTICATED -->
A verification failure **does not distinguish the reason.** All six failures go out with the same 401 and the same wording,
and no `details` — telling them which check caught it would let an attacker narrow the shape.

`timingSafeEqual` throws `RangeError: Input buffers must have the same byte length` when the lengths differ.
<!-- verified: node v24.7.0 run — called with a 31-byte and a 32-byte buffer and the exception wording observed --> That is why the length check comes first. The reissue token **is never stored in plaintext** —
only the `sha256` hash goes in, so a DB leak does not amount to session theft.

## 3. `requireAuth` and `AuthUser` (`src/http/require-auth.ts`)

<!-- file: src/http/require-auth.ts -->
```ts
import type { RequestHandler } from 'express';
import { AppError } from './app-error';
import { verifyAccessToken } from './tokens';

export type AuthUser = { id: string; roles: string[] };

declare global {
  namespace Express {
    interface Request { user?: AuthUser }
  }
}

export const requireAuth: RequestHandler = (req, _res, next) => {
  const raw = req.get('authorization') ?? '';
  const [scheme, token] = raw.split(' ');
  if (scheme?.toLowerCase() !== 'bearer' || !token) {
    throw new AppError('UNAUTHENTICATED', 'Authentication failed');
  }
  const claims = verifyAccessToken(token);
  req.user = { id: claims.sub, roles: claims.roles };
  next();
};

export function requireRole(role: string): RequestHandler {
  return (req, _res, next) => {
    if (!req.user?.roles.includes(role)) throw new AppError('FORBIDDEN', 'You do not have permission');
    next();
  };
}
```

Declare `user` as an **optional property**. Declared as required, the type says "it is there" even in a router that
`requireAuth` was never attached to, and that lie is exactly where an authorization incident happens. The consumer uses a throwing
accessor (`actor()`, `resources/api-endpoints.md` §5) instead of a `!` assertion — measured, the two forms split into
401 and 500.

The subject comes **only from a verified token**. An `ownerId` in the request body · query · header is a value the attacker chooses.
`TaskCreateSchema` being a `z.strictObject` is the second layer of that — put `ownerId` in the body and it is
rejected with a 400 before the spread order even comes up.
<!-- verified: express@5.2.1 + zod@4.4.3 run — POSTing `{ title:'intrusion', ownerId:'owner-2' }` gave 400 VALIDATION_FAILED and the ownerId of the other row was unchanged -->

## 4. A role is 403, ownership is 404

Mix the two and the safety device becomes an information disclosure device. There is one criterion — **does the person who received
that response learn something new from that fact alone.**

| Situation | Response | Why |
| --- | --- | --- |
| the token is missing or fails verification | 401 `UNAUTHENTICATED` | we do not know who they are |
| reading · updating · deleting someone else's `Task` | 404 `NOT_FOUND` | a 403 would answer that the id really exists |
| an admin path with an insufficient role | 403 `FORBIDDEN` | the existence of the path is already public information |

```ts
// src/http/routers/admin.ts — a router that requires a role
// ❌ returning an ownership failure as 403 — sweeping ids reveals which ids really exist
if (task.ownerId !== actor(req).id) throw new AppError('FORBIDDEN', 'You do not have permission');
// ✅ only the role check is 403. Ownership is a query condition, and no result means 404
adminRouter.use(requireAuth, requireRole('admin'));
```

## 5. Login · reissue · logout (`src/http/routers/auth.ts`)

The contract fixes it this way — when the frontend receives a 401 it **attempts one reissue and, if that fails again, sends the user
to login.**

```ts
// src/http/routers/auth.ts — the cookie settings and the three endpoints
// cross-site in production only. SameSite=None requires Secure, and a Secure cookie does not come back
// over plain http — in development the frontend dev server proxies /api to make it the same origin
// and lax is used.
const CROSS_SITE = env.NODE_ENV === 'production';

function setRefreshCookie(res: Response, token: string): void {
  res.cookie(RT, token, {
    httpOnly: true, secure: CROSS_SITE, sameSite: CROSS_SITE ? 'none' : 'lax',
    path: '/api/auth', maxAge: 14 * 864e5,
  });
}

authRouter.post('/login', async (req, res) => {
  const { email, password } = parseBody(LoginSchema, req);
  const user = authenticate(email, password);   // failure is AppError('UNAUTHENTICATED')
  setRefreshCookie(res, await issueRefreshToken(user.id));
  res.json({ data: { accessToken: signAccessToken(user.id, user.roles), expiresIn: env.AUTH_ACCESS_TTL_SEC } });
});

authRouter.post('/refresh', async (req, res) => {
  requireAllowedOrigin(req);                    // the CSRF defense of a cookie-authenticated route
  const raw = readCookie(req, RT);
  if (!raw) throw new AppError('UNAUTHENTICATED', 'Authentication failed');
  const { ownerId, token } = await rotateRefreshToken(raw);   // rotation + reuse detection
  setRefreshCookie(res, token);
  res.json({ data: { accessToken: signAccessToken(ownerId), expiresIn: env.AUTH_ACCESS_TTL_SEC } });
});

authRouter.post('/logout', requireAuth, async (req, res) => {
  const raw = readCookie(req, RT);
  if (raw) await revokeRefreshToken(raw);       // invalidates the whole family
  res.clearCookie(RT, { path: '/api/auth' });
  res.sendStatus(204);
});
```

**Rotation and reuse detection are a pair.** Every reissue hands out a new token and marks the old one spent. A spent
token arriving again means a copy is in circulation, so **the whole family is invalidated** — the thief and the original
user both go to the login screen. That is the intent.

```ts
// src/services/auth-service.ts — only the hash of a reissue token is stored
export async function issueRefreshToken(ownerId: string, familyId?: string): Promise<string> {
  const { token, hash } = newRefreshToken();
  await prisma.refreshToken.create({
    data: { tokenHash: hash, ownerId, familyId: familyId ?? hash,
            expiresAt: new Date(Date.now() + 14 * 864e5) },
  });
  return token;   // the plaintext leaves only through the cookie. Nothing of it remains in storage
}
```

`rotateRefreshToken` · `revokeRefreshToken` are functions in this same file working on the same table — lookups are always done
with `hashRefreshToken(raw)`.

`requireAllowedOrigin` does something different from CORS. What a CORS response header blocks is only the browser
**reading the response**; it cannot block the request from executing, so this one route, authenticated by cookie alone,
checks `Origin` on the server itself. The remaining routes, which use the access token, do not need this check.

<!-- verified: express@5.2.1 + supertest@7.2.2 run — login→reissue→200 with the new token, 403 for a disallowed Origin, 401 on reuse of a rotated token, then 401 on a following reissue because the family was invalidated, 401 for a reissue with no cookie, and 401 for a reissue after logout -->
A login failure **does not distinguish the reason**: a missing account and a wrong password go out with the same 401 and the same
wording. Distinguish them and account existence can be enumerated from the response alone. The measurement asserted that the
status and wording of the two inputs were identical.

The actual `Set-Cookie` in production mode was `rt=…; Max-Age=1209600; Path=/api/auth; HttpOnly; Secure;
SameSite=None`, and that cookie **did not come back** on a plain http request (the reissue gave 401).
<!-- verified: express@5.2.1 + a superagent cookie jar run — logged in with NODE_ENV=production and observed Set-Cookie, and the following reissue from the same agent received 401 with no cookie. The browser's localhost exception could not be confirmed in this repository -->

## 6. The test auth header (`src/test/auth.ts`)

The pack's tests pass `authFor(ownerId)` straight into `.set()`. Whether it is a header or a cookie is a function of the combination, so
this helper lives in the seam. **Do not mock `requireAuth`** — mocking it removes from the tests the very authorization
wiring that has to be verified.

<!-- file: src/test/auth.ts -->
```ts
import { signAccessToken } from '../http/tokens';

export function authFor(ownerId: string, roles: string[] = []): Record<string, string> {
  return { Authorization: `Bearer ${signAccessToken(ownerId, roles)}` };
}
```

Being a synchronous function is the contract — it has to fit on the one line `request(app).get(url).set(authFor('owner-1'))`,
and if the signing were async every test would grow an `await`. `createHmac` is synchronous, so this holds as it is.

## Misuse list ① — session cookie idioms → the form of this combination

These are habits carried over from same-origin SSR. They all pass the syntax check and show up only in the browser.

| Old habit (same-origin session) | The current form (cross-origin SPA) |
| --- | --- |
| Putting the access token in a cookie too | The access token goes in the `Authorization` header. Only the reissue token goes in a cookie |
| Setting `sameSite: 'strict'` and calling it done | Cross-site, the cookie is not sent at all — `'none'` + `Secure` |
| Turning on `sameSite: 'none'` only | The browser discards a `None` without `Secure`. The two are a pair |
| Leaving CORS open with `origin: true` | With `credentials`, `*` is impossible. Pick from the allowlist and echo it back |
| Storing the reissue token in plaintext | Store only the `sha256` hash. A DB leak must not amount to session theft |
| Only clearing the cookie on logout | Invalidate the token family on the server too. Deleting the cookie is only a client hint |
| `===` for token comparison | `timingSafeEqual`. A signature comparison is done in constant time |

## Misuse list ② — confused pairs

| Frequently chosen wrongly | The exact condition for each |
| --- | --- |
| 401 `UNAUTHENTICATED` vs 403 `FORBIDDEN` | 401 is "we do not know who you are", 403 is "we know who you are but the role is insufficient" |
| 403 `FORBIDDEN` vs 404 `NOT_FOUND` | An ownership failure is always 404. 403 only on a path whose existence is already public |
| `router.use(requireAuth)` vs an argument per route | Attach it per router. Per route, a new route is quietly published |
| `req.user!.id` vs a throwing accessor | The assertion leaks as a 500 when the mount is forgotten. The accessor closes with a 401 |
| Access token lifetime vs reissue token lifetime | The former is minutes (15), the latter days (14) + rotation. Set them equal and the reason for splitting them disappears |
| Reissue rotation vs a fixed token | Rotation + reuse detection. A fixed token, once leaked, is valid until it expires |
| The CORS allowlist vs an `Origin` check on the server | The former blocks the browser from reading the response, the latter blocks the request from executing. A cookie-authenticated route needs **both** |
| Exposing the reason `verifyAccessToken` failed vs generalizing | Always generalize. Telling them which check caught it narrows the forgery shape |
