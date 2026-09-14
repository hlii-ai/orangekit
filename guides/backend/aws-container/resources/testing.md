<!-- orangekit-pack: backend/aws-container v3.12.0 -->
# Tests (Vitest + docker compose local parity)

The advantage of this stack is that **local is the same as production**. `docker compose` brings PostgreSQL 16 up as it is,
so migrations and queries are verified by **actually running them** rather than by imitating them.

## Three layers

| layer | target | DB | speed | location |
| --- | --- | --- | --- | --- |
| 1. pure | Zod schemas, path validation, cursor encoding, domain calculations | none | ms | `tests/unit/` |
| 2. handler | routing, parsing, the error envelope, the auth branch | a stand-in for the query module | tens of ms | `tests/handler/` |
| 3. integration | migrations, real SQL, ownership isolation, constraint violations | a real PostgreSQL | seconds | `tests/integration/` |

**Ownership isolation must be verified at layer 3.** There is no data-layer line of defense, so the fact that "someone
else's row does not come out" is proven only by real SQL.

## Keep the test database separate from the development DB

The full `docker-compose.yml` is in `resources/deployment-and-operations.md`. What the tests require is the single
fact that **`app_test` actually exists**, and hanging an initialization script on the `db` service
means no developer ever has to create it by hand.

```sql
-- docker/init-test-db.sql  (compose mounts it at /docker-entrypoint-initdb.d)
CREATE DATABASE app_test OWNER app;
```

- The tests use **a separate database** (`app_test`). `afterEach` runs a `TRUNCATE`, so
  point them at the development DB and the data you are working on disappears
- **The initialization script runs only when the data volume is first created.** If the volume already exists,
  run `docker compose exec db createdb -U app app_test` once, or rebuild it with `down -v` —
  skip that and the integration tests die with "database does not exist" and the cause looks like a migration failure

## Vitest configuration — fill env in first

The moment you import `@/app` or `@/db/client`, `@/config/env` runs its boot validation, and with a required key
missing the `process.exit(1)` **kills the whole test worker.**

```ts
// tests/test-env.ts — shared by both vitest configs. Every value is a string (the env schema converts them)
export const testEnv = {
  NODE_ENV: 'test', DB_SSL: 'false', S3_BUCKET: 'test-bucket',
  DATABASE_URL: 'postgres://app:local@localhost:5432/app_test',
  CORS_ORIGINS: 'http://localhost:5173',
  OIDC_ISSUER: 'https://issuer.test',                 // has to match the iss of the test token
  OIDC_JWKS_URL: 'https://issuer.test/jwks.json',     // a local JWKS is injected → it is never called
  OIDC_AUDIENCE: 'test-client',                       // has to match the client_id of the test token
  OIDC_AUTHORIZE_BASE: 'https://auth.test',
  SPA_CALLBACK_URL: 'http://localhost:5173/auth/callback',
  SPA_LOGOUT_URL: 'http://localhost:5173/',
  AUTH_STATE_SECRET: 'test-secret-at-least-32-characters-long',
}
```

```ts
// vitest.config.ts  — layers 1 and 2 (fast, parallel)
import path from 'node:path'
import { defineConfig } from 'vitest/config'
import { testEnv } from './tests/test-env'

export default defineConfig({
  resolve: { alias: { '@': path.resolve(__dirname, 'src') } },
  test: {
    environment: 'node',
    env: testEnv,                    // without it @/config/env ends the worker with exit(1)
    include: ['tests/unit/**/*.test.ts', 'tests/handler/**/*.test.ts'],
  },
})

// vitest.integration.config.ts — layer 3 (real DB, serial). Only the parts that differ from above:
Object.assign(process.env, testEnv)  // globalSetup runs in this process, not in a worker
  test: {
    env: testEnv,
    include: ['tests/integration/**/*.test.ts'],
    globalSetup: ['tests/integration/global-setup.ts'],
    setupFiles: ['tests/integration/setup.ts'],
    fileParallelism: false,          // several files emptying the same DB at once break each other
    testTimeout: 20_000,
  },
```

- **`test.env` applies to the workers only.** `globalSetup` runs in the same process as the config file, so
  `Object.assign(process.env, testEnv)` is needed separately — without it `@/config/env` calls `exit(1)` during
  the migration step and **Vitest exits with no failure message**
- Both configs register `@` in `resolve.alias`. Vitest does not read tsconfig's paths

```json
{
  "scripts": {
    "test": "vitest run",
    "test:integration": "docker compose up -d --wait db && vitest run -c vitest.integration.config.ts",
    "db:migrate": "drizzle-kit migrate"
  }
}
```

**Without `--wait` they race.** `docker compose up -d db` guarantees only that the container *starts booting*, so
the migration in `globalSetup` attaches to a PostgreSQL that is still initializing. `--wait` waits until compose's
`healthcheck` passes — the health check definition is the contract.

## Layer 1 — pure tests

Test only value in, value out. The cheapest, and the most frequently broken.

```ts
// tests/unit/return-path.test.ts
import { expect, it } from 'vitest'
import { safeReturnPath } from '@/http/return-path'

it.each([
  ['/tasks/42?tab=1', '/tasks/42?tab=1'],
  ['//evil.com', '/'],              // a scheme-relative URL
  ['/\\evil.com', '/'],             // browsers treat a backslash as /
  ['https://evil.com', '/'],
  ['/tasks\n/x', '/'],              // control character injection
])('safeReturnPath: %s → %s', (i, expected) => expect(safeReturnPath(i)).toBe(expected))
```

Pin the Zod schemas the same way — refusing unknown keys and over-limit values, applying defaults, and
**whether `UpdateTaskInput.safeParse({})` fails** (refusing an empty PATCH = no default left behind).

## Layer 2 — handler tests

Call it without a server through `app.request()`. Replace **only the verifier and the query module** with stand-ins.

```ts
// tests/handler/tasks.post.test.ts
import { describe, expect, it, vi } from 'vitest'

vi.mock('@/db/queries/tasks', () => ({
  insertTask: vi.fn(async (ownerId: string, input: { title: string }) =>
    ({ id: 'n1', ownerId, title: input.title, body: '', createdAt: new Date() })),
}))
vi.mock('@/http/auth', async (orig) => ({
  ...(await orig<typeof import('@/http/auth')>()),
  requireAuth: async (c: any, next: any) => {           // only signature verification is stood in for
    c.set('user', { sub: 'user-1', groups: [] })
    await next()
  },
}))

const { app } = await import('@/app')
const post = (body: unknown) => app.request('/api/tasks', {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
})

describe('POST /api/tasks', () => {
  it('returns 201 and a data envelope once validation passes', async () => {
    const res = await post({ title: 'first task' })
    expect(res.status).toBe(201)
    expect((await res.json()).data.title).toBe('first task')
  })
  it('returns 422 and a field error when title is empty', async () => {
    const res = await post({ title: '' })
    expect(res.status).toBe(422)
    const body = await res.json()
    expect(body.error.code).toBe('VALIDATION_FAILED')
    expect(body.error.details.title).toBeDefined()
  })
})
```

`requireAuth` is a factory that takes the verifier by injection, so you can also swap only the key source and run **the real verification path** with no stand-in (below).

## Layer 3 — real-DB integration tests

```ts
// tests/integration/global-setup.ts — once for the whole suite
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import { db, pool } from '@/db/client'

export default async function setup() {
  await migrate(db, { migrationsFolder: './drizzle' })   // apply the real migrations as they are
  return async () => { await pool.end() }
}

// tests/integration/setup.ts — isolation per test
import { afterEach } from 'vitest'
import { sql } from 'drizzle-orm'
import { env } from '@/config/env'

// do not TRUNCATE the development DB. The connection string is a secret, so it never goes in the message
if (!env.DATABASE_URL.endsWith('/app_test')) throw new Error('tests must target app_test')

afterEach(async () => {
  // the migration record lives in the drizzle schema, so emptying public alone is enough
  await db.execute(sql`
    DO $$ DECLARE t text;
    BEGIN
      FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
      LOOP EXECUTE format('TRUNCATE TABLE %I RESTART IDENTITY CASCADE', t); END LOOP;
    END $$;`)
})
```

```ts
// tests/integration/tasks.ownership.test.ts
import { describe, expect, it } from 'vitest'
import { insertTask, findOwnedTask, updateOwnedTask, deleteOwnedTask } from '@/db/queries/tasks'

const ALICE = '11111111-1111-1111-1111-111111111111'
const BOB = '22222222-2222-2222-2222-222222222222'
const task = (title: string) => ({ title, body: '' })      // insertTask takes parsed input

describe('ownership isolation', () => {
  it('a task belonging to another user is not read', async () => {
    const row = await insertTask(ALICE, task('alice task'))
    expect(await findOwnedTask(BOB, row.id)).toBeNull()
  })
  it('updating a task of another user touches 0 rows', async () => {
    const row = await insertTask(ALICE, task('alice task'))
    expect(await updateOwnedTask(BOB, row.id, { title: 'hijacked' })).toBeNull()
    expect((await findOwnedTask(ALICE, row.id))!.title).toBe('alice task')
  })
  it('deleting a task of another user touches 0 rows', async () => {
    const row = await insertTask(ALICE, task('alice task'))
    expect(await deleteOwnedTask(BOB, row.id)).toBe(0)
  })
  it('a duplicate title for the same user is refused with 23505', async () => {
    await insertTask(ALICE, task('duplicate'))
    await expect(insertTask(ALICE, task('duplicate'))).rejects.toMatchObject({ code: '23505' })
    await expect(insertTask(BOB, task('duplicate'))).resolves.toBeDefined()   // unique per user
  })
})
```

Duplicate these four (read, update, delete, constraint) for every new resource. **A missing ownership filter is caught
more reliably by this test than by review.**

## To test the auth path with a real token

**Sign with a local key pair and plug that public key straight into the verifier.** With no network, the whole `jwtVerify`
path (signature, issuer, audience, expiry) runs exactly as it does in production.

```ts
// tests/handler/auth.test.ts
import { Hono } from 'hono'
import { expect, it } from 'vitest'
import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair } from 'jose'
import { makeJwksVerifier, makeRequireAuth } from '@/http/auth'
import { onError } from '@/http/errors'
import type { AppEnv } from '@/http/types'

const { privateKey, publicKey } = await generateKeyPair('RS256')
const jwk = { ...(await exportJWK(publicKey)), kid: 'test', alg: 'RS256', use: 'sig' }
const jwks = createLocalJWKSet({ keys: [jwk] })

const sign = (over: { iss?: string; exp?: string; client_id?: string } = {}) =>
  new SignJWT({ token_use: 'access', client_id: over.client_id ?? 'test-client' })
    .setProtectedHeader({ alg: 'RS256', kid: 'test' })
    .setIssuer(over.iss ?? 'https://issuer.test').setSubject('user-1')
    .setIssuedAt().setExpirationTime(over.exp ?? '5m')
    .sign(privateKey)

const app = new Hono<AppEnv>()
app.use('*', makeRequireAuth(makeJwksVerifier(jwks)))   // ← the point where the local JWKS is actually wired in
app.get('/me', (c) => c.json({ data: { sub: c.get('user').sub } }))
app.onError(onError)

const call = (token?: string) =>
  app.request('/me', token ? { headers: { Authorization: `Bearer ${token}` } } : {})

it('a valid token passes', async () =>
  expect((await (await call(await sign())).json()).data.sub).toBe('user-1'))

it.each([
  ['expired', await sign({ exp: '-1m' })],
  ['a different issuer', await sign({ iss: 'https://evil.test' })],
  ['a different client_id', await sign({ client_id: 'other-app' })],
  ['no token', undefined],
])('%s → the same 401 UNAUTHORIZED envelope', async (_label, token) => {
  const res = await call(token)
  expect(res.status).toBe(401)
  expect((await res.json()).error.code).toBe('UNAUTHORIZED')
  expect(res.headers.get('WWW-Authenticate')).toBe('Bearer')
})
```

All four cases have to produce **the same status, the same code, the same message**. Let the reason differ in the response and an attacker
becomes able to tell "a valid token for a different audience" apart from "a forged signature".

## Misuse list (confusable pairs)

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| `app.request()` vs supertest | for Hono, `app.request()` is enough. Bring a server up and you get port contention and shutdown leaks |
| importing `@/app` without `test.env` | `config/env` calls `exit(1)` and the worker dies → fill `env` in both configs, and since `globalSetup` is outside the workers, `Object.assign(process.env, ...)` in the config file |
| `docker compose up -d db` (no `--wait`) | it guarantees only that booting has started → the migration races a DB that is still initializing |
| `drizzle-kit push` vs `migrate` (in tests) | tests take `migrate` — it means something only if it verifies the very SQL that goes to production |
| running integration tests in parallel | sharing one DB has the TRUNCATEs erase each other → `fileParallelism: false` or a DB per worker |
| inserting in `beforeEach` vs a fixture file | create only the rows a test needs, inside that test. A shared seed couples tests to each other |
| mocking the DB vs a real DB | query correctness (ownership, constraints, indexes) is not proven by mocking. Mocking stops at layer 2 |
| `vi.mock` hoisting | `vi.mock` is hoisted above the imports → load a module that needs a stand-in later with `await import()` |
| `expect(res.body)` | `app.request()` hands back a standard `Response` → `await res.json()` |
| tests pointed at the development DB | assert in `setup.ts` that `DATABASE_URL` ends at `app_test`. Otherwise the development data disappears |
