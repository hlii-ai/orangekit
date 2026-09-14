<!-- orangekit-pack: backend/gcp-serverless v3.14.0 -->
# Data access — ownership lives inside the query, and mutations live inside a transaction

What this file owns is the four files in `src/firestore/` — `client.ts` · `converter.ts` · `tasks.ts` ·
`cursor.ts`. Document shape·collection placement·composite index declarations are owned by `data-modeling.md`, schema types by
`input-validation.md`, and gRPC error detection and status mapping by `error-handling.md`.

**This file is the security boundary of this axis.** The rules are a blanket deny and the server attaches with a service account and
bypasses them (the measurement in section 3 of `data-modeling.md`) — a query that leaves out `where('ownerId', …)` is not stopped
behind the scenes; it hands over someone else's document just as it is.

## 1. Which function to use when

**The repository knows nothing about HTTP.** It takes no `Context` and knows no status code — it only throws a domain code or returns `null`.

| what you want to do | function | when it is missing or someone else's | why they differ like that |
| --- | --- | --- | --- |
| list | `listTasks(ownerId, q)` | it simply is not included | the boundary is in `where`, so it is never read in the first place |
| single lookup | `getTask(ownerId, taskId)` | **`null`** (not an exception) | "absent" is a normal flow. Whether it becomes a 404 is decided by the layer above |
| create | `createTask(ownerId, data)` | — | `ownerId` comes only from the argument. It does not come from the body |
| update | `updateTask(ownerId, taskId, patch)` | **`AppError('NOT_FOUND', …)`** | a mutation has to be distinguishable from "did nothing" |
| delete | `deleteTask(ownerId, taskId)` | **`AppError('NOT_FOUND', …)`** | a `delete()` with no check **succeeds even on a missing document** (section 6) |

**The argument order is `ownerId` → `taskId` without exception.** Both are `string`, so it compiles even reversed —
confirmed by running it, this one mistake turned every single-item lookup into a 404. The imports are in the hub's Common Imports.

## 2. One client per process (`src/firestore/client.ts`)

Cloud Run is a **resident process**. Build a `new Firestore()` per request and gRPC channels pile up one per request; put it at module top level and that channel lives between requests and is reused.

<!-- file: src/firestore/client.ts -->
```ts
// src/firestore/client.ts
import { Firestore } from '@google-cloud/firestore';
import { settings } from '../settings.js';

const emulator = settings.FIRESTORE_EMULATOR_HOST;
const [emulatorHost, emulatorPort] = emulator ? emulator.split(':') : [];

/** One per process. This instance holds the gRPC channel — do not build it inside a request. */
export const firestore = new Firestore(
  emulatorHost
    ? { projectId: settings.GCP_PROJECT_ID, host: emulatorHost, port: Number(emulatorPort), ssl: false }
    : { projectId: settings.GCP_PROJECT_ID },
);
```

**The environment is read only through `settings`** (`input-validation.md`) — this file is not a policy exception.

<!-- verified: with @google-cloud/firestore 9.0.0, gave host/port/ssl:false only, cleared the FIRESTORE_EMULATOR_HOST environment variable, and succeeded at writing to and reading from the emulator -->
**Attaching to the emulator works with these three options alone.** With `ssl: false` the SDK does not ask for credentials, so it
attaches without ADC — do not lean on environment-variable auto-detection. Isolation is owned by `testing-and-deploy.md`.

## 3. converter — re-parse it at the place you read (`src/firestore/converter.ts`)

A document **changes outside the code.** A document edited in the console, a document written under an earlier schema, and a half-applied migration all mix into the same collection — it is not trusted input.

<!-- file: src/firestore/converter.ts -->
```ts
// src/firestore/converter.ts
import type { DocumentData, FirestoreDataConverter, QueryDocumentSnapshot, WithFieldValue } from '@google-cloud/firestore';
import { Task } from '../schemas/task.js';

export const taskConverter: FirestoreDataConverter<Task> = {
  /** `id` is the document ID — put it in the data too and the two values diverge. */
  toFirestore(task: WithFieldValue<Task>): DocumentData {
    const { id: _id, ...fields } = task as Task;
    return fields;
  },
  /** A document can change outside the code — re-parse it at the place you read. */
  fromFirestore(snap: QueryDocumentSnapshot): Task {
    return Task.parse({ ...snap.data(), id: snap.id });
  },
};
```

```ts
// ❌ it compiles. All three values are false — a cast confirms nothing
const task = snap.data() as Task;
// ✅ read from a reference carrying the converter and it goes through parsing
const task2 = (await tasksRef.doc(taskId).get()).data();
```

<!-- verified: wrote the document { title: 42, status: 'archived' } into the emulator directly, without a converter, and instrumented reading it down two paths -->

| how the same document was read | what was observed |
| --- | --- |
| `snap.data() as Task` | `typeof title === 'number'` · `status === 'archived'` (outside the enum) · **`id === undefined`** |
| through `taskConverter` | `ZodError` — `title:invalid_type`, `status:invalid_value` |
| **control**: a normal document through the converter | it passed and `id` was filled from the document ID (`createdAt` is a `Timestamp`) |

Without the control, the converter cannot be told apart from "it throws on everything". `id` being `undefined` is especially quiet — let that value become the next request's `taskId` and it points at a document that does not exist.

## 4. Ownership lives inside the query (`src/firestore/tasks.ts`)

Build and export the reference carrying `withConverter` **in one place only**. Let another file build a bare `firestore.collection('tasks')` and only that path receives raw documents.

**This section carries the file in full** — section 6 explains the reasoning behind the four mutation functions, but the code is here and only here. Split it into two blocks and neither is a complete file any more, and then this module receives neither a type check nor an execution check.

<!-- file: src/firestore/tasks.ts -->
```ts
// src/firestore/tasks.ts
import { Timestamp, type CollectionReference, type Query } from '@google-cloud/firestore';
import { firestore } from './client.js';
import { taskConverter } from './converter.js';
import { decodeCursor, encodeCursor } from './cursor.js';
import { AppError } from '../errors.js';
import type { Task, TaskCreate, TaskQuery, TaskUpdate } from '../schemas/task.js';

export const tasksRef: CollectionReference<Task> = firestore
  .collection('tasks')
  .withConverter(taskConverter);

export async function listTasks(
  ownerId: string,
  q: TaskQuery,
): Promise<{ items: Task[]; nextCursor: string | null }> {
  let query: Query<Task> = tasksRef.where('ownerId', '==', ownerId);
  if (q.status) query = query.where('status', '==', q.status);
  query = query.orderBy('createdAt', 'desc').orderBy('__name__', 'desc');
  if (q.cursor) {
    const { createdAt, taskId } = decodeCursor(q.cursor);
    query = query.startAfter(createdAt, taskId);
  }
  const items = (await query.limit(q.limit).get()).docs.map((d) => d.data());
  const last = items.at(-1);
  const nextCursor = last && items.length === q.limit ? encodeCursor(last.createdAt, last.id) : null;
  return { items, nextCursor };
}

export async function createTask(ownerId: string, data: TaskCreate): Promise<Task> {
  const ref = tasksRef.doc();                              // take the ID first
  const task: Task = { id: ref.id, ownerId, title: data.title,
                       status: data.status, createdAt: Timestamp.now() };
  await ref.create(task);                                  // the converter strips id out of the data
  return task;
}

export async function getTask(ownerId: string, taskId: string): Promise<Task | null> {
  const task = (await tasksRef.doc(taskId).get()).data();
  if (!task || task.ownerId !== ownerId) return null;      // read by ID alone and it hands over someone else's
  return task;
}

export async function updateTask(ownerId: string, taskId: string, patch: TaskUpdate): Promise<Task> {
  const ref = tasksRef.doc(taskId);
  return firestore.runTransaction(async (tx) => {
    const current = (await tx.get(ref)).data();
    if (!current || current.ownerId !== ownerId) throw new AppError('NOT_FOUND', 'task not found');
    const next: Task = { ...current, ...patch };
    tx.set(ref, next);
    return next;
  });
}

export async function deleteTask(ownerId: string, taskId: string): Promise<void> {
  const ref = tasksRef.doc(taskId);
  await firestore.runTransaction(async (tx) => {
    const current = (await tx.get(ref)).data();
    if (!current || current.ownerId !== ownerId) throw new AppError('NOT_FOUND', 'task not found');
    tx.delete(ref);
  });
}
```

**The shape that reads first and then filters with `.filter(t => t.ownerId === …)` is already past reading someone else's document** — the read cost and the exposure both happened, and this axis has no backup.

**The two sort keys and the index declaration are one decision** — fix `orderBy` and you fix `firestore.indexes.json` in the same commit (section 4 of `data-modeling.md`).

## 5. Cursor pagination (`src/firestore/cursor.ts`)

**A cursor is not trusted input.** A decode failure is a validation failure rather than an exception, and exposing the internal sort key as it is turns it into the wire contract, after which the ordering can never change.

<!-- file: src/firestore/cursor.ts -->
```ts
// src/firestore/cursor.ts
import { Timestamp } from '@google-cloud/firestore';
import { AppError } from '../errors.js';

export function encodeCursor(createdAt: Timestamp, taskId: string): string {
  const raw = JSON.stringify([createdAt.seconds, createdAt.nanoseconds, taskId]);
  return Buffer.from(raw, 'utf8').toString('base64url');
}

export function decodeCursor(cursor: string): { createdAt: Timestamp; taskId: string } {
  let p: unknown = null;
  try { p = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')); } catch { /* it is refused below */ }
  // Do not skip the shape check — decoding and JSON.parse succeed on [1,2,3] and {"a":1} as well.
  if (!Array.isArray(p) || p.length !== 3 ||
      typeof p[0] !== 'number' || typeof p[1] !== 'number' || typeof p[2] !== 'string') {
    throw new AppError('VALIDATION_FAILED', 'the cursor is not valid', { cursor: ['the format is not valid'] });
  }
  return { createdAt: new Timestamp(p[0], p[1]), taskId: p[2] };
}
```

<!-- verified: ran 1 round trip and 5 corrupted inputs ('', 'not-base64!!', [1,2,3], {"a":1}, [1,2]) through the implementation above and observed the results -->
The round trip gave the value back unchanged and all five corrupted inputs were refused with `VALIDATION_FAILED` — without the shape
check, `[1,2,3]` goes into `startAfter`, the SDK's error folds into `INTERNAL`, and the cause disappears.

<!-- verified: seeded 7 documents with an identical createdAt into firestore-emulator 1.19.8 and paged all the way through under each of the two orderings, counting the IDs received -->

| paging 7 documents with the same `createdAt` at `limit: 2` | rows received | unique | lost | duplicated |
| --- | --- | --- | --- | --- |
| `('createdAt','desc')` **alone** | 2 | 2 | **5** | 0 |
| `('createdAt','desc')` + `('__name__','desc')` | 7 | 7 | **0** | 0 |

The first row is the positive control. With `startAfter(createdAt)` alone, **everything else carrying the same value gets
skipped** — 5 of the 7 vanished at the second page. Ascending, the same document would come out over and over.

## 6. A mutation reads and confirms inside a transaction, then writes

The code is **carried in full by section 4** (no copy is kept here). What to read here is three shapes.

| function | boundary | if you get it wrong |
| --- | --- | --- |
| `createTask` | carries over **both** `data.title` and `data.status` | hard-code `status` and the value the client sent silently disappears |
| `getTask` | **confirms** `ownerId` after the read | read by document ID alone and it hands over someone else's task |
| `updateTask` · `deleteTask` | **reads and confirms, then writes** inside `runTransaction` | split the confirmation from the write and you overwrite a document whose owner changed in between |

<!-- verified: observed calling delete() on a missing document ID in the emulator and getting a writeTime back. The control delete({exists:true}) was refused with gRPC 5 -->
**`delete()` succeeds even on a missing document.** Called on a missing ID, a `writeTime` came back with no exception,
while the control `delete({ exists: true })` was refused with **gRPC 5**. Success does not mean "it was deleted" but "it is
absent now that this is over" — call it without the check and a request to delete someone else's also comes back a success.

<!-- verified: put 300ms between the ownership check and the write, slipped a competing write into that gap, and instrumented the final document state of both implementations -->

| slipping a competing write in 300 ms after the check | when the document is deleted in that gap | when the owner becomes `bob` in that gap |
| --- | --- | --- |
| ❌ `get` → `set` with no transaction | the document **came back to life** | it **overwrote** `bob`'s document with `alice`'s values |
| ✅ `runTransaction` | it stayed deleted | `bob`'s values survived |

<!-- verified: in the same scenario, instrumented how long the competing write took to return — 4ms without the transaction, 316ms with it -->
**What stops it is serialization, not the retries.** For the competing write to come back took
**4 ms** without the transaction and **316 ms** with it — the transaction's read held the document and the competing write waited
on the commit. When the retries are exhausted gRPC 10 comes up, and that is `CONFLICT` (`error-handling.md`).

## 7. Prove the block (`test/tasks.test.ts`)

**A test that carries only the negative assertion is not a guard.** Assert only "reading someone else's gives `null`" and it stays green even when the whole function is replaced with `return null`. Attach the positive pair **inside the same `it`**.

```ts
// test/tasks.test.ts  (besides these two, the file also has the cursor test of section 5 and the list isolation test)
import { describe, expect, it } from 'vitest';
import { createTask, deleteTask, getTask, updateTask } from '../src/firestore/tasks.js';
import { withEmulator } from './helpers.js';   // owned by testing-and-deploy.md

const ALICE = 'alice-sub';
const BOB = 'bob-sub';

describe('ownership boundary', () => {
  it("someone else's task is null — the owner gets their own back exactly as sent", () => withEmulator(async () => {
    const task = await createTask(ALICE, { title: 'my task', status: 'done' });
    expect(task.status).toBe('done');                      // ✅ hard-code status and this goes red
    expect(await getTask(BOB, task.id)).toBeNull();
    // ✅ without the positive pair, replacing getTask wholesale with `return null` stays green
    expect((await getTask(ALICE, task.id))?.title).toBe('my task');
  }));

  it("someone else's task is NOT_FOUND for update and delete too — your own is applied and deleted", () => withEmulator(async () => {
    const task = await createTask(ALICE, { title: 'original', status: 'open' });
    expect(task.status).toBe('open');                      // ✅ a control that also blocks hard-coding 'done'
    await expect(updateTask(BOB, task.id, { title: 'hijacked' })).rejects.toMatchObject({ code: 'NOT_FOUND' });
    await expect(deleteTask(BOB, task.id)).rejects.toMatchObject({ code: 'NOT_FOUND' });
    expect((await getTask(ALICE, task.id))?.title).toBe('original');   // ✅ did it really survive
    expect((await updateTask(ALICE, task.id, { title: 'edited' })).title).toBe('edited');
    await deleteTask(ALICE, task.id);
    expect(await getTask(ALICE, task.id)).toBeNull();                  // ✅ is it really deleted
  }));
});
```

The other two are the cursor test of section 5 (paging 7 same-timestamp documents with no loss·duplication) and the list isolation test
(`listTasks` holds none of someone else's tasks and all of your own), making **4** in the file as a whole.

<!-- verified: ran the 4 above on the emulator to confirm a green baseline, then planted 8 kinds of mutation into the implementation one at a time and re-ran -->
Confirmed by running it: the 4 baseline tests were green and **all 8 kinds of mutation came out red** — removing the ownership
check in `getTask` (1 failure) · `getTask` always `null` (2) · `createTask` hard-coding `status` (1) · `createTask`
ignoring `ownerId` (3) · removing `orderBy('__name__')` (1) · `deleteTask` as a bare `delete()` (1) ·
removing `where('ownerId')` (2) · removing the ownership check in `updateTask` (1).

## Misuse list ① — idioms from other SDKs·other axes → the shape on this axis

| old habit | the current shape (this axis) |
| --- | --- |
| getting the instance with `admin.firestore()` | `firestore` (`src/firestore/client.ts`) — policy blocks `firebase-admin` |
| `snap.data() as Task` | read from a reference carrying the converter — in section 3 the cast lied about three things |
| reading and then `.filter(t => t.ownerId === …)` | `where('ownerId', '==', ownerId)` — by the time you filter, it has already been read |
| `offset`/`skip` pagination | cursors. `offset` bills you for the documents it skipped and shifts under inserts |
| splitting pages on `orderBy('createdAt')` alone | attach `__name__` as the secondary key — in section 5, 5 of 7 vanished |
| `get` → check → `update` | all three inside `runTransaction`. In section 6 the document came back to life |

## Misuse list ② — confusion pairs

| what gets picked wrong often | the exact condition for applying it |
| --- | --- |
| `getTask(ownerId, taskId)` vs the reversed order | both are `string`, so the type check does not catch it. **The owner comes first** |
| returning `null` vs `AppError` | a lookup gives `null` (a normal flow), a mutation gives `NOT_FOUND` (the request did not take place) |
| `runTransaction` vs `batch` | a batch **does not read** — if an ownership check is needed, it is a transaction |
| `startAfter` vs `startAt` | the cursor starts from the **next** item. `startAt` puts the boundary document on two pages |
| `ref.create()` vs `ref.set()` | `create` fails with gRPC 6 if it already exists. For a create, `create` is the right one |
