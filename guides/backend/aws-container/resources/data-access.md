<!-- orangekit-pack: backend/aws-container v3.12.0 -->
# Data access (Drizzle ORM + RDS PostgreSQL)

This covers only query patterns and **running** migrations.

> **The table design rules are not here.** Normalization, keys, constraints and index design are owned by the T1 rule card
> `.claude/rules/data-modeling.md`. That card loads automatically when editing `drizzle/**`, `db/**` and
> `**/migrations/**`, but **it does not match when you fix a query inside `src/**`** —
> when that happens, open the path above and read it directly.

## One singleton client (`src/db/client.ts`)

<!-- file: src/db/client.ts -->
```ts
// src/db/client.ts
import { readFileSync } from 'node:fs'
import { drizzle } from 'drizzle-orm/node-postgres'
import { Pool } from 'pg'
import { env } from '@/config/env'
import * as schema from '@/db/schema'

// The RDS server certificate is issued by an Amazon private root — it is not in Node's default trust store
const ca = env.DB_CA_PATH ? readFileSync(env.DB_CA_PATH, 'utf8') : undefined

export const pool = new Pool({
  connectionString: env.DATABASE_URL,
  max: env.DB_POOL_MAX,                 // Fargate task count × max ≤ RDS max_connections
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
  ssl: env.DB_SSL ? { rejectUnauthorized: true, ca } : undefined,
})

export const db = drizzle(pool, { schema })
```

- Do not build a `new Pool()` per request — connections explode and RDS starts refusing new ones
- On shutdown, put `await pool.end()` in the SIGTERM handler (`src/index.ts`)
- Compute the connection ceiling as **task count × `DB_POOL_MAX`**. Exceed the autoscaling ceiling and
  scaling out is an outage

### TLS does not end with `rejectUnauthorized: true`

Deploy with only `rejectUnauthorized: true` on and the first connection fails with `SELF_SIGNED_CERT_IN_CHAIN`,
because Amazon RDS's root certificate is not in Node's default trust store. If a developer reverts it to
`false` here, **it is wide open to a man in the middle** — the connection is encrypted but never confirms who
is on the other end. The correct fix is to put the bundle in the image and inject the path.

```dockerfile
ADD https://truststore.pki.rds.amazonaws.com/global-bundle.pem /etc/ssl/rds/global-bundle.pem
ENV DB_CA_PATH=/etc/ssl/rds/global-bundle.pem
```

Move on-premises and you put the in-house CA bundle path into the same `DB_CA_PATH` — **app code does not change**.
Local `docker compose` runs `DB_SSL=false` (plaintext loopback), so it does not need this path.

## Schema definition (the source for migrations)

This block is **canonical for the table definitions**. Every `tasks` citation in the other resource files points here.

```ts
// src/db/schema.ts
import { index, pgTable, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core'

export const tasks = pgTable('tasks', {
  id: uuid('id').primaryKey().defaultRandom(),
  ownerId: text('owner_id').notNull(),          // the token's sub — text, in case the IdP is swapped
  title: text('title').notNull(),
  body: text('body').notNull().default(''),
  archivedAt: timestamp('archived_at', { withTimezone: true }),   // null = active
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (t) => [
  index('tasks_owner_created_idx').on(t.ownerId, t.createdAt, t.id),
  uniqueIndex('tasks_owner_title_key').on(t.ownerId, t.title),
])

export const tags = pgTable('tags', {
  id: uuid('id').primaryKey().defaultRandom(),
  ownerId: text('owner_id').notNull(),          // the child table carries the owner directly too
  taskId: uuid('task_id').notNull().references(() => tasks.id, { onDelete: 'cascade' }),
  name: text('name').notNull(),
}, (t) => [
  index('tags_owner_task_idx').on(t.ownerId, t.taskId),
  uniqueIndex('tags_task_name_key').on(t.taskId, t.name),
])

export type Task = typeof tasks.$inferSelect
export type NewTask = typeof tasks.$inferInsert
```

- **Always keep an index whose leading column is `owner_id`.** Every read filters by owner, so
  without this index it becomes a full table scan
- **Match the index columns to the sort key all the way down.** With the cursor ordering on `(created_at, id)` and the index
  stopping at `(owner_id, created_at)`, ordering inside a tie group is not resolved by the index
- **Put `owner_id` on the child table too.** In a structure where the owner is knowable only by joining the parent,
  you end up dropping the filter on join-free paths such as an `IN` read
- Time is always `withTimezone: true` (`timestamptz`). A column with no timezone changes meaning the moment
  the deployment region changes
- Pull the types out with `$inferSelect` / `$inferInsert` — do not hand-write the row type again

## A query always takes an `ownerId` (`src/db/queries/tasks.ts`)

This layer has no concept of authentication. Instead the signature enforces that **it cannot even be called without an owner argument**.

```ts
import { and, desc, eq, isNotNull, isNull, sql } from 'drizzle-orm'
import { db } from '@/db/client'
import { tasks } from '@/db/schema'
import type { UpdateTaskInput } from '@/schemas/tasks'

export async function findOwnedTask(ownerId: string, id: string) {
  const [row] = await db.select().from(tasks)
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
    .limit(1)
  return row ?? null
}

export async function listOwnedTasks(
  ownerId: string, limit: number,
  cursor?: { createdAt: Date; id: string }, archived?: boolean,
) {
  return db.select().from(tasks)
    .where(and(
      eq(tasks.ownerId, ownerId),
      cursor
        ? sql`(${tasks.createdAt}, ${tasks.id}) < (${cursor.createdAt}, ${cursor.id})`
        : undefined,                                   // and() ignores undefined
      archived ? isNotNull(tasks.archivedAt) : isNull(tasks.archivedAt),  // unset = active only
    ))
    .orderBy(desc(tasks.createdAt), desc(tasks.id))
    .limit(limit + 1)                                  // +1 decides whether a next page exists
}
```

`(created_at, id) < (...)` is PostgreSQL's row value comparison. It settles cursor pagination's tie handling
in one condition. `tasks_owner_created_idx` is `(owner_id, created_at, id)`, so the index covers the whole
sort key — drop the last two columns and ordering is performed again inside a tie group.

## A mutation checks the affected rows

**The classic trap of this layer**: an `update`/`delete` carrying an ownership filter returns
"0 rows, no error" against someone else's resource. Discard the result and that request is answered as success.

```ts
// Narrow the patch type to UpdateTaskInput — not Partial<NewTask>
export async function updateOwnedTask(ownerId: string, id: string, patch: UpdateTaskInput) {
  const [row] = await db.update(tasks)
    .set({ ...patch, updatedAt: new Date() })
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
    .returning()
  return row ?? null                     // null → the service throws a 404
}

export async function deleteOwnedTask(ownerId: string, id: string) {
  const rows = await db.delete(tasks)
    .where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
    .returning({ id: tasks.id })
  return rows.length                     // 0 → 404
}
```

```ts
// ❌ Discard the result — a 204 goes out even when called with someone else's id
await db.delete(tasks).where(and(eq(tasks.id, id), eq(tasks.ownerId, ownerId)))
```

`insert` likewise uses the `.returning()` result in the response. Echo back the input the client sent and the
response goes out missing the DB defaults (`id`, `createdAt`).

**Do not leave the `patch` type open as `Partial<NewTask>`.** That lets `patch.ownerId` ride into the
`set`, and one request that passed the ownership filter **hands the row to someone else**. Accept only the parsed request type
(`UpdateTaskInput`) and `ownerId`, `id` and `createdAt` are not in the type in the first place.

## Transactions

When several tables change together, bind them in a transaction. **Do not let `tx` leak outside the callback.**

```ts
import { and, eq } from 'drizzle-orm'
import { db } from '@/db/client'
import { tasks, tags } from '@/db/schema'

export async function replaceTaskTags(ownerId: string, taskId: string, names: string[]) {
  return db.transaction(async (tx) => {
    const [task] = await tx.select({ id: tasks.id }).from(tasks)
      .where(and(eq(tasks.id, taskId), eq(tasks.ownerId, ownerId))).limit(1)
    if (!task) return null                          // the ownership check is inside the transaction too

    // The owner condition goes on child table mutations as well (checking the parent does not do it for you)
    await tx.delete(tags).where(and(eq(tags.ownerId, ownerId), eq(tags.taskId, taskId)))
    if (names.length === 0) return []
    return tx.insert(tags).values(names.map((name) => ({ ownerId, taskId, name }))).returning()
  })
}
```

- Do not make HTTP calls or long waits inside a transaction (it holds a connection while the pool dries up)
- A rollback is automatic when the callback throws — there is rarely a reason to call `tx.rollback()` yourself

## Do not create an N+1

```ts
import { and, eq, inArray } from 'drizzle-orm'
import { db } from '@/db/client'
import { tags } from '@/db/schema'

// ❌ As many queries go out as the list is long
for (const task of rows) task.tags = await findTags(task.id)

// ✅ Fetch once and group in memory — the owner condition stays on the batch read too
const tagRows = await db.select().from(tags)
  .where(and(eq(tags.ownerId, ownerId), inArray(tags.taskId, rows.map((r) => r.id))))
const byTask = new Map<string, typeof tagRows>()
for (const t of tagRows) byTask.set(t.taskId, [...(byTask.get(t.taskId) ?? []), t])
```

**The fact that an `IN` list came from your own rows is not an ownership filter.** The moment an id comes from external input
(an array in the request body, a cache, another query's result), that read becomes a read with no owner condition.
Even when `rows` looks safe, keep the condition attached — safety does not travel with it when it is reused.

When the relation is often read together, switch to `db.query.tasks.findMany({ with: { tags: true } })` (which needs a
relations declaration). Either way, **the query count must not be proportional to the list length.**

## Migration workflow

```bash
docker compose up -d --wait db          # start postgres:16 and wait until healthy
npx drizzle-kit generate                # schema.ts diff → generates drizzle/NNNN_*.sql
$EDITOR drizzle/0003_*.sql              # always read the generated SQL
npx drizzle-kit migrate                 # apply to the local DB
npm run test:integration                # regression check against a real DB
```

```ts
// drizzle.config.ts
import { defineConfig } from 'drizzle-kit'

export default defineConfig({
  schema: './src/db/schema.ts',
  out: './drizzle',
  dialect: 'postgresql',
  dbCredentials: { url: process.env.DATABASE_URL! },
})
```

**Applying in production**: run it as a migration-only one-off task in the deploy pipeline. Call `migrate()` at app boot
and the Fargate tasks coming up together contend over the same migration.

**Split a destructive change**: ① add a nullable column + deploy → ② backfill + support old and new code at once →
③ promote to NOT NULL + drop the old column. Do it in one go and you create a point of no rollback.

## Misuse list (version idiom)

| old habit (drizzle-kit 0.20 or earlier / wrong usage) | current form |
| --- | --- |
| `drizzle-kit generate:pg` | `drizzle-kit generate` (the dialect comes from the config file) |
| `driver: 'pg'` in the config | `dialect: 'postgresql'` |
| `dbCredentials: { connectionString }` | `dbCredentials: { url }` |
| An index callback returning an object `(t) => ({ idx: index(...) })` | Return an array `(t) => [index(...).on(t.col)]` |
| Changing the production schema with `drizzle-kit push` | Production is `generate` → review → `migrate`. `push` is for local experiments only |
| Hand-writing SQL first and matching schema.ts to it later | schema.ts is the source — SQL is always a `generate` output |
| `timestamp('at')` (no timezone) | `timestamp('at', { withTimezone: true })` |
| Creating `drizzle(pool)` per request | One module-scope singleton |

## Misuse list (confusable pairs)

| often chosen wrong | exactly when it applies |
| --- | --- |
| `db.select()` vs `db.query.<t>.findMany()` | The first is closer to SQL and better for joins and aggregates; the second needs a relations declaration and is better for nested loading |
| Missing `eq(tasks.ownerId, ownerId)` | A query with no owner condition is a data leak on this stack — the first thing to look at in review |
| Using `inArray(...)` on its own | That the id list came from your own rows is not a filter → `and(eq(t.ownerId, ownerId), inArray(...))` |
| A `set(patch)` whose patch type is `Partial<NewTask>` | `ownerId` rides in and ownership transfers → narrow it to the parsed request type |
| `ssl: { rejectUnauthorized: false }` | TLS without verification is open to a man in the middle → put the RDS bundle (`DB_CA_PATH`) in `ca` and keep `true` |
| A single-row read with no `.limit(1)` | You end up pulling everything and using only the first row |
| String concatenation in an `sql` template | `sql\`... ${value}\`` binds, but `sql.raw('...' + v)` is an injection path |
| Mixing `false`/`null` into `and(...)` | Pass "no condition" as `undefined` — `and()` drops it automatically |
| Omitting `.returning()` | You cannot tell whether the mutation succeeded. 0 rows is answered as success |
| Aurora-only functions and the Data API | Forbidden — keep the same engine as on-premises PostgreSQL (`portability-boundaries.md`) |
