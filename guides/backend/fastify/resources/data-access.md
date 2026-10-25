<!-- orangekit-pack: backend/fastify v3.36.0 -->
# Data access — Drizzle queries and the ownership condition

This file owns the three files under `src/db/` (pool · table · queries) and how transactions and migrations run.
Table design principles (normalization · index choice) belong to the T1 data modeling card, and the routes that
call the queries are owned by `resources/api-endpoints.md`. The auth tables (`users` · `refresh_tokens`) exist only
when self-issued auth is used, and `resources/auth-boundaries.md` owns them.

## 1. Decision tree — which query shape to use

| situation | shape | why |
| --- | --- | --- |
| single-table CRUD (this pack's default) | `db.select(view).from(tasks).where(...)` | only the selected columns remain in the type |
| updates and deletes under ownership | `update/delete ... .where(and(id, owner))` + affected row count | against someone else's row it silently succeeds with 0 rows (§4) |
| several writes atomically | `db.transaction(async (tx) => ...)` | inside the callback it is **`tx` throughout** (§6) |
| SQL the builder cannot express | tagged `` sql`…` `` | values go out as parameters. `sql.raw` is forbidden (policy `no-sql-raw`) |

## 2. The pool and the client (`src/db/client.ts`)

There is **one** pool in the repository. It is exported as a module rather than `decorate`d onto the app
instance — the layering holds only if query functions do not take a `FastifyInstance` (policy
`db-layer-knows-no-http`).

<!-- file: src/db/client.ts -->
```ts
// src/db/client.ts
import { drizzle } from 'drizzle-orm/node-postgres'
import { Pool } from 'pg'
import { env } from '../env'
import * as schema from './schema'

export const pool = new Pool({ connectionString: env.DATABASE_URL, max: env.DB_POOL_MAX })
export const db = drizzle(pool, { schema })
```

Do not put `pool.end()` in an `onClose` hook of `buildApp`. When tests build and close the app several times, every
app from the second onward uses a closed pool — shutdown is done by `shutdown` in `operations.md`, **after** the app
is closed.

## 3. The table definition (`src/db/schema.ts`)

<!-- file: src/db/schema.ts -->
```ts
// src/db/schema.ts
import { index, pgEnum, pgTable, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core'

export const taskStatus = pgEnum('task_status', ['open', 'done'])

export const tasks = pgTable('tasks', {
  id: uuid('id').primaryKey().defaultRandom(),   // the choice for a new project — if the existing tables use serial, follow that
  ownerId: text('owner_id').notNull(),
  title: text('title').notNull(),
  status: taskStatus('status').notNull().default('open'),
  // precision 3 — a JS Date holds only milliseconds. Leftover µs drop rows on the cursor round trip
  createdAt: timestamp('created_at', { withTimezone: true, precision: 3 }).notNull().defaultNow(),
}, (t) => [
  index('tasks_owner_created_idx').on(t.ownerId, t.createdAt, t.id),
  uniqueIndex('tasks_owner_title_uq').on(t.ownerId, t.title),
])

export type TaskRow = typeof tasks.$inferSelect
```

The index `(owner_id, created_at, id)` matches the list query in §5 **down to the column order** — narrow by owner,
walk by the sort key. The unique `(owner_id, title)` makes the 409 path real (`error-handling.md`).

## 4. Query functions (`src/db/tasks.ts`)

The first argument of every function is `ownerId` — **with two arguments of the same type (`string`), calling them
in swapped order slips past the type checker.** That is why the shape column in the ledger pins the order.

<!-- file: src/db/tasks.ts -->
```ts
// src/db/tasks.ts
import { and, desc, eq, lt, or } from 'drizzle-orm'
import { z } from 'zod'
import { AppError } from '../http/app-error'
import type { TaskCreate, TaskQuery, TaskUpdate, TaskView } from '../schemas/task'
import { db } from './client'
import { tasks } from './schema'

// Do not select ownerId — even though the response schema filters it, the data layer does not carry it in the first place
const view = { id: tasks.id, title: tasks.title, status: tasks.status, createdAt: tasks.createdAt }

// Cursor = createdAt (ISO) + '_' + id. Even with rows at the same instant, id settles the order
// Validate each part against the type and range the DB accepts — let it through and PG throws 22P02/22008, which becomes a 500
function decodeCursor(cursor: string): { at: Date; id: string } {
  const sep = cursor.lastIndexOf('_')
  const raw = cursor.slice(0, sep)
  const at = new Date(raw)
  const id = cursor.slice(sep + 1)
  const year = at.getUTCFullYear()
  if (sep < 1 || Number.isNaN(at.getTime()) || at.toISOString() !== raw || year < 1970 || year > 9999
    || !z.uuid().safeParse(id).success) {
    throw new AppError('VALIDATION_FAILED', 'Invalid cursor', { cursor: ['Malformed value'] })
  }
  return { at, id }
}

export function encodeCursor(row: Pick<TaskView, 'createdAt' | 'id'>): string {
  return `${row.createdAt.toISOString()}_${row.id}`
}

export async function listTasks(ownerId: string, q: TaskQuery): Promise<TaskView[]> {
  const conds = [eq(tasks.ownerId, ownerId)]
  if (q.status) conds.push(eq(tasks.status, q.status))
  if (q.cursor) {
    const c = decodeCursor(q.cursor)
    const after = or(lt(tasks.createdAt, c.at), and(eq(tasks.createdAt, c.at), lt(tasks.id, c.id)))
    if (after) conds.push(after)
  }
  return db.select(view).from(tasks)
    .where(and(...conds))
    .orderBy(desc(tasks.createdAt), desc(tasks.id))
    .limit(q.limit)
}

export async function getTask(ownerId: string, id: string): Promise<TaskView | null> {
  const [row] = await db.select(view).from(tasks)
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
    .limit(1)
  return row ?? null
}

export async function insertTask(ownerId: string, input: TaskCreate): Promise<TaskView> {
  const [row] = await db.insert(tasks).values({ ...input, ownerId }).returning(view)
  if (!row) throw new AppError('INTERNAL', 'Insert returned no row')
  return row
}

export async function updateTask(ownerId: string, id: string, patch: TaskUpdate): Promise<TaskView> {
  const rows = await db.update(tasks).set(patch)
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
    .returning(view)
  // A mutation under an ownership filter silently succeeds with 0 rows against someone else's row — the affected row count decides
  if (rows.length === 0) throw new AppError('NOT_FOUND', 'Task not found')
  return rows[0]!
}

export async function deleteTask(ownerId: string, id: string): Promise<void> {
  const res = await db.delete(tasks)
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
  if (res.rowCount === 0) throw new AppError('NOT_FOUND', 'Task not found')
}
```

`update().returning()` returns an empty array for 0 rows, while `delete()` without `returning` returns
node-postgres's `QueryResult` — hence two different checks <!-- verified: ran drizzle-orm@0.45.4 + pg@8.23.1 — with someone else's id, update gave rows=[] and delete gave rowCount=0 (2026-10-15) -->.

## 5. Cursor pagination — the tiebreaker is mandatory

Cut by `createdAt < cursor` alone and **rows created in the same millisecond vanish at the page boundary.** Put `id`
into the cursor too and cut in `(createdAt, id)` lexicographic order. Sort by the same two keys.
<!-- verified: with 7 rows sharing a createdAt and limit 3, removing the tiebreaker made the test fail (2026-10-15) -->

**The cursor is a string the user sends** — validate each decoded part against the type and range the DB accepts.
If the id is not a uuid, PG throws `22P02`; if the year is outside PostgreSQL's range, `22008` — either way a
**500**. The date has to survive a `toISOString()` round trip unchanged, and the year has to be 1970–9999
<!-- verified: measured in audit A — before validation, decodeCursor turned a …_notuuid cursor into a 500; after adding validation, a 400 (2026-10-15) -->.

The list route (`resources/api-endpoints.md` §5) builds `nextCursor` only when `data.length === limit`. When the row count is an exact multiple
of limit, one extra empty page comes at the end — to avoid it, fetch `limit + 1` rows to decide whether a next page
exists (this pack's `listTasks` does not).

The default precision of `timestamptz` is µs, while a JS `Date` is ms. Look up the same row with `=` using the
`Date` you read back and you get **0 rows** — the cursor's tiebreaker branch (`createdAt = c.at`) never matches, so
the remaining rows of that millisecond are skipped. That is why the table sets `precision: 3`.
<!-- verified: PostgreSQL 18.4 + pg@8.23.1 — an = lookup with the Date read back from a timestamptz row (µs=899677) gave 0 rows, timestamptz(3) gave 1 row (2026-10-15) -->

A test that walks 7 same-millisecond rows to the end with `limit=3` proves this section:

<!-- file: src/test/tasks.pagination.test.ts -->
```ts
// src/test/tasks.pagination.test.ts
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { buildApp, type App } from '../app'
import { pool } from '../db/client'
import { resetDb, seedTask } from './db'
import { authFor } from './auth'

let app: App
beforeAll(async () => { app = await buildApp({ logger: false }) })
afterAll(async () => { await app.close(); await pool.end() })
beforeEach(resetDb)

describe('pagination', () => {
  it('returns every row exactly once through the cursor, even when many share a millisecond', async () => {
    const at = new Date('2026-01-01T00:00:00.123Z')
    for (let i = 0; i < 7; i++) await seedTask('alice', { createdAt: at })
    const seen: string[] = []
    let cursor: string | null = null
    do {
      const q: string = cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''
      const res = await app.inject({ url: `/api/tasks?limit=3${q}`, headers: authFor('alice') })
      expect(res.statusCode).toBe(200)
      const body = res.json() as { data: { id: string }[]; nextCursor: string | null }
      seen.push(...body.data.map((x) => x.id))
      cursor = body.nextCursor
    } while (cursor)
    expect(seen).toHaveLength(7)
    expect(new Set(seen).size).toBe(7)
  })
})
```

## 6. Transactions — inside the callback it is `tx` throughout

Only the `tx` that the `db.transaction` callback receives is that transaction's connection. Use `db` inside the
callback and **the query goes out on another connection, commits, and is not rolled back.**

```ts
// src/services/task-service.ts
import { db } from '../db/client'
import { tasks } from '../db/schema'
import type { TaskCreate, TaskView } from '../schemas/task'

// Create all of them or none of them — every query inside the callback goes through tx
export async function importTasks(ownerId: string, inputs: TaskCreate[]): Promise<TaskView[]> {
  return db.transaction(async (tx) => {
    const out: TaskView[] = []
    for (const input of inputs) {
      const [row] = await tx.insert(tasks).values({ ...input, ownerId })
        .returning({ id: tasks.id, title: tasks.title, status: tasks.status, createdAt: tasks.createdAt })
      out.push(row!)
    }
    return out
  })
}
```

<!-- verified: ran drizzle-orm@0.45.4 — when the second insert was a unique violation, tx left 0 rows; replacing tx with db left 1 row (2026-10-15) -->
Throwing from the callback rolls back and rethrows the same error — the 409 mapping is done by `toAppError`.
Do not make external HTTP or queue calls inside a transaction: they are not rolled back and they only lengthen the
lock.

## 7. Migrations — generate is development, migrate is a deploy step

<!-- file: drizzle.config.ts -->
```ts
// drizzle.config.ts
import { defineConfig } from 'drizzle-kit'
import { env } from './src/env'

export default defineConfig({
  dialect: 'postgresql',
  // *schema.ts — src/db/auth-schema.ts, added by the auth variant, joins the same migration flow
  schema: './src/db/*schema.ts',
  out: './drizzle',
  dbCredentials: { url: env.DATABASE_URL },
})
```

The config imports `env` too — without `DATABASE_URL` (and the required keys the auth variant adds), drizzle-kit
stops with the same "invalid environment variables" error. Give the migration step the same environment as the app.
The `schema` glob was not run
<!-- unverified: did not run whether drizzle-kit@0.31's schema glob reads schema.ts and auth-schema.ts together — if it does not, write it as the array ['./src/db/schema.ts', './src/db/auth-schema.ts'] -->. The observation before that dates from the single-path days <!-- verified: ran drizzle-kit@0.31.11 — it read the config importing env.ts, and with DATABASE_URL unset printed the EnvSchema error -->.

```bash
npx drizzle-kit generate --name add_due_date   # schema diff → drizzle/NNNN_*.sql (commit it)
npx drizzle-kit migrate                        # applies only what is pending — a separate step of the deploy pipeline
```

`migrate` records what it applied in `drizzle.__drizzle_migrations` and does not reapply on a second run
<!-- verified: drizzle-kit@0.31.11 — 1 record after running twice against an empty DB -->. Do not use
`drizzle-kit push` against a production DB — it leaves no file, so there is nothing to review and nothing to roll back.

## Misuse list ① — Prisma · Express habits → Drizzle idioms

| old habit | current form (Drizzle 0.45) |
| --- | --- |
| `findUnique({ where: { id } })` then compare the owner | `.where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))` |
| `updateMany(...).count === 0` | `update(...).returning(view)` then `rows.length === 0` |
| `$queryRawUnsafe(sql)` | tagged `` sql`…` `` — values are parameters |
| `prisma migrate deploy` | `drizzle-kit migrate` (a deploy step) |
| `e.code === 'P2002'` | `e.cause.code === '23505'` — `error-handling.md` |

## Misuse list ② — confusable pairs

| often picked wrong | exact condition |
| --- | --- |
| `db` vs `tx` | always `tx` inside a transaction callback |
| `returning().length` vs `rowCount` | the former if you attached `returning`, the latter if you did not |
| `TaskRow` vs `TaskView` | the whole row (including `ownerId`, for tests) vs the response shape (no `ownerId`) |
| `drizzle-kit push` vs `migrate` | the former only on a local scratch DB. Shared and production DBs always use the latter |
