<!-- orangekit-pack: backend/fastify v3.35.0 -->
# Auth boundary — self-issued (login · refresh rotation · bearer verification)

In this variant the server issues tokens itself at `/api/auth`. This file owns **the boundary** (environment keys ·
tables · bearer verification · the test header): `src/auth-env.ts` · `src/db/auth-schema.ts` ·
`src/http/require-auth.ts` · `src/test/auth.ts`. The **flow that hands tokens out** (login · rotation · logout ·
cookies · CORS) is owned by `resources/auth-flows.md`, the envelope by `resources/api-endpoints.md`, and the ownership
queries by `resources/data-access.md`. **This axis has no data-layer policy engine** — `requireAuth` and the queries'
`where` are the only boundary.

## 1. Judgment — two tokens, two storage locations

| token | lifetime | browser | app (`client: 'app'`) | server storage |
| --- | --- | --- | --- | --- |
| access (HS256 JWT) | `AUTH_ACCESS_TTL_SEC` (default 900 seconds) | memory → `Authorization: Bearer` | the same | none |
| refresh (32 random bytes) | `AUTH_REFRESH_TTL_DAYS` (default 14 days) | httpOnly cookie `rt` (`Path=/api/auth`) | response body → secure storage | **sha256 hash** + family ID |

| endpoint | body | success | failure |
| --- | --- | --- | --- |
| `POST /api/auth/login` | `{ email, password, client? }` | 200 `{ data: { accessToken, refreshToken? } }` | 401 (no reason given) |
| `POST /api/auth/refresh` | browser: none · app: `{ refreshToken }` | 200 in the same shape + a rotated refresh token | 401 |
| `POST /api/auth/logout` | browser: none · app: `{ refreshToken }` | 204 — invalidates the whole family (idempotent) | — |

**The browser's refresh and logout send neither a body nor a `Content-Type`** — a JSON header with an empty body
makes Fastify return a 400. No sign-up route is included (only `createUser` exists) — sign-up policy is the project's
domain.

## 2. Environment keys and tables (`src/auth-env.ts` · `src/db/auth-schema.ts`)

<!-- file: src/auth-env.ts -->
```ts
// src/auth-env.ts — does not read process.env. src/env.ts merges it into EnvSchema and validates in one go
import { z } from 'zod'

export const AuthEnvSchema = z.object({
  AUTH_JWT_SECRET: z.string().min(32, 'Must be at least 32 characters'),
  AUTH_ACCESS_TTL_SEC: z.coerce.number().int().min(60).max(3600).default(900),
  AUTH_REFRESH_TTL_DAYS: z.coerce.number().int().min(1).max(90).default(14),
  // 'none' when the frontend and the API are on different registrable domains — Secure is then enforced
  AUTH_COOKIE_SAMESITE: z.enum(['strict', 'lax', 'none']).default('lax'),
  WEB_ORIGINS: z.string().transform((s) => s.split(',').map((o) => o.trim().replace(/\/+$/, '')).filter(Boolean)).pipe(z.array(z.url()).min(1)),
})

// Test-only defaults — src/test/env.ts puts them only into empty keys
export const authTestEnv: Record<string, string> = {
  AUTH_JWT_SECRET: 'test-only-secret-not-for-production-0123456789',
  WEB_ORIGINS: 'http://localhost:5173',
}
```

<!-- file: src/db/auth-schema.ts -->
```ts
// src/db/auth-schema.ts — read by the './src/db/*schema.ts' glob in drizzle.config.ts
import { index, pgTable, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core'

const at = (name: string) => timestamp(name, { withTimezone: true, precision: 3 })

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  email: text('email').notNull(),          // normalized to lowercase on insert
  passwordHash: text('password_hash').notNull(),
  createdAt: at('created_at').notNull().defaultNow(),
}, (t) => [uniqueIndex('users_email_uq').on(t.email)])

export const refreshTokens = pgTable('refresh_tokens', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  familyId: uuid('family_id').notNull(),   // one login = one family. When reuse shows up, the whole family is cut
  tokenHash: text('token_hash').notNull(), // the raw value is not stored — so a DB leak does not become session theft
  expiresAt: at('expires_at').notNull(),
  usedAt: at('used_at'),
  revokedAt: at('revoked_at'),
}, (t) => [uniqueIndex('refresh_tokens_hash_uq').on(t.tokenHash), index('refresh_tokens_family_idx').on(t.familyId)])
```

The migrations for the two tables belong to **the project's migration flow** — `npx drizzle-kit generate` produces
the SQL and `drizzle-kit migrate` in the deploy step applies it (`resources/data-access.md` §7). `tasks.owner_id` is
`text`, so no FK is set — the owner value is the string form of `users.id`.

## 3. Bearer verification (`src/http/require-auth.ts`)

<!-- file: src/http/require-auth.ts -->
```ts
// src/http/require-auth.ts
import type { FastifyRequest } from 'fastify'
import { jwtVerify, SignJWT } from 'jose'
import { env } from '../env'
import { AppError } from './app-error'

export type AuthUser = { id: string }
declare module 'fastify' {
  interface FastifyRequest { user?: AuthUser }
}

const key = new TextEncoder().encode(env.AUTH_JWT_SECRET)

export function signAccessToken(userId: string): Promise<string> {
  return new SignJWT({}).setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setSubject(userId).setIssuedAt().setExpirationTime(`${env.AUTH_ACCESS_TTL_SEC}s`).sign(key)
}

// onRequest hook — set on the first line of the route plugin body. Failure throws (it does not write the reply)
export async function requireAuth(req: FastifyRequest): Promise<void> {
  const [scheme, token, extra] = (req.headers.authorization ?? '').split(' ')
  if (scheme?.toLowerCase() !== 'bearer' || !token || extra !== undefined) {
    throw new AppError('UNAUTHENTICATED', 'Authentication required')
  }
  try {
    // The server pins the allowed algorithms — following the token header's alg opens alg confusion and none
    const { payload } = await jwtVerify(token, key, { algorithms: ['HS256'] })
    if (typeof payload.sub !== 'string' || payload.sub === '') throw new Error('no sub')
    req.user = { id: payload.sub }
  } catch (e) {
    req.log.info({ reason: (e as { code?: string }).code ?? 'invalid' }, 'access token rejected')
    throw new AppError('UNAUTHENTICATED', 'Authentication required')
  }
}
```

The failure reason (expiry · signature · format) stays only in the log's `reason`, and there is one response. `user`
is an **optional property** — routes take it out with `ownerOf(req.user)` (`resources/api-endpoints.md` §5). The
subject comes only from a verified token.

## 4. The test header (`src/test/auth.ts`)

`authFor` is synchronous — it has to fit in one line, `headers: authFor('alice')`. jose's `sign()` is asynchronous, so
the same HS256 JWS is built with `node:crypto`. Whether the verifier (jose) accepts a standard token is tested along
the way.

<!-- file: src/test/auth.ts -->
```ts
// src/test/auth.ts — test-only. Does not mock requireAuth (the wiring would drop out of the test)
import { createHmac } from 'node:crypto'
import { env } from '../env'

const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url')

export function authFor(ownerId: string): Record<string, string> {
  const now = Math.floor(Date.now() / 1000)
  const data = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: ownerId, iat: now, exp: now + 300 })}`
  return { authorization: `Bearer ${data}.${createHmac('sha256', env.AUTH_JWT_SECRET).update(data).digest('base64url')}` }
}
```

Why `requireAuth` is not mocked: mock it and the very wiring that needs testing (is the hook in the same context as
the routes) drops out of the test. The signing secret is the test value from `authTestEnv`, and `src/test/env.ts`
puts it in before the app modules (`resources/testing.md` §2).

## Misuse list ① — session · seam-era habits → this variant's shape

| old habit | current form |
| --- | --- |
| the access token in a cookie | the `Authorization` header. Only the refresh token is a cookie, narrowed with `Path=/api/auth` |
| reading the secret from code or straight from `process.env` | `AuthEnvSchema` is merged into `EnvSchema` and validated at boot (under 32 characters, boot fails) |
| taking only `sub` out with `jwt.decode()` | decoding is not verification — `jwtVerify` checks the signature and `exp` |
| storing the raw refresh token | only the sha256 hash — `refresh_tokens.token_hash` |
| declaring `req.user` as a required property | an optional property + `ownerOf(req.user)` — a route missing the hook closes as a 401 |

## Misuse list ② — confusable pairs

| what is often picked wrong | exact condition for applying it |
| --- | --- |
| 401 `UNAUTHENTICATED` vs 403 `FORBIDDEN` | the former when who it is is unknown, the latter when the role is insufficient. An ownership failure is neither — it is a 404 |
| `jwtVerify(token, key)` vs pinning `{ algorithms: ['HS256'] }` | the latter. The server decides the allowed algorithms |
| access token lifetime vs refresh token lifetime | the former in minutes (900 seconds), the latter in days (14 days) + rotation. Make them equal and the reason for splitting them disappears |
| `authFor` with jose `sign()` | it is asynchronous, so the one line `headers: authFor(…)` breaks — build the same JWS with `createHmac` |
