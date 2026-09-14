<!-- orangekit-pack-ledger: backend/firebase v3.14.0 -->

# firebase pack — symbol ledger (L0 declaration)

This is the contract the main session declared before authoring. It is the only device that keeps duplicate definitions and **guessed
signatures** from appearing when clusters are split and written in parallel.

## provides — this pack defines these

**The "shape" column is mandatory.** Assign only the owning file and leave the shape empty and a sibling cluster
guesses the signature — measured: another cluster called `getTask(ownerId, id)` as `getTask(id, ownerId)`, and
because both arguments are `string` neither TypeScript nor the gate caught it, turning every single-document read into a 404.
Write the argument **order** · the return · what it throws on failure · **and what the caller has to wire up**.

**Two places that are especially dangerous in this pack**:
① `ownerId` and `taskId` are **both `string`**. Pin the order **`ownerId` → `taskId`** across every
function.
② **The obligation to consume the fields** — even with a matching signature, not using the *content* of an argument
is the same class of fatal defect (measured on aws-serverless: the create function discarded `status`, and documents
created with that value vanished from the list forever).

| symbol | definition file | shape | role |
| --- | --- | --- | --- |
| `TaskDoc` | data-modeling.md | **`functions/src/firestore/model.ts`** — `{ id: string; title: string; status: TaskStatus; ownerId: string; createdAt: Timestamp; updatedAt: Timestamp }` — **`id` is a copy of the document ID** (so a query result can be serialized as-is). `createdAt` is written with `FieldValue.serverTimestamp()` and **the client's clock is not trusted** | Document shape |
| `TaskStatus` | data-modeling.md | **`functions/src/firestore/model.ts`** — `'open' \| 'done'` — rules, schema and queries use **the same literal set**. That list is also baked into the rules as strings, so extend it in both places together | Status enumeration |
| `COLLECTION` | data-modeling.md | **`functions/src/firestore/model.ts`** — `const COLLECTION = 'tasks'` — **the only place** the collection name is assembled. Let the rules path and this constant diverge and the rules guard a different collection | Collection name |
| `taskConverter` | data-modeling.md | **`functions/src/firestore/model.ts`** — `FirestoreDataConverter<TaskDoc>` — `toFirestore`/`fromFirestore`. **`fromFirestore` fills `id` from the snapshot.** Use `snap.data()` without the converter and objects with no `id` circulate | Type converter |
| `rulesForTasks` | security-rules.md | **`firestore.rules`** — the `match /tasks/{taskId}` block in `firestore.rules` — `read`, `create`, `update` and `delete` are written **separately**. Bundle them under one `write` and the invariants of create and update differ, so one of the two is necessarily loose | Security rules |
| `isOwner` | security-rules.md | **`firestore.rules`** — the rules function `isOwner(res)` — `request.auth != null && res.data.ownerId == request.auth.uid`. **On `update` it looks at both `resource` (the existing document) and `request.resource` (the new one)** — look only at the new one and an update handing ownership to someone else passes | Rules function |
| `db` | data-access.md | **`functions/src/firestore/client.ts`** — `Firestore` — holds the result of `getFirestore()` at **module top level** (outside the cold start). `initializeApp()` is called once — **though calling it again with the same options quietly returns the first app without throwing** (`app/duplicate-app` only when the options differ). So a duplicate call is blocked by discipline, not by the runtime (measured by C2) | admin client |
| `listTasks` | data-access.md | **`functions/src/firestore/tasks.ts`** — `(ownerId: string, q: TaskQuery) => Promise<{ items: TaskDoc[]; cursor?: string }>` — `where('ownerId','==',ownerId)` is **the only boundary**. Pages with `orderBy('createdAt','desc')` + `startAfter` | List |
| `getTask` | data-access.md | **`functions/src/firestore/tasks.ts`** — `(ownerId: string, taskId: string) => Promise<TaskDoc \| null>` — **the order of the two `string`s is everything.** Read the document, confirm the `ownerId` matches, and return `null` (not an exception) when it does not — a document ID alone reads other people's documents too | Single document |
| `createTask` | data-access.md | **`functions/src/firestore/tasks.ts`** — `(ownerId: string, input: TaskCreate) => Promise<TaskDoc>` — **carries over both `title` and `status` from `input`.** Hard-code `status` and the value the client sent vanishes silently. `ownerId` comes only from the auth context | Create |
| `updateTask` | data-access.md | **`functions/src/firestore/tasks.ts`** — `(ownerId: string, taskId: string, patch: TaskUpdate) => Promise<TaskDoc>` — writes **after confirming existence and ownership inside a transaction**. Split the check from the write and the owner can change in between. Absent or owned by someone else is `AppError('NOT_FOUND')` | Update |
| `deleteTask` | data-access.md | **`functions/src/firestore/tasks.ts`** — `(ownerId: string, taskId: string) => Promise<void>` — **`delete()` succeeds even on a document that does not exist.** Confirm existence and ownership inside a transaction, otherwise `AppError('NOT_FOUND')`. Unchecked, a request to delete someone else's document is answered as success | Delete |
| `encodeCursor` | data-access.md | **`functions/src/firestore/tasks.ts`** — `(createdAt: Timestamp, taskId: string) => string` — an opaque string. Do not turn an internal sort key into a wire contract | Cursor encoding |
| `decodeCursor` | data-access.md | **`functions/src/firestore/tasks.ts`** — `(cursor: string) => { createdAt: Timestamp; taskId: string }` — failure is `AppError('VALIDATION_FAILED')`. **A cursor is not trusted input** | Cursor decoding |
| `TaskCreateSchema` | input-validation.md | **`functions/src/schemas/task.ts`** — `z.strictObject` — **rejects** unknown keys. `status` defaults to `'open'` | Create body |
| `TaskUpdateSchema` | input-validation.md | **`functions/src/schemas/task.ts`** — partial update. **Do not put `.default()` on an optional field** — with it, a field that was not sent overwrites what is stored with the default | Update body |
| `TaskQuerySchema` | input-validation.md | **`functions/src/schemas/task.ts`** — `z.object` — `limit` (1-100, default 20) · `cursor?` · `status?` | List query |
| `TaskCreate` · `TaskUpdate` · `TaskQuery` | input-validation.md | The `z.output` of each schema | Derived types |
| `REGION` | input-validation.md | **`functions/src/params.ts`** — `defineString('TASKS_REGION', …)`. **Declare it at module top level and call `.value()` inside the handler** — a top-level call blows up during the deploy analysis phase | Function parameter |
| `PAGE_MAX` | input-validation.md | **`functions/src/params.ts`** — `defineInt('TASKS_PAGE_MAX', …)` | Function parameter |
| `WEBHOOK_KEY` | input-validation.md | **`functions/src/params.ts`** — `defineSecret('TASKS_WEBHOOK_KEY')` | Secret parameter |
| `Config` | input-validation.md | **`functions/src/params.ts`** — `z.output<typeof ConfigSchema>` | Config type |
| `config` | input-validation.md | **`functions/src/params.ts`** — `config() => Config` — validates the parameter values with Zod and caches them. **Call it inside the handler**. **The keys are the environment variable names verbatim** (`TASKS_PAGE_MAX` · `TASKS_WEBHOOK_KEY`) — do not rewrite them as camelCase. Keeping them identical to the declared parameters is what makes a missing one visible (measured: a sibling cluster destructured `{ pageMax }` and got `undefined`) | Config accessor |
| `parseCallable` | input-validation.md | **`functions/src/schemas/task.ts`** — `<S extends z.ZodType>(schema: S, data: unknown) => z.output<S>` — validates `onCall`'s `request.data`. Failure is `AppError('VALIDATION_FAILED')` | Call body parsing |
| `logger` | functions-patterns.md | **`functions/src/obs/logger.ts`** — re-exports `firebase-functions/logger`. **Do not use `console.log`** — the structured fields disappear and it cannot be queried in Cloud Logging | Structured logger |
| `withErrors` | functions-patterns.md | **`functions/src/obs/logger.ts`** — `<T>(h: (req: CallableRequest) => Promise<T>) => (req: CallableRequest) => Promise<T>` — moves an `AppError` onto an `HttpsError`, logs an unhandled exception and then **folds it into a generic message**. **Wrap the handler and export that** | Handler wrapper |
| `requireUid` | functions-patterns.md | **`functions/src/obs/logger.ts`** — `(req: CallableRequest) => string` — synchronous. Without `req.auth?.uid` it throws `AppError('UNAUTHENTICATED')`. **`onCall` verifies the token automatically but does not block its absence** | Principal extraction |
| `emulatorEnv` | testing-and-deploy.md | **`functions/test/emulator.ts`** — `() => void` — sets `FIRESTORE_EMULATOR_HOST` and friends before the tests. **The only device keeping tests from leaking onto the real project** | Emulator wiring |
| `withRulesTest` | testing-and-deploy.md | **`functions/test/emulator.ts`** — `(fn: (env: RulesTestEnvironment) => Promise<void>) => Promise<void>` — opens the `@firebase/rules-unit-testing` environment and always closes it. Leave it open and the next test runs on the previous rules | Rules test harness |

## Owner of each test file — **one owner per path**

When two clusters each ship the same logical file, **the paths differ and the gate's duplicate-fence check does not
catch it either** — measured: `rules.test.ts` shipped twice under different paths with different content, and the
"block proof" conclusions of the two files contradicted each other head-on.

| file | owning resource | content |
| --- | --- | --- |
| `functions/test/emulator.ts` | testing-and-deploy.md | `emulatorEnv` · `withRulesTest` · `RULES` |
| `functions/test/rules.test.ts` | **security-rules.md** | All of the rules unit tests. Other resources **only reference** it |
| `functions/test/tasks.test.ts` | testing-and-deploy.md | Function (`onCall`) regression |
| `functions/test/repo.test.ts` | data-access.md | Repository direct-call regression — it does not go through a callable |

**Every test goes under `functions/test/`** — do not use a root `test/`.

## Function entry points the pack exports — **the names are pinned here**

These are the names `functions/src/index.ts` exports. **The seam owns them** (`api-endpoints` decides which
endpoints exist), but **the axis pins the names** — unpinned, each cluster calls them something different, and
measured, that actually happened (they split into `tasksCreate` ↔ `createTask` and the test file would not even
load). Use the prefixed form so the names **do not collide** with the repository symbols (`createTask` and friends).

| export | repository counterpart |
| --- | --- |
| `tasksList` | `listTasks` |
| `tasksGet` | `getTask` |
| `tasksCreate` | `createTask` |
| `tasksUpdate` | `updateTask` |
| `tasksDelete` | `deleteTask` |

**`tasksGet` does not return `null` for a missing document** — it throws `AppError('NOT_FOUND')` and
`withErrors` moves that onto `HttpsError('not-found')`. Returning `null` is the contract of the repository's
`getTask`, not of the callable.

## requires — the seam must provide these

| symbol | kind | shape the pack assumes | why it belongs to the seam |
| --- | --- | --- | --- |
| `AppError` | project | `new AppError(code: string, message: string, details?: Record<string, string[]>)` — **the last two arguments are both `string`, so the order is everything.** Must be in the code table: `VALIDATION_FAILED` · **`UNAUTHENTICATED`** (thrown by `requireUid`) · `NOT_FOUND` · `CONFLICT` · `FORBIDDEN` · `INTERNAL` | The error code table is a function of the wire contract |
| `toHttpsError` | project | `toHttpsError(e: unknown) => HttpsError` — moves an `AppError` onto a Firebase `HttpsError` code. **`withErrors` calls it** | The envelope is a function of the wire contract |
| `AuthUser` | project | At minimum `{ uid: string; roles: string[] }` — pulled from custom claims | The claim shape is a function of the auth method |
| `authFor` | project | `authFor(uid: string, roles?: string[]) => Partial<CallableRequest>` — builds the auth context fragment a test passes to a function. **Synchronous**. **The pack does not define this name locally** — define it and there are two definitions after assembly (measured: the react-vite pack made the same mistake). When a pack test needs a throwaway principal, use a different name such as `fakeAuth` | Same as above |
| `clientAccessPolicy` | project | `'rules-only' \| 'functions-only' \| 'both'` — declares **whether the frontend reads Firestore directly through the SDK**. This value changes which of the rules and the functions is the primary boundary, so the combination decides it | The access path is a function of the combination |

## Justifying the gate's REVIEWs (no silent pass)

| REVIEW | verdict |
| --- | --- |
| Exports missing from the ledger: `tasksList`·`tasksGet`·`tasksCreate`·`tasksUpdate`·`tasksDelete` | **Normal — the seam decides ownership.** On this axis a function is an endpoint, so "which endpoints exist" is the share of the `api-endpoints` seam slot (in a combination where the frontend reads directly through the SDK the count shrinks or goes to 0). The pack exports five **as examples that show the shape**, and the seam uses them as-is, picks among them, or rewrites them. Putting them in the ledger's `provides` would mean "the pack pinned this as a contract" and take the decision away from the seam |
| Ghost definitions: `tasksCreate`·`tasksUpdate`·`tasksDelete` | **Normal for the same reason.** The three mutation functions are entry points exported by `functions/src/index.ts`, and **their consumers are the client SDK and the deploy pipeline**, not the guide body. `tasksList` and `tasksGet` are not on this list because the tests call them |
| Export missing from the ledger: `TaskStatusSchema` | **Normal.** It is the Zod counterpart of the `TaskStatus` literal union, reused by `TaskCreateSchema`, `TaskUpdateSchema` and `TaskQuerySchema`. The ledger already pins `TaskStatus`, so there is no need to pin its derivative again |
| Exports missing from the ledger: `PROJECT_ID`·`RULES` | **Normal.** They are local constants of the rules unit test harness (used by `withRulesTest`). Neither the seam nor any other file references them |

## Known gaps

None. Every axis-local mandatory slot is filled, and what looks empty (API endpoints · auth boundaries ·
complete example) is the seam's share, declared by `seamSlots` in `pack.json`.
