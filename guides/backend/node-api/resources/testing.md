<!-- orangekit-pack: backend/node-api v3.13.0 -->
# Testing — Vitest 2 · supertest 7 · real DB isolation

This file owns **the test harness and the lifetime of the test DB**: Vitest configuration, the shape for driving the app
with supertest, per-worker DB isolation, fixtures and cleanup. Connection pool sizing, health checks, and the shutdown procedure are
owned by `operations.md` (they handle the same resource, so read both files together). The shape of the query functions is in
`data-access.md` and the error code table in `error-handling.md`.

## 1. Judgment — when does this axis use a real DB

**This axis has no data-layer policy engine.** The ownership filter exists only in the application's query, so
a test verifying it that does not go through a real DB **proves nothing** — a test with Prisma mocked
confirms only "the mock I wrote matches the code I wrote".

| what you want to confirm | layer | tool | real DB |
| --- | --- | --- | --- |
| the Zod schema filters out a bad body | unit | Vitest | no |
| the service picks the right branch | unit | Vitest | no |
| the router emits exactly 400/404/409 | integration | Vitest + supertest | yes |
| **reading someone else's row gives a 404** | integration | supertest + a real DB | **yes** |
| **a 0-row mutation does not go out as success** | integration | supertest + a real DB | **yes** |
| `P2002` maps to 409 | integration | a real DB (it fires only with a unique constraint) | **yes** |
| the behavior of Prisma, Express, or Zod themselves | — | not tested | — |

The default is **a real-DB integration test**. In this stack, the only legitimate places for mocking are external HTTP calls and the clock.

## 2. Vitest configuration (`vitest.config.ts`)

<!-- file: vitest.config.ts -->
```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config';   // ✅ 'vitest/config', not 'vite'

export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
    setupFiles: ['src/test/db.ts'],   // re-evaluated for every test file
    pool: 'forks',                    // worker = separate process = separate connection pool
    poolOptions: {
      forks: { minForks: 1, maxForks: 4, isolate: false },   // ✅ the condition under which the §4 guard holds
    },
    hookTimeout: 30_000,              // the migration runs inside this
    testTimeout: 15_000,
  },
});
```

Import `defineConfig` from `'vite'` and the `test` key is absent from the type, so it **fails with TS2769**
(confirmed by running it: `Object literal may only specify known properties, and 'test' does not exist in
type 'UserConfigExport'`). In a repository whose config files are not included in `tsc`, this mistake quietly
remains and blows up in CI — put `vitest.config.ts` into the `include` of `tsconfig.json`.

**The worker count is set by `poolOptions.forks.maxForks`** — that is the value the forks pool reads.
`test.maxWorkers` does not break anything (confirmed by running it: it passed even with `maxWorkers` and `maxForks` set inconsistently) but
is ignored by the forks pool, so in this design, where it has to match the schema count, it quietly gives the wrong number.

**`isolate: false` is the premise of this design.** Under the default `true`, a new process starts per test file
and the per-worker guard of §4 is powerless — the evidence is given as a measurement in §4.

## 3. Driving the router for real with supertest (`*.test.ts`)

Hand the app object `makeApp()` built straight to `request()` — do not call `listen()`.
supertest opens and closes an ephemeral port per request, so there is no port collision and no cleanup code.

```ts
// src/http/routers/tasks.test.ts
import { afterEach, describe, expect, it } from 'vitest';
import request from 'supertest';
import { makeApp } from '../../app';
import { resetDb, seedTask, testDb } from '../../test/db';

const app = makeApp();
afterEach(resetDb);

describe('POST /api/tasks', () => {
  it('returns 400 and the field errors when the title is missing', async () => {
    // drop the auth header and you get a 401, not a 400 — requireAuth runs first
    const res = await request(app).post('/api/tasks').set(authFor('owner-1')).send({});
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(res.body.error.details.title).toBeDefined();
  });
});
```

**The field error key is `details`** — the ledger nailed `AppError` down as `details?: Record<string, string[]>`,
and that value rides into the envelope as-is. The shape of the enclosing envelope (where the `error` key sits) is decided by the seam's
`errorHandler`, but **the field error key inside it is the pack's contract.**

Express 5 **forwards the rejection of an async handler to the error middleware**
<!-- verified: ran express@5.2.1 + supertest@7.2.2. The test asserting that a throw in an async handler reaches (err,req,res,next) passed -->
— so do not test a handler wrapped in `try/catch`; **let it throw and look at the status code**.

## 4. Test DB isolation — what to pick and when

The one problem in this section is tests erasing each other's rows under parallel execution.

| strategy | isolation unit | when to pick it | cost |
| --- | --- | --- | --- |
| **per-worker schema** | process | the default. Fully isolated while keeping parallelism | one migration per worker |
| transaction rollback | test | only when the app does not open its own transaction | it breaks when nested with the service's `$transaction` |
| truncate + serial execution | file | when you have no permission to create a schema | `fileParallelism: false` — the slowest |

**Do not pick transaction rollback as the default.** This pack's service layer takes the transaction boundary
itself (`data-access.md`), so nesting inside an outer transaction misaligns the rollback point.

<!-- file: src/test/db.ts -->
```ts
// src/test/db.ts
import { execFileSync } from 'node:child_process';
import type { Task } from '@prisma/client';

// This is the exception where process.env is used directly (policies.md: env-single-entry).
// Each worker needs a different schema injected, but src/env.ts freezes its values at boot.
// Do not put TEST_DATABASE_URL in EnvSchema — app boot must not know this key.
const base = process.env.TEST_DATABASE_URL;
if (!base) throw new Error('TEST_DATABASE_URL is missing. This stops tests from connecting to the production DB.');
const schema = `test_w${process.env.VITEST_POOL_ID ?? '0'}`;
const url = `${base}?schema=${schema}&connection_limit=2`;
process.env.DATABASE_URL = url;

// setupFiles is re-evaluated for every test file. Only with isolate: false does globalThis
// survive in the process, so the migration runs once per worker rather than once per file.
const slot = globalThis as unknown as { __schemaReady?: Promise<void> };
slot.__schemaReady ??= (async () => {
  execFileSync('npx', ['prisma', 'migrate', 'deploy'], {
    env: { ...process.env, DATABASE_URL: url },
    stdio: 'inherit',
  });
})();
await slot.__schemaReady;

// A static import runs before the assignment above — it has to be a dynamic import to read the new URL.
const client = await import('../db/client');
export const testDb = client.prisma;   // the same singleton as the app. Do not build a separate instance

export async function resetDb(): Promise<void> {
  await testDb.task.deleteMany();
}

export async function seedTask(ownerId: string, over: Partial<Task> = {}): Promise<Task> {
  return testDb.task.create({
    data: { title: over.title ?? 'Write the report', status: over.status ?? 'open', ownerId },
  });
}
```

What was confirmed by running it (Vitest 2.1.9 · Node 24.7.0 · 6 test files · `maxForks: 2`):

- `VITEST_POOL_ID` is **the pool slot number**. It is bounded to the range `1`…`maxForks` and outlives a
  process — with more files than workers, several processes inherit the same value (3 pids shared POOL_ID `1`).
  **The schema name needs exactly this property**: the schema count is bounded by `maxForks`
- `setupFiles` is **re-evaluated for every test file** — a module-scope guard cannot stop the duplication
- **With `isolate` at its default (`true`) the guard is powerless**: a new process starts per file, so
  `globalThis` is created afresh and the guard body ran **as many times as there are files (6)**, not workers (2).
  Give it `isolate: false` and it drops to 2 pids · 2 runs of the guard body. `migrate deploy` running once per
  file is the cause of the intermittent failures that burn `hookTimeout`
- The URL the file above builds is passed to `migrate deploy` unchanged
  (`...?schema=test_w1&connection_limit=2`)

**`testDb` is the singleton in `src/db/client.ts` itself.** If a test builds its own client there are two
connection pools, and a test may fail to see a row the app wrote over the other connection.

## 5. Ownership regression tests — the most expensive tests on this axis

With no policy engine, these three have to exist **for every router**. Delete everything else and
keep these.

**A negative assertion alone does not prove the block.** Replace `getTask` entirely with `return null`, or swap the two
columns in the `where`, and "someone else's → 404" still passes — because everything is a 404.
**Only pairing it with the positive path** makes the test a guard.

```ts
// src/http/routers/tasks.test.ts
it('200 for the owner, 404 for anyone else — assert them as a pair', async () => {
  const mine = await seedTask('owner-1');
  const other = await seedTask('owner-2');
  const ok = await request(app).get(`/api/tasks/${mine.id}`).set(authFor('owner-1'));
  expect(ok.status).toBe(200);           // ✅ without it, an implementation that 404s everything passes
  const denied = await request(app).get(`/api/tasks/${other.id}`).set(authFor('owner-1'));
  expect(denied.status).toBe(404);       // ✅ it does not leak existence (not a 403)
});

it('a 0-row change does not go out as a 200 — assert them as a pair', async () => {
  const mine = await seedTask('owner-1');
  const other = await seedTask('owner-2');
  const ok = await request(app)
    .patch(`/api/tasks/${mine.id}`).set(authFor('owner-1')).send({ status: 'done' });
  expect(ok.status).toBe(200);           // ✅ the positive path
  const denied = await request(app)
    .patch(`/api/tasks/${other.id}`).set(authFor('owner-1')).send({ status: 'done' });
  expect(denied.status).toBe(404);
  const after = await testDb.task.findFirst({ where: { id: other.id } });
  expect(after?.status).toBe('open');    // re-read from the DB to see the row really did not change
});
```

`authFor()` is **provided by the seam** — whether it is a header or a cookie is decided by the combination
(`auth-boundaries` in `seamSlots`), and if the pack nailed that shape down it would break per combination. The test
**drives the seam's `requireAuth` as-is rather than mocking it**: mock it and the authorization wiring, the very
thing to be verified, drops out of the test.

Put the partial-update regression in the same place — assert that `title` is untouched when only `{ status: 'done' }` was
sent. If a `.default()` stacks on the schema, another field is overwritten while the syntax stays perfect.

## 6. What is not tested

- **The libraries themselves**: whether Zod filters a string, whether Express matches a path, whether Prisma
  builds SQL. These are not properties of our code
- **Ownership logic over a mocked Prisma**: a mock does not execute the real `WHERE` clause.
  It can pass and still fail to stop a leak
- **The coverage number**: 90% without the three tests in §5 is more dangerous than none —
  it gives a signal of safety
- **Whether the schema exists**: the fact that `migrate deploy` succeeded is that proof
- **Log output strings**: they break when the shape changes and protect nothing.
  Instead, look at **whether a secret goes out**, as in the `redact` test in `operations.md`

## Misuse list ① — Jest → Vitest 2 idioms

| old habit (Jest) | current shape (Vitest 2) |
| --- | --- |
| a separate config in `jest.config.js` | the `test` key of `vitest.config.ts` (`defineConfig` from `vitest/config`) |
| global `describe`/`it` provided by default | explicit imports by default. For globals, `test.globals: true` |
| `jest.mock('module')` | `vi.mock('module')` — though on this axis Prisma is not mocked |
| `testEnvironment: 'node'` | `test.environment: 'node'` |
| `maxWorkers` | `poolOptions.forks.maxForks` — the forks pool does not read `maxWorkers` |
| preparing the DB in `globalSetup` | a setup file + a `globalThis` guard + **`isolate: false`** (because a per-worker schema is needed) |
| `--runInBand` | `test.fileParallelism: false` |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `defineConfig` from `'vite'` vs from `'vitest/config'` | if you use the `test` key it must be the latter. The former is TS2769 |
| `setupFiles` vs `globalSetup` | per-worker work (the isolated DB) is `setupFiles`, once outside the processes (starting Docker) is `globalSetup` |
| `VITEST_POOL_ID` vs `VITEST_WORKER_ID` | the schema name uses **`POOL_ID` only**. `WORKER_ID` increments per file (measured 1…6) and the schemas grow without bound |
| `request(app)` vs `request(server)` | hand over the app object. Hand over a `listen()`ed server and you take on the cleanup |
| `afterEach(resetDb)` vs `beforeEach(resetDb)` | `afterEach` — it erases the leftover rows of a failed test right there rather than in the next test |
| 404 vs 403 as the ownership-violation response | **404**. A 403 lets them enumerate which resources exist |
| `toBe` vs `toMatchObject` (the response body) | pin the whole envelope with `toBe` and it breaks every time the seam changes. Look only at the keys you need |
