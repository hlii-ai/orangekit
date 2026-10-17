<!-- orangekit-pack: backend/fastify v3.35.0 -->
# Auth boundary — external IdP (OIDC access token verification only)

In this variant an external IdP (Cognito · Auth0 · Keycloak · Identity Platform and the like) issues the tokens. Login ·
refresh · logout are done by the frontend or app directly with the IdP (Authorization Code + PKCE) — **this server has
no `/api/auth` routes.** The server only verifies the bearer token against the JWKS. This file owns **the boundary**:
`src/auth-env.ts` · `src/http/require-auth.ts` · `src/test/auth.ts`. The flow (IdP registration · CORS · what logout
means) is owned by `resources/auth-flows.md`, the envelope by `resources/api-endpoints.md`, and the ownership queries
by `resources/data-access.md`.

> **This axis has no data-layer policy engine.** Even though the IdP issues the token, **the IdP does not know "does
> this task belong to this user"** — `requireAuth` and the queries' `where` are the only boundary.

## 1. Judgment — what is verified and what is not trusted

| check | value | if left out |
| --- | --- | --- |
| signature | the public key from `OIDC_JWKS_URI` (chosen by `kid`) | a token signed with any key passes |
| algorithm | `RS256` · `ES256` only | confusion via `HS256` using the public key as the secret · `none` |
| issuer `iss` | exactly equal to `OIDC_ISSUER` | a token from **another tenant** of the same IdP product passes |
| audience `aud` | `OIDC_AUDIENCE` (this API's identifier) | a token **meant for another app** in the same tenant passes |
| expiry `exp` · `nbf` | jose's default checks | a stolen token stays valid forever |
| subject `sub` | a non-empty string → `AuthUser.id` | the owner value is empty and the ownership filter is neutralized |

`ownerId` is the IdP's `sub`. `sub` is unique **only within an issuer** — if you come to accept more than one issuer,
the owner value has to be bound to `iss` (this variant assumes a single issuer). It accepts **access tokens**, not ID
tokens — an ID token's `aud` is the client ID, which gets mixed up with the API audience check.

## 2. Environment keys (`src/auth-env.ts`)

<!-- file: src/auth-env.ts -->
```ts
// src/auth-env.ts — does not read process.env. src/env.ts merges it into EnvSchema and validates in one go
import { z } from 'zod'

export const AuthEnvSchema = z.object({
  OIDC_ISSUER: z.url(),            // must match the token's iss character for character (trailing slash included)
  OIDC_AUDIENCE: z.string().min(1), // this API's identifier — the value of the API (resource server) registered with the IdP
  OIDC_JWKS_URI: z.url(),           // jwks_uri from the discovery document — stated explicitly so boot does not hit the network
  WEB_ORIGINS: z.string().transform((s) => s.split(',').map((o) => o.trim().replace(/\/+$/, '')).filter(Boolean)).pipe(z.array(z.url()).min(1)),
})

// Test-only defaults — src/test/env.ts puts them only into empty keys. Tests never connect to these addresses
export const authTestEnv: Record<string, string> = {
  OIDC_ISSUER: 'https://issuer.test/',
  OIDC_AUDIENCE: 'tasks-api',
  OIDC_JWKS_URI: 'https://issuer.test/.well-known/jwks.json',
  WEB_ORIGINS: 'http://localhost:5173',
}
```

## 3. Bearer verification (`src/http/require-auth.ts`)

<!-- file: src/http/require-auth.ts -->
```ts
// src/http/require-auth.ts
import type { KeyObject } from 'node:crypto'
import type { FastifyRequest } from 'fastify'
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose'
import { env } from '../env'
import { AppError } from './app-error'

export type AuthUser = { id: string }
declare module 'fastify' {
  interface FastifyRequest { user?: AuthUser }
}

// The remote key set is lazily loaded and cached — fetched on the first verification, not at creation, and refetched when an unknown kid arrives
let keys: JWTVerifyGetKey = createRemoteJWKSet(new URL(env.OIDC_JWKS_URI))

// Lets tests verify tokens signed with their own key without a network. Throws outside tests
export function useTestVerificationKey(key: KeyObject): void {
  if (env.NODE_ENV !== 'test') throw new Error('useTestVerificationKey is test-only')
  keys = async () => key
}

// onRequest hook — set on the first line of the route plugin body. Failure throws (it does not write the reply)
export async function requireAuth(req: FastifyRequest): Promise<void> {
  const [scheme, token, extra] = (req.headers.authorization ?? '').split(' ')
  if (scheme?.toLowerCase() !== 'bearer' || !token || extra !== undefined) {
    throw new AppError('UNAUTHENTICATED', 'Authentication required')
  }
  try {
    const { payload } = await jwtVerify(token, keys, {
      issuer: env.OIDC_ISSUER,
      audience: env.OIDC_AUDIENCE,
      algorithms: ['RS256', 'ES256'],
    })
    if (typeof payload.sub !== 'string' || payload.sub === '') throw new Error('no sub')
    req.user = { id: payload.sub }
  } catch (e) {
    // The reason (expiry · signature · iss · aud · JWKS unreachable) goes to the log only — there is one response
    req.log.info({ reason: (e as { code?: string }).code ?? 'invalid' }, 'access token rejected')
    throw new AppError('UNAUTHENTICATED', 'Authentication required')
  }
}
```

**Failing to reach the JWKS is a 401 too.** An IdP outage does not leak out as a 500, and the client goes to login
after one refresh. So that covering an outage with a 401 is visible in the log, it records `reason` (jose's `code`,
e.g. `ERR_JWKS_TIMEOUT`).
<!-- unverified: jose@6's createRemoteJWKSet lazy loading · refetch on kid miss · error code names come from reading the jose@6.2.12 .d.ts comments and docs, not from running -->

`user` is an **optional property** — routes take it out with `ownerOf(req.user)` (`resources/api-endpoints.md` §5).
If you need roles (`FORBIDDEN`), add the claims the IdP carries (groups · scopes) to `AuthUser`, **split the route
plugin**, and set a role hook on that context — an ownership failure is a 404 regardless of role.

## 4. The test header (`src/test/auth.ts`) — with its own key, no network

`authFor` is synchronous — it has to fit in one line, `headers: authFor('alice')`. When the module loads it creates an
RSA key pair and hands the public key to the verifier. Signing builds an RS256 JWS with `sign` (synchronous) from
`node:crypto` — the verifier is jose as-is, so the `iss` · `aud` · `exp` checks run in tests too. `requireAuth` is
not mocked.

<!-- file: src/test/auth.ts -->
```ts
// src/test/auth.ts — test-only
import { generateKeyPairSync, sign } from 'node:crypto'
import { env } from '../env'
import { useTestVerificationKey } from '../http/require-auth'

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 })
useTestVerificationKey(publicKey)

const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url')

// Override claims to test the rejection paths (iss · aud · exp) — the default is a valid token this API accepts
export function signTestToken(claims: Record<string, unknown>): string {
  const now = Math.floor(Date.now() / 1000)
  const body = { iss: env.OIDC_ISSUER, aud: env.OIDC_AUDIENCE, iat: now, exp: now + 300, ...claims }
  const data = `${b64({ alg: 'RS256', typ: 'JWT' })}.${b64(body)}`
  return `${data}.${sign('sha256', Buffer.from(data), privateKey).toString('base64url')}`
}

export function authFor(ownerId: string): Record<string, string> {
  return { authorization: `Bearer ${signTestToken({ sub: ownerId })}` }
}
```

<!-- file: src/test/auth.oidc.test.ts -->
```ts
// src/test/auth.oidc.test.ts
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { buildApp, type App } from '../app'
import { pool } from '../db/client'
import { authFor, signTestToken } from './auth'

let app: App
beforeAll(async () => { app = await buildApp({ logger: false }) })
afterAll(async () => { await app.close(); await pool.end() })

describe('OIDC access token verification', () => {
  it('a matching iss · aud · signature is a 200, and if even one is off it is the same 401', async () => {
    const list = (headers: Record<string, string>) => app.inject({ url: '/api/tasks', headers })
    expect((await list(authFor('alice'))).statusCode).toBe(200)
    const bad = [
      signTestToken({ sub: 'alice', iss: 'https://other-tenant.test/' }),
      signTestToken({ sub: 'alice', aud: 'another-api' }),
      signTestToken({ sub: 'alice', exp: Math.floor(Date.now() / 1000) - 60 }),
      signTestToken({ sub: '' }),
      'not.a.jwt',
    ]
    for (const token of bad) {
      const res = await list({ authorization: `Bearer ${token}` })
      expect(res.statusCode).toBe(401)
      expect(res.json().error.code).toBe('UNAUTHENTICATED')
    }
  })
})
```

`authFor(ownerId)` keeps the exact one-argument shape the ledger pins. What builds the rejection paths is
`signTestToken`, which exists only in this variant — it overlays exactly one mismatch on top of a valid token's
default claims.

## Misuse list ① — self-issued · SDK habits → this variant's shape

| old habit | current form |
| --- | --- |
| verifying by "looking up" the token with the IdP SDK (admin client) | `jwtVerify` + a remote JWKS — the IdP is not called per request |
| pasting the public key into code or an environment variable | `OIDC_JWKS_URI` — the IdP rotates the keys and they are refetched on a `kid` miss |
| taking only `sub` out with `jwt.decode()` | decoding is not verification — check signature · `iss` · `aud` · `exp`, all of them |
| replacing `requireAuth` with a mock in tests | `useTestVerificationKey` + signing with its own key — the verification path runs as-is |

## Misuse list ② — confusable pairs

| what is often picked wrong | exact condition for applying it |
| --- | --- |
| ID token vs access token | the API accepts only the latter. The former is for the client to know the user |
| `aud` check vs `client_id` check | some IdPs do not put `aud` in the access token (a Cognito access token carries `client_id`) — then drop `audience` and compare the `client_id` claim directly. Checking neither is wrong <!-- unverified: the claim makeup of a Cognito access token is from the docs, not run --> |
| `OIDC_ISSUER` with vs without a trailing slash | it has to match the token's `iss` character for character — it differs per IdP. Use the `issuer` value from the discovery document as-is |
| a JWKS failure as 500 vs 401 | 401 + the `reason` in the log. With a 500 the client cannot take the re-login path |
