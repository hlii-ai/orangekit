<!-- orangekit-pack-ledger: backend/aws-serverless v3.34.0 -->

# aws-serverless pack — symbol ledger (the L0 declaration)

This is the contract the main session declared before authoring. It is the only device that keeps duplicate
definitions and **signature guessing** out when clusters are split and written in parallel.

## provides — this pack defines these

**The "shape" column is mandatory.** Assign only the owning file and leave the shape empty and a sibling cluster
guesses the signature — measured (2026-08-23, node-api), another cluster called `getTask(ownerId, id)` as
`getTask(id, ownerId)`, and because both arguments are `string` neither TypeScript nor the gate
caught it, turning every single-item read into a 404. Record argument **order** · the return · what it throws on failure ·
**and what the caller is obliged to wire**.

| symbol | definition file | shape | role |
| --- | --- | --- | --- |
| `Task` | data-modeling.md | **`src/keys.ts`** — `{ pk: string; sk: string; id: string; title: string; status: 'open' \| 'done'; ownerId: string; createdAt: string; gsi1pk?: string; gsi1sk?: string }` — **the key attributes live on the item** (DynamoDB has no code generation) | Domain item |
| `keys` | data-modeling.md | **`src/keys.ts`** — `keys.task(ownerId, id) => { pk, sk }` · `keys.taskList(ownerId) => { pk, skPrefix }` · `keys.taskGsi1(ownerId, status, id) => { gsi1pk, gsi1sk }` · `keys.statusList(ownerId, status) => { gsi1pk, gsi1skPrefix }` · `keys.newId() => string` — **the owner is first in every one of them.** Two of `taskGsi1`'s three arguments are `string`, so the order is everything. Key assembly happens in this one place only | Key assembly utility |
| `TABLE` | data-modeling.md | **`src/keys.ts`** — `const TABLE: string` — it comes from `env.TABLE_NAME` | The single-table name |
| `ddb` | data-access.md | **`src/db/client.ts`** — a `DynamoDBDocumentClient` singleton. **Build it outside the handler (at module top level)** — initialization outside the cold start | Document client |
| `listTasks` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, q: { limit: number; cursor?: string; status?: TaskStatus }) => Promise<{ items: Task[]; cursor?: string }>` — it uses Query only (Scan forbidden) | List |
| `getTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, id: string) => Promise<Task \| null>` — **the owner is first** | Single item |
| `putTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, input: TaskCreate) => Promise<Task>` — **carry over both `title` and `status` from `input`.** Hardcode `status` and the GSI partition is pinned along with it, so an item created under that value disappears from the list forever (audits A and C, measured). Only `ownerId` comes from the session. `ConditionExpression` prevents an overwrite, and a collision is `AppError('CONFLICT')` | Create |
| `updateTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, id: string, patch: TaskUpdate) => Promise<Task>` — a conditional update. A failed condition is `AppError('NOT_FOUND')` | Update |
| `deleteTask` | data-access.md | **`src/db/tasks.ts`** — `(ownerId: string, id: string) => Promise<void>` — a conditional delete. A failed condition is `AppError('NOT_FOUND')` | Delete |
| `encodeCursor` | data-access.md | **`src/db/tasks.ts`** — `(key: Record<string, unknown>) => string` — turns a `LastEvaluatedKey` into an opaque string | Cursor encoding |
| `decodeCursor` | data-access.md | **`src/db/tasks.ts`** — `(cursor: string) => Record<string, unknown>` — failure is `AppError('VALIDATION_FAILED')` | Cursor decoding |
| `EnvSchema` | input-validation.md | **`src/env.ts`** — a `ZodObject` — applied at **module top level (the cold start)** through `safeParse(process.env)` | Environment variable schema |
| `env` | input-validation.md | **`src/env.ts`** — `Env` — `TABLE_NAME` · `LOG_LEVEL` · `NODE_ENV` · `AWS_REGION` | Validated environment values |
| `TaskCreateSchema` | input-validation.md | **`src/schemas/task.ts`** — `z.strictObject` — it **refuses** unknown keys | Create body |
| `TaskUpdateSchema` | input-validation.md | **`src/schemas/task.ts`** — a partial update. Do not stack `.default()` onto it | Update body |
| `TaskQuerySchema` | input-validation.md | **`src/schemas/task.ts`** — `z.object` — it **strips** unknown keys | List query |
| `parseBody` | input-validation.md | **`src/http/parse.ts`** — `<S extends z.ZodType>(schema: S, event: APIGatewayProxyEventV2) => z.output<S>` — a missing or non-JSON body gives `AppError('VALIDATION_FAILED')` | Body parsing |
| `parseQuery` | input-validation.md | **`src/http/parse.ts`** — `<S extends z.ZodType>(schema: S, event: APIGatewayProxyEventV2) => z.output<S>` — `queryStringParameters` can be `null` | Query parsing |
| `pathParam` | input-validation.md | **`src/http/parse.ts`** — `(event: APIGatewayProxyEventV2, name: string) => string` — absent gives `AppError('VALIDATION_FAILED')` | Path parameter |
| `Env` | input-validation.md | **`src/env.ts`** — `z.infer<typeof EnvSchema>` | |
| `TaskCreate` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskCreateSchema>` | |
| `TaskUpdate` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskUpdateSchema>` | |
| `TaskQuery` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskQuerySchema>` | |
| `TaskStatusSchema` | input-validation.md | **`src/schemas/task.ts`** — `z.enum(['open', 'done'])` — `TaskStatus` derives from it and both request schemas reuse it | Status enum |
| `TaskStatus` | input-validation.md | **`src/schemas/task.ts`** — `z.output<typeof TaskStatusSchema>` = `'open' \| 'done'` | |
| `ERROR_STATUS` | error-handling.md | **`src/http/errors.ts`** — `Record<string, number>` — domain code → HTTP status. **The only mapping table** | Status mapping |
| `toAppError` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => AppError` — the response adapter **must call it first** | Normalization |
| `isConditionalCheckFailed` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => boolean` — `ConditionalCheckFailedException` **and** `TransactionCanceledException`'s `CancellationReasons[i].Code === 'ConditionalCheckFailed'`. Go by the name alone and a condition failure inside a transaction is missed and becomes a 500 (C1, measured) | Condition-failure detection |
| `isThroughputExceeded` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => boolean` — `ProvisionedThroughputExceededException` · `RequestLimitExceeded` · **`ThrottlingException`** (the name an on-demand table uses) · `$metadata.httpStatusCode === 429`. The basis is the SDK's own `THROTTLING_ERROR_CODES` (C1, measured) | Throttle detection |
| `isInvalidRequest` | error-handling.md | **`src/http/errors.ts`** — `(e: unknown) => boolean` — `ValidationException`. It arrives when the request does not match DynamoDB's syntax or constraints. **`toAppError` folds it into a 400** — without the mapping, the ordinary misuse of reusing a cursor against a different index becomes a 5xx (audit A, measured) | Request-shape error detection |
| `fieldErrors` | error-handling.md | **`src/http/errors.ts`** — `(e: ZodError) => Record<string, string[]>` | Field errors |
| `logger` | handler-patterns.md | **`src/obs/logger.ts`** — `Logger` (powertools). **Build it at module top level** — attach request-scoped values with `addContext` | Structured logger |
| `ApiHandler` | handler-patterns.md | `(e: APIGatewayProxyEventV2, c: Context) => Promise<APIGatewayProxyResultV2>` — **do not use `Handler` from `@types/aws-lambda`.** `Handler`'s return is `void \| Promise<T>`, so `await h(...)` is TS2322 (reproduced on tsc 5.9.3). The narrowed shape is assignable to `Handler` | Handler type alias |
| `withContext` | handler-patterns.md | **`src/obs/logger.ts`** — `(h: ApiHandler) => ApiHandler` — it attaches the request ID and the cold-start flag to the logger, logs an unhandled exception and then **rethrows it**. **Export the handler wrapped in it.** What turns it into an envelope is the `try/catch` + `respond.fail` inside the handler, not this wrapper | Handler wrapper |
| `isColdStart` | handler-patterns.md | **`src/obs/logger.ts`** — `() => boolean` — `true` on the first invocation only. It reads a module top-level flag | Cold-start detection |
| `TaskTable` | deploy-and-iam.md | **`infra/table.ts`** — a CDK `Construct` subclass. `new TaskTable(scope, id)` — it creates the single table + GSI1 | Table stack |
| `grantTaskAccess` | deploy-and-iam.md | **`infra/table.ts`** — `(fn: NodejsFunction, table: TaskTable, mode: 'read' \| 'write' \| 'batch') => void` — **least privilege per function.** Do not grant table-wide permissions. `'batch'` adds `BatchGetItem`·`BatchWriteItem`·`TransactWriteItems`·`ConditionCheckItem` — grant it **only to functions that really call a batch or a transaction** (audit A: with only the two modes, the batch pattern the pack teaches turns into a runtime AccessDenied) | IAM grant |
| `invokeHandler` | testing.md | **`test/invoke.ts`** — `(h: ApiHandler, event: Partial<APIGatewayProxyEventV2>) => Promise<APIGatewayProxyResultV2>` — it runs the handler directly from a test. **The event is merged shallowly** — if `authFor` supplies `requestContext` it overwrites the default `requestContext` wholesale, so it has to carry `requestId` and `http` back too | Test harness |

## requires — the seam must provide these

`project` means the seam has to `export` it, and `library` is decided by whether the name appears
in an import statement. **Write the call signature for every symbol the pack calls** — leave it out and the seam
guesses the argument order (the gate blocks that with a FAIL).

| symbol | kind | shape the pack assumes | why it is a seam |
| --- | --- | --- | --- |
| `AppError` | project | `new AppError(code: string, message: string, details?: Record<string, string[]>)` — **the last two arguments are both `string`, so the order is everything.** The code table must contain: `VALIDATION_FAILED` · **`UNAUTHENTICATED`** (`requireAuth` throws it — leave it out and a 401 goes out as a 500) · `NOT_FOUND` · `CONFLICT` · `FORBIDDEN` · `RATE_LIMITED` · `INTERNAL`. Put it in `src/http/app-error.ts` | The error code table and the field-error shape are functions of the wire contract |
| `respond` | project | `respond(result: unknown, init?: { status?: number }) => APIGatewayProxyResultV2` · `respond.fail(e: unknown) => APIGatewayProxyResultV2` — **normalize with `toAppError` first, then settle the status from `ERROR_STATUS`.** Put it in `src/http/respond.ts` | The response envelope is a function of the wire contract |
| `requireAuth` | project | `requireAuth(event: APIGatewayProxyEventV2) => AuthUser` — synchronous. Failure is `AppError('UNAUTHENTICATED')`. Put it in `src/http/require-auth.ts`. **It is not middleware but a function called on the handler's first line** (Lambda has no middleware chain) | The token verification method is a function of the combination |
| `AuthUser` | project | at minimum `{ id: string; roles: string[] }` — pulled from the Cognito claims | Same as above |
| `authFor` | project | `authFor(ownerId: string, roles?: string[]) => Partial<APIGatewayProxyEventV2>` — it builds the event fragment (the authorizer claims) a test passes to `invokeHandler`. **Synchronous** | The claim shape is a function of the auth method |
| `routes` | project | the declaration that maps API Gateway routes to functions in CDK. It assumes the shape `routes(scope, { table })` | Route↔function mapping is a function of the combination |

## Known gaps

None. All 6 axis-local mandatory slots are filled, and what looks empty (API endpoints · auth boundaries ·
complete example) is the seam's share, declared by `seamSlots` in `pack.json`.

## Symbols appearing in examples — app symbols (the project creates them)

Neither `provides` nor `requires`. Only the name appears in the examples, so having no definition even after assembly is normal.

| name | appears in | role |
| --- | --- | --- |
| `TaskService` | handler-patterns.md (layering example) | Service-layer example |

## Justification for the gate's REVIEWs (no silent pass)

| REVIEW | verdict |
| --- | --- |
| mixed call shapes for `grantTaskAccess` and `invokeHandler` | **False positive.** Both are multi-line calls, so the gate's single-line scan reads them as calls with no arguments. The real calls take 3 and 2 arguments respectively, matching the ledger shape |
| `TaskQuery` appears once | **Normal.** The seam's handler uses it to type the return of `parseQuery(TaskQuerySchema, event)` — having no consumer inside the pack is correct (`TaskCreate` and `TaskUpdate` are the same) |
| `usersTable` | deploy-and-iam.md (least-privilege contrast example) | A table for another domain |
