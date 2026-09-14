<!-- orangekit-pack: backend/node-nest v3.16.0 -->
# Testing — attach to a real DB and split by schema per worker

This file owns **the test harness**. `authFor`, which builds the auth header, is the seam's share
(`auth-boundaries` decides header or cookie), and the examples below assume a header in that place.

## 1. What is tested at which layer

| target | approach | real DB |
| --- | --- | --- |
| Pure functions (cursor encoding, error mapping) | Direct call | Not needed |
| A service alone (branches, exceptions) | `Test.createTestingModule` + a Repository double | Not needed |
| Query correctness (ownership, `affected`) | The app attached to a real DB | **Needed** |
| Endpoints (status codes, envelope) | supertest + the global pipes and filters | **Needed** |

**Always test the ownership check against a real DB.** A double answers the way we wrote it, so it passes
even with `ownerId` missing from the `where` — by definition a double cannot see that defect.

## 2. A service alone — Repository double

<!-- verified: @nestjs/testing@11.2.1, run — getRepositoryToken(Task) is the string 'TaskRepository', and calling update with a double returning affected: 0 produced AppError('NOT_FOUND') -->

```ts
// test/tasks.service.spec.ts (excerpt)
const moduleRef = await Test.createTestingModule({
  providers: [
    TasksService,
    { provide: getRepositoryToken(Task), useValue: { update: async () => ({ affected: 0 }) } },
    { provide: DataSource, useValue: { transaction: async (fn: unknown) => fn } },
  ],
}).compile();
await expect(moduleRef.get(TasksService).update('owner-a', 'id', {})).rejects.toMatchObject({ code: 'NOT_FOUND' });
```

`getRepositoryToken(Task)` is the injection token. **If the service builds the Repository itself this place
disappears** — "only through DI" from `data-access.md` §2 pays off here.

## 3. Per-worker schema isolation (`test/db.ts`)

<!-- file: test/db.ts -->
```ts
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { DataSource } from 'typeorm';
import { AppModule } from '../src/app.module';
import { buildValidationPipe } from '../src/common/validation';
import { buildDataSourceOptions } from '../src/database/data-source';
import { validateEnv } from '../src/config/env';
import { Task } from '../src/tasks/task.entity';

export const testSchema = process.env.DB_SCHEMA ?? 'public';

export async function prepareSchema(schema: string): Promise<void> {
  const env = validateEnv({ ...process.env, DB_SCHEMA: 'public' });
  const admin = new DataSource(buildDataSourceOptions(env));
  await admin.initialize();
  const runner = admin.createQueryRunner();
  await runner.dropSchema(schema, true, true);
  await runner.createSchema(schema, true);
  await runner.release();
  await admin.destroy();
}

export async function createTestApp(
  configure?: (app: INestApplication) => void,
): Promise<INestApplication> {
  const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
  const app = moduleRef.createNestApplication({ logger: false });
  app.useGlobalPipes(buildValidationPipe());
  configure?.(app);
  await app.init();
  await app.get(DataSource).runMigrations();
  return app;
}

export async function resetDb(app: INestApplication): Promise<void> {
  await app.get(DataSource).getRepository(Task).deleteAll();
}

export async function seedTask(app: INestApplication, ownerId: string, patch: Partial<Task> = {}): Promise<Task> {
  const repo = app.get(DataSource).getRepository(Task);
  return repo.save(repo.create({ title: 'Task', ownerId, ...patch }));
}
```

<!-- verified: PostgreSQL 18.4 + jest@30.4.2, run — a pg_tables query confirmed the tasks table was created in the test_w1 schema -->
The unit of isolation is **a schema, not a database**, for the value: creating a database per worker costs
connections and template cloning, and splitting by transaction rollback makes the transaction itself
untestable. A schema splits with one line of `DataSourceOptions.schema` and the migrations run unchanged.

**Write no raw SQL.** A schema name is an identifier and cannot be parameterized, which makes
`query('CREATE SCHEMA ' + name)` tempting — but `QueryRunner`'s `createSchema` and
`dropSchema` do that job. Cleanup is `repo.deleteAll()`, so there is no SQL there either.

## 4. Set the schema **before** importing AppModule

<!-- verified: @nestjs/config@4.0.4, run — changing process.env.DB_SCHEMA inside createTestApp left DataSource.options.schema at 'public', and the tables were created in public rather than the isolated schema. The tests still passed 4/4 -->
**This is the most expensive trap in this file.** `ConfigModule.forRoot()` runs `validate` the moment the
module file is loaded — because it is evaluated as an argument to a class decorator. Change `process.env`
after importing `AppModule` and **it is not reflected in the configuration.**

The symptom is nasty because the tests are green then too. Two workers share the same `public`
schema and delete each other's rows, but each test cleans up in `beforeEach`, so it mostly
just passes. It was found not through a failure but **by querying `pg_tables` directly**.

<!-- file: test/setup.ts -->
```ts
import 'reflect-metadata';

// Set the schema **before importing AppModule**.
// ConfigModule.forRoot() runs validate the moment the module file is loaded, so
// changing process.env after that is not reflected in the configuration (measured).
process.env.DB_SCHEMA = `test_w${process.env.JEST_WORKER_ID ?? '1'}`;
```

`setupFiles` runs before the test files and their imports — which makes this the only safe
place. `setupFilesAfterEnv` is too late.

<!-- file: test/global-setup.ts -->
```ts
import 'reflect-metadata';
import type { Config } from '@jest/types';
import { prepareSchema } from './db';

export default async function globalSetup(config: Config.GlobalConfig): Promise<void> {
  for (let worker = 1; worker <= config.maxWorkers; worker++) {
    await prepareSchema(`test_w${worker}`);
  }
}
```

`globalSetup` runs **once, outside the workers** — so it has no `JEST_WORKER_ID`. Creating only its own
schema leaves worker 2 facing an empty one and failing. Take `maxWorkers` and create them all.

<!-- file: jest.config.js -->
```js
/** @type {import('jest').Config} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  rootDir: '.',
  testRegex: '.*\\.spec\\.ts$',
  setupFiles: ['<rootDir>/test/setup.ts'],
  globalSetup: '<rootDir>/test/global-setup.ts',
  maxWorkers: 2,
  testTimeout: 20000,
};
```

Keeping the config as `jest.config.ts` makes jest 30 try to read it as ESM, fail, and emit a warning
(it still works). `.js` + JSDoc type annotations get the same type checking without the warning.
<!-- verified: jest@30.4.2, run — jest.config.ts produced a "Failed to load the ES module" warning that disappeared after switching to .js -->

## 5. Endpoint tests — prove the block

<!-- file: test/tasks.spec.ts -->
```ts
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { AllExceptionsFilter } from '../src/common/all-exceptions.filter';
import { createTestApp, resetDb, seedTask } from './db';

const A = '11111111-1111-1111-1111-111111111111';
const B = '22222222-2222-2222-2222-222222222222';
const authFor = (ownerId: string) => ({ 'x-owner-id': ownerId });

describe('Tasks API', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp((a) => a.useGlobalFilters(new AllExceptionsFilter()));
  });
  afterAll(async () => { await app.close(); });
  beforeEach(async () => { await resetDb(app); });

  it('the owner reads their own task and others cannot', async () => {
    const mine = await seedTask(app, A, { title: 'My task' });
    const ok = await request(app.getHttpServer()).get(`/api/tasks/${mine.id}`).set(authFor(A));
    expect(ok.status).toBe(200);
    expect(ok.body.data.title).toBe('My task');

    const denied = await request(app.getHttpServer()).get(`/api/tasks/${mine.id}`).set(authFor(B));
    expect(denied.status).toBe(404);
  });

  it('the owner updates, another user gets 404, and the value is unchanged', async () => {
    const mine = await seedTask(app, A, { title: 'Original title' });
    const ok = await request(app.getHttpServer()).patch(`/api/tasks/${mine.id}`).set(authFor(A)).send({ title: 'Changed title' });
    expect(ok.status).toBe(200);
    expect(ok.body.data.title).toBe('Changed title');

    const denied = await request(app.getHttpServer()).patch(`/api/tasks/${mine.id}`).set(authFor(B)).send({ title: 'Hijack' });
    expect(denied.status).toBe(404);
    const after = await request(app.getHttpServer()).get(`/api/tasks/${mine.id}`).set(authFor(A));
    expect(after.body.data.title).toBe('Changed title');
  });

  it('the list carries only rows of the owner', async () => {
    await seedTask(app, A, { title: 'A-1' });
    await seedTask(app, A, { title: 'A-2' });
    await seedTask(app, B, { title: 'B-1' });
    const res = await request(app.getHttpServer()).get('/api/tasks?limit=10').set(authFor(A));
    expect(res.status).toBe(200);
    expect(res.body.data).toHaveLength(2);
    expect(res.body.data.map((t: { title: string }) => t.title).sort()).toEqual(['A-1', 'A-2']);
  });

  it('a key absent from the DTO is rejected and a valid body passes', async () => {
    const ok = await request(app.getHttpServer()).post('/api/tasks').set(authFor(A)).send({ title: 'Valid' });
    expect(ok.status).toBe(201);

    const bad = await request(app.getHttpServer()).post('/api/tasks').set(authFor(A)).send({ title: 'Typo', admin: true });
    expect(bad.status).toBe(400);
    expect(bad.body.error.details).toHaveProperty('admin');
  });
});
```

**Every `it` attaches the positive and the negative as a pair.** With only the negative, breaking the
implementation wholesale stays green — because every request becomes a 404. The second test above re-reads the value
after the update for the same reason: a 404 alone does not distinguish "it was blocked" from "the original value was wiped".

<!-- verified: jest@30.4.2 + PostgreSQL 18.4, run — removing ownerId from get()'s where failed the first test immediately (1 failed), and restoring it passed 4/4 -->
Actually perform the block proof: delete the ownership filter, confirm the test **goes red**, then
restore it. If it does not go red, that test is decoration, not a guard.

The `configure` callback of `createTestApp` is where the seam's exception filter goes. Leave it off and
every `AppError` goes out as a 500, so **every status code assertion loses its meaning**
(`error-handling.md` §4).

## 6. What to clean up and what to leave

| when | what it does | why |
| --- | --- | --- |
| `globalSetup` | Create as many schemas as there are workers | Once is enough. Creating them every time is slow |
| `beforeAll` | Boot the app + run migrations | One app is shared by the whole file |
| `beforeEach` | `resetDb` | Cuts order dependence between tests |
| `afterAll` | `app.close()` | Omit it and jest hangs on "open handles" |

Cleanup is not put in `afterEach` so that a failed test's DB state is left behind —
the `beforeEach` cleanup takes care of it for the next test.

## Misuse list ① — Express/Vitest idiom → Nest + Jest form

| old habit | current form |
| --- | --- |
| `supertest(app)` (the Express app directly) | `supertest(app.getHttpServer())` |
| Module mocking with `jest.mock('../src/db')` | `overrideProvider(token).useValue(...)` — DI is already the seam |
| `new Service(new Repo())` in `beforeAll` | `Test.createTestingModule` — use the real injection graph as-is |
| `process.env.X = ...` inside a test | In `setupFiles` (§4). After module load it is too late |
| `vi.fn()` / `vitest` config | `jest.fn()` / `jest.config.js`. Jest is the Nest CLI default |
| Isolating with transaction rollback | Isolate by schema. The transaction itself has to be testable |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `setupFiles` vs `setupFilesAfterEnv` | The first runs **before** the test framework (environment setup), the second after (registering matchers). Setting the schema always takes the first |
| `globalSetup` vs `beforeAll` | The first runs once outside the process (no worker id), the second inside the worker, per file |
| `app.init()` vs `app.listen()` | `init()` is enough for tests. `listen` grabs a port and collides under parallel execution |
| `deleteAll()` vs `TRUNCATE` | The first is an API, so the ORM knows the schema and the FK order. The second becomes raw SQL |
| `expect(res.status).toBe(404)` on its own | Without a positive path paired with it, it is not a block proof (§5) |
| Testing ownership without a real DB | A double answers the way we wrote it — it cannot structurally see that defect |
