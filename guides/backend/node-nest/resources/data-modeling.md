<!-- orangekit-pack: backend/node-nest v3.16.0 -->
# Data modeling — entities, connection, migrations

This file owns **the table mapping and connection assembly**. Writing queries is owned by `data-access.md`,
and the migration deploy order at operations time by `operations.md` §7.

## 1. What to look at first when deciding a column

| decision | criterion | this pack's value |
| --- | --- | --- |
| Primary key | Is it exposed externally | `uuid` — a sequence number leaks the total count and the creation rate |
| Status column | Is the value set closed | `text` + a CHECK constraint. A PostgreSQL `enum` type costs DDL to add a value |
| Time column | Is it used for cursors or ordering | `timestamptz` + **`precision: 3`** (§2) |
| Owner column | Is the row tied to a user | `ownerId uuid` + **the first column** of the composite index |
| Unique constraint | Is a duplicate a domain error | `(ownerId, title)` — a global unique leaks other people's data |

**Do not make a unique constraint global.** With `UNIQUE(title)`, another user writing the same title gets
a 409, and that leaks **the fact that someone else is using that title**. Tie it to the owner.

## 2. Entity (`src/tasks/task.entity.ts`)

<!-- file: src/tasks/task.entity.ts -->
```ts
import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

export type TaskStatus = 'open' | 'done';

@Entity({ name: 'tasks' })
@Index('IDX_tasks_owner_created', ['ownerId', 'createdAt', 'id'])
export class Task {
  @PrimaryGeneratedColumn('uuid')
  id!: string;

  @Column({ type: 'text' })
  title!: string;

  @Column({ type: 'text', default: 'open' })
  status!: TaskStatus;

  @Column({ type: 'uuid' })
  ownerId!: string;

  @CreateDateColumn({ type: 'timestamptz', precision: 3 })
  createdAt!: Date;

  @UpdateDateColumn({ type: 'timestamptz', precision: 3 })
  updatedAt!: Date;
}
```

**`precision: 3` is the most important character in this file.**
<!-- verified: PostgreSQL 18.4 + typeorm@1.1.0, run — with no precision (µs storage), round-tripping the cursor through toISOString() lost 1 of 5 rows from the read; after switching to precision: 3 the same scenario returned all 5 -->
`timestamptz` stores down to microseconds while JavaScript `Date` expresses only milliseconds.
Send the cursor out as an ISO string and the microseconds are cut off in that round trip; apply
`LessThan` with the truncated value and **every row inside the truncated interval is skipped.** Match the
column precision to the language's resolution and the gap itself disappears.

Putting `!` on a field is TypeScript's definite assignment assertion — the ORM is what fills the value, so the
compiler cannot see the initialization. It is a narrower remedy than turning `strictPropertyInitialization` off.

The column order of `@Index`, `['ownerId', 'createdAt', 'id']`, must be **the same order** as the list query
in §5. Unless the owner filter comes first, the index goes unused.

## 3. Read shape (`src/tasks/task.view.ts`)

<!-- file: src/tasks/task.view.ts -->
```ts
import { FindOptionsSelect } from 'typeorm';
import { Task } from './task.entity';

export type TaskView = Pick<Task, 'id' | 'title' | 'status' | 'createdAt'>;

export const TASK_VIEW: FindOptionsSelect<Task> = {
  id: true,
  title: true,
  status: true,
  createdAt: true,
};
```

**Why the type and the `select` value live in one file**: let them diverge and compilation passes while only
the runtime value comes up empty. Add `updatedAt` to `TaskView` and forget `TASK_VIEW`, and that field exists
in the type and rides in the response envelope as `undefined`. On one screen, changing only one side is hard.

Not carrying `ownerId` is a contract too — an owner id in the response is an internal identifier leak by itself,
and the client starts imitating access control with it.

## 4. Connection assembly (`src/database/data-source.ts`)

<!-- file: src/database/data-source.ts -->
```ts
import 'reflect-metadata';
import { DataSource, DataSourceOptions } from 'typeorm';
import { EnvVars, validateEnv } from '../config/env';
import { SlowQueryLogger } from '../ops/logging';
import { Task } from '../tasks/task.entity';

type DbEnv = Pick<EnvVars, 'DATABASE_URL' | 'DB_SCHEMA' | 'DB_POOL_MAX' | 'DB_SLOW_QUERY_MS'>;

export function buildDataSourceOptions(env: DbEnv): DataSourceOptions {
  return {
    type: 'postgres',
    url: env.DATABASE_URL,
    schema: env.DB_SCHEMA,
    entities: [Task],
    migrations: [`${__dirname}/migrations/*.{ts,js}`],
    synchronize: false,
    migrationsRun: false,
    extra: { max: env.DB_POOL_MAX },
    maxQueryExecutionTime: env.DB_SLOW_QUERY_MS,
    logger: new SlowQueryLogger(),
  };
}

export const dataSource = new DataSource(buildDataSourceOptions(validateEnv(process.env)));
```

**One function serves both the app and the CLI.** The app has `AppModule` pull the values from `ConfigService`
and call this function; the TypeORM CLI reads the `dataSource` at the end of the file directly. Let the options
diverge and you get mismatches like "the migration passed but the app is looking at a different schema".

| option | value | why |
| --- | --- | --- |
| `synchronize` | `false` | On, it runs unannounced DDL on every deploy. Dropping a column is dropping data |
| `migrationsRun` | `false` | Separates boot from migration (`operations.md` §7) |
| `schema` | `env.DB_SCHEMA` | The point where tests isolate by per-worker schema (`testing.md` §3) |
| `extra.max` | `env.DB_POOL_MAX` | The pg pool ceiling. Instance count × this value must not exceed the server ceiling |
| `maxQueryExecutionTime` | `env.DB_SLOW_QUERY_MS` | A query exceeding this arrives at `SlowQueryLogger.logQuerySlow` |

`reflect-metadata` sits on this file's first line too **because there are two entry points** — the CLI loads
this file directly without going through `main.ts`.

## 5. Migrations (`src/database/migrations/`)

<!-- file: src/database/migrations/1756000000000-CreateTasks.ts -->
```ts
import { MigrationInterface, QueryRunner, Table, TableIndex } from 'typeorm';

export class CreateTasks1756000000000 implements MigrationInterface {
  async up(q: QueryRunner): Promise<void> {
    await q.createTable(
      new Table({
        name: 'tasks',
        columns: [
          { name: 'id', type: 'uuid', isPrimary: true, default: 'gen_random_uuid()' },
          { name: 'title', type: 'text' },
          { name: 'status', type: 'text', default: "'open'" },
          { name: 'ownerId', type: 'uuid' },
          { name: 'createdAt', type: 'timestamptz', precision: 3, default: 'now()' },
          { name: 'updatedAt', type: 'timestamptz', precision: 3, default: 'now()' },
        ],
        checks: [{ name: 'CHK_tasks_status', expression: `"status" IN ('open','done')` }],
        uniques: [{ name: 'UQ_tasks_owner_title', columnNames: ['ownerId', 'title'] }],
      }),
      true,
    );
    await q.createIndex(
      'tasks',
      new TableIndex({ name: 'IDX_tasks_owner_created', columnNames: ['ownerId', 'createdAt', 'id'] }),
    );
  }

  async down(q: QueryRunner): Promise<void> {
    await q.dropTable('tasks', true);
  }
}
```

<!-- verified: PostgreSQL 18.4, run — migration:run created the table, CHECK, UNIQUE and indexes, and the test harness re-ran the same migration against an isolated schema and passed -->
**Use `QueryRunner`'s DDL API and write no raw SQL.** `q.query('CREATE TABLE ...')` is a string and
so does not recognize the schema — even on a connection attached to an isolated schema it creates the table
wherever `search_path` points (usually `public`). `createTable` follows the DataSource's `schema` setting,
so **the same migration holds on both the production schema and the test schema.**

Running it takes two commands. The first applies, the second reverts.

```bash
npx typeorm-ts-node-commonjs migration:run -d src/database/data-source.ts
npx typeorm-ts-node-commonjs migration:revert -d src/database/data-source.ts
```

Do not leave `down` empty. A migration that cannot be reverted leaves you **with no option but
forward** when something goes wrong mid-deploy.

## 6. Order for changing a schema

Do not make a destructive change in one step. Deploy and migration are not atomic, so new code and old
code run side by side for a while.

| what you want | safe order |
| --- | --- |
| Add a column | Add as nullable → deploy the code → backfill → NOT NULL |
| Drop a column | Remove its use from the code → deploy → DROP in the next release |
| Rename a column | Add the new column → write both → backfill → switch the read → drop the old column |
| Add a constraint | Clean up violating rows → add as `NOT VALID` → `VALIDATE` |

## Misuse list ① — TypeORM 0.2/0.3 idiom → 1.x form

<!-- verified: typeorm@1.1.0 runtime export list checked — Connection, createConnection, getRepository and getManager are absent -->

| old habit (0.2-0.3) | current form (TypeORM 1.x) |
| --- | --- |
| `createConnection()` · `getConnection()` | `new DataSource(options)` + `initialize()`. In Nest, `TypeOrmModule` does it instead |
| Global `getRepository(Task)` | `@InjectRepository(Task)` or `dataSource.getRepository(Task)` |
| `getManager().transaction(...)` | `dataSource.transaction(...)` |
| `ormconfig.json` | A `DataSourceOptions` assembled in code — it gets type checked |
| Updating everything with `repo.update({}, patch)` | `repo.updateAll(patch)` — **the name is a warning.** It has no place on this axis |
| `@Column({ type: 'timestamp' })` | `timestamptz` + `precision: 3`. A time without a timezone changes meaning when the deployment region changes |
| Developing with `synchronize: true` | Migrations from the start. It keeps the development schema and the production schema from diverging |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `@CreateDateColumn` vs `@Column({ default: 'now()' })` | The former has the ORM put the value in, the latter the DB. When there is a path that skips the ORM (a migration, manual SQL), only the latter can be trusted |
| `@PrimaryGeneratedColumn('uuid')` vs `@PrimaryColumn` | The former is generated by the DB. When the application has to make the id (idempotent creation), the latter |
| A CHECK constraint vs DTO validation | Do both. The DTO gives a 400 and the CHECK blocks the bypass paths |
| `nullable: true` vs a default | NULL when "there is no value" and "it has not been decided yet" mean different things; otherwise a default |
| Index `['ownerId','createdAt']` vs `['createdAt','ownerId']` | Filter first, ordering second. Swap the order and the owner filter gets no index |
