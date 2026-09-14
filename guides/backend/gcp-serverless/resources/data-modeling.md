<!-- orangekit-pack: backend/gcp-serverless v3.14.0 -->
# Document design — ownership lives in a field, and the index decides the query shape

What this file owns is **what goes into a document and where it is placed**, and the **two declarations**
that decision forces — `firestore.indexes.json` · `firestore.rules`. The code that reads and writes is owned by
`data-access.md` (`src/firestore/`), and the schema types (`Task`·`TaskCreate`) are owned by
`input-validation.md` (`src/schemas/task.ts`). **This file creates no new export** — that is design discipline.

**This axis has no policy engine.** Section 3 below demonstrates it by execution: reading the same document under the
same rules down two paths, one was refused and **the server credential path went through.** What keeps
ownership is document design and application code, nothing else.

## 1. The placement decision — root collection or subcollection

This choice comes before any technique. **Changing it means moving data, so it cannot be reversed.**

| a document that … | placement | why |
| --- | --- | --- |
| belongs to one user and **will someday need administration·aggregation·transfer** | **root `tasks/{taskId}` + an `ownerId` field** ← what this pack picked | ownership is visible in the query, so a machine can check it (the `ownership-in-query` policy). Hide it in the path and there is no string to check |
| belongs to one user and **will never be looked at across the user boundary** | the subcollection `users/{uid}/tasks/{taskId}` | the path is the owner. But the moment you do look across, you need a `collectionGroup` query, and **that query has no owner boundary** |
| is shared by several subjects | root + `memberIds: string[]` (filter with `array-contains`) | it is not expressible as a single owner |
| cannot exist without a parent | subcollection | but **deleting the parent document leaves the subcollection behind** — deletion is not automatic |

The last row is the trap of subcollections. Delete the `users/{uid}` document and the `tasks/*` beneath it stay
alive while `users/{uid}` becomes **a parent that does not exist**. To delete them you have to enumerate the children.

**The most expensive illusion on this axis is that a subcollection keeps ownership for you.** Even with the
`uid` embedded in the path, what puts that `uid` there is application code, and put a wrong value in and the path
points straight at someone else's spot. The rules do not stop that (section 3).

## 2. Document shape — what is stored and what is not

A single `tasks/8kQ2vN…` document looks like this. The document ID is `Task.id`, so **`id` is not in
the data.**

```json
{
  "ownerId": "PLd3aX8mQ2bK7…",
  "title": "Send the invoice",
  "status": "open",
  "createdAt": "<Timestamp 1700000000.000000000>"
}
```

| field | stored type | stored? | why |
| --- | --- | --- | --- |
| `id` | — | **no** | it is the document ID. Keep it as a field too and the two values diverge, and once they have, there is no telling which is real |
| `ownerId` | `string` | **yes** | it is **the only place** the query filter reads. Encode it into the document ID (`{uid}_{rand}`) and the query cannot read it |
| `title` | `string` | yes | the length ceiling is applied by the schema (`input-validation.md`) — see section 6 |
| `status` | `string` | yes | what gets stored is the **lowercase values** `'open'`·`'done'` |
| `createdAt` | `Timestamp` | yes | it is the key for sorting·range filters. Leave it as an ISO string and the comparison becomes a string comparison, and the moment time zones mix the ordering collapses |

The `createdAt` slot in the example above is **a `Timestamp` value, not a string** — it imitates the console display.

<!-- unverified: the emulator does not imitate sharding, so the hotspot itself was not observed. The auto-ID recommendation is design guidance from the Firestore documentation -->
**Use auto-generated document IDs** (`tasksRef.doc()`). A human-readable sequential ID (`task-1`·`task-2`) or a
timestamp-prefixed ID crowds writes into one stretch of the key space — Firestore shards by key range, so
**a monotonically increasing ID always hits the same shard.**

The value that goes into `ownerId` is the `sub` of a verified ID token (`identity-tokens.md`). A user
identifier in the request body is input, not a credential.

## 3. `firestore.rules` is a blanket deny — and that is the honest state

<!-- file: firestore.rules -->
```
rules_version = '2';

service cloud.firestore {
  match /databases/{database}/documents {
    // On this axis the only thing that attaches to Firestore is server access made by Cloud Run with a service account (ADC),
    // and server access bypasses the rules entirely. There is no path by which a client SDK attaches directly.
    // Write a condition into the rules and all you create is the false premise that "the rules protect us".
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
```

**Include this file in the deployment artifact.** Without it the default for a new database applies, and what that
default is depends on the mode picked when the project was created — you end up with a value outside your control as the boundary.

**The rules are alive, and the server passes straight through them.** On a Firestore emulator loaded with the rules
above, the same document was read down two paths.

<!-- verified: loaded **the file above as-is** into firestore-emulator 1.19.8 and looked up tasks/ix1 down two paths — instrumented the response codes and bodies directly -->

| path | response |
| --- | --- |
| the client path that goes through the rules (no credentials) | **403** `PERMISSION_DENIED` — `false for 'get' @ L9` |
| the server credential path (the path this pack uses) | **200** — it got the same document back unchanged |

<!-- verified: in the same emulator session, every write·read·transaction of this pack performed with @google-cloud/firestore 9.0.0 succeeded -->
And under those same rules, create·update·delete·transaction on `@google-cloud/firestore` 9 **all
succeeded.** The 403 is the positive control showing the rules are not dead, and the 200 is the observation that those
rules have no effect whatsoever on this pack's code.

**So there is nowhere to write "defense in depth".** A query that leaves out the ownership check is not stopped
behind the scenes — it hands over someone else's document.

## 4. Composite index declarations (`firestore.indexes.json`)

**The query shape decides the index.** `listTasks` in `data-access.md` builds two shapes, and
those two are exactly the two entries in this file.

| query | the index it needs |
| --- | --- |
| `where ownerId` + `orderBy createdAt desc` + `orderBy __name__ desc` | `ownerId` ASC → `createdAt` DESC → `__name__` DESC |
| the above + `where status` | `ownerId` ASC → `status` ASC → `createdAt` DESC → `__name__` DESC |

**Equality filters first, sort keys after.** Swap the order and that index does not satisfy this query.

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

<!-- verified: ran the file above through FirestoreApi.validateSpec of firebase-tools 14 — VALID. As a positive control, a file with order changed to "SIDEWAYS" was refused with «Field "order" must be one of ASCENDING, DESCENDING» -->
This file passes firebase-tools' index spec validator — that the validator does not take just
anything was confirmed by the wrong file being refused.

**Do not leave out the `__name__` row.** The last sort key is `desc`, so the document ID ordering has to be `DESCENDING`
as well. Omit it and it becomes the default `ASCENDING`, and that index does not satisfy
`orderBy('__name__', 'desc')` — that is, the very shape cursor pagination uses cannot find an index.

## 5. A missing index passes the emulator — which is why it first dies on deploy

<!-- verified: ran the second query shape of section 4 against firestore-emulator 1.19.8 with firestore.indexes.json emptied out and got a normal response -->
Confirmed by running it: with the `indexes` array **left empty**, a `where ownerId` + `where status` + `orderBy createdAt` +
`orderBy __name__` query was run and the emulator returned the results as usual. **Green tests do not
mean the index exists.**

<!-- unverified: with no real GCP project, production actually refusing this query was not observed. The domain handling of gRPC 9 is owned by error-handling.md -->
In production a composite query with no index fails with **gRPC 9 `FAILED_PRECONDITION`**. This pack
**folds it into a 500** — it is not a user input problem but a missing deployment, and folding it into a 4xx makes the cause
disappear from the logs (`error-handling.md`).

**When you build a new filter·sort combination, fix this file in the same commit.** An index put off until later is
the one class of "the tests passed but it dies on deploy", and nothing catches the window in between.

## 6. Document size and write contention

A single document has to be **smaller than 1 MiB**, and the real ceiling is a little below that.

<!-- verified: on firestore-emulator 1.19.8, observed a 1000 KiB field succeed and a 1100 KiB field refused with gRPC 3 INVALID_ARGUMENT -->

| what was written | result |
| --- | --- |
| a 1000 KiB string field | success |
| a 1100 KiB string field | **gRPC 3** `INVALID_ARGUMENT` — `longer than 1048487 bytes` |

**gRPC 3 is not among this pack's detection functions (5·6·9·10)** — so it folds into `INTERNAL` (500). Keeping
documents small so you never meet this code is the only answer: put the length ceiling for `title` in the schema
(`input-validation.md`), and put things that grow, like attachments·bodies, in Cloud Storage rather than the document,
leaving only a reference in the document.

**Do not grow an array without bound.** An array inside a document makes a single write rewrite the whole document, so
as items grow, write cost and contention grow together. Anything whose item count grows goes out into a subcollection.

**Do not crowd writes onto one document.** Transactions that read and write the same document are **serialized** against each other.

<!-- verified: on firestore-emulator 1.19.8, ran 20 transactions of the same kind concurrently against one document and against 20 documents respectively and instrumented the wall clock -->

| what | time taken | final value |
| --- | --- | --- |
| 20 transactions on **one** document | **7749 ms** | 20 (correct) |
| one each on **20** documents (control) | **32 ms** | — |

**The result is right and only throughput collapses** — which is why nobody notices until the load goes up.
Gather a summary value like "task count" into one user document and that document becomes the serialization point for the
whole account. If you need a count, split the summary document per owner, or read it with an aggregation query.

## Misuse list ① — idioms from other axes → the shape on this axis

| old habit | the current shape (this axis) |
| --- | --- |
| keeping ownership with a `request.auth` condition in the rules | the rules are `if false`. The server bypasses the rules — that is what the measurement in section 3 is |
| attaching with `firebase-admin` and understanding the rules as an "admin bypass" | this axis attaches with `@google-cloud/firestore`. The bypass is not an exception but **the only path** |
| the RDB habit: deciding ownership with a join instead of an owner column | there are no joins. `ownerId` has to be there **as a document field** for the query to read it |
| adding an index when things get slow | a composite query with no index is not slow, it **fails** (gRPC 9) |
| storing `createdAt` as an ISO string | `Timestamp`. With a string, the moment time zones mix the ordering collapses |
| assuming deleting the parent document deletes the children | the subcollection stays — you have to enumerate the children and delete them |

## Misuse list ② — confusion pairs

| what gets picked wrong often | the exact condition for applying it |
| --- | --- |
| root collection + `ownerId` vs subcollection | if ownership **has to be checkable by a machine**, it is root. Hide it in the path and there is no string to check |
| the `__name__` sort key vs omitting it | it is mandatory whenever the sort key is not unique (the same `createdAt`). This pack always attaches it |
| index `ASCENDING` vs query `desc` | the direction of the index has to match the direction of the query's `orderBy` **literally** |
| equality-filter order vs sort-key order | index fields go **equality filters first, sort keys after** |
| a green emulator vs the index existing | the emulator does not require an index (section 5) — green is not evidence |
| an array inside a document vs a subcollection | if the items **grow**, subcollection. An array rewrites the whole document on every write |
