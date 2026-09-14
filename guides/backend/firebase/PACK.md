<!-- orangekit-pack: backend/firebase v3.14.0 verified 2026-08-24 firebase-admin@14 firebase-functions@7 firebase@12 firebase-tools@15 zod@4 typescript@7 vitest@4 @types/node@26 @firebase/rules-unit-testing@5 -->

# firebase axis pack — hub fragments

These are the **axis-local fragments to insert verbatim** when building the combination hub (`SKILL.md`). A combination that has a
pre-built seam does not use this file — there the seam's `HUB.md` holds the whole hub.

Each fragment sits between `<!-- pack-slot: name -->` and `<!-- /pack-slot -->`, closes inside the axis,
and holds whatever the frontend axis turns out to be.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
functions/
├── src/
│   ├── index.ts             # Function exports only — no logic here (the deploy analysis reads this file)
│   ├── params.ts            # defineString/defineSecret — the **only** file that declares configuration values
│   ├── firestore/
│   │   ├── client.ts        # initializeApp + getFirestore (module top level, outside the cold start)
│   │   ├── model.ts         # TaskDoc · TaskStatus · COLLECTION · taskConverter
│   │   └── tasks.ts         # Task repository — confirms existence and ownership in a transaction
│   ├── schemas/
│   │   └── task.ts          # Zod schemas + parseCallable
│   ├── http/
│   │   ├── app-error.ts     # AppError — **owned by the seam**
│   │   ├── https.ts         # toHttpsError — **owned by the seam**
│   │   └── auth.ts          # AuthUser · authFor — **owned by the seam**
│   └── obs/
│       └── logger.ts        # Re-exports firebase-functions/logger · withErrors · requireUid
├── test/
│   ├── setup.ts             # vitest setupFiles — emulatorEnv() runs before any src/ import
│   ├── emulator.ts          # emulatorEnv · withRulesTest · RULES — the only device keeping tests off the real project
│   ├── rules.test.ts        # Rules unit tests — **owned by security-rules.md** (one owner per path)
│   ├── tasks.test.ts        # Function (onCall) regression — owned by testing-and-deploy.md
│   └── repo.test.ts         # Repository direct-call regression — owned by data-access.md
├── vitest.config.mts        # setupFiles · fileParallelism:false. It is `.mts` because of type:commonjs
└── .env / .env.local / .secret.local   # **gitignore these.** The CLI generates .env.local automatically and it beats .env

scripts/
└── check-indexes.mjs        # The only local index check before deploy (firebase deploy demands auth first)

firestore.rules              # Rules — the tasks block writes read/create/update/delete separately
firestore.indexes.json       # Composite indexes — change a query and this changes too. **It is pure JSON**
firebase.json                # Emulator suite configuration — the harness reads the ports from here
```

**There are two boundaries and they block different code paths.** Security Rules block **direct access from
the client SDK**; the application checks block **Cloud Functions**. `firebase-admin`
**bypasses the rules entirely**, so however tight the rules are, that path is defenseless unless
ownership is confirmed inside the function. Look at only one of the two boundaries and write "there is a policy
engine, so we are safe" and exactly that hole remains.

**The three files in `src/http/` are seam-owned.** The pack only calls them.
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
## Core Principles

1. **There are two boundaries and they block different code paths.** Security Rules block only direct access from the
   client SDK. `firebase-admin` **bypasses the rules entirely** <!-- verified: pilot C1 emulator run — with the rules denying everything, the client SDK got permission-denied and the admin SDK succeeded -->
2. **Ownership lives in the query.** The function path has no rules, so `where('ownerId','==',ownerId)` is the only
   boundary. Reading by document ID alone reads other people's documents, so `getTask` confirms ownership after the read and returns `null` otherwise.
3. **The check and the write are in one transaction.** Split them and the owner changes in between. `delete()` succeeds even on a missing document, so `deleteTask` is no exception.
4. **The server makes the timestamp.** `FieldValue.serverTimestamp()` is a **sentinel**, so the write's return value carries no value —
   read the document again to confirm <!-- verified: pilot C1 measurement — `instanceof Timestamp === false`, and `set()` returns only `_writeTime` -->
5. **One `params` file owns the configuration.** Declare at module top level and call `.value()` **inside the handler** — a top-level call blows up during the deploy analysis phase.
6. **It is a document model — there are no joins.** The query shape is the index, and changing a `where`+`orderBy` combination
   changes `firestore.indexes.json` with it. Normalization and foreign-key idioms are dormant on this axis.
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
## Common Imports

```ts
// functions/src/index.ts — 2nd gen entry points
import { onCall, type CallableRequest } from 'firebase-functions/v2/https';
import { withErrors, requireUid } from './obs/logger';
// functions/src/obs/logger.ts — re-exported structured logger (`logger` comes only from here)
export * as logger from 'firebase-functions/logger';
// functions/src/firestore/client.ts — module top level, outside the cold start
import { initializeApp } from 'firebase-admin/app';
import { getFirestore, FieldValue, Timestamp } from 'firebase-admin/firestore';
// functions/src/params.ts · functions/src/schemas/task.ts
import { defineString, defineSecret } from 'firebase-functions/params';
import { z } from 'zod';
```

`HttpsError` also comes from `firebase-functions/v2/https`, but `toHttpsError`, which throws it, is **seam-owned** (`src/http/https.ts`) and the pack only calls it through `withErrors`.

### Places confused with 1st gen

| 1st gen idiom | the form on this axis (2nd gen) |
| --- | --- |
| `import * as functions from 'firebase-functions'` → `functions.https.onCall` | Straight from the subpath — `import { onCall } from 'firebase-functions/v2/https'` |
| Handler arguments `(data, context)` · `context.auth.uid` | **One** argument `(request: CallableRequest)` · `request.data` · `request.auth?.uid` (`requireUid` pulls it out) |
| `functions.config().svc.key` | `defineString`/`defineSecret` in `params` · `.value()` inside the handler |
| `functions.region('…').https.onCall(h)` | The first argument is the options — `onCall({ region, concurrency, minInstances }, h)` |
| `admin.firestore()` · `admin.firestore.FieldValue` | `getFirestore()` · `FieldValue` from `firebase-admin/firestore` |
<!-- /pack-slot -->

<!-- pack-slot: architecture-overview -->
## Architecture Overview

```
[A] Client SDK path (firebase@12)
Browser ──direct read/write──▶ ║ Security Rules ║ ──▶ Firestore
                              rulesForTasks · isOwner   ← this boundary blocks [A] only

[B] Function path (firebase-admin@14)
Browser ──onCall──▶ withErrors ─▶ requireUid ─▶ parseCallable ─▶ repository ─▶ db ─▶ Firestore
                        │             │              │        listTasks·getTask   (no rules evaluation)
                        │             │              │        createTask·updateTask·deleteTask
       AppError→toHttpsError    UNAUTHENTICATED  VALIDATION_FAILED   │
                                                                     ▼
                              ║ Application checks — where('ownerId'…) · runTransaction check ║
                                                        ← this boundary blocks [B] only
```

**The rules do not sit on [B].** The admin SDK attaches with administrator credentials, so however tight `rulesForTasks` is,
[B] is defenseless unless ownership is confirmed inside the function. Conversely the application checks cannot see [A] — a request
attaching directly through the SDK passes not one line of function code. Which path is open is declared by the seam's
`clientAccessPolicy`.

`taskConverter` sits between `db` and the repository — `fromFirestore` fills `id` from the snapshot, so a `snap.data()` that
skips the converter leaks objects with no `id`. The list's cursor is wrapped by `encodeCursor`/`decodeCursor`.
<!-- /pack-slot -->

<!-- pack-slot: http-status-and-antipatterns -->
## Error Codes and Antipatterns

This is the correspondence between `AppError`'s domain codes and the `HttpsError` codes. **The function that moves between them (`toHttpsError`) is seam-owned**, and the pack throws only `AppError`, assuming this correspondence.

| domain code (`AppError`) | `HttpsError` code | when |
| --- | --- | --- |
| `VALIDATION_FAILED` | `invalid-argument` | `parseCallable` failed · `decodeCursor` failed |
| `UNAUTHENTICATED` | `unauthenticated` | `requireUid` could not find `request.auth` |
| `NOT_FOUND` | `not-found` | The existence-and-ownership check of `updateTask`/`deleteTask` failed |
| `FORBIDDEN` | `permission-denied` | Insufficient role (`AuthUser.roles`) |
| `CONFLICT` | `already-exists` | Uniqueness constraint violation |
| `INTERNAL` | `internal` | Unhandled exception — `withErrors` logs it and folds it into a generic message |

| recurring anti-pattern | why it is expensive |
| --- | --- |
| Putting the original exception verbatim on the `HttpsError` | Firestore paths and field names leak to the client. That is why `withErrors` folds them |
| Answering `FORBIDDEN` for a missing document | Whether someone else's document exists leaks through the code difference. Both are `NOT_FOUND` |
| Throwing on an ownership failure inside `getTask` | The contract is `null`. Throw and the caller's branching splits |
<!-- /pack-slot -->

<!-- pack-slot: quick-start-axis -->
## Quick Start — adding one feature

The order is the dependency. A later step references names from an earlier one, so going backwards means fixing things twice.

| # | step | file to open | what to settle |
| --- | --- | --- | --- |
| 1 | Document shape | `functions/src/firestore/model.ts` | `TaskDoc` fields · `TaskStatus` literals · `COLLECTION` · `taskConverter` |
| 2 | Rules | `firestore.rules` | `read`/`create`/`update`/`delete` **separately** in `rulesForTasks`. `isOwner` looks at **both** `resource` and `request.resource` |
| 3 | Indexes | `firestore.indexes.json` | One composite index line per new `where`+`orderBy` combination |
| 4 | Repository | `functions/src/firestore/tasks.ts` | `listTasks`·`getTask`·`createTask`·`updateTask`·`deleteTask` — arguments in the order **`ownerId` → `taskId`** |
| 5 | Schemas | `functions/src/schemas/task.ts` | `TaskCreateSchema`·`TaskUpdateSchema`·`TaskQuerySchema` · `parseCallable` |
| 6 | Functions | `functions/src/index.ts` (+ `obs/logger.ts`) | Only `onCall` exports wrapped in `withErrors(…)`. No logic here |
| 7 | Tests | `functions/test/rules.test.ts` · `functions/test/tasks.test.ts` (`functions/test/emulator.ts`) | Rules through `withRulesTest`, wiring through `emulatorEnv`. Positive and negative paired inside **the same `it`** |

The two invariants of step 4 are the ones most often broken on this axis.

```ts
// functions/src/firestore/tasks.ts
const snap = await db.collection(COLLECTION).withConverter(taskConverter)
  .where('ownerId', '==', ownerId)
  .orderBy('createdAt', 'desc')
  .limit(q.limit)
  .get();

// The check and the write are in one transaction
await db.runTransaction(async (tx) => {
  const cur = await tx.get(ref);
  if (!cur.exists || cur.data()!.ownerId !== ownerId) throw new AppError('NOT_FOUND', 'Task not found');
  tx.update(ref, { ...patch, updatedAt: FieldValue.serverTimestamp() });
});
```
<!-- /pack-slot -->

<!-- pack-slot: anti-patterns-axis -->
## Anti-Patterns

| mistake | price |
| --- | --- |
| **"The rules are there, so we are safe"** — the rules are locked, so the function need not confirm ownership | `firebase-admin` **bypasses the rules entirely**. The whole function path is left defenseless — the most expensive single line on this axis <!-- verified: pilot C1 emulator run — with the rules denying everything, an admin SDK write succeeded --> |
| Bundling everything under one `allow write:` | The invariants of create and update differ so one of the two is necessarily loose, and on delete `request.resource` is `null`, so **even deleting your own document is refused** <!-- verified: pilot C1 measurement — Null value error --> |
| Looking only at `request.resource` in an `update` rule | It is the merged whole document, so `ownerId` is visible — an update handing ownership to someone else passes |
| Assuming the indexes are right because the emulator passed | **Two failure modes split here.** ⓐ **Missing composite index** — the emulator does not enforce it and in production **that one query** dies with `FAILED_PRECONDITION` <!-- verified: emptying the index list still passed both composite queries. As a positive control, an `in` of 31 gives INVALID_ARGUMENT and broken rules are reported as a compile error, so the observation apparatus is on (measured in audits B1 and B2) --> ⓑ **A syntax error in `firestore.indexes.json`** — the emulator **does not even read it and stays silent**, but `firebase deploy` **aborts the whole deploy** at `loadCJSON`/`validateSpec` <!-- verified: firebase-tools 15.28.1 source run — loadCJSON throws, firestore/api.js:63 validateSpec (audit B1) --> |
| `createTask` hard-coding `status` | The value the client sent vanishes silently, and documents created with it drop out of the list filter forever |
| Calling `getTask(taskId, ownerId)` | Both are `string`, so neither the type check nor the gate catches it. Every single-document read comes back empty |
| Putting `.default()` on an optional field of `TaskUpdateSchema` | A field that was not sent overwrites what is stored with the default |
| Running the tests without `emulatorEnv` | It attaches with real project credentials and writes to production data |
| Assuming deleting the parent document deletes the subcollection | The subcollection is **left orphaned** and the parent is `exists=false` — clean up explicitly <!-- verified: pilot C1 measurement --> |
<!-- /pack-slot -->

## For the seam to fill

| slot | why it is a function of the combination |
| --- | --- |
| `api-endpoints` | The onCall/onRequest choice + request/response envelope. **In a combination where the frontend reads directly through the SDK, the number of endpoints itself changes** |
| `auth-boundaries` | Custom claims and roles, and **whether direct client access is allowed** (`clientAccessPolicy`). That value changes whether the primary boundary sits in the rules or in the functions |
| `complete-example` | Rules → indexes → document write → query → function → test, end to end |
