<!-- orangekit-pack: backend/fastify v3.36.0 -->
# Testing — `app.inject` and a real PostgreSQL

This file owns the Vitest configuration · the test DB guard · the fixtures (`src/test/`) and **the shape of the tests
that prove the blocking**. `authFor` (`src/test/auth.ts`), which builds the auth header, and the test defaults for the
auth keys (`authTestEnv`) are owned by `resources/auth-boundaries.md` — how the token is signed is a function of the
auth method.

## 1. Decision tree — what is checked with which test

| what you want to see | test shape | why |
| --- | --- | --- |
| ownership · auth boundary · envelope · status codes | `app.inject` route test + a real DB | encapsulation, serialization, and the error handler come from **the registration structure** — invisible at the function level |
| cursor · ordering · affected row count | the same route test (or the query function directly) | these are properties of SQL, so without a DB the test lies |
| transaction atomicity | the service function directly + a real DB | only the DB can tell you whether it rolled back |
| schema boundary values | `safeParse` unit test | no DB needed |

Do not replace the DB with a mock. The defects on this axis (a missing ownership condition · the tiebreaker · `db`
instead of `tx`) are all questions of **what the SQL actually returns**, so they vanish the moment the mock responds
the way you expected.

`app.inject` opens no socket and runs the whole request lifetime (hooks → parsing → validation → handler →
serialization → error handler). No port and no supertest are needed.

## 2. Vitest configuration and the test DB guard

<!-- file: vitest.config.ts -->
```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    globalSetup: ['./src/test/global-setup.ts'],
    setupFiles: ['./src/test/env.ts'],
    // The test files share one DB — unless file parallelism is off, resetDb deletes each other's rows
    fileParallelism: false,
  },
})
```

<!-- file: src/test/env.ts -->
```ts
// src/test/env.ts — setupFiles. Injects the test DB URL and the auth keys before the app modules load
import { authTestEnv } from '../auth-env'

const url = process.env.TEST_DATABASE_URL
if (!url) throw new Error('TEST_DATABASE_URL is not set — tests do not run against the development DB')
// Reject unless the name ends in _test — resetDb deletes rows
if (!new URL(url).pathname.endsWith('_test')) throw new Error(`The test DB name must end in _test: ${new URL(url).pathname}`)
process.env.DATABASE_URL = url
process.env.LOG_LEVEL ??= 'warn'
process.env.NODE_ENV ??= 'test'
// The auth keys differ per variant — the variant supplies test-only values. Values already set are not overwritten
for (const [k, v] of Object.entries(authTestEnv)) process.env[k] ??= v
```

<!-- file: src/test/global-setup.ts -->
```ts
// src/test/global-setup.ts — once per test run. Applies the migrations to the test DB
import { drizzle } from 'drizzle-orm/node-postgres'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import { Pool } from 'pg'

export default async function setup() {
  const url = process.env.TEST_DATABASE_URL
  if (!url || !new URL(url).pathname.endsWith('_test')) throw new Error('TEST_DATABASE_URL must be a DB whose name ends in _test')
  const pool = new Pool({ connectionString: url, max: 1 })
  await migrate(drizzle(pool), { migrationsFolder: './drizzle' })
  await pool.end()
}
```

**The `_test` name guard is the blocking device.** `resetDb` deletes rows — point `TEST_DATABASE_URL` at the
development DB by mistake and the development data disappears. In that case the guard stops before any module loads
<!-- verified: with TEST_DATABASE_URL set to …/app, global-setup failed with "must be a DB whose name ends in _test" and the development DB's row count did not change (2026-10-15) -->.

`setupFiles` changes `DATABASE_URL` **before the app modules are imported** — which is why `src/env.ts` reads the test
DB. `globalSetup` runs in a separate context and does not receive that injection, so it reads `TEST_DATABASE_URL`
directly and opens its own `max: 1` pool (the exception to policy `single-pool`).

## 3. Fixtures (`src/test/db.ts`)

<!-- file: src/test/db.ts -->
```ts
// src/test/db.ts
import { db } from '../db/client'
import { tasks, type TaskRow } from '../db/schema'

// The same singleton as the app — do not create a separate test-only client (DATABASE_URL already points at the test DB)
export const testDb = db

export async function resetDb(): Promise<void> {
  await testDb.delete(tasks)
}

let n = 0
export async function seedTask(ownerId: string, patch: Partial<typeof tasks.$inferInsert> = {}): Promise<TaskRow> {
  const [row] = await testDb.insert(tasks).values({ ownerId, title: `Task ${++n}`, ...patch }).returning()
  return row!
}
```

The first argument of `seedTask` is `ownerId` too — the same order as the query functions, so whoever reads the tests
is not confused.

**Confirm isolation by asking the DB.** Tests can be green while writing to the development DB. Right after a run, ask
both DBs `select count(*) from tasks` and check that the development DB has 0 rows and only the test DB has rows — the
count itself depends on the last test <!-- verified: right after the scratch run on 2026-10-15, app had 0 rows · app_test had 7 rows (a point-in-time value — the reproduction command is the select above) -->.

## 4. Route tests — a negative assertion is paired with a positive one

<!-- file: src/test/tasks.routes.test.ts -->
```ts
// src/test/tasks.routes.test.ts
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { buildApp, type App } from '../app'
import { pool } from '../db/client'
import { resetDb, seedTask } from './db'
import { authFor } from './auth'

let app: App
beforeAll(async () => { app = await buildApp({ logger: false }) })
afterAll(async () => { await app.close(); await pool.end() })
beforeEach(resetDb)

describe('ownership', () => {
  it('someone else\'s task is a 404 identical to absence, and your own task is a 200', async () => {
    const mine = await seedTask('alice')
    const theirs = await seedTask('bob')
    const own = await app.inject({ url: `/api/tasks/${mine.id}`, headers: authFor('alice') })
    const other = await app.inject({ url: `/api/tasks/${theirs.id}`, headers: authFor('alice') })
    const missing = await app.inject({ url: '/api/tasks/00000000-0000-4000-8000-000000000000', headers: authFor('alice') })
    expect(own.statusCode).toBe(200)
    expect(own.json().data.id).toBe(mine.id)
    expect(other.statusCode).toBe(404)
    // Absence and non-ownership are the same envelope byte for byte — if they differ, it becomes an existence oracle
    expect(other.body).toBe(missing.body)
  })

  it('updating someone else\'s task touches 0 rows, so it is a 404 and the original is unchanged', async () => {
    const theirs = await seedTask('bob', { title: 'original' })
    const res = await app.inject({ method: 'PATCH', url: `/api/tasks/${theirs.id}`, headers: authFor('alice'), payload: { title: 'hijacked' } })
    expect(res.statusCode).toBe(404)
    const still = await app.inject({ url: `/api/tasks/${theirs.id}`, headers: authFor('bob') })
    expect(still.json().data.title).toBe('original')
  })

  it('the list shows only your own tasks', async () => {
    const mine = await seedTask('alice')
    await seedTask('bob')
    const res = await app.inject({ url: '/api/tasks', headers: authFor('alice') })
    expect(res.statusCode).toBe(200)
    expect(res.json().data.map((t: { id: string }) => t.id)).toEqual([mine.id])
  })

  it('deleting someone else\'s task is a 404 and the original remains, while deleting your own is a 204', async () => {
    const mine = await seedTask('alice')
    const theirs = await seedTask('bob')
    const other = await app.inject({ method: 'DELETE', url: `/api/tasks/${theirs.id}`, headers: authFor('alice') })
    expect(other.statusCode).toBe(404)
    expect((await app.inject({ url: `/api/tasks/${theirs.id}`, headers: authFor('bob') })).statusCode).toBe(200)
    const own = await app.inject({ method: 'DELETE', url: `/api/tasks/${mine.id}`, headers: authFor('alice') })
    expect(own.statusCode).toBe(204)
  })

  it('the response does not carry ownerId', async () => {
    const mine = await seedTask('alice')
    const res = await app.inject({ url: `/api/tasks/${mine.id}`, headers: authFor('alice') })
    expect(res.statusCode).toBe(200)
    expect(Object.keys(res.json().data).sort()).toEqual(['createdAt', 'id', 'status', 'title'])
  })
})

describe('auth boundary', () => {
  it('every registered /api route is a 401 without auth, and the ops endpoints stay open', async () => {
    // Do not list them by hand — new routes and new domain plugins are included automatically
    const routes: { method: string; url: string }[] = []
    const probe = await buildApp({ logger: false, onRoute: (r) => {
      for (const m of [r.method].flat()) routes.push({ method: m, url: r.url })
    } })
    // /api/auth/* is where tokens are obtained, so it is public — rejection on those paths is checked by the auth-boundaries.md tests
    const api = routes.filter((r) => r.url.startsWith('/api/') && !r.url.startsWith('/api/auth/'))
    expect(api.length).toBeGreaterThanOrEqual(5)
    for (const r of api) {
      const url = r.url.replace(/:[A-Za-z]+/g, '00000000-0000-4000-8000-000000000000')
      const res = await probe.inject({ method: r.method as 'GET', url })
      expect(res.statusCode, `${r.method} ${r.url}`).toBe(401)
    }
    expect((await probe.inject({ url: '/healthz' })).statusCode).toBe(200)
    await probe.close()
  })
})
```

With only `expect(other.statusCode).toBe(404)`, **the test stays green even if you replace the query function
wholesale with `return null`** — because everything is a 404. The `own.statusCode === 200` in the same `it` is what
separates "blocked" from "completely broken". There is one ownership pair **for each of the four functions: read,
list, update, delete** — prove only one and you can delete the condition from the other three and stay green.

The auth boundary test does not list routes by hand. It collects the **registered** routes through
`buildApp({ onRoute })` and walks them, so a new domain plugin attached without the auth hook is caught
automatically. The `/healthz` 200 is the pair that catches the hook being moved up to the root so that everything is
401. Only paths under `/api/auth/` are excluded — login is a place that has to be reachable without a token, and
rejection on those paths (no cookie · reuse · origin mismatch) is asserted separately by the tests in
`resources/auth-boundaries.md`. `authFor` lives in `src/test/auth.ts`.

## 5. The rollback test (`src/services/task-service.test.ts`)

<!-- file: src/services/task-service.test.ts -->
```ts
// src/services/task-service.test.ts
import { eq } from 'drizzle-orm'
import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import { pool } from '../db/client'
import { tasks } from '../db/schema'
import { resetDb, testDb } from '../test/db'
import { importTasks } from './task-service'

beforeEach(resetDb)
afterAll(async () => { await pool.end() })

describe('importTasks', () => {
  it('if one conflicts everything rolls back, and with no conflict everything goes in', async () => {
    await expect(importTasks('alice', [{ title: 'a', status: 'open' }, { title: 'a', status: 'open' }])).rejects.toThrow()
    expect(await testDb.select().from(tasks).where(eq(tasks.ownerId, 'alice'))).toHaveLength(0)
    await importTasks('alice', [{ title: 'a', status: 'open' }, { title: 'b', status: 'open' }])
    expect(await testDb.select().from(tasks).where(eq(tasks.ownerId, 'alice'))).toHaveLength(2)
  })
})
```

The success assertion (2 rows) after the rollback assertion (0 rows) is the pair — without it the test is green even
if `importTasks` does nothing.

## 6. The blocking is proven — results of breaking the implementation on purpose

<!-- verified: applied each mutation below in scratch and ran vitest run (2026-10-15) -->

| mutation | result | the test that caught it |
| --- | --- | --- |
| remove the `ownerId` condition from `getTask` | red | someone else's task 404 |
| remove `rows.length === 0` from `updateTask` | red | updating someone else's task 404 |
| move the auth hook to a sibling plugin | red | every registered route |
| remove the `id` tiebreaker from the cursor | red | 7 rows in the same ms |
| expose `ownerId` in the view **and** the response schema | red | ownerId not exposed |
| remove the `ownerId` condition from `listTasks` | red | the list shows only your own tasks |
| remove `rowCount === 0` from `deleteTask` | red | deleting someone else's task 404 |
| remove the cursor's uuid and range validation | red | tampered cursor 400 |
| remove the NUL rejection from `Title` | red | NUL 400 |
| add an `/api/reports` plugin with no auth hook | red | every registered route |
| remove the 409 mapping | red | 409 + no SQL exposed |
| `.default('open')` on `TaskUpdateSchema` | red | partial update |
| `tx` → `db` in `importTasks` | red | rollback (1 row remained) |
| remove **only** the response schema (view unchanged) | green — **expected** | the first line of defense (view) remains |

The last row is not a defect but evidence of the double defense. When you add a new test, add a row to this table
and actually run that mutation — a test that was never run against a mutation is decoration, not a blocking device.

## Misuse list ① — supertest · Jest habits → Fastify 5 + Vitest 3 idioms

| old habit | current form |
| --- | --- |
| `request(app.server).get(...)` + `listen` | `app.inject({ url, headers })` — the full lifetime without a socket |
| `res.body` (parsed) | `res.json()` / the raw text is `res.body` |
| `jest.mock('../db')` | a real DB + the `_test` guard + `resetDb` |
| `new Pool()` in every file | `testDb` = the same singleton as the app |
| `import { defineConfig } from 'vite'` | `'vitest/config'` — the one from `vite` has no type for the `test` key <!-- verified: vite@7.3.7 + tsc — TS2769 'test' does not exist in type 'UserConfigExport' --> |

## Misuse list ② — confusable pairs

| often picked wrong | exact condition |
| --- | --- |
| `globalSetup` vs `setupFiles` | migrations (once per run) go in the former, environment injection (per worker, before module load) in the latter |
| `fileParallelism: false` vs a DB per worker | with one DB the former is mandatory — leave it on and `resetDb` deletes each other's rows |
| only `app.close()` in `afterAll` vs `pool.end()` as well | both — the pool is not owned by the app, so `close()` does not close it |
| `TaskRow` vs `TaskView` in assertions | compare response bodies against the latter's key set. Fixtures return the former |
