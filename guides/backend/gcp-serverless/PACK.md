<!-- orangekit-pack: backend/gcp-serverless v3.14.0 verified 2026-08-24 hono@4 @hono/node-server@2 @google-cloud/firestore@9 jose@6 zod@4 typescript@7 vitest@4 @types/node@26 -->

# gcp-serverless axis pack — hub fragments

These are the fragments moved into `SKILL.md` at assembly time. Each fragment sits between `<!-- pack-slot: name -->` and
`<!-- /pack-slot -->`, and it closes inside the axis, so it is used as-is however the combination changes.
Only the slots listed in the "What the seam fills in" table at the end of the file are rewritten by the seam.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── main.ts                  # boot only — startServer() + shutdown(server) inside the SIGTERM handler
├── app.ts                   # createApp(): mount routers + installErrorHandlers + /healthz
├── settings.ts              # the **only file** that reads the process environment (validates and fails at module top level)
├── errors.ts                # AppError — **owned by the seam.** Does not import the framework
├── schemas/
│   ├── task.ts              # zod schemas + TaskStatus (the values are lowercase 'open'·'done')
│   └── errors.ts            # fieldErrors — zod errors into a field map
├── firestore/
│   ├── client.ts            # Firestore instance — module top level, one per process
│   ├── converter.ts         # taskConverter — re-parses the schema on read
│   ├── tasks.ts             # task repository — knows nothing about HTTP. ownerId → taskId order
│   ├── cursor.ts            # encodeCursor · decodeCursor — a cursor is not trusted input
│   └── errors.ts            # gRPC code detection (3·5·6·9·10) — knows nothing about HTTP
├── identity/
│   └── verify.ts            # verifyIdToken · jwks — Identity Platform ID tokens
├── http/
│   ├── errors.ts            # ERROR_STATUS · toAppError (imports hono)
│   ├── handlers.ts          # installErrorHandlers — **owned by the seam**
│   ├── auth.ts              # currentUser · AuthUser — **owned by the seam**
│   └── routes.ts            # apiRouter — **owned by the seam**
├── obs/
│   └── log.ts               # log() — one JSON line to stdout. Uses the severity key
└── services/
    └── tasks.ts             # domain rules. Calls the repository and throws AppError

firestore.indexes.json       # composite index declarations — without them the list query dies at runtime
firestore.rules              # blanket deny — on this axis the client never attaches to Firestore directly
vitest.config.ts             # test environment + emulator env injection (settings parses at module top level, so beforeAll is too late)
Dockerfile                   # Cloud Run container. Reads PORT from the environment and binds to 0.0.0.0

test/
├── helpers.ts               # appFetch · withEmulator
├── schemas.test.ts          # schema units — partial update·unknown key·empty object
├── errors.test.ts           # gRPC code detection and status mapping
└── tasks.test.ts            # ownership regression — the positive and the negative in the same test
```

**Layering runs one way**: `routes → services → firestore`. The moment a repository takes a `Context` or
knows an HTTP status, that layer has already collapsed — the tests only run once they stand up HTTP.

**The three files under `src/http/` (`handlers.ts`·`auth.ts`·`routes.ts`) and `src/errors.ts` belong to the
seam.** The pack only calls them. Having no definition before assembly is normal, and the gate
checks that they are satisfied when run with `--assembly`.
<!-- /pack-slot -->

<!-- pack-slot: quick-start-axis -->
## Quick Start

**When adding a new endpoint**
1. Define the request schema in `src/schemas/task.ts` — `.strict()` on **both the body and the query**
2. Add the repository function to `src/firestore/tasks.ts` — the first argument is **always `ownerId`**, then `taskId`
3. Put ownership in **the query's `where('ownerId', '==', ownerId)`** (do not filter after the read)
4. A mutation (update·delete) reads and confirms inside `firestore.runTransaction()`, then writes
5. When a new filter·sort combination appears, declare a composite index in `firestore.indexes.json`
6. Domain rules throw from `src/services/tasks.ts` as `AppError(<code>, …)` — the code has to be in `ERROR_STATUS`

**When adding a new collection / document type**
1. Build the zod schema and the derived type in `src/schemas/` — `.strict()` rejects unknown keys
2. Store `ownerId` **as a document field** (encode it into the document ID and the query cannot read it)
3. Build a converter and **re-parse the schema** in `fromFirestore`
4. Build and export the collection reference carrying `withConverter()` **in one place only**
5. Sort the list on **two keys**, `createdAt` + `__name__` — documents with identical timestamps leak or overlap at the page boundary
6. Declare the composite index in `firestore.indexes.json`, and isolate the emulator test with `withEmulator()`
<!-- /pack-slot -->

<!-- pack-slot: architecture-overview -->
## Architecture Overview

**One Cloud Run container (a resident process) is the whole of it.** Four decisions of this axis stand on the premise that the process is alive between requests — Firestore client reuse · the JWKS cache · SIGTERM drain · concurrency.

| component | responsibility | where it lives |
| --- | --- | --- |
| Cloud Run container | binds `0.0.0.0` on `settings.PORT`, drains for **10 seconds** after SIGTERM | `src/main.ts` |
| Hono app (`createApp`) | mounts routers · `installErrorHandlers` · `/healthz` | `src/app.ts` |
| Firestore client | attaches with the service account (ADC). **A single instance at module top level** | `src/firestore/client.ts` |
| Identity Platform verification | verifies the ID token against the JWKS. The key set is also a single one at module top level | `src/identity/verify.ts` |
| `settings` | **the only file that reads the environment.** It validates at boot time and fails there | `src/settings.ts` |

**Layering runs one way**: `routes → services → firestore` — the repository knows nothing about HTTP and does not take a `Context`. **`handlers.ts`·`auth.ts`·`routes.ts` under `src/http/` and `src/errors.ts` belong to the seam** (the response envelope and the way credentials arrive are decided by the combination, not the axis). **There is no policy engine** — `firestore.rules` is a blanket deny and the server attaches with a service account, bypassing the rules entirely: the application layer is **the only boundary**, and a missing ownership filter is a data leak.
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
## Core Principles (5 Key Rules)

### 1. Use only input that passed a `.strict()` schema
Allow unknown keys and a typo'd filter is answered with **a normal list while it is silently ignored**. Apply it to both the body and the query.

```ts
// ❌ unknown keys pass — a typo'd status parameter hands back the whole unfiltered list
const q = z.object({ limit: z.number() }).parse(raw);
// ✅ the schema rejects it
const q = TaskQuery.parse(raw);
```

### 2. Answer absence and lack of permission the same way
Give a `403` on someone else's document and a `404` on a missing one and **that difference is itself proof of existence**. The subject comes only from the verified `sub` that `currentUser` planted — an `ownerId` in the body·query is input, not a credential.

```ts
// ❌ it tells them the document is someone else's — sweep document IDs and you build a list of what exists
if (doc.ownerId !== ownerId) throw new AppError('FORBIDDEN', 'no permission');
// ✅ indistinguishable from absence
if (doc.ownerId !== ownerId) throw new AppError('NOT_FOUND', 'task not found');
```

### 3. Ownership lives in the query's `where`

```ts
// ❌ read everything, then filter — this axis has no backup. The exposure and the read cost have both already happened
const all = await tasksRef.get();
// ✅ the boundary is inside the query
const snap = await tasksRef.where('ownerId', '==', ownerId).limit(q.limit).get();
```

### 4. Fix the `ownerId` → `taskId` argument order across every function

```ts
// ❌ both are string, so it compiles even reversed — measured, every single-item lookup came back 404
const task = await getTask(taskId, ownerId);
// ✅ the owner comes first
const task = await getTask(ownerId, taskId);
```

### 5. A mutation reads and confirms inside a transaction, then writes

```ts
// ❌ delete() succeeds even on a missing document — without the check, a request to delete someone else's also succeeds
await tasksRef.doc(taskId).delete();
// ✅ read in the same transaction, confirm ownerId, then write (data-access.md holds the full shape)
await firestore.runTransaction(async (tx) => { /* get → confirm ownerId → delete */ });
```
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
## Common Imports

**Do not set up path aliases** — attach the **`.js` extension** to relative paths (the list below is relative to the `src/` root). An alias has to be configured separately in three places — build·test·container — so when one of them drifts it silently points at a different file.

```ts
import { Hono } from 'hono';
import { serve } from '@hono/node-server';
import { Firestore, Timestamp } from '@google-cloud/firestore';
import { createRemoteJWKSet } from 'jose';
import { z } from 'zod';
// the pack defines them (ledger provides)
import { settings } from './settings.js';
import { Task, TaskCreate, TaskUpdate, TaskQuery, TaskStatus } from './schemas/task.js';
import { fieldErrors } from './schemas/errors.js';
import { firestore } from './firestore/client.js';
import { taskConverter } from './firestore/converter.js';
import { tasksRef, listTasks, getTask, createTask, updateTask, deleteTask } from './firestore/tasks.js';
import { isInvalidArgument, isNotFound, isAlreadyExists, isFailedPrecondition, isAborted } from './firestore/errors.js';
import { verifyIdToken, jwks, type IdTokenClaims } from './identity/verify.js';
import { statusFor, toAppError } from './http/errors.js';   // statusFor alone for a status — policy blocks subscript access
import { log } from './obs/log.js';
// the seam defines them (ledger requires)
import { AppError } from './errors.js';
import { installErrorHandlers } from './http/handlers.js';
import { currentUser, type AuthUser } from './http/auth.js';
import { apiRouter } from './http/routes.js';
```
<!-- /pack-slot -->

<!-- pack-slot: http-status-and-antipatterns -->
## HTTP Status Mapping

`ERROR_STATUS` (`src/http/errors.ts`) is **the only mapping table**. Look it up with `statusFor(code)` — bare subscript access puts `undefined` where the status goes for a code absent from the table, and that runtime error folds back into a 500, so **the original code disappears from the logs.** Call `toAppError` **first**: before normalization the original message carries the project ID and document paths.

| domain code | status | when |
| --- | --- | --- |
| `VALIDATION_FAILED` | 422 | zod parse failure · a corrupted cursor (`decodeCursor`)  · gRPC 3 (document size limit exceeded)|
| `UNAUTHENTICATED` | 401 | `verifyIdToken` failure — expiry·signature·issuer are **not distinguished** |
| `FORBIDDEN` | 403 | only when identity is confirmed and the **role·scope** falls short — an ownership failure is a 404 |
| `NOT_FOUND` | 404 | a missing document **and someone else's document** — the two are not distinguished |
| `CONFLICT` | 409 | gRPC 6 (`isAlreadyExists`) · gRPC 10 (`isAborted`, retries exhausted) |
| `INTERNAL` | 500 | everything else. gRPC 9 (`isFailedPrecondition`) is here too — it is usually a missing index, a deployment defect rather than a user input problem |
<!-- /pack-slot -->

<!-- pack-slot: anti-patterns-axis -->
## Anti-Patterns

| anti-pattern | what it becomes on this axis | instead |
| --- | --- | --- |
| Pulling in `firebase-admin` to use `getFirestore()` or `verifyIdToken()` | the code overlaps the `firebase` axis pack and the security boundaries of two axes mix — that one rests on the premise that the rules block the client, while this axis denies in the rules entirely | `@google-cloud/firestore` + `jose`. The `no-firebase-admin` policy blocks it with a FAIL |
| "The rules protect us"·"the data layer backs it up"·"defense in depth" | the server attaches with a service account and **bypasses the rules entirely.** This axis has no second layer | the application layer is the only boundary. A missing ownership check = a data leak |
| Reading the collection and then filtering the owner out in JavaScript | someone else's documents have **already been read**, and the read cost scales with the size of the collection | put ownership in `where('ownerId', '==', ownerId)` |
| Deploying a filter + sort combination without declaring an index | it dies with gRPC 9 in production. **The emulator does not require an index, so the tests pass** | declare it in `firestore.indexes.json` and include it in the deployment artifact |
| Building `new Firestore()`·`createRemoteJWKSet()` per request, or calling `shutdown(server)` at the top level | the first piles up gRPC channels and round-trips to Google on every request. The second exits the container right after boot | a single instance at module top level · drain (10 seconds) **inside** the `SIGTERM` handler |
| The router parsing the `Authorization` header itself | the boundary becomes two, and those two checks will always diverge | read only the subject `currentUser` planted. Verification is `verifyIdToken` alone |
| The repository taking a `Context` or knowing an HTTP status | the layering collapses and data-layer tests only run once they stand up HTTP | `routes → services → firestore`, one way |
| Taking `ownerId` from the request body | documents get created under someone else's name, or someone else's documents get read | it comes only from the `sub` of a verified token |
<!-- /pack-slot -->

> **The slots below are written by L2** (L0 freezes only the directory tree):
> `core-principles-axis` · `common-imports-axis` · `architecture-overview` ·
> `http-status-and-antipatterns` · `quick-start-axis` · `anti-patterns-axis`.

## What the seam fills in

| slot | what |
| --- | --- |
| `api-endpoints` | the Hono router shape · the request/response envelope · emitting the error envelope |
| `auth-boundaries` | how the token arrives (bearer vs session cookie) · wiring `currentUser` · the login/logout flow |
| `complete-example` | index → schema → converter → repository → service → router → test, end to end |
