<!-- orangekit-seam: vue+node-api v3.13.0 -->
# Complete example — one pass from migration to tests

Joins up a single `Task` feature from start to finish. **The only things newly defined here are the schema and the service**;
everything else consumes what already exists — the purpose of this file is to make visible which file owns which
step. Each section points at the canonical file for that step.

## 1. The decision — the six steps and their owners

Go down in this order when building a new feature. Invert it — start from the router — and there is no schema, so
`any` spreads and the handler is finished before you have decided where to put the ownership condition.

| # | Step | File | Canonical source |
| --- | --- | --- | --- |
| 1 | migration · model | `prisma/schema.prisma` | §2 of this file (design is the T1 data-modeling card) |
| 2 | request schema | `src/schemas/task.ts` | `resources/input-validation.md` |
| 3 | query | `src/db/tasks.ts` | `resources/data-access.md` |
| 4 | service (transaction boundary) | `src/services/task-service.ts` | §4 of this file |
| 5 | router · mount | `src/http/routers/tasks.ts` · `src/app.ts` | `resources/api-endpoints.md` |
| 6 | tests | `src/http/routers/tasks.test.ts` | §6 of this file · `resources/testing.md` |

There is one reason for going down to step 3 before coming back up — **step 3 is where ownership is attached.**
This axis has no data-layer policy engine, so the `where` of the query is the only boundary.

## 2. The migration and the model (`prisma/schema.prisma`)

<!-- file: prisma/schema.prisma -->
```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

enum TaskStatus {
  open
  done
}

model Task {
  id        String     @id @default(cuid())
  title     String     @db.VarChar(200)
  status    TaskStatus @default(open)
  dueAt     DateTime?
  ownerId   String
  createdAt DateTime   @default(now())
  updatedAt DateTime   @updatedAt
  comments  Comment[]

  @@unique([ownerId, title])
  @@index([ownerId, createdAt, id])
}

model Comment {
  id      String @id @default(cuid())
  body    String
  taskId  String
  task    Task   @relation(fields: [taskId], references: [id], onDelete: Cascade)
  ownerId String
}

model AuditEntry {
  id      String   @id @default(cuid())
  ownerId String
  taskId  String
  action  String
  at      DateTime @default(now())
}

model RefreshToken {
  id        String    @id @default(cuid())
  tokenHash String    @unique
  ownerId   String
  expiresAt DateTime
  usedAt    DateTime?
  familyId  String

  @@index([ownerId])
}
```

<!-- verified: prisma@6.19.3 run — this file as it stands passed `prisma generate` and produced Task · Comment · AuditEntry · RefreshToken and TaskStatus in @prisma/client. `migrate` could not be run because there was no PostgreSQL -->
All four models are needed for a reason. `Comment` is the relation the nested `select` example of `resources/data-access.md` §5
attaches to, `AuditEntry` is used by the transaction of §4, and `RefreshToken` is used by the rotation of
`resources/auth-boundaries.md` §5. Drop any one of them and the code of that section dangles in the assembled guide.

`@@unique([ownerId, title])` is where `P2002` → 409 fires, and `@@index([ownerId, createdAt, id])` is in the
**same order** as the sort key of the cursor pagination. With a different index order the cursor still works but every page
sorts again. `@db.VarChar(200)` is the pair of Zod's `.max(200)` — either one alone is not enough.

Applying it runs as a **step separate from the deploy**: `npx prisma migrate dev --name add-task` in development,
`npx prisma migrate deploy` on deploy. It is never called from application boot —
if instances come up at the same time they race to apply the same migration.

## 3. The pack gives the schema and the queries — only match the consumption shape

The code for steps 2 and 3 is in `resources/input-validation.md` and `resources/data-access.md`. What has to be checked
here is only **two call shapes**, and both were actually wrong in the measurement.

```ts
// src/services/task-service.ts — the shape of consuming a pack query
// ❌ the argument order is inverted. Both are strings, so tsc does not catch it and every read becomes a 404
const task = await getTask(id, ownerId);
// ✅ the owner comes first
const task = await getTask(ownerId, id);
```

The `q` of `listTasks(ownerId, q)` is `TaskQuery` as it is. The query function fetches one extra row with `take: q.limit + 1`,
so **the consumer trims it and builds the cursor** — the router does that assembly
(`resources/api-endpoints.md` §6).

## 4. The service — the transaction boundary (`src/services/task-service.ts`)

If one query finishes the job, no service is needed. It appears **when several writes have to be atomic.**
Archiving requires the status change and the audit record to succeed together or fail together.

```ts
// src/services/task-service.ts
import type { Prisma } from '@prisma/client';
import { AppError } from '../http/app-error';
import { prisma } from '../db/client';

export function archiveTask(ownerId: string, id: string) {
  return prisma.$transaction(async (tx: Prisma.TransactionClient) => {
    const changed = await tx.task.updateMany({ where: { id, ownerId }, data: { status: 'done' } });
    if (changed.count === 0) throw new AppError('NOT_FOUND', 'Task not found');
    await tx.auditEntry.create({ data: { ownerId, taskId: id, action: 'archive' } });
  });
}
```

All three lines are needed. **Ownership goes in the `where`** (a comparison after the read is pierced by races),
**the affected row count is the ruling** (`updateMany` returns `count: 0` without an exception for someone else's row),
and **the audit record is inside the same transaction** (put it outside and there is a combination where the status changes and the record vanishes).

Do not make an HTTP call or publish to a queue inside the transaction — a rollback does not take those side effects
back, and waiting for an external response only lengthens the lock. Do it after the commit.

## 5. The router and the mount (`src/http/routers/tasks.ts` · `src/app.ts`)

The full text of `tasksRouter` is in `resources/api-endpoints.md` §5. Here we look only at the lines that attach the service
of §4 — the service throws and the router builds only the success envelope.

```ts
// src/http/routers/tasks.ts — the archive route (requireAuth is attached to the whole router)
tasksRouter.post('/:id/archive', async (req, res) => {
  const task = await archiveTask(actor(req).id, req.params.id);
  res.json({ data: task });
});
```

```ts
// src/app.ts — the mount order inside makeApp() (excerpt)
app.use(cors);                       // the preflight comes before the body parser
app.use(express.json({ limit: '1mb' }));
app.use('/api/auth', authRouter);
app.use('/api/tasks', tasksRouter);
app.use(notFound);                   // after the routers
app.use(errorHandler);               // always last
```

<!-- verified: express@5.2.1 + supertest@7.2.2 run — with this wiring the owner's archive request gave 200 `{"data":{…"status":"done"}}`, the same request from a stranger gave 404 NOT_FOUND, and the status of the stranger's row stayed open. The transaction itself (prisma.$transaction · auditEntry) was replaced with an in-memory stub because there was no PostgreSQL, so it is unverified against the real thing -->
`makeApp` and `notFound` are owned by the pack (`resources/project-structure.md`) — they are not redefined here;
only the mount lines grow.

## 6. The tests, all the way through (`src/http/routers/tasks.test.ts`)

<!-- file: src/http/routers/tasks.test.ts -->
```ts
import { afterEach, describe, expect, it } from 'vitest';
import request from 'supertest';
import { makeApp } from '../../app';
import { resetDb, seedTask, testDb } from '../../test/db';
import { authFor } from '../../test/auth';

const app = makeApp();
afterEach(resetDb);

describe('GET/PATCH /api/tasks/:id — ownership', () => {
  it('the owner gets 200 and a stranger 404 — asserted as a pair', async () => {
    const mine = await seedTask('owner-1');
    const other = await seedTask('owner-2', { title: "someone else's task" });
    const ok = await request(app).get(`/api/tasks/${mine.id}`).set(authFor('owner-1'));
    expect(ok.status).toBe(200);
    expect(ok.body).toMatchObject({ data: { id: mine.id, title: 'Write the report' } });
    const denied = await request(app).get(`/api/tasks/${other.id}`).set(authFor('owner-1'));
    expect(denied.status).toBe(404);
    expect(denied.body.error.code).toBe('NOT_FOUND');
  });

  it('a 0-row change never goes out as 200 — asserted as a pair', async () => {
    const mine = await seedTask('owner-1');
    const other = await seedTask('owner-2', { title: "someone else's task" });
    const ok = await request(app)
      .patch(`/api/tasks/${mine.id}`).set(authFor('owner-1')).send({ status: 'done' });
    expect(ok.status).toBe(200);
    expect(ok.body.data.title).toBe('Write the report');   // the .default() overlap regression
    const denied = await request(app)
      .patch(`/api/tasks/${other.id}`).set(authFor('owner-1')).send({ status: 'done' });
    expect(denied.status).toBe(404);
    const after = await testDb.task.findFirst({ where: { id: other.id } });
    expect(after?.status).toBe('open');              // read back from the DB
  });

  it('no auth gives 401, auth gives 200 — asserted as a pair', async () => {
    const mine = await seedTask('owner-1');
    const anon = await request(app).get(`/api/tasks/${mine.id}`);
    expect(anon.status).toBe(401);
    expect(anon.body.error.code).toBe('UNAUTHENTICATED');
    const ok = await request(app).get(`/api/tasks/${mine.id}`).set(authFor('owner-1'));
    expect(ok.status).toBe(200);
  });
});
```

**The positive assertion is half of this test.** Assert only the failures and you stay green even after breaking the implementation entirely —
because then everything is a 404. Two mutations were actually planted to confirm it:

<!-- verified: vitest@2.1.9 + supertest@7.2.2 run — the two mutations below were each applied, run, and reverted -->
| Planted defect | What breaks | Result |
| --- | --- | --- |
| `getTask` changed to `return null` | the positive assertion (`toBe(200)`) | 3 of 4 failed |
| `ownerId` removed from the `where` | the negative assertion (`expected 200 to be 404`) | 2 of 4 failed |

With only one side, a defect on the other side passes. Asserted as a pair, this test becomes a guard.
`seedTask` · `resetDb` · `testDb` come from the pack (`resources/testing.md`) and `authFor` from the seam
(`resources/auth-boundaries.md` §6). **Do not mock `requireAuth`** — mocking it removes from the tests
the very authorization wiring that has to be verified.

## Misuse list ① — where the end-to-end example actually breaks

| Old habit | The form of this combination |
| --- | --- |
| Calling `migrate deploy` at boot | A step separate from the deploy. Instances coming up together race |
| Matching the schema with `db push` | No migration file remains, so there is no record to roll back |
| Calling `prisma` directly from a router | Queries go in `src/db/`, the transaction boundary in `src/services/` |
| A service taking a `Request` as an argument | Plain arguments only. Interpreting HTTP is the router's job |
| Writing the audit record outside the transaction | Inside the same `tx`. Outside, the status changes and the record vanishes |
| Building the cursor from `createdAt` alone | The total order `(createdAt, id)`. Rows created in the same millisecond do exist |
| An ownership test with only failure assertions | Assert the positive path as a pair inside the same `it` |

## Misuse list ② — confused pairs

| Frequently chosen wrongly | The exact condition for each |
| --- | --- |
| `getTask(ownerId, id)` vs `getTask(id, ownerId)` | The owner comes first. Both are `string`, so the compiler does not catch it |
| `src/db/` vs `src/services/` | One query, `db/`. Several writes that must be atomic, `services/` |
| `updateMany` vs `update` | With an ownership filter both are safe. The difference is the failure signal (`count: 0` vs `P2025`) |
| `migrate dev` vs `migrate deploy` | The former builds the SQL in development, the latter only applies what was built |
| `@@unique` vs Zod `.refine()` | Only the DB rules on uniqueness atomically. Check-then-insert is pierced by races |
| `toMatchObject` vs `toBe` (the envelope) | Look only at the keys you need. Pinning the whole envelope breaks every time the seam changes |
| `afterEach(resetDb)` vs `beforeEach` | `afterEach` — it deletes the leftover rows of a failed test right there |
