<!-- orangekit-pack: backend/node-nest v3.16.0 -->
# Data access — ownership is a fetch condition

This file owns **queries and their safety**. Table definitions and connection options belong to `data-modeling.md`,
request shapes to `input-validation.md`, and the status code of a failure to `error-handling.md`.

This axis has **no row-level policy engine.** The application attaches to the DB over a trusted connection, so
a query that omits the ownership filter does not get slower — it **returns someone else's rows.**

## 1. Choosing a read API

| need | method | watch out |
| --- | --- | --- |
| List | `find({ where, select, order, take })` | An array `where` is an **OR** (§3) |
| Single row | `findOne({ where, select })` | `null` when absent. `findOneOrFail` throws |
| Existence | `existsBy(where)` | Does not fetch the row |
| Count | `countBy(where)` | Alongside a list, `findAndCount` |
| Create | `create(...)` → `save(...)` | `create` builds **only an in-memory instance**. `save` is the INSERT |
| Partial update | `update(where, patch)` | Does not load the entity. Look at `affected` (§4) |
| Delete | `delete(where)` | Same |

`save(entity)` is an UPDATE when the id is present and an INSERT when it is not — **no ownership check attaches.**
So every update and delete in this pack is `update`/`delete` + `where`, and `save` is used only for creation.

## 2. A Repository is obtained only through DI (`src/tasks/tasks.service.ts`)

<!-- file: src/tasks/tasks.service.ts -->
```ts
import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { DataSource, FindOptionsWhere, In, LessThan, Repository } from 'typeorm';
import { AppError } from '../common/app-error';
import { decodeCursor } from './cursor';
import { CreateTaskDto } from './dto/create-task.dto';
import { ListTasksQueryDto } from './dto/list-tasks.query.dto';
import { UpdateTaskDto } from './dto/update-task.dto';
import { Task } from './task.entity';
import { TASK_VIEW, TaskView } from './task.view';

@Injectable()
export class TasksService {
  constructor(
    @InjectRepository(Task) private readonly tasks: Repository<Task>,
    private readonly dataSource: DataSource,
  ) {}

  async list(ownerId: string, q: ListTasksQueryDto): Promise<TaskView[]> {
    const base: FindOptionsWhere<Task> = { ownerId, ...(q.status ? { status: q.status } : {}) };
    let where: FindOptionsWhere<Task>[] = [base];
    if (q.cursor) {
      const c = decodeCursor(q.cursor);
      where = [
        { ...base, createdAt: LessThan(c.createdAt) },
        { ...base, createdAt: c.createdAt, id: LessThan(c.id) },
      ];
    }
    return this.tasks.find({
      where,
      select: TASK_VIEW,
      order: { createdAt: 'DESC', id: 'DESC' },
      take: q.limit,
    });
  }

  async get(ownerId: string, id: string): Promise<TaskView | null> {
    return this.tasks.findOne({ where: { id, ownerId }, select: TASK_VIEW });
  }

  async create(ownerId: string, dto: CreateTaskDto): Promise<TaskView> {
    const saved = await this.tasks.save(this.tasks.create({ ...dto, ownerId }));
    return { id: saved.id, title: saved.title, status: saved.status, createdAt: saved.createdAt };
  }

  async update(ownerId: string, id: string, patch: UpdateTaskDto): Promise<TaskView> {
    const res = await this.tasks.update({ id, ownerId }, patch);
    if (res.affected === 0) throw new AppError('NOT_FOUND', 'Task not found');
    const after = await this.get(ownerId, id);
    if (!after) throw new AppError('NOT_FOUND', 'Task not found');
    return after;
  }

  async remove(ownerId: string, id: string): Promise<void> {
    const res = await this.tasks.delete({ id, ownerId });
    if (res.affected === 0) throw new AppError('NOT_FOUND', 'Task not found');
  }

  async closeAll(ownerId: string, ids: string[]): Promise<number> {
    return this.dataSource.transaction(async (manager) => {
      const res = await manager.getRepository(Task).update({ id: In(ids), ownerId }, { status: 'done' });
      if (res.affected !== ids.length) throw new AppError('NOT_FOUND', 'Some tasks were not found');
      return res.affected ?? 0;
    });
  }
}
```

`@InjectRepository(Task)` is the sole procurement path. A service that builds
`dataSource.getRepository(Task)` into a field itself **removes the place a test would slot a
double** — because there is nothing left for `getRepositoryToken(Task)` to override
(`testing.md` §2). The exception is inside a transaction, and the reason is in §7.

**A service does not take `Request` or `Response`.** That the first argument is always `ownerId` is
a contract, not a convention — a caller that does not pull out the principal and pass it will not compile.

## 3. An array `where` is an OR — repeat ownership on every branch

<!-- verified: typeorm@1.1.0 + PostgreSQL 18.4, run — reading with the ❌ form below mixed in rows of another owner (B) for a total of 8 -->
This was confirmed with 5 rows owned by A and 3 owned by B in the list.

```ts
// src/tasks/tasks.service.ts
// ❌ The second branch has no ownerId — that branch passes another user's rows through wholesale
const leaked = await this.tasks.find({
  where: [{ ownerId, createdAt: LessThan(c.createdAt) }, { status: 'open' }],
});
// ✅ Repeat ownership on every branch (spreading base in is the device that does it)
const rows = await this.tasks.find({
  where: [{ ...base, createdAt: LessThan(c.createdAt) }, { ...base, createdAt: c.createdAt, id: LessThan(c.id) }],
});
```

**The policy regex does not catch this defect.** `ownership-in-query` only looks at "is `ownerId` in
the `where` at least once", so the ❌ above passes too. That is why `policies.md` put this item under
"for humans to keep" — knowing where the machine cannot see is the purpose of that list.

## 4. A mutation checks the affected row count

<!-- verified: typeorm@1.1.0 + PostgreSQL 18.4, run — an update against a row owned by someone else came back with affected = 0 and succeeded without an exception -->
An `update` or `delete` carrying an ownership filter **silently succeeds against another user's row.** No row
changed, and that is not an error. Unchecked, a 200 goes out and the client believes the update happened.

```ts
// src/tasks/tasks.service.ts
// ❌ Read as success — against someone else's row nothing changed, yet a 200 goes out
await this.tasks.update({ id, ownerId }, patch);
// ✅ The affected row count is the existence-and-ownership verdict
const res = await this.tasks.update({ id, ownerId }, patch);
if (res.affected === 0) throw new AppError('NOT_FOUND', 'Task not found');
```

`UpdateResult.affected` is `number | undefined` and `DeleteResult.affected` is
`number | null | undefined` — which is why the `=== 0` comparison is the safe form. Written as `> 0`,
`undefined` reads as failure and a legitimate mutation becomes a 404.

**It is a 404, not a 403.** Give a 403 to a request pointing at someone else's row and an id sweep can
enumerate which resources exist (`error-handling.md` §5).

## 5. Cursor pagination

<!-- verified: PostgreSQL 18.4, run — paging 5 rows at limit 2 over 3 requests returned exactly 5, and two rows sharing a timestamp sorted stably in reverse id order -->
Offset pagination skips or repeats rows once an insert or delete happens on an earlier page.
A cursor takes "the last row seen" as its reference and does not have that problem.

```ts
// src/tasks/cursor.ts — carry every sort key in the cursor
// (carry only createdAt and the order collapses among rows sharing a timestamp)
const where = [
  { ...base, createdAt: LessThan(c.createdAt) },
  { ...base, createdAt: c.createdAt, id: LessThan(c.id) },
];
```

The ordering must be `order: { createdAt: 'DESC', id: 'DESC' }` — **the same order as the cursor's two
columns**. Let one of them diverge and rows leak or repeat at the page boundary.

<!-- file: src/tasks/cursor.ts -->
```ts
import { AppError } from '../common/app-error';
import { TaskView } from './task.view';

export function encodeCursor(t: TaskView): string {
  return Buffer.from(`${t.createdAt.toISOString()}|${t.id}`, 'utf8').toString('base64url');
}

export function decodeCursor(raw: string): { createdAt: Date; id: string } {
  const [ts, id] = Buffer.from(raw, 'base64url').toString('utf8').split('|');
  const createdAt = new Date(ts ?? '');
  if (!id || Number.isNaN(createdAt.getTime())) {
    throw new AppError('VALIDATION_FAILED', 'Malformed cursor', { cursor: ['Malformed'] });
  }
  return { createdAt, id };
}
```

**Time precision becomes a problem here.** `toISOString()` writes only to milliseconds, so if the column
stores microseconds the value is truncated in the round trip and rows in that interval are skipped. The remedy
is on the column side, not the cursor side — `precision: 3` in `data-modeling.md` §2 is that remedy.

## 6. `select` narrows the value only — the type stays

<!-- verified: typeorm@1.1.0, run — on an object fetched with select: TASK_VIEW the ownerId key existed and its value was undefined -->

```ts
// src/tasks/tasks.service.ts
// ❌ It compiles. The runtime value is undefined — riding in the envelope it becomes a silently wrong response
const t = await this.tasks.findOne({ where: { id, ownerId }, select: TASK_VIEW });
return { owner: t!.ownerId };
// ✅ Declare the return type as TaskView — touching an unselected column then fails to compile
async get(ownerId: string, id: string): Promise<TaskView | null> { /* ... */ }
```

TypeORM hands back the entity type even for a result narrowed by `select`. **The type system knows
nothing about this narrowing**, which is the quietest trap on this axis, and the only defense is pinning
the service method's return type to `TaskView`.

## 7. Transaction boundaries

```ts
// src/tasks/tasks.service.ts
// ✅ Inside a transaction, use the Repository the manager hands you — the injected one is outside that transaction
return this.dataSource.transaction(async (manager) => {
  const res = await manager.getRepository(Task).update({ id: In(ids), ownerId }, { status: 'done' });
  if (res.affected !== ids.length) throw new AppError('NOT_FOUND', 'Some tasks were not found');
  return res.affected ?? 0;
});
```

**Use the injected Repository inside a transaction and that query runs outside it** — it survives a rollback.
This is the one place where "a Repository only through DI" from §2 has an exception.

**Do not make external calls (HTTP, queue, mail) inside a transaction.** They do not roll back, and the lock only grows longer.
Call them outside, after confirming the commit.

## Misuse list ① — Prisma/ActiveRecord idiom → TypeORM 1.x form

Half the people arriving on this axis come from another ORM. Only the lookalikes that mean something different are listed.

| old habit | current form (TypeORM 1.x) |
| --- | --- |
| `prisma.task.findUnique({ where: { id } })` | `findOne({ where: { id, ownerId } })` — you can add conditions regardless of uniqueness |
| `findMany({ where: { OR: [...] } })` | `find({ where: [ ... ] })` — **the array itself is the OR** |
| An exception when `update({ where, data })` finds nothing | `update(where, patch)` throws nothing. Look at `affected` |
| `select: { id: true }` narrowing the type | It does not narrow. Declare the return type by hand (§6) |
| Paging with `take`/`skip` | `skip` is an offset. This pack uses a cursor (§5) |
| A `$transaction([...])` array | `dataSource.transaction(async (manager) => ...)` — use `manager` inside the callback |
| `task.save()` (ActiveRecord) | `repo.save(task)`. Do not hang methods on an entity |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `create()` vs `save()` | `create` only builds the instance (no query). `save` is what puts it in the DB |
| `save()` vs `update()` | Use `save` for an update and there is nowhere to attach the ownership condition. A partial update is always `update(where, patch)` |
| `findOne` vs `findOneOrFail` | The latter throws `EntityNotFoundError` — leave that exception alone and a 500 goes out. This pack standardizes on `findOne` + a `null` check |
| `where: { a, b }` vs `where: [{ a }, { b }]` | The first is AND, the second OR. Get it wrong and ownership is disabled wholesale |
| `In([])` (empty array) | An empty array matches no row. Check the length before the call |
| `delete()` vs `softDelete()` | The latter needs a `@DeleteDateColumn`. Without it the column is missing and the query fails |
