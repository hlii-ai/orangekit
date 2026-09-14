<!-- orangekit-pack-policies: backend/node-nest v3.16.0 -->

# node-nest pack — cross-file invariants

The gate checks **whether the pack itself and the seam keep the policies this pack declares**. When the place
that declares a policy and the place that enforces it differ with no obligation to reconcile them, the policy is only documentation — this file is that obligation.

## Machine checks (gate `check_policies` · `check_pack_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad span.
Counting prose and anti-pattern examples turns every hit into a false positive.

**The `proof example` column is mandatory** (the gate FAILs without it). The gate asserts ① that the example matches its own regex
② and, for `forbid`, that the example is absent from the target files.

**Do not use markdown emphasis in a `scope` value.** `**seam**` is not recognized as a scope, so the policy
silently aims at every file.

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-entry` | forbid | guide | `process\.env` | `data-modeling.md, testing.md` | `const url = process.env.DATABASE_URL` | `process.env['DATABASE_URL']` | Environment values are read only through `ConfigService`, after passing `validateEnv`. Reading them directly bypasses the types, the validation and the boot-time failure. Two exemptions: the **CLI DataSource**, which runs outside DI, and the test harness that splits schemas by worker id. **`main.ts` is deliberately not exempt** — with `bufferLogs: true` + `useLogger` there is no reason to read env early just to build a logger |
| `env-validated-at-boot` | require | file:input-validation.md | `validateSync\(` | — | `const errors = validateSync(parsed, { forbidUnknownValues: false })` | `const errors = await validate(parsed)` | A missing or malformed value must fail **at boot**, not at first use. A first-use failure blows up on one particular request hours after the deploy |
| `env-wired-to-config-module` | require | file:project-structure.md | `validate:[[:space:]]*validateEnv` | — | `ConfigModule.forRoot({ isGlobal: true, validate: validateEnv })` | `ConfigModule.forRoot({ isGlobal: true })` | With nowhere **using** the validation function, the schema is dead code. `input-validation.md` defines it and the root module wires it — a contract spanning two files, so each side is aimed at separately |
| `ownership-in-query` | require | file:data-access.md | `where:[[:space:]]*\{[^}]*ownerId` | — | `where: { id, ownerId }` | `async get(ownerId: string, id: string)` | **The largest risk on this axis.** There is no data-layer policy engine, so ownership has to ride in the query condition. Comparing after the fetch loses to a race, and omitting it is a data leak. **Why the regex demands it inside the `where` object**: a bare `ownerId:` is satisfied by a single TypeScript parameter annotation (`ownerId: string`) and sees nothing about whether it reached `where` |
| `mutation-affected-rows` | require | file:data-access.md | `\.affected[[:space:]]*(!==\|===)` | — | `if (res.affected === 0) throw new AppError('NOT_FOUND')` | `return res.affected ?? 0` | A mutation carrying an ownership filter silently succeeds with **0 rows changed** against someone else's row. Without looking at `UpdateResult.affected` it returns 200 (measured: editing another user's row gives `affected = 0`) |
| `no-blanket-mutation` | forbid | guide | `\.(updateAll\|deleteAll)\(` | `testing.md` | `await this.tasks.updateAll({ status: 'done' })` | `await repo.deleteAll()` | `updateAll` and `deleteAll`, new in TypeORM 1.x, hit the whole table **with no WHERE**. There is no place at all to attach an ownership filter, so on this axis they have no reason to appear in domain code. The only exemption is test cleanup emptying an isolated schema |
| `no-sql-string-interpolation` | forbid | guide | `\.query\([^)]*\$\{` | — | `await ds.query(` + a backtick + `SELECT * FROM ${table}` | `await manager.query(sql${suffix})` | Identifiers cannot be parameterized, so you end up splicing strings, and the habit carries over to values. Pass values through `query(sql, params)` or the tagged template `repo.sql`, and handle schema and table names with `QueryRunner`'s DDL API (`createSchema`, `createTable`) — this pack writes not one line of raw DDL |
| `no-typeorm-globals` | forbid | guide | `createConnection\(\|getConnection\(\|getManager\(` | — | `const conn = await createConnection()` | `const em = getManager()` | **Those names do not exist** in TypeORM 1.x (checked against the runtime exports). Carrying over the 0.2-era global-connection idiom kills boot with `TypeError: not a function`. The connection is a `DataSource` and app code receives it through DI |
| `no-synchronize` | forbid | guide | `synchronize:[[:space:]]*[^f[:space:]]` | — | `synchronize: true` | `synchronize: process.env.NODE_ENV !== 'production'` | Reflecting the schema from entities automatically runs unannounced DDL on every deploy — dropping a column becomes dropping data. Tests are not exempt either: this pack's tests **actually run the migrations** and so verify the migrations too |
| `timestamp-precision-pinned` | require | file:data-modeling.md | `precision:[[:space:]]*3` | — | `@CreateDateColumn({ type: 'timestamptz', precision: 3 })` | `@Column({ type: 'timestamptz' })` | `timestamptz` is microseconds, JS `Date` is milliseconds. Round-tripping a cursor as an ISO string truncates the precision in between and **skips rows** (measured: 1 of 5 rows lost). Pinning the column precision to 3 matches the resolutions of the DB and the language |
| `validation-pipe-strict` | require | file:input-validation.md | `forbidNonWhitelisted:[[:space:]]*true` | — | `forbidNonWhitelisted: true` | `whitelist: true` | With only `whitelist` on, an unknown key is **silently dropped** — a misspelled field is ignored, a 200 goes out, and the client cannot find the cause. Rejecting is what makes the typo surface immediately |
| `no-console` | forbid | guide | `console\.(log\|error\|warn)\(` | — | `console.log(user)` | `console.error(e)` | Use only the structured logger. `console` has no level, no context and no serialization, so it is not searchable in production. Use Nest's `Logger` (injected or `new Logger('Context')`) and let `buildLogger` decide the output shape |
| `graceful-shutdown` | require | file:operations.md | `SIGTERM` | — | `process.once('SIGTERM', () => void stop('SIGTERM'))` | `process.once('SIGINT', handler)` | Failing to drain in-flight requests on container shutdown produces 5xx on every deploy. **Nest's `enableShutdownHooks()` alone is not enough** — it does not create a drain window (measured) |
| `error-status-single-table` | require | file:error-handling.md | `ERROR_STATUS` | — | `ERROR_STATUS[err.code] ?? 500` | `const status = 404` | Deciding status codes per file makes the same failure go out under different codes depending on where it happened |
| `vocab-task` | forbid | guide | `\bnotes?\b` | — | `const notes = []` | `const note = {}` | The domain vocabulary is pinned to `Task`/`tasks`/`task` (issued by L0). Measured: the frontend used `/tasks` and the backend `/notes`, leaving the complete examples unable to run against each other |
| `guard-on-controller` | require | seam | `AuthGuard` | — | `@UseGuards(AuthGuard)` | `@UseGuards(RolesGuard)` | **Why the scope is `seam`**: `AuthGuard` is defined by the seam, so scoping this to `guide` means it can never fail as long as the seam ships — and the controller wiring that actually needs checking goes unchecked |
| `envelope-from-filter` | require | seam | `AllExceptionsFilter` | — | `app.useGlobalFilters(new AllExceptionsFilter())` | `app.useGlobalFilters(new HttpExceptionFilter())` | The envelope is emitted in exactly one place. A controller doing `res.status(...).json(...)` itself splits the envelope. It aims at the seam for the same reason as above |

A `scope` of `guide` looks at the whole assembled guide (pack + seam), `pack` at pack files only, `seam` at seam
files only, and `file:<name>` at that one file. `require` is satisfied by at least one occurrence.
Before assembly (`--pack`) a `seam`-scoped policy is undecidable, so **the skip is reported explicitly**.

## For humans to keep (machine-undecidable)

- **An array `where` is an OR — attach ownership to every branch.** In a two-branch query such as
  cursor pagination, dropping `ownerId` from one side lets that branch pass through another user's rows
  wholesale. The regex only looks at "does `where` contain `ownerId` at least once", so it **cannot see
  a per-branch omission** (the leak was reproduced by measurement)
- **Do not answer differently for absent and unauthorized.** Reading someone else's row is a 404, not a 403 —
  distinguishing them lets an unauthorized user enumerate which resources exist
- **`select` narrows the runtime value only, not the type.** An object fetched with `select: TASK_VIEW`
  still has type `Task`, so `task.ownerId` compiles while the value is `undefined`
  (measured). Declaring the return type as `TaskView` **explicitly** is the only defense
- **Do not assume a query string becomes a number without `@Type(() => Number)`.** Global
  `transform: true` alone leaves `@IsInt()` rejecting `'20'`
- **Do not carry default values into a partial-update DTO.** `PartialType` only makes fields
  optional; leave the defaults in place and a field the client never sent gets overwritten
- **Do not make external calls (HTTP, queue) inside a transaction.** They do not roll back and the lock only grows longer
- **Run migrations as a step separate from the deploy.** Turning on `migrationsRun` at boot makes
  instances race when they come up together
- **Do not close a provider in `onModuleDestroy`.** That hook fires while in-flight requests are
  still outstanding (measured: 1ms after SIGTERM, with the request finishing 1.2s later)
