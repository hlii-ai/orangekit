<!-- orangekit-seam: react-vite+aws-container/backend v3.35.0 -->
# Complete example — one full lap around the `tasks` resource

Migration → schema → query → service → handler → test, driven through **a single domain** (a new resource follows this order too).
The goal: a signed-in user lists their own tasks (cursor · `?status=`), creates, updates (including the `open`↔`done` transition) and deletes them, and titles are unique per owner.

## 1. Define the schema → generate the migration

```ts
// src/db/schema.ts
import { index, pgEnum, pgTable, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core'

export const taskStatus = pgEnum('task_status', ['open', 'done'])   // the create default is open
export const tasks = pgTable('tasks', {
  id: uuid('id').primaryKey().defaultRandom(),
  ownerId: text('owner_id').notNull(),
  title: text('title').notNull(),
  body: text('body').notNull().default(''),
  status: taskStatus('status').notNull().default('open'),
  archivedAt: timestamp('archived_at', { withTimezone: true }),      // null = active
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (t) => [
  index('tasks_owner_created_idx').on(t.ownerId, t.createdAt, t.id),  // covers the whole sort key
  uniqueIndex('tasks_owner_title_key').on(t.ownerId, t.title),
])

export type Task = typeof tasks.$inferSelect
export type NewTask = typeof tasks.$inferInsert
```

Design decisions (normalization, keys, index composition) follow `.claude/rules/data-modeling.md`, and the canonical schema
(including `tags`) follows `resources/data-access.md`.

```bash
docker compose up -d --wait db
npx drizzle-kit generate      # → drizzle/0001_wild_tasks.sql
```

```sql
-- drizzle/0001_wild_tasks.sql  (generated — read and review it. Never write it by hand first)
CREATE TYPE "public"."task_status" AS ENUM('open', 'done');--> statement-breakpoint
CREATE TABLE "tasks" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "owner_id" text NOT NULL,
  "title" text NOT NULL,
  "body" text DEFAULT '' NOT NULL,
  "status" "task_status" DEFAULT 'open' NOT NULL,
  "archived_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "tasks_owner_created_idx" ON "tasks" USING btree ("owner_id","created_at","id");
CREATE UNIQUE INDEX "tasks_owner_title_key" ON "tasks" USING btree ("owner_id","title");
```

```bash
npx drizzle-kit migrate       # apply locally → the integration tests use this same SQL
```

## 2. Request schemas (Zod)

The canonical definition is `src/schemas/tasks.ts` in `resources/input-validation.md`. The shape this example uses:

```ts
// src/schemas/tasks.ts
import { z } from 'zod'

export const TaskIdParam = z.object({ id: z.uuid() })

const TaskStatus = z.enum(['open', 'done'])
const TaskFields = z.strictObject({              // the definition without defaults is the original
  title: z.string().trim().min(1).max(120),
  body: z.string().max(20_000),
  status: TaskStatus,
})
export const CreateTaskInput = TaskFields.extend({ body: TaskFields.shape.body.default(''), status: TaskStatus.default('open') })
export const UpdateTaskInput = TaskFields.partial().refine(     // ← not Create.partial()
  (v) => Object.keys(v).length > 0, { error: 'At least one field to change is required' },
)
export const ListTasksQuery = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(20),
  cursor: z.string().max(200).optional(),
  archived: z.stringbool().optional(),
  status: TaskStatus.optional(),                // ?status=open|done, unset = any status
})

export type CreateTaskInput = z.infer<typeof CreateTaskInput>
export type UpdateTaskInput = z.infer<typeof UpdateTaskInput>
export type ListTasksQuery = z.infer<typeof ListTasksQuery>
```

Building it with `CreateTaskInput.partial()` keeps `.default()` alive, so a `{ title: 'x' }` PATCH parses as `{ title: 'x', body: '', status: 'open' }`
→ and `set({ ...patch })` **wipes the body and reopens a completed task.** A status-transition `{ status }` PATCH is taken by the same schema too.

## 3. Queries — every function takes `ownerId`

```ts
// src/db/queries/tasks.ts
import { and, desc, eq, isNotNull, isNull, sql } from 'drizzle-orm'
import { db } from '@/db/client'
import { tasks, type Task } from '@/db/schema'
import type { CreateTaskInput, UpdateTaskInput } from '@/schemas/tasks'

export type Cursor = { createdAt: Date; id: string }

export async function insertTask(ownerId: string, input: CreateTaskInput) {
  // put ownerId last — put it first and a same-named key in input overwrites it
  const [row] = await db.insert(tasks).values({ ...input, ownerId }).returning()
  return row
}
export async function findOwnedTask(ownerId: string, id: string) {
  const [row] = await db.select().from(tasks)
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId))).limit(1)
  return row ?? null
}
export async function listOwnedTasks(
  ownerId: string, limit: number, cursor?: Cursor, archived?: boolean, status?: Task['status'],
) {
  return db.select().from(tasks)
    .where(and(
      eq(tasks.ownerId, ownerId),
      cursor ? sql`(${tasks.createdAt}, ${tasks.id}) < (${cursor.createdAt}, ${cursor.id})`
             : undefined,
      archived ? isNotNull(tasks.archivedAt) : isNull(tasks.archivedAt),   // unspecified = active only
      status ? eq(tasks.status, status) : undefined,                       // unspecified = any status
    ))
    .orderBy(desc(tasks.createdAt), desc(tasks.id))
    .limit(limit + 1)                       // one extra row to tell whether a next page exists
}
// opening the patch type to Partial<NewTask> lets patch.ownerId ride along and transfer ownership
export async function updateOwnedTask(ownerId: string, id: string, patch: UpdateTaskInput) {
  const [row] = await db.update(tasks).set({ ...patch, updatedAt: new Date() })
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId))).returning()
  return row ?? null                        // null = absent or not mine
}
export async function deleteOwnedTask(ownerId: string, id: string) {
  const rows = await db.delete(tasks)
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId))).returning({ id: tasks.id })
  return rows.length                        // 0 = absent or not mine
}
```

## 4. Service — domain rules and failure mapping

```ts
// src/services/tasks.ts
import { AppError } from '@/http/errors'
import { isUniqueViolation } from '@/db/errors'
import * as q from '@/db/queries/tasks'
import type { CreateTaskInput, ListTasksQuery, UpdateTaskInput } from '@/schemas/tasks'

const encodeCursor = (n: { createdAt: Date; id: string }) =>
  Buffer.from(`${n.createdAt.toISOString()}|${n.id}`).toString('base64url')

function decodeCursor(raw?: string): q.Cursor | undefined {
  if (!raw) return undefined
  const [iso, id] = Buffer.from(raw, 'base64url').toString('utf8').split('|')
  const createdAt = new Date(iso ?? '')
  if (Number.isNaN(createdAt.getTime()) || !id) throw new AppError(400, 'VALIDATION_FAILED', 'bad cursor')
  return { createdAt, id }
}

export async function listTasks(ownerId: string, query: ListTasksQuery) {
  const rows = await q.listOwnedTasks(ownerId, query.limit, decodeCursor(query.cursor), query.archived, query.status)
  const hasMore = rows.length > query.limit
  const items = hasMore ? rows.slice(0, query.limit) : rows
  return { items, nextCursor: hasMore ? encodeCursor(items[items.length - 1]!) : null }
}

export async function createTask(ownerId: string, input: CreateTaskInput) {
  try {
    return await q.insertTask(ownerId, input)
  } catch (err) {
    if (isUniqueViolation(err, 'tasks_owner_title_key')) {
      throw new AppError(409, 'CONFLICT', 'A task with the same title already exists')
    }
    throw err                                  // an unknown failure is not swallowed
  }
}

const notFound = () => new AppError(404, 'NOT_FOUND', 'Task not found')   // absent = unauthorized

export async function getTask(ownerId: string, id: string) {
  const task = await q.findOwnedTask(ownerId, id)
  if (!task) throw notFound()
  return task
}
export async function updateTask(ownerId: string, id: string, patch: UpdateTaskInput) {
  const updated = await q.updateOwnedTask(ownerId, id, patch)
  if (!updated) throw notFound()               // never answer 0 rows with success
  return updated
}
export async function deleteTask(ownerId: string, id: string) {
  if ((await q.deleteOwnedTask(ownerId, id)) === 0) throw notFound()
}
```

## 5. Routes and wiring

```ts
// src/routes/tasks.ts
import { Hono } from 'hono'
import { jsonBody, pathParam, queryParams } from '@/http/validate'
import { CreateTaskInput, ListTasksQuery, TaskIdParam, UpdateTaskInput } from '@/schemas/tasks'
import * as tasks from '@/services/tasks'
import type { AppEnv } from '@/http/types'

export const tasksRoutes = new Hono<AppEnv>()

tasksRoutes.get('/', async (c) => {
  const page = await tasks.listTasks(c.get('user').sub, queryParams(c, ListTasksQuery))
  return c.json({ data: page.items, nextCursor: page.nextCursor })
})
tasksRoutes.post('/', async (c) => {
  const created = await tasks.createTask(c.get('user').sub, await jsonBody(c, CreateTaskInput))
  return c.json({ data: created }, 201)
})
tasksRoutes.get('/:id', async (c) => {
  const { id } = pathParam(c, TaskIdParam)
  return c.json({ data: await tasks.getTask(c.get('user').sub, id) })
})
tasksRoutes.patch('/:id', async (c) => {
  const { id } = pathParam(c, TaskIdParam)
  const patch = await jsonBody(c, UpdateTaskInput)
  return c.json({ data: await tasks.updateTask(c.get('user').sub, id, patch) })
})
tasksRoutes.delete('/:id', async (c) => {
  const { id } = pathParam(c, TaskIdParam)
  await tasks.deleteTask(c.get('user').sub, id)
  return c.body(null, 204)
})
```

In `src/app.ts`, mount it with `app.route('/api/tasks', tasksRoutes)` **on the line after**
`app.use('/api/*', requireAuth)` (only the public route `/api/auth` goes before it).
Hono runs in registration order, so inverting the order publishes this resource without authentication.

## 6. Tests

Layer 2 (the handler: parsing · error envelope · auth branching) is written with `app.request()` (`resources/testing.md`).
What is shown here is the more important layer 3: **ownership isolation is proved only by real SQL.**

```ts
// tests/integration/tasks.test.ts  (layer 3: a real DB)
import { describe, expect, it } from 'vitest'
import { createTask, getTask, listTasks, updateTask, deleteTask } from '@/services/tasks'

const ALICE = '11111111-1111-1111-1111-111111111111'
const BOB = '22222222-2222-2222-2222-222222222222'

describe('the tasks service', () => {
  it('only the owner reads a task they created', async () => {
    const created = await createTask(ALICE, { title: 'Meeting notes', body: '', status: 'open' })
    await expect(getTask(ALICE, created.id)).resolves.toMatchObject({ title: 'Meeting notes' })
    await expect(getTask(BOB, created.id)).rejects.toMatchObject({ status: 404 })
  })
  it("updating or deleting someone else's task is a 404 (0 rows is never answered as success)", async () => {
    const created = await createTask(ALICE, { title: 'Private memo', body: '', status: 'open' })
    await expect(updateTask(BOB, created.id, { status: 'done' })).rejects.toMatchObject({ status: 404 })
    await expect(deleteTask(BOB, created.id)).rejects.toMatchObject({ status: 404 })
    await expect(getTask(ALICE, created.id)).resolves.toMatchObject({ status: 'open' })   // it is still there
  })
  it('a PATCH that changes only the title does not wipe the body or status, and the ?status= filter returns only that status', async () => {
    const created = await createTask(ALICE, { title: 'Draft', body: 'body that must survive', status: 'open' })
    await updateTask(ALICE, created.id, { status: 'done' })
    const updated = await updateTask(ALICE, created.id, { title: 'Revised' })
    expect(updated.body).toBe('body that must survive')     // with Create.partial() this becomes '' here
    expect(updated.status).toBe('done')            // if the default survived, this would revert to 'open' here
    const ids = async (status: 'open' | 'done') => (await listTasks(ALICE, { limit: 100, status })).items.map((t) => t.id)
    expect(await ids('done')).toContain(created.id)
    expect(await ids('open')).not.toContain(created.id)
  })
  it('a duplicate title for the same owner is a 409', async () => {
    await createTask(ALICE, { title: 'Duplicate', body: '', status: 'open' })
    await expect(createTask(ALICE, { title: 'Duplicate', body: '', status: 'open' }))
      .rejects.toMatchObject({ status: 409, code: 'CONFLICT' })
  })
})
```

The third test catches the regression that breaks most often in this example: if a default survives in the PATCH schema,
**every partial update quietly becomes a full overwrite.** The manual curl smoke check and the container
build and deployment order are in `resources/deployment-and-operations.md`.

## Misuse list — where copying this example breaks

| Commonly gone wrong while copying | The form to keep |
| --- | --- |
| Reusing a query function with the `ownerId` argument removed | The first argument `ownerId` is part of the signature. Remove it and the boundary is gone |
| Not checking the `.returning()` result in the service | `null`/`0` means 404. Returning 204 without checking makes a call with someone else's id succeed |
| Implementing the duplicate check as `select` then `insert` | Two concurrent requests both pass. Use a unique index + `23505` → 409 |
| Returning a list without `limit` | Keep the `limit + 1` pattern. An unbounded list times out as rows grow |
| Letting the client specify `id` | `defaultRandom()` makes it. Do not put `id` in the input schema (`strictObject` rejects it) |
| Not updating `updatedAt` | `set({ ...patch, updatedAt: new Date() })` — a default applies to inserts only |
| Decoding the cursor without validation | Reject a corrupted cursor with 400. Passing `new Date(undefined)` straight through empties the query silently |
| Mounting a protected route before `requireAuth` | `c.get('user')` becomes `undefined` and the route is published without auth (conversely, `/api/auth` belongs before it) |
| Writing the PATCH schema as `Create.partial()` | A surviving `.default()` overwrites unspecified fields (`status` reverts to `open`) → derive it from a base without defaults |
| Writing SQL or permission branches directly in the handler | A handler does parsing · calling · status code only. Rules go in the service, SQL in the query module |
