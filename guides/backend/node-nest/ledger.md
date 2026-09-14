<!-- orangekit-pack-ledger: backend/node-nest v3.16.0 -->

# node-nest pack — symbol ledger (L0 declaration)

**This is the contract the main session declared before authoring.** The definition-file assignment in `provides` is an **ownership assignment**,
and it is the only device that keeps duplicate definitions from appearing when clusters are split and written in
parallel. L1 defines only the symbols assigned to its own cluster; step outside and the gate's `--pack` catches it at the fan-in.

`requires` is what this pack consumes but does not define — **the seam must provide it**.
Library APIs are not ledger material.

**Write the source path in the "shape" column.** The ledger assigns "which **resource file** owns this",
but that is document ownership, not the **path of the code**. In Nest this distinction leaks especially
badly — one symbol is one file (`@Module` · `@Injectable` · `@Entity`) and sibling files `import` it by that
path. Measured on fastapi: the consumer's and the definer's paths diverged, the assembly broke, and
**the gate did not catch it** (the ledger check looks only at resource files).

## provides — this pack defines these

Only symbols carrying an `export` declaration are listed.

| symbol | definition file | shape | role |
| --- | --- | --- | --- |
| `AppModule` | project-structure.md | `src/app.module.ts`. The `@Module` root — imports `ConfigModule.forRoot({ validate: validateEnv })` · `TypeOrmModule.forRootAsync` · the feature modules. **It holds no controller of its own** | Root module (assembly point) |
| `bootstrap` | project-structure.md | `src/main.ts`. `() => Promise<void>` — imports `reflect-metadata` **on the first line of the file**, then `NestFactory.create` → global pipes → `installShutdown` → `listen`, in that order | Boot function (process entry point) |
| `TasksModule` | project-structure.md | `src/tasks/tasks.module.ts`. `@Module` — imports `TypeOrmModule.forFeature([Task])` and `exports` `TasksService`. The controllers array is **filled by the seam** | Feature module |
| `Task` | data-modeling.md | `src/tasks/task.entity.ts`. An `@Entity({ name: 'tasks' })` class — `id` · `title` · `status: TaskStatus` · `ownerId` · `createdAt` · `updatedAt`. Time columns are `{ type: 'timestamptz', precision: 3 }` | Entity (table mapping) |
| `TaskStatus` | data-modeling.md | `src/tasks/task.entity.ts`. `'open' \| 'done'` | Status union |
| `TaskView` | data-modeling.md | `src/tasks/task.view.ts`. `Pick<Task, 'id' \| 'title' \| 'status' \| 'createdAt'>` — it does not carry `ownerId` | Return type of the 5 reads. **The seam's controller needs a name for it in order to type its handlers** |
| `TASK_VIEW` | data-modeling.md | `src/tasks/task.view.ts`. `FindOptionsSelect<Task>` — the `select` value picking the same columns as `TaskView`. **Why both live in one file**: let the type and the `select` diverge and compilation passes while only the runtime value comes up empty | `select` constant |
| `TasksService` | data-access.md | `src/tasks/tasks.service.ts`. `@Injectable`. Five methods — `list(ownerId, q)` · `get(ownerId, id)` · `create(ownerId, dto)` · `update(ownerId, id, patch)` · `remove(ownerId, id)`. **The owner is always the first argument.** `update` and `remove` throw `AppError('NOT_FOUND')` when the affected row count is 0 | Domain service (owns the queries) |
| `buildDataSourceOptions` | data-modeling.md | `src/database/data-source.ts`. `buildDataSourceOptions(env)` — the argument is `Pick<EnvVars, 'DATABASE_URL' \| 'DB_SCHEMA' \| 'DB_POOL_MAX' \| 'DB_SLOW_QUERY_MS'>`, returning `DataSourceOptions`. `synchronize: false` and `migrationsRun: false` are pinned | Assembles the DataSource options (shared by app and CLI) |
| `dataSource` | data-modeling.md | `src/database/data-source.ts`. A `DataSource` — **the default-export target for the TypeORM CLI only**. The app does not use it; it is injected with the one `TypeOrmModule` built | DataSource for the CLI |
| `encodeCursor` | data-access.md | `src/tasks/cursor.ts`. `(t: TaskView) => string` — carries `createdAt` + `id` as base64url | Cursor encoding |
| `decodeCursor` | data-access.md | `src/tasks/cursor.ts`. `(raw: string) => { createdAt: Date; id: string }` — a malformed value raises `AppError('VALIDATION_FAILED')` | Cursor decoding |
| `EnvVars` | input-validation.md | `src/config/env.ts`. A class carrying class-validator decorators. `NODE_ENV` · `PORT` · `DATABASE_URL` · `DB_SCHEMA` · `LOG_LEVEL` · `DB_POOL_MAX` · `DB_SLOW_QUERY_MS` · `DRAIN_DELAY_MS` · `SHUTDOWN_TIMEOUT_MS`. **A key that is not declared is a key `ConfigService` does not know** | Environment variable schema (the class is the schema) |
| `validateEnv` | input-validation.md | `src/config/env.ts`. `(raw: Record<string, unknown>) => EnvVars` — passed to `ConfigModule.forRoot({ validate })`. A failure throws **at boot** | Environment validation entry point |
| `CreateTaskDto` | input-validation.md | `src/tasks/dto/create-task.dto.ts`. `title` required · `status` optional | Create request body |
| `UpdateTaskDto` | input-validation.md | `src/tasks/dto/update-task.dto.ts`. `PartialType(CreateTaskDto)` — **it carries no default values** | Update request body (partial update) |
| `ListTasksQueryDto` | input-validation.md | `src/tasks/dto/list-tasks.query.dto.ts`. `limit` (default 20) · `cursor?` · `status?`. `@Type(() => Number)` is **required** on numeric fields | List query string |
| `buildValidationPipe` | input-validation.md | `src/common/validation.ts`. `buildValidationPipe() => ValidationPipe` — pins `whitelist` · `forbidNonWhitelisted` · `transform` · `exceptionFactory`. `bootstrap` attaches it with `useGlobalPipes` | Assembles the global validation pipe |
| `ERROR_STATUS` | error-handling.md | `src/common/error-status.ts`. `Record<string, number>` — domain code → HTTP status. **The single mapping table** | Domain error code → HTTP status table |
| `toAppError` | error-handling.md | `src/common/error-status.ts`. `(e: unknown) => AppError` — the seam's exception filter **must call it first** | Unknown throw → `AppError` normalization |
| `isUniqueViolation` | error-handling.md | `src/common/error-status.ts`. `(e: unknown) => boolean` — `QueryFailedError.driverError.code === '23505'` | Detects a unique constraint violation |
| `isForeignKeyViolation` | error-handling.md | `src/common/error-status.ts`. `(e: unknown) => boolean` — `'23503'` in the same place | Detects a foreign key violation |
| `fieldErrors` | error-handling.md | `src/common/error-status.ts`. `(errors: ValidationError[]) => Record<string, string[]>` — a nested DTO is flattened onto an `a.b` path | `ValidationError[]` → field error map |
| `testSchema` | testing.md | `test/db.ts`. `string` — `test_w${JEST_WORKER_ID}`. Different per worker. `createTestApp` injects this value as `DB_SCHEMA` | Per-worker schema name |
| `prepareSchema` | testing.md | `test/db.ts`. `prepareSchema(schema: string) => Promise<void>` — `QueryRunner.dropSchema`/`createSchema`. **It writes no raw SQL.** Why it takes an argument: `globalSetup` runs **outside** the workers and has no `JEST_WORKER_ID`, so creating only its own schema leaves worker 2 facing an empty one | Schema creation (once, in globalSetup) |
| `createTestApp` | testing.md | `test/db.ts`. `createTestApp(configure?)` — `configure` is `(app: INestApplication) => void`, returning `Promise<INestApplication>`. Attaches the global pipes exactly as the real app does and calls `configure` **before `init()`**. That is where the seam's exception filter goes — without it every `AppError` goes out as a 500 and the tests cannot see status codes (measured). The caller is responsible for `app.close()` | Boots the test app |
| `resetDb` | testing.md | `test/db.ts`. `(app: INestApplication) => Promise<void>` — `repo.deleteAll()`. Cleanup **between** tests | Cleanup between tests |
| `seedTask` | testing.md | `test/db.ts`. `(app: INestApplication, ownerId: string, patch?: Partial<Task>) => Promise<Task>` | Creates a fixture |
| `ReadinessService` | operations.md | `src/ops/readiness.service.ts`. `@Injectable` — `isReady(): boolean` · `beginDrain(): void`. **The sole owner of the drain flag** | Readiness state (drain flag) |
| `HealthController` | operations.md | `src/ops/health.controller.ts`. `@Controller()` — `GET /healthz` (liveness, looks at no dependency) · `GET /readyz` (readiness, 503 while draining) | Health endpoints |
| `OpsModule` | operations.md | `src/ops/ops.module.ts`. `@Module` — `exports` `ReadinessService` and carries `HealthController`. `AppModule` imports it | Operations module |
| `installShutdown` | operations.md | `src/ops/shutdown.ts`. `installShutdown(app, env)` — `env` is `Pick<EnvVars, 'DRAIN_DELAY_MS' \| 'SHUTDOWN_TIMEOUT_MS'>`, returning `void` — wires SIGTERM/SIGINT. Drain → grace period → `app.close()` → `closeAllConnections()` on timeout. **`bootstrap` calls it before `listen`** | Shutdown wiring |
| `buildLogger` | operations.md | `src/ops/logging.ts`. `buildLogger(env)` — the argument is `Pick<EnvVars, 'LOG_LEVEL'>`, returning a `ConsoleLogger` (`json: true`). **Attach it with `bufferLogs: true` + `app.useLogger(...)`, not as an option to `NestFactory.create`** — that is what keeps `main.ts` from reading `process.env` | Assembles the structured logger |
| `SlowQueryLogger` | operations.md | `src/ops/logging.ts`. A TypeORM `Logger` implementation — only `logQuerySlow` and `logQueryError` do real work. `buildDataSourceOptions` attaches it paired with `maxQueryExecutionTime` | Observes slow queries and query errors |

## requires — the seam must provide these

**Distinguish the kind.** `project` means the seam must `export` it; `library` comes from a package the seam
chose, so it is judged by whether the name appears in an import statement.

| symbol | kind | shape the pack assumes | why it belongs to the seam |
| --- | --- | --- | --- |
| `AppError` | project | Put it in `src/common/app-error.ts`. `new AppError(code, message?, details?)` · fields `code: string` · `details?: Record<string, string[]>`. **Must be in the code table**: `VALIDATION_FAILED` (thrown by `buildValidationPipe`) · `NOT_FOUND` (`TasksService`) · `CONFLICT` · `UNAUTHENTICATED` · `FORBIDDEN` · `INTERNAL`. Omit one and `ERROR_STATUS` silently falls to 500 | The error code table and the field error shape are a function of the wire contract |
| `AllExceptionsFilter` | project | Put it in `src/common/all-exceptions.filter.ts`. `new AllExceptionsFilter()` — no arguments. `@Catch()` — normalizes through `toAppError`, decides the status via `ERROR_STATUS`, then **emits the envelope**. `bootstrap` attaches it with `useGlobalFilters` | The response envelope shape is a function of the wire contract |
| `AuthGuard` | project | Put it in `src/auth/auth.guard.ts`. A `CanActivate` — puts the verified principal on `request.user`. Failure is `AppError('UNAUTHENTICATED')` | **How the token is verified is a function of the combination** — a session cookie when the frontend axis has a server runtime, a bearer token for an SPA |
| `CurrentUser` | project | Put it in `src/auth/current-user.decorator.ts`. A parameter decorator built with `createParamDecorator` — the controller receives it as `@CurrentUser() user: AuthUser` | Same as above. The injection shape is a function of the guard |
| `AuthUser` | project | At minimum `{ id: string }`. Attached to Express `Request['user']` by declaration merging | Same as above |
| `TasksController` | project | Put it in `src/tasks/tasks.controller.ts`. `@Controller('api/tasks')` — consumes this pack's `TasksService` and DTOs to build the endpoints and the envelope. It is carried in `TasksModule`'s `controllers` | The handler shape and the envelope are a function of the combination (`api-endpoints` in `seamSlots`) |
| `authFor` | project | `authFor(ownerId: string) => Record<string, string>` — builds the auth header object to pass to supertest `.set()`. **Test-only**; app code never calls it | Header or cookie is a function of `auth-boundaries`. Left as prose only, the gate cannot catch it after assembly |

## Known gaps

None. All six axis-local mandatory slots are filled, and what looks empty (API endpoints · auth boundaries ·
complete example) is not a gap but **the seam's share**, declared by `seamSlots` in `pack.json`.
For unverified items of content, `knownGaps` in `pack.json` is the canonical source.

## Symbols appearing in examples (app symbols the project creates)

Neither `provides` nor `requires` — the pack does not define them and the seam is not going to supply them; the consumer
project writes them for its own domain. They appear by name only in examples, so having no definition after
assembly is normal.

| name | appears in | role |
| --- | --- | --- |
| `UsersModule` | project-structure.md (module assembly example) | Another feature module |
| `CreateTasks1756000000000` | data-modeling.md §5 (migration example) | A migration class. The name carries a timestamp, so it differs per project |
