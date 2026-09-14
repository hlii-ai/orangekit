<!-- orangekit-pack: backend/node-api v3.13.0 -->
# Data access — the Prisma 6 query layer (`src/db/`)

What this file owns: the PrismaClient singleton · query functions · pagination · the transaction boundary ·
running migrations. What it does not own: **table, column, and index design is canonical in the T1 data modeling card
(`.claude/rules/data-modeling.md`), which auto-loads on the `prisma/**`·`db/**` paths** —
do not copy it here. Error code detection and status mapping are in `resources/error-handling.md`, request schemas in
`resources/input-validation.md`, and app assembly and layering discipline in `resources/project-structure.md`.

> **This axis has no row-level policy engine.** The application connects to PostgreSQL over a trusted connection, so
> the `where` in this file is **the only authorization boundary.** Omit the ownership filter and there is no layer
> behind it to stop you — the omission is a data leak outright. The "the data layer is the backup, so this is defense in depth" narrative is false on this axis.

## 1. Judgment — which call do you choose

First settle **what establishes the owner**. `ownerId` comes only from a verified session (the `req.user.id` that
`requireAuth` put there). Never use an owner value read from the request body, the query string, or a header — that is a value the attacker
chooses.

| what you want to do | shape | failure signal |
| --- | --- | --- |
| list within the owner's scope | `findMany({ where: { ownerId } })` | an empty array |
| single item within the owner's scope | `findFirst({ where: { id, ownerId } })` | `null` |
| create | `create({ data: { ...input, ownerId } })` | throw (`P2002` etc.) |
| update | `updateMany` + check the affected row count | `{ count: 0 }` — **no exception** |
| delete | `deleteMany` + check the affected row count | `{ count: 0 }` — **no exception** |
| several writes atomically | `$transaction(async (tx) => …)` | rolls back on an exception |
| SQL the ORM cannot express | the `$queryRaw` tagged template | throw |

A query function **takes plain arguments only.** Take an HTTP object and testing a query starts requiring a server and
the layering collapses (§1–2 of `resources/project-structure.md`).

## 2. The client singleton (`src/db/client.ts`)

This is the **only place** in the repository where `new PrismaClient(` appears. Two instances means two connection
pools, and every pool-sizing calculation is then wrong.

<!-- file: src/db/client.ts -->
```ts
// src/db/client.ts
import { PrismaClient } from '@prisma/client';
import { env } from '../env';

export const prisma = new PrismaClient({
  datasourceUrl: env.DATABASE_URL,
  log: env.NODE_ENV === 'development' ? ['warn', 'error'] : ['error'],
});
```

The connection string comes only from `env` — open the pool with a value that was never validated at boot and the failure is pushed to
the first query (`resources/input-validation.md`). Pool size and timeouts are decided by `resources/operations.md`.

A module singleton is enough. **Confirmed by running it**: loading the same module twice, once with a static `import` and
once with a dynamic `import()`, gave `a === b` as `true`. The `globalThis` guard is an idiom of HMR runtimes that swap the
module graph while keeping the process alive; for this server, which comes up once and stays, it is needless global pollution.

## 3. Query functions (`src/db/tasks.ts`)

Ownership goes **entirely into the `where`.** The shape that reads the row and compares the owner afterwards is open to a
change in between, and if the comparison is accidentally omitted there is no signal at all.

<!-- file: src/db/tasks.ts -->
```ts
// src/db/tasks.ts
import type { Prisma, Task, TaskStatus } from '@prisma/client';
import { AppError } from '../http/app-error';
import { prisma } from './client';

const fields = { id: true, title: true, status: true, createdAt: true } satisfies Prisma.TaskSelect;
export type TaskView = Prisma.TaskGetPayload<{ select: typeof fields }>;
type Patch = Partial<Pick<Task, 'title' | 'status'>>;

export function listTasks(
  ownerId: string,
  q: { limit: number; cursor?: string; status?: TaskStatus },
): Promise<TaskView[]> {
  return prisma.task.findMany({
    where: { ownerId, ...(q.status ? { status: q.status } : {}) },
    select: fields,
    orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
    take: q.limit + 1,
    ...(q.cursor ? { cursor: { id: q.cursor }, skip: 1 } : {}),
  });
}

export function getTask(ownerId: string, id: string): Promise<TaskView | null> {
  return prisma.task.findFirst({ where: { id, ownerId }, select: fields });
}

export function insertTask(ownerId: string, input: Patch & { title: string }): Promise<TaskView> {
  return prisma.task.create({ data: { ...input, ownerId }, select: fields });
}

export async function updateTask(ownerId: string, id: string, patch: Patch): Promise<TaskView> {
  const changed = await prisma.task.updateMany({ where: { id, ownerId }, data: patch });
  if (changed.count === 0) throw new AppError('NOT_FOUND', 'Task not found');
  const view = await getTask(ownerId, id);
  if (!view) throw new AppError('NOT_FOUND', 'Task not found');
  return view;
}

export async function deleteTask(ownerId: string, id: string): Promise<void> {
  const removed = await prisma.task.deleteMany({ where: { id, ownerId } });
  if (removed.count === 0) throw new AppError('NOT_FOUND', 'Task not found');
}
```

The `q` of `listTasks` is shaped to take `TaskQuery` (`resources/input-validation.md`) as-is —
the fields the schema parses (`limit`·`cursor`·`status`) are reflected **both in the argument type and in the `where`.**
Because typing is structural, `TaskQuery` still fits an argument type that is missing a field, and it compiles:
a missing filter is not a type error but **a condition that is silently ignored.** Confirmed by running it: passing `status: 'done'`
returned 1 completed item, `'open'` returned 1 open item, and omitting it returned 2.

In `insertTask`, **`ownerId` comes after the spread.** Swap the order and an `ownerId` carried in the request body
overwrites the session value. Measured (against a real DB): `{ ...body, ownerId }` stored `alice` while
`{ ownerId, ...body }` stored `attacker`. The syntax passes either way.

## 4. A mutation checks the affected row count

A mutation carrying an ownership filter **ends with 0 rows changed and no exception** against someone else's row. Without the check,
the router returns a 200 and the caller believes the update happened.

Measured on PostgreSQL — touching `bob`'s row as `alice`:

| call | the SQL Prisma sent | result |
| --- | --- | --- |
| `updateMany({ where: { id, ownerId } })` | `UPDATE … WHERE "id" = $1 AND "ownerId" = $2` | `{ count: 0 }`, no exception, the victim row untouched |
| `update({ where: { id, ownerId } })` | the same WHERE + `RETURNING` | throws `P2025` |
| `deleteMany({ where: { id, ownerId } })` | `DELETE … WHERE "id" = $1 AND "ownerId" = $2` | `{ count: 0 }`, no exception |

Both are safe at the DB level — the difference is only **the failure signal**. `updateMany`/`deleteMany` are the quiet
side, so always look at `count`. If you are going to use `update`/`delete`, catch `P2025` with `isRecordNotFound`
and normalize it to `NOT_FOUND` (`resources/error-handling.md`).

**The response for someone else's row is a 404.** Return a 403 and you are telling them "that id exists", and
an unauthorized user can sweep ids to enumerate which resources exist. That is why the functions above throw the same
`NOT_FOUND` for absence and for lack of permission.

## 5. Narrow the columns, and fetch relations in one go

Omit `select` and every column comes back. On a model with secrets, hashes, or internal flags, that becomes a path
straight into the logs and the response. It is also why the `fields` constant above leaves out `ownerId` —
there is no reason to put the owner identifier into the response envelope.

Query a relation inside a loop and the queries grow with the row count. **Measured (10 rows)**: 1 list + 10 loop
iterations = **11 queries**, a nested `select` = **2 queries**, and `_count` when only the count is needed = **1 query**.

```ts
// src/db/tasks.ts — relation loading (extend fields only when you need it)
// ✅ nested select — one query per relation level, and the columns stay narrow
const withComments = await prisma.task.findMany({
  where: { ownerId },
  select: { id: true, title: true, comments: { select: { id: true, body: true } } },
});

// ✅ if you only need the count, do not fetch the relation rows
const withCounts = await prisma.task.findMany({
  where: { ownerId },
  select: { id: true, title: true, _count: { select: { comments: true } } },
});
```

The nested `select` is 2 queries rather than 1 because Prisma reads by default with a query per relation level rather than
a JOIN. The point is that it does not scale with the row count.

## 6. Cursor pagination

With `skip` (an offset) the DB actually reads and discards the skipped rows, so later pages slow down linearly, and an insert or
delete in between makes rows duplicate or vanish. A cursor resumes reading **from a position in the sort key.**

Take one extra row with `take: limit + 1` to learn whether there is a next page — that removes the separate `count` query.

```ts
// src/services/task-service.ts — the consumer side of listTasks
const rows = await listTasks(user.id, { limit, cursor });
const hasMore = rows.length > limit;
const items = hasMore ? rows.slice(0, limit) : rows;
const nextCursor = hasMore ? items[items.length - 1].id : null;
```

The sort key has to be a **total order**. `createdAt` alone is not enough — measured, 6 rows created back to back
had the same millisecond value, and the row order within a tie depends on the execution plan. Put a unique column (`id`) in as the
secondary key to make it a total order, and build the index in the same order (`@@index([ownerId, createdAt, id])` — the design
itself is canonical in the T1 data modeling card).

## 7. The transaction boundary (`src/services/`)

A transaction is opened by **the service**, not by a query function. Let each query function open its own and they nest when you
compose two of them, and the boundary starts depending on call order.

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

**Confirmed by running it**: when the callback threw, the `create` inside it was rolled back (row count 5 → 5). When passing the
transaction to a helper, the argument type is `Prisma.TransactionClient` — typed as `PrismaClient` it still compiles, but
types no longer stop the mistake of the helper using a connection outside the transaction.

Do not make an HTTP call or publish to a queue inside a transaction. Those side effects do not come back on a rollback, and
the lock only lengthens while you wait for the external response. Do it after the commit.

## 8. Running migrations (`prisma/migrations/`)

| situation | command | notes |
| --- | --- | --- |
| schema change during development | `npx prisma migrate dev --name <change>` | generates the SQL file, applies it, and runs `generate` too |
| deployment | `npx prisma migrate deploy` | run it **as a step separate from application boot** |
| regenerate only the client types | `npx prisma generate` | start here when types stop matching after a schema change |

**Confirmed by running it**: `migrate dev --name init` created and applied
`prisma/migrations/<timestamp>_init/migration.sql` and then regenerated the client.

Do not call `migrate deploy` from boot. When several instances come up at once they race to apply the same migration,
and a failed migration leaves the app unable to boot. `db push` leaves no migration file, so do not use it in a shared
environment — there is no record to reverse.

## Misuse list ① — old Prisma idioms → Prisma 6

| old habit | current shape (Prisma 6) |
| --- | --- |
| intercepting queries with `prisma.$use(middleware)` <!-- verified: ran Prisma 6.19.3 — typeof prisma.$use === 'undefined' --> | there is no `$use`. Use `prisma.$extends({ query: … })` |
| `findFirst({ …, rejectOnNotFound: true })` <!-- verified: ran Prisma 6.19.3 — PrismaClientValidationError --> | the option was removed. `findFirstOrThrow` / `findUniqueOrThrow` |
| `datasources: { db: { url } }` <!-- verified: ran Prisma 6.19.3 — queries still ran with the old shape --> | write it as the single line `datasourceUrl: url` (the old shape still works) |
| building a string and passing it to `$queryRawUnsafe` | the tagged template `$queryRaw` — values are bound as parameters. Measured: putting `alice' OR '1'='1` in `ownerId` returned 0 rows |
| `findUnique({ where: { id } })` then `if (row.ownerId !== me)` | put ownership in the `where`. <!-- verified: ran Prisma 6.19.3 — the ownerId condition rode along in the SQL and the result was null --> The extended whereUnique also allows `findUnique({ where: { id, ownerId } })`, but this pack standardizes on `findFirst` |
| paging with `skip: (page - 1) * size` | cursor pagination (`cursor` + `skip: 1`) |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `updateMany` vs `update` | with an ownership filter both are safe. The difference is the failure signal — `updateMany` is quiet with `{ count: 0 }` while `update` throws `P2025`. If you are not going to look at `count`, do not use `updateMany` |
| `findFirst` vs `findUnique` | `findFirst` when searching by a non-unique condition (`ownerId`) alone. The `where` of `findUnique` **must** include a unique key (type check: `{ id: string } & TaskWhereInput`) |
| `select` vs `include` | `select` to narrow columns. `include` is every column of the body plus the relation, so secret columns ride along |
| `$transaction([...])` vs `$transaction(async tx => …)` | the former for a bundle of mutually independent queries (sequential execution, one transaction). The latter when an intermediate result decides the next query |
| `count` vs `_count` | `prisma.task.count()` to count rows only. `select: { _count: … }` to attach a relation count to each parent row |
| `upsert` vs `create` then handling `P2002` | `upsert` when there is a unique constraint and "update if it exists" is the intent. `create` + `isUniqueViolation` when a duplicate **has to be reported as an error** |
| `deleteMany({})` vs individual deletes | an empty `where` erases the whole table. Do not use it outside test cleanup (`resetDb`) |
