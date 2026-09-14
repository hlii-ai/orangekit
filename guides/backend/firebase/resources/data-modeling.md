<!-- orangekit-pack: backend/firebase v3.14.0 -->
# Firestore data modeling — the document shape is the rules' input

This file owns **collection layout · document shape (`TaskDoc`) · the converter · composite indexes · limits**.
The security rules **reference the field names set here verbatim as strings**, so if this shape wobbles
`resources/security-rules.md` is wrong wholesale. The read and write functions (`listTasks`, `createTask`, …) are owned by
`resources/data-access.md`, and the input schemas by `resources/input-validation.md`.

## 1. Decision tree — top-level collection or subcollection

| question | yes | no |
| --- | --- | --- |
| Can the owner change (transfer, sharing) | Top-level `tasks/{taskId}` | Next question |
| Is a cross-cutting query needed beyond one owner (admin lists, aggregates) | Top-level | Next question |
| Must it be deleted **together with** the parent document | Neither deletes it automatically — see the measurement below | Subcollection `users/{uid}/tasks/{taskId}` |

This pack pins **top-level `tasks`**. With ownership in the `ownerId` field rather than the path, a document can be
transferred without moving it, and the rules path closes with the single `match /tasks/{taskId}`.

**A subcollection is not deleted along with its parent.** Measured on the emulator: after deleting `users/u1`,
querying `users/u1/tasks` shows the parent as `exists=false` while **one subdocument is still there**.
Express ownership through the path alone and that orphaned document has no owner. Even when choosing a subcollection,
keep `ownerId` **in the document as well** — both the rules and the queries look at the field.

`collectionGroup('tasks')` sweeps every collection of that name whatever the parent. Measured, it returned
2 subcollection documents belonging to different users in one result — **proof that a subcollection does not
give isolation.** Isolation is what `where('ownerId', '==', ownerId)` creates.

## 2. Document shape (`functions/src/firestore/model.ts`)

`id` is **a copy of the document ID**. It lets a query result be serialized as-is, and lets the rules enforce
that the copy matches the real thing with `request.resource.data.id == taskId`.

<!-- file: functions/src/firestore/model.ts -->
```ts
// functions/src/firestore/model.ts
import type {
  DocumentData,
  FirestoreDataConverter,
  PartialWithFieldValue,
  QueryDocumentSnapshot,
  Timestamp,
} from 'firebase-admin/firestore';

// The only place the collection name is assembled. It pairs with the rules' `match /tasks/{taskId}` —
// let this and the rules path diverge and the rules guard a collection nobody uses.
export const COLLECTION = 'tasks';

// Rules, schema and queries use **the same literal set**. When extending it, also fix
// `d.status in ['open', 'done']` in firestore.rules — no machine keeps the pair aligned.
export type TaskStatus = 'open' | 'done';

export interface TaskDoc {
  id: string;
  title: string;
  status: TaskStatus;
  ownerId: string;
  createdAt: Timestamp;
  updatedAt: Timestamp;
}

export const taskConverter: FirestoreDataConverter<TaskDoc> = {
  toFirestore(task: PartialWithFieldValue<TaskDoc>): DocumentData {
    return { ...task };
  },
  fromFirestore(snap: QueryDocumentSnapshot): TaskDoc {
    const stored = snap.data() as Omit<TaskDoc, 'id'>;
    // The document ID is authoritative. Even if the stored `id` disagrees, the snapshot side wins.
    return { ...stored, id: snap.id };
  },
};
```

Read the document `c2`, stored with `id: 'WRONG'`, through the converter and `id` comes back as `'c2'`. Use
`snap.data()` without the converter and the stored `'WRONG'` flows straight out.
<!-- verified: actually written to and read from the Firestore emulator and compared (firebase-admin@14.3.0) -->

`createdAt` is stamped by the server. Do not trust the function instance's clock either — it differs per instance.

```ts
// functions/src/firestore/tasks.ts (excerpt)
// ❌ Put the client's or the function instance's clock into the document
await ref.set({ id: ref.id, title, status, ownerId, createdAt: new Date() });
// ✅ The server stamps it at commit time — the rules can enforce this value with `request.time` too
await ref.set({
  id: ref.id, title, status, ownerId,
  createdAt: FieldValue.serverTimestamp(),
  updatedAt: FieldValue.serverTimestamp(),
});
```

Even through the converter, `FieldValue.serverTimestamp()` fits into the `createdAt: Timestamp` slot —
because the type `set()` accepts is `WithFieldValue<TaskDoc>`.
<!-- verified: tsc passes with typescript@7.0.2 + firebase-admin@14.3.0 (no cast) -->

## 3. The owner field — one field feeds both boundaries at once

`ownerId` is not decoration but **the shared input of two boundaries**.

| boundary | what it looks at | without it |
| --- | --- | --- |
| Security Rules (browser) | `resource.data.ownerId == request.auth.uid` | The client reads other people's documents |
| Application checks (Cloud Functions) | `where('ownerId', '==', ownerId)` | The admin SDK bypasses the rules, so **there is no boundary at all** |

```ts
// functions/src/firestore/tasks.ts (excerpt) — db is owned by ./client
const tasks = db.collection(COLLECTION).withConverter(taskConverter);
// ✅ Ownership lives in the query. Reading by document ID alone reads other people's documents.
const page = await tasks
  .where('ownerId', '==', ownerId)
  .orderBy('createdAt', 'desc')
  .limit(20)
  .get();
```

`ownerId` comes **only from the auth context**. Taken from the request body it is a forgeable field —
that validation is owned by `resources/input-validation.md`.

## 4. Composite indexes (`firestore.indexes.json`)

An equality `where` plus an `orderBy` on a different field requires a **composite index**. The two queries this pack
uses need one each — one `(ownerId, status, createdAt)` cannot cover the `(ownerId, createdAt)` query.
An index has to match **from the leading field onward**, and dropping the `status` equality breaks the prefix.
<!-- unverified: the prefix rule is documentation knowledge. The emulator does not enforce indexes, so it cannot be measured here -->

<!-- file: firestore.indexes.json -->
```json
{
  "indexes": [
    {
      "collectionGroup": "tasks",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "ownerId", "order": "ASCENDING" },
        { "fieldPath": "createdAt", "order": "DESCENDING" },
        { "fieldPath": "__name__", "order": "DESCENDING" }
      ]
    },
    {
      "collectionGroup": "tasks",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "ownerId", "order": "ASCENDING" },
        { "fieldPath": "status", "order": "ASCENDING" },
        { "fieldPath": "createdAt", "order": "DESCENDING" },
        { "fieldPath": "__name__", "order": "DESCENDING" }
      ]
    }
  ],
  "fieldOverrides": []
}
```

**This is the most expensive trap on this axis. The emulator neither enforces the indexes nor validates
this file.** Two measurements:

- With `"indexes": []`, throwing `where(ownerId) + where(status) + orderBy(createdAt desc)` at it,
  the emulator **passes everything**. Only in production does that query fail.
- Start the emulator with a file carrying a **wrong key**, such as `"direction": "UP"` instead of `"order"`,
  and it comes up normally without a single warning. Errors in this file surface **only at deploy**.

So an index cannot be judged by "the tests are green, we are fine". Change a query and change this file in the
same commit, and **deploy the index first, then the functions** — the order is owned by
`resources/testing-and-deploy.md`.

## 5. The price of denormalization

A document model has no joins. When a list screen needs a value from another document, **copying** is the answer,
and the moment you copy you take on **the obligation to update both copies together**.

| approach | read | write | when |
| --- | --- | --- | --- |
| Fetch each one every time | As many reads as documents | Cheap | The list is short and updates are frequent |
| Copy the value (denormalize) | One | **The entire fan-out** when the original changes | The list is long and the original almost never changes |
| Keep a separate counter | One | `FieldValue.increment` | Only the count is needed |

```ts
// functions/src/firestore/tasks.ts (excerpt) — move the document and the counter as one atomic unit
await db.runTransaction(async (tx) => {
  const snap = await tx.get(ref);                    // **all** reads first
  if (!snap.exists || snap.get('ownerId') !== ownerId) throw new AppError('NOT_FOUND', 'Not found');
  tx.update(ref, { status: 'done', updatedAt: FieldValue.serverTimestamp() });
  tx.update(counter, { openCount: FieldValue.increment(-1) });
});
```

In a transaction **every read must come before every write**. Reverse the order and it fails immediately, measured, with
`Firestore transactions require all reads to be executed before all writes.`
`FieldValue.increment(1)` is not a value but a transform sentinel (`NumericIncrementTransform`), so it
adds without reading — which is why there is no contention on the counter.

## 6. Limits — all measured on the emulator

| limit | measured value | how it was measured |
| --- | --- | --- |
| Whole document size | **1,048,576 bytes** — over it, `INVALID_ARGUMENT: maximum entity size is 1048576 bytes` | Three 400 KB fields |
| A single field value | **1,048,487 bytes** — `The value of property "title" is longer than 1048487 bytes` | One 1 MiB string |
| `in` comparison values | **30** — from 31 on, `'IN' supports up to 30 comparison values.` | Raising the value count |
| `array-contains` | **Once** per query — `Only a single array-contains clause is allowed in a query` | A query with two of them |
| Auto document ID | 20 characters | `col.doc().id` |
| Batch write count | The emulator **passes even 1000** — it does not enforce the limit | Batches of 500, 501 and 1000 |
| Write rate per document | The emulator does not enforce it, so **it cannot be measured** <!-- unverified: production's soft limit cannot be measured here --> | — |

The last two rows are the point. **What the emulator passed does not mean "within the limits".**
Batch size and hot documents (writes piling onto one document) are never caught here — a design that piles
the counters onto a single document stays green in the emulator forever.

## Misuse list ① — relational schema → Firestore document model

| old habit (relational) | current form (Firestore) |
| --- | --- |
| Confirming the owner by a join | Put `ownerId` in the document and use `where('ownerId', '==', ownerId)` |
| `ON DELETE CASCADE` | Does not exist. A subcollection survives the parent's deletion (measured) — write the deletion code yourself |
| The DB handles indexes | Write them by hand in `firestore.indexes.json` and **deploy them first** |
| `COUNT(*)` | A counter document + `FieldValue.increment` |
| `NOW()` / `DEFAULT CURRENT_TIMESTAMP` | `FieldValue.serverTimestamp()` |
| `WHERE a IN (…)` with no value limit | `in` takes up to 30 values (measured) |
| The schema enforces the columns | A document accepts anything — enforcement comes from the rules (`hasOnly`) and Zod, in two places |
| Normalization by default | The cost of a list read is proportional to the document count, so copying is the default and the update obligation is the price |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| Subcollection vs an `ownerId` field | A subcollection is not isolation (`collectionGroup` pierces it). Ownership is always a field |
| `snap.data()` vs the converter | Read without the converter and a stored `id` that disagrees with the document ID comes out as-is |
| `FieldValue.serverTimestamp()` vs `Timestamp.now()` | The first is stamped by the server at commit, the second is the clock of **the instance that called it** |
| One `orderBy` vs a composite index | With even one equality `where` attached, an `orderBy` on a different field requires an index |
| Emulator passing vs the index existing | The emulator checks neither the indexes nor the syntax of `firestore.indexes.json` (measured) |
| `increment` vs read-add-write | `increment` is a sentinel and does not read. Read and write and you get contention and need a transaction |
| Batch vs transaction | A batch is atomic writes only; a transaction is a write **based on a value you read**. Existence and ownership checks take the latter |
