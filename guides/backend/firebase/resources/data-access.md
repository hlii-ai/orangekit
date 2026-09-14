<!-- orangekit-pack: backend/firebase v3.14.0 -->
# Data access — `firebase-admin` bypasses Security Rules

This file owns `functions/src/firestore/client.ts` and `functions/src/firestore/tasks.ts`.
The document shape (`TaskDoc` · `TaskStatus` · `COLLECTION` · `taskConverter`) is
`functions/src/firestore/model.ts` — owned by `resources/data-modeling.md`. The Zod schemas and
`TaskCreate` · `TaskUpdate` · `TaskQuery` are `functions/src/schemas/task.ts`
(`resources/input-validation.md`), and `AppError` is the seam's `functions/src/http/app-error.ts`.
The function surface (`onCall` · `withErrors` · `requireUid`) is `resources/functions-patterns.md`.

**The rules do not block this path.** Under `allow read, write: if false` the client SDK gets
`permission-denied` while the admin SDK succeeds. The `ownerId` check in this file is the **only**
boundary on the function path.

## 1. Decision tree — what blocks this read or write

| where this code runs | do the rules block it | then what does |
| --- | --- | --- |
| Client SDK in a browser or app (`firebase@12`) | Yes | `firestore.rules` (`resources/security-rules.md`) |
| `firebase-admin` in Cloud Functions | **No** | Only the `ownerId` check in this file |

What to use is decided by **whether you must read before writing**.

| what you want | what to use | why |
| --- | --- | --- |
| List | `listTasks` — `where('ownerId')` + composite ordering | A query sweeping the whole collection picks up other people's documents too |
| Single document | `getTask` — read, compare `ownerId`, return `null` on mismatch | Knowing a document ID is not authorization |
| Write after checking existence and ownership | `runTransaction` | The owner can change between the check and the write |

## 2. The module top level owns the client (`functions/src/firestore/client.ts`)

Build it **outside** the handler. It runs once on the cold start and every following invocation reuses it —
measured, the same instance served 6 consecutive invocations from the same module instance.

<!-- file: functions/src/firestore/client.ts -->
```ts
// functions/src/firestore/client.ts
import { getApps, initializeApp } from 'firebase-admin/app';
import { getFirestore, type Firestore } from 'firebase-admin/firestore';

// Module top level — runs once on the cold start and every following invocation reuses it.
if (getApps().length === 0) {
  initializeApp();
}

export const db: Firestore = getFirestore();
```

The `getApps().length === 0` guard exists **because the second call is silent**.
<!-- verified: firebase-admin 14.3.0 run — two argument-less calls do not throw and return the first app (apps=1). Pass options on both sides with different values and it is 'app/duplicate-app'. Pass options on only one side and the installed lifecycle.js sees the autoInit mismatch first, giving 'app/invalid-app-options' -->
**When both calls passed options and those options differ** it is `app/duplicate-app`; **when one is argument-less** it is
`app/invalid-app-options`. The `client.ts` above is **argument-less**, so the one actually encountered is the latter —
it blows up the moment another file initializes with options. Identical forms silently ignore one of the two, so
pinning the initialization point to this one file is the only defense.

## 3. The repository (`functions/src/firestore/tasks.ts`)

It is the axis's security primitive, so it ships in full. The argument order is **`ownerId` → `taskId`** in every function,
and both being `string` means a swap is not caught by the types.

<!-- file: functions/src/firestore/tasks.ts -->
```ts
// functions/src/firestore/tasks.ts
import { FieldPath, FieldValue, Timestamp, type Query } from 'firebase-admin/firestore';
import { db } from './client.js';
import { COLLECTION, taskConverter, type TaskDoc } from './model.js';
import type { TaskCreate, TaskQuery, TaskUpdate } from '../schemas/task.js';
import { AppError } from '../http/app-error.js';

const col = () => db.collection(COLLECTION).withConverter(taskConverter);

export function encodeCursor(createdAt: Timestamp, taskId: string): string {
  return Buffer.from(JSON.stringify([createdAt.toMillis(), taskId]), 'utf8').toString('base64url');
}

// The upper bound of a Firestore timestamp (9999-12-31T23:59:59.999Z). An out-of-range value has startAfter
// reject with a raw Error rather than an AppError, turning what should be a 400 into a 500.
const MAX_CURSOR_MS = 253402300799999;

export function decodeCursor(cursor: string): { createdAt: Timestamp; taskId: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'));
  } catch {
    throw new AppError('VALIDATION_FAILED', 'cursor is not decodable');
  }
  if (!Array.isArray(parsed) || typeof parsed[0] !== 'number' || typeof parsed[1] !== 'string') {
    throw new AppError('VALIDATION_FAILED', 'cursor shape is wrong');
  }
  const [ms, taskId] = parsed as [number, string];
  if (!Number.isSafeInteger(ms) || ms < 0 || ms > MAX_CURSOR_MS || taskId.length === 0) {
    throw new AppError('VALIDATION_FAILED', 'cursor value is out of range');
  }
  return { createdAt: Timestamp.fromMillis(ms), taskId };
}

export async function listTasks(ownerId: string, q: TaskQuery): Promise<{ items: TaskDoc[]; cursor?: string }> {
  let query: Query<TaskDoc> = col().where('ownerId', '==', ownerId);
  if (q.status) query = query.where('status', '==', q.status);
  // With several documents sharing a createdAt the ordering wobbles — break the tie with the document ID.
  query = query.orderBy('createdAt', 'desc').orderBy(FieldPath.documentId(), 'desc').limit(q.limit);
  if (q.cursor !== undefined) {
    const c = decodeCursor(q.cursor);
    try {
      query = query.startAfter(c.createdAt, c.taskId);
    } catch {
      throw new AppError('VALIDATION_FAILED', 'cursor is not usable for this query');
    }
  }
  const items = (await query.get()).docs.map((d) => d.data());
  const last = items.length === q.limit ? items[items.length - 1] : undefined;
  return { items, cursor: last ? encodeCursor(last.createdAt, last.id) : undefined };
}

export async function getTask(ownerId: string, taskId: string): Promise<TaskDoc | null> {
  const task = (await col().doc(taskId).get()).data();
  if (!task || task.ownerId !== ownerId) return null;
  return task;
}

export async function createTask(ownerId: string, input: TaskCreate): Promise<TaskDoc> {
  const ref = col().doc();
  await ref.set({
    id: ref.id,
    title: input.title,
    status: input.status,
    ownerId,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });
  const created = (await ref.get()).data();
  if (!created) throw new AppError('INTERNAL', 'created document vanished');
  return created;
}

export async function updateTask(ownerId: string, taskId: string, patch: TaskUpdate): Promise<TaskDoc> {
  const ref = col().doc(taskId);
  await db.runTransaction(async (tx) => {
    const current = (await tx.get(ref)).data();
    if (!current || current.ownerId !== ownerId) throw new AppError('NOT_FOUND', 'task not found');
    tx.update(ref, { ...patch, updatedAt: FieldValue.serverTimestamp() });
  });
  const after = (await ref.get()).data();
  if (!after) throw new AppError('NOT_FOUND', 'task not found');
  return after;
}

export async function deleteTask(ownerId: string, taskId: string): Promise<void> {
  const ref = col().doc(taskId);
  await db.runTransaction(async (tx) => {
    const current = (await tx.get(ref)).data();
    if (!current || current.ownerId !== ownerId) throw new AppError('NOT_FOUND', 'task not found');
    tx.delete(ref);
  });
}
```

Five things worth reading are compressed into this file.

**`delete()` succeeds even on a document that does not exist.**
<!-- verified: emulator run — delete() on a nonexistent document resolved with a WriteResult(_writeTime). delete({ exists: true }) rejected with code 5 NOT_FOUND -->
So unless `deleteTask` checks existence and ownership inside a transaction, **a request to delete someone else's document
is answered as success too** — a delete without a check has no way to report failure.

**A transaction function runs more than once.**
<!-- verified: emulator run — issuing 8 concurrent transactions against the same document executed the transaction function 25 times (17 retries) and the final value was exactly 8. Running the same contention without a transaction left the final value at 1 (7 updates lost) -->
So **put no side effects in a transaction body** — they happen as many times as it retries. Reads come before
writes (otherwise rejected with `… require all reads to be executed before all writes.`).

**Build the cursor from `createdAt` alone and you lose documents.**
<!-- verified: emulator run — paging 24 documents with only 3 distinct createdAt values at limit 5 to the end, the composite cursor returned all 24 (0 duplicates, 0 missing) while the createdAt-only cursor returned just 15 and skipped 9 forever -->
When a tie group lands on a page boundary, `startAfter(createdAt)` skips it wholesale.
Add one more `orderBy` to break the tie and build the cursor from both values.

**Do not put the function instance's clock in `createdAt`.** `FieldValue.serverTimestamp()` is a
sentinel, so the value returned right after `set()` carries no value — which is why `createTask` re-reads the document after the write.

**Skip the cursor validation and the list becomes a 500.** Check only the shape and **not the range** and `[0,""]` ·
`[1e15,"x"]` · `[-62135596801000,"x"]` reach `startAfter`, raise a raw `Error`, and `withErrors`
folds it into `INTERNAL` — **letting any authenticated user turn the list into a 500.**

## 4. Batches and bulk writes — limits the emulator does not enforce

The limits were measured only after confirming **that the observation apparatus reports rejections**.

| attempt | emulator result |
| --- | --- |
| Positive control: one 2MB field / one 1KB field | `REJECTED code=3 INVALID_ARGUMENT … longer than 1048487 bytes.` / `OK` |
| `WriteBatch` of 499 · 500 · 501 · 1000 · 2000 | **All `OK`** |

<!-- verified: the table above was measured with the same commitN() harness. Because the 2MB control first confirmed the harness really reports server rejections, the count limit passing is 'not enforced', not 'could not measure' -->
**The emulator does not enforce the batch count limit.** Production's `WriteBatch` ceiling is 500, so code
that was green locally breaks only after deploy. When there is any chance of exceeding it, use
`BulkWriter` from the start — it gives up atomicity in exchange for no count limit
<!-- verified: emulator run — wrote 1200 documents with BulkWriter and confirmed 1200 with count() (3.5s) -->
(1200 documents in 3.5s). When atomicity is required, split into chunks of 500 or fewer.

## 5. Block proof (`functions/test/repo.test.ts`)

This is the regression that calls the repository **directly** (excerpt — the full text is `functions/test/repo.test.ts`).
`functions/test/tasks.test.ts` is the `onCall` entry point regression, owned by `resources/testing-and-deploy.md`,
so the same path is not filled in here. **With only a negative assertion it is not a guard** —
pair a positive with it inside each `it`.

```ts
// functions/test/repo.test.ts
describe('ownership boundary — this check is the only thing that blocks the admin SDK', () => {
  it('single: the owner gets it and others do not', async () => {
    const mine = await createTask(ALICE, { title: 'alice', status: 'open' });
    expect((await getTask(ALICE, mine.id))?.id).toBe(mine.id);
    expect(await getTask(BOB, mine.id)).toBeNull();
  });

  it('delete: the owner deletes and others get NOT_FOUND', async () => {
    const his = await createTask(BOB, { title: 'b', status: 'open' });
    await expect(deleteTask(ALICE, his.id)).rejects.toThrow(/not found/);
    expect((await getTask(BOB, his.id))?.id).toBe(his.id);
    await deleteTask(BOB, his.id);
    expect(await getTask(BOB, his.id)).toBeNull();
  });

  it('pagination: page to the end with 0 duplicates and 0 missing, and reject a forged cursor', async () => {
    const owner = 'pager-' + Date.now();
    const made: string[] = [];
    for (let i = 0; i < 7; i++) made.push((await createTask(owner, { title: 'p', status: 'open' })).id);
    const seen: string[] = [];
    let cursor: string | undefined;
    do {
      const p = await listTasks(owner, { limit: 3, ...(cursor ? { cursor } : {}) });
      seen.push(...p.items.map((t) => t.id));
      cursor = p.cursor;
    } while (cursor);
    expect([...seen].sort()).toEqual([...made].sort());
  });

  it('cursor: every tampered input is VALIDATION_FAILED (not a 500)', async () => {
    const owner = 'vec-' + Date.now();
    await createTask(owner, { title: 'v', status: 'open' });
    const enc = (v: unknown) => Buffer.from(JSON.stringify(v), 'utf8').toString('base64url');
    expect((await listTasks(owner, { limit: 1 })).items).toHaveLength(1); // ✅ positive pair
    for (const bad of ['', 'zzzz', enc([0, '']), enc([1e15, 'x']),
                       enc([-62135596801000, 'x']), enc([1e400, 'x']), enc([1.5, 'x'])]) {
      await expect(listTasks(owner, { limit: 3, cursor: bad })).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
    }
  });
});
```

Each guard was **actually deleted** to confirm the suite goes red.

| what was deleted | result |
| --- | --- |
| `where('ownerId','==',ownerId)` in `listTasks` | 2 failures (list · pagination) |
| The ownership check in `getTask` | 1 failure (single) |
| The in-transaction existence and ownership check in `deleteTask` | 1 failure (delete) |
| The in-transaction existence and ownership check in `updateTask` | 1 failure (update) |
| `createTask` discarding `input.status` and pinning `'open'` | 1 failure (create) |
| `FieldPath.documentId()` from the cursor ordering | 1 failure (pagination) |
| The shape validation in `decodeCursor` | 1 failure (cursor vectors) |
| All of the range validation in `decodeCursor` | 1 failure (cursor vectors) |
| Only the upper bound `ms > MAX_CURSOR_MS` from the range validation | 1 failure (cursor vectors) |
| `taskId.length === 0` **or** the try/catch around `startAfter`, **only one of them** | It does not die — the two cover each other. Delete **both** and there is 1 failure |
| Changing `if (q.cursor !== undefined)` to `if (q.cursor)` | 1 failure — an empty cursor silently becomes page 1 |
| Turning `deleteTask`'s `runTransaction` into read-then-write | **It does not die** — see below |

The last two rows are the point. **The two layers of cursor defense cover each other, so deleting one at a time
does not kill it** — keep both anyway. And **a single-actor suite cannot kill a transaction**:
what a transaction protects is not ownership but **the window between the check and the write**, and that window opens
only under contention. Hence the separate contention block.

## Misuse list ① — client SDK (`firebase@12`) → admin SDK (`firebase-admin@14`)

The two SDKs share names while differing in shape. Paste a client example into a function and most of it
dies with `TS2305` (no such export), but a name that **exists on both sides**, such as `Timestamp`, goes silently wrong.

| old habit (client SDK) | current form (admin SDK) |
| --- | --- |
| `import { collection } from 'firebase/firestore'` | admin has no `collection` export — `db.collection('tasks')` |
| The function composition `query(col, where(...), orderBy(...))` | The method chain `col.where(...).orderBy(...)` |
| `serverTimestamp()` | `FieldValue.serverTimestamp()` |
| `Timestamp` (`firebase/firestore`) | `Timestamp` (`firebase-admin/firestore`) — **a different class** <!-- verified: importing both modules in the same process confirmed `cs.Timestamp === ad.Timestamp` is false --> |
| The rules block it, so no ownership check is needed | The rules do not block admin — `where('ownerId')` is the only boundary |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `set()` vs `update()` | `set()` overwrites the whole document (`set({a})` on `{a,b}` → `{a}`). A partial update is `update()` or `set(…, { merge: true })` |
| `update()` vs `delete()` on a missing document | `update()` gives code 5 `NOT_FOUND`; `delete()` **succeeds** |
| `startAfter(snapshot)` vs `startAfter(values)` | A snapshot means re-reading the document, and a value list must match the `orderBy` count **exactly** (over it, `Too many cursor values specified.`) |
