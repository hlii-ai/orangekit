<!-- orangekit-pack: backend/fastify v3.35.0 -->
# Auth flow — self-issued (login · refresh rotation · logout)

This file owns **the side that hands tokens out**: `src/services/auth-service.ts` (passwords · refresh tokens) ·
`src/http/auth-plugin.ts` (`/api/auth` routes · cookies · CORS). The side that **checks** tokens (`requireAuth` ·
environment keys · tables · `authFor`) is owned by `resources/auth-boundaries.md`. The wire shape is the endpoint table in §1 of that file.

## 1. Judgment — the life of one refresh token

| event | what the server does | what the client sees |
| --- | --- | --- |
| login | verifies the password → 1 refresh token in a new family + an access token | 200 + cookie `rt` (the app gets it in the body) |
| 401 after the access token expires | — | one refresh attempt (contract §5) |
| refresh | sets `used_at` on the old token → a new token in the same family | 200 + a rotated `rt` |
| **a spent token comes back** | `revoked_at` on the whole family (committed) → rejected | 401 → login screen. For the thief and the original user alike |
| expired · invalid · missing | rejected | 401 |
| logout | invalidates the whole family + deletes the cookie | 204 |

**Rotation and reuse detection are a pair.** With rotation alone, a stolen token succeeds once too, and when the
original user's refresh then fails, the server cannot tell whether that is evidence of theft. Only with the spent mark does "the same token arrived twice" become visible.

## 2. Passwords and refresh rotation (`src/services/auth-service.ts`)

Password hashing is `scrypt` from `node:crypto` — it brings in no native addon (argon2 · bcrypt bindings), so there
is no binding failure at install time, and it uses the OWASP-recommended parameters (N=2^17 · r=8 · p=1). Comparison is `timingSafeEqual`.

<!-- file: src/services/auth-service.ts -->
```ts
// src/services/auth-service.ts
import { createHash, randomBytes, randomUUID, scrypt, timingSafeEqual } from 'node:crypto'
import { and, eq, isNull } from 'drizzle-orm'
import { refreshTokens, users } from '../db/auth-schema'
import { db } from '../db/client'
import { env } from '../env'
import { AppError } from '../http/app-error'

const COST = { N: 2 ** 17, r: 8, p: 1, maxmem: 256 * 1024 * 1024 }
const derive = (pw: string, salt: Buffer) =>
  new Promise<Buffer>((ok, fail) => scrypt(pw, salt, 64, COST, (e, k) => (e ? fail(e) : ok(k))))
const sha256 = (raw: string) => createHash('sha256').update(raw).digest('hex')

async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16)
  return `scrypt$${salt.toString('base64url')}$${(await derive(pw, salt)).toString('base64url')}`
}
async function verifyPassword(pw: string, stored: string): Promise<boolean> {
  const [, salt, hash] = stored.split('$')
  const want = Buffer.from(hash ?? '', 'base64url')
  const got = await derive(pw, Buffer.from(salt ?? '', 'base64url'))
  return got.length === want.length && timingSafeEqual(got, want)
}
const DUMMY = hashPassword('a value that matches the cost for a missing account')

export async function createUser(email: string, password: string): Promise<string> {
  const [row] = await db.insert(users)
    .values({ email: email.toLowerCase(), passwordHash: await hashPassword(password) }).returning({ id: users.id })
  return row!.id
}

// A missing account pays the same scrypt cost — so response time does not leak whether the account exists
export async function authenticate(email: string, password: string): Promise<string> {
  const [u] = await db.select().from(users).where(eq(users.email, email.toLowerCase())).limit(1)
  const ok = await verifyPassword(password, u?.passwordHash ?? (await DUMMY))
  if (!u || !ok) throw new AppError('UNAUTHENTICATED', 'Incorrect email or password')
  return u.id
}

function newRow(userId: string, familyId: string) {
  const token = randomBytes(32).toString('base64url')   // CSPRNG — never Math.random
  const expiresAt = new Date(Date.now() + env.AUTH_REFRESH_TTL_DAYS * 86_400_000)
  return { token, values: { userId, familyId, tokenHash: sha256(token), expiresAt } }
}

export async function issueRefreshToken(userId: string): Promise<string> {
  const { token, values } = newRow(userId, randomUUID())
  await db.insert(refreshTokens).values(values)
  return token
}

// Rotation + reuse detection. When a spent token comes back, a copy is circulating — cut the family, **commit**, then reject
export async function rotateRefreshToken(raw: string): Promise<{ userId: string; token: string }> {
  const now = new Date()
  const out = await db.transaction(async (tx) => {
    const [row] = await tx.select().from(refreshTokens).where(eq(refreshTokens.tokenHash, sha256(raw))).for('update')
    if (!row || row.revokedAt || row.expiresAt <= now) return null
    if (row.usedAt) {
      await tx.update(refreshTokens).set({ revokedAt: now })
        .where(and(eq(refreshTokens.familyId, row.familyId), isNull(refreshTokens.revokedAt)))
      return null   // throwing here would roll back the invalidation too
    }
    await tx.update(refreshTokens).set({ usedAt: now }).where(eq(refreshTokens.id, row.id))
    const next = newRow(row.userId, row.familyId)
    await tx.insert(refreshTokens).values(next.values)
    return { userId: row.userId, token: next.token }
  })
  if (!out) throw new AppError('UNAUTHENTICATED', 'Please log in again')
  return out
}

// The same lock as rotation — take the presented token's row FOR UPDATE so the family is cut after any overlapping rotation finishes.
// Read and write without the lock and a rotation in between inserts a new token, leaving a live token behind
export async function revokeRefreshToken(raw: string): Promise<void> {
  await db.transaction(async (tx) => {
    const [row] = await tx.select({ familyId: refreshTokens.familyId }).from(refreshTokens)
      .where(eq(refreshTokens.tokenHash, sha256(raw))).for('update')
    if (row) {
      await tx.update(refreshTokens).set({ revokedAt: new Date() })
        .where(and(eq(refreshTokens.familyId, row.familyId), isNull(refreshTokens.revokedAt)))
    }
  })
}
```

Refresh tokens are **looked up by hash** — the comparison happens inside the DB index and the raw value is not in
storage. `for('update')` queues concurrent refreshes of the same token: when two tabs refresh at once with the same
cookie, the second is judged a reuse and the family is cut (no grace window — `knownGaps` in `pack.json`).

## 3. Endpoints · cookies · CORS (`src/http/auth-plugin.ts`)

<!-- file: src/http/auth-plugin.ts -->
```ts
// src/http/auth-plugin.ts
import cookie from '@fastify/cookie'
import cors from '@fastify/cors'
import rateLimit from '@fastify/rate-limit'
import type { FastifyReply, FastifyRequest } from 'fastify'
import fp from 'fastify-plugin'
import type { FastifyPluginAsyncZod } from 'fastify-type-provider-zod'
import { z } from 'zod'
import { env } from '../env'
import { authenticate, issueRefreshToken, revokeRefreshToken, rotateRefreshToken } from '../services/auth-service'
import { AppError } from './app-error'
import { signAccessToken } from './require-auth'

const RT = 'rt'
// Every login runs scrypt (N=2^17, about 128MiB) — without a limit it is a brute-force path and a memory and thread-pool exhaustion path.
// The key is the IP (default req.ip). Behind a proxy, buildApp's trustProxy has to be right for it to count the real client IP
const LOGIN_LIMIT = { max: 10, timeWindow: '1 minute' }
const REFRESH_LIMIT = { max: 30, timeWindow: '1 minute' }
const Login = z.strictObject({ email: z.email(), password: z.string().min(1).max(1024), client: z.enum(['web', 'app']).default('web') })
const AppToken = z.strictObject({ refreshToken: z.string().min(1).max(200) }).optional()
const Tokens = z.object({ data: z.object({ accessToken: z.string(), refreshToken: z.string().optional() }) })

// A request authenticated only by a cookie is a CSRF target — compare the origin exactly against the allowlist
function cookieToken(req: FastifyRequest): string {
  const raw = req.cookies[RT]
  if (!raw || !env.WEB_ORIGINS.includes(req.headers.origin ?? '')) throw new AppError('UNAUTHENTICATED', 'Please log in again')
  return raw
}

async function respond(reply: FastifyReply, userId: string, refreshToken: string, app: boolean) {
  const accessToken = await signAccessToken(userId)
  reply.header('cache-control', 'no-store')   // a response carrying tokens is not left in intermediate or browser caches
  if (app) return { data: { accessToken, refreshToken } }
  reply.setCookie(RT, refreshToken, {
    httpOnly: true, path: '/api/auth', sameSite: env.AUTH_COOKIE_SAMESITE, maxAge: env.AUTH_REFRESH_TTL_DAYS * 86_400,
    secure: env.NODE_ENV === 'production' || env.AUTH_COOKIE_SAMESITE === 'none',
  })
  return { data: { accessToken } }
}

const authRoutes: FastifyPluginAsyncZod = async (app) => {
  await app.register(cookie)   // the cookie parser only in this context (/api/auth)
  // global:false — in this context it counts only routes carrying config.rateLimit (login · refresh). Going over throws an Error
  // with statusCode 429, and the root errorHandler turns it into the RATE_LIMITED envelope
  await app.register(rateLimit, { global: false })
  app.post('/login', { config: { rateLimit: LOGIN_LIMIT }, schema: { body: Login, response: { 200: Tokens } } }, async (req, reply) => {
    const userId = await authenticate(req.body.email, req.body.password)
    return respond(reply, userId, await issueRefreshToken(userId), req.body.client === 'app')
  })
  app.post('/refresh', { config: { rateLimit: REFRESH_LIMIT }, schema: { body: AppToken, response: { 200: Tokens } } }, async (req, reply) => {
    const fromApp = req.body?.refreshToken
    const { userId, token } = await rotateRefreshToken(fromApp ?? cookieToken(req))
    return respond(reply, userId, token, fromApp !== undefined)
  })
  app.post('/logout', { schema: { body: AppToken } }, async (req, reply) => {
    const raw = req.body?.refreshToken ?? (req.cookies[RT] ? cookieToken(req) : undefined)
    if (raw) await revokeRefreshToken(raw)
    return reply.clearCookie(RT, { path: '/api/auth' }).code(204).send()
  })
}

// Wrapped in fp so it attaches to the root — CORS preflight requests have to reach /api/tasks too. No requireAuth hook
export const authPlugin = fp(async (app) => {
  await app.register(cors, {
    origin: env.WEB_ORIGINS, credentials: true,
    methods: ['GET', 'POST', 'PATCH', 'DELETE'], exposedHeaders: ['location', 'x-request-id'],
  })
  await app.register(authRoutes, { prefix: '/api/auth' })
})
```

<!-- unverified: the @fastify/cookie@11 · @fastify/cors@11 · jose@6 combination was not run in this pack. The shapes were written by cross-checking jose@6.2.12's .d.ts (jwtVerify · SignJWT) against the two plugins' docs -->

**The limiter is on by default.** `@fastify/rate-limit` is registered only in the `/api/auth` context and attached via
route config to `login` (10 per minute) · `refresh` (30 per minute) — going over the limit throws an `Error` with
`statusCode` 429, and `toAppError` in the root `errorHandler` turns it into the `RATE_LIMITED` envelope. The default
store is **process memory**, so with two or more instances the limit loosens by the number of instances — a
multi-instance deployment attaches a shared store (Redis) through the plugin's `redis` option. An IP key alone cannot
stop an attack that hammers one account from many IPs (adding an email key is a project decision). <!-- verified: @fastify/rate-limit@11.2.1 + fastify@5 — observed with inject in the scratch that with global:false + a route config.rateLimit, going over delivers an Error with statusCode 429 to setErrorHandler and attaches retry-after (2026-10-17). This pack's auth-plugin code and the test above were not themselves run -->

## 4. The test that proves this flow's promises (`src/test/auth.routes.test.ts`)

<!-- file: src/test/auth.routes.test.ts -->
```ts
// src/test/auth.routes.test.ts
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { buildApp, type App } from '../app'
import { refreshTokens, users } from '../db/auth-schema'
import { pool } from '../db/client'
import { createUser } from '../services/auth-service'
import { testDb } from './db'

let app: App
beforeAll(async () => { app = await buildApp({ logger: false }) })
afterAll(async () => { await app.close(); await pool.end() })
beforeEach(async () => { await testDb.delete(refreshTokens); await testDb.delete(users) })

const login = (password: string, email = 'a@example.com') =>
  app.inject({ method: 'POST', url: '/api/auth/login', payload: { email, password } })
const refresh = (rt: string, origin = 'http://localhost:5173') =>
  app.inject({ method: 'POST', url: '/api/auth/refresh', headers: { origin }, cookies: { rt } })
const rtOf = (res: { cookies: { name: string; value: string }[] }) => res.cookies.find((c) => c.name === 'rt')!.value

describe('self-issued auth', () => {
  it('the right password yields a usable token, and a wrong password and a missing account are the same 401', async () => {
    await createUser('a@example.com', 'correct horse')
    const ok = await login('correct horse')
    expect(ok.statusCode).toBe(200)
    const auth = { authorization: `Bearer ${ok.json().data.accessToken}` }
    expect((await app.inject({ url: '/api/tasks', headers: auth })).statusCode).toBe(200)
    const wrong = await login('nope')
    expect(wrong.statusCode).toBe(401)
    expect(wrong.json().error).toEqual((await login('nope', 'ghost@example.com')).json().error)
  })

  it('rotation is a 200, another origin and reuse are a 401, and after reuse the legitimate copy is cut too', async () => {
    await createUser('a@example.com', 'correct horse')
    const rt0 = rtOf(await login('correct horse'))
    expect((await refresh(rt0, 'https://evil.example')).statusCode).toBe(401)
    const first = await refresh(rt0)
    expect(first.statusCode).toBe(200)
    expect((await refresh(rt0)).statusCode).toBe(401)          // reuse
    expect((await refresh(rtOf(first))).statusCode).toBe(401)  // family invalidated
  })

  it('login attempts over the limit get the 429 RATE_LIMITED envelope, and token responses are not cached', async () => {
    const fresh = await buildApp({ logger: false })   // the limiter store is separate per app instance — it does not mix with the attempts in the tests above
    try {
      await createUser('a@example.com', 'correct horse')
      const ok = await fresh.inject({ method: 'POST', url: '/api/auth/login', payload: { email: 'a@example.com', password: 'correct horse' } })
      expect(ok.headers['cache-control']).toBe('no-store')
      let last = ok
      for (let i = 0; i < 12 && last.statusCode !== 429; i++) {
        last = await fresh.inject({ method: 'POST', url: '/api/auth/login', payload: { email: 'a@example.com', password: 'nope' } })
      }
      expect(last.statusCode).toBe(429)
      expect(last.json().error.code).toBe('RATE_LIMITED')
      expect(last.headers['retry-after']).toBeDefined()
    } finally { await fresh.close() }
  })
})
```

The login test goes as far as checking that `/api/tasks` is a 200 with the issued token — "login is a 200" alone stays
green even if the signing key disagrees with `requireAuth`. The last assertion in the refresh test (the legitimate
copy is a 401 too) is the evidence of family invalidation — drop it and only the reuse rejection remains, blind to the case where the thief rotated first.

## Misuse list ① — session · seam-era habits → this variant's shape

| old habit | current form |
| --- | --- |
| turning on only `sameSite: 'none'` | it pairs with `Secure` — this file forces `secure` when it is `none` |
| CORS `origin: true` + `credentials` | only the allowlist (`WEB_ORIGINS`). Cookie routes also compare `Origin` on the server |
| a fixed refresh token | rotation + family invalidation on reuse |
| logout only deletes the cookie | the server-side family is invalidated too — deleting the cookie is only a hint to the client |
| `bcrypt` native bindings | `node:crypto` `scrypt` — zero dependencies, comparison with `timingSafeEqual` |

## Misuse list ② — confusable pairs

| what is often picked wrong | exact condition for applying it |
| --- | --- |
| `throw` in reuse detection vs `return null` and throwing outside | the latter. Throwing inside the transaction rolls back the family invalidation too |
| cookie refresh vs body refresh | the browser uses the former (origin check mandatory), the app the latter (no cookie, so it is not a CSRF target) |
| the CORS allowlist vs the server's `Origin` comparison | the former stops the browser from **reading** the response, the latter stops the request from **executing**. Cookie routes need both |
| setting the login limit app-wide (`global: true`) | no — per route. App-wide, it counts `/api/tasks` too and legitimate users get blocked |
| an immediate 401 for a missing account vs comparing against a dummy hash | the latter. Returning immediately lets response time reveal that the account exists |
