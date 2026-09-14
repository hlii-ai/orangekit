<!-- orangekit-pack: backend/aws-serverless v3.13.0 -->
# Data modeling — the access patterns decide the key

This file owns **the shape of the one table**: the access-pattern list · the PK/SK combination · the GSI choice ·
the item type (`Task`) · the key assembler (`keys`) · the table name (`TABLE`). That is, all of `src/keys.ts`.
Queries and write commands are owned by `resources/data-access.md`, and the CDK construct that builds the table (`TaskTable`)
and the GSI provisioning by `resources/deploy-and-iam.md`.

The T1 data-modeling card **lies dormant** on this axis — that card presumes normalization and foreign keys, and
its `paths:` does not match this stack either. Single-table design is written directly by this file.

## 1. The decision — fill in the access-pattern table first

Relational goes entity → normalization → query. DynamoDB is **the reverse**: write the query list first,
that list decides the key, and the key decides the item shape. Invert the order and you arrive later at
"there is no way to do this query but a Scan" — and by then it is a migration.

**Fill this table in before designing.** While a cell is still empty, the key is not ready to be settled.

| # | access pattern | query shape | index |
| --- | --- | --- | --- |
| AP1 | read one of the owner's tasks | `GetItem(pk, sk)` | base table |
| AP2 | all of the owner's tasks, newest first | `pk = :pk AND begins_with(sk, 'TASK#')` | base table |
| AP3 | the owner's tasks by status, newest first | `gsi1pk = :g` | GSI1 |
| AP4 | create a task (without overwriting) | `PutItem` + `attribute_not_exists` | base table |
| AP5 | update or delete a task (mine only) | `Update/DeleteItem(pk, sk)` + `attribute_exists` | base table |

Three criteria fill the table in.

| question | if the answer is "yes" |
| --- | --- |
| does the query carry **a value pinned by equality** | that value is the partition key (here, the owner) |
| does the result need **an order** | the sort key has to produce that order |
| is there a query whose partition key has to be **a different value** | build one more GSI |

## 2. The single table and key assembly (`src/keys.ts`)

There is one table. Item kinds are told apart by `pk`/`sk` prefixes. **The place that builds a key string
is this file and nowhere else** — assemble the prefix in two places and fixing only one forks them silently.

The item type lives here too. DynamoDB has neither a schema nor code generation, so `pk` · `sk` · `gsi1pk` are
**ordinary attributes of the item**, and only with the type and the assembler in one file is an attribute name settled in one place.

<!-- file: src/keys.ts -->
```ts
// src/keys.ts
import { randomUUID } from 'node:crypto';
import { env } from './env';
import type { TaskStatus } from './schemas/task';

/** The single-table name. Only `src/env.ts` reads the process environment. */
export const TABLE: string = env.TABLE_NAME;

/** The key attributes live inside the item — there is no separate key object. */
export type Task = {
  pk: string; sk: string;
  id: string; title: string; status: TaskStatus;
  ownerId: string; createdAt: string;
  gsi1pk?: string; gsi1sk?: string;   // sparse GSI — an item without them is not indexed
};

const owner = (ownerId: string) => `USER#${ownerId}`;
const item = (id: string) => `TASK#${id}`;

/** Key assembly happens here and nowhere else. The owner comes first. */
export const keys = {
  task: (ownerId: string, id: string) => ({ pk: owner(ownerId), sk: item(id) }),
  taskList: (ownerId: string) => ({ pk: owner(ownerId), skPrefix: 'TASK#' }),
  taskGsi1: (ownerId: string, status: TaskStatus, id: string) => ({
    gsi1pk: `${owner(ownerId)}#STATUS#${status}`,
    gsi1sk: item(id),
  }),
  statusList: (ownerId: string, status: TaskStatus) => ({
    gsi1pk: `${owner(ownerId)}#STATUS#${status}`,
  }),
  /** An id that carries time order — §3 below. */
  newId: (): string =>
    Date.now().toString(16).padStart(12, '0') + randomUUID().replaceAll('-', '').slice(0, 16),
};
```

That `taskList` hands back a `skPrefix` is the point. A list query holds on **a partition-key equality + a sort-key
prefix**, and both go into the `KeyConditionExpression` — not into a filter that sifts after the read.

## 3. The SK decides the order — generating an id is a modeling decision

`GetItem` only holds if `keys.task(ownerId, id)` can build the `sk` out of `id` alone.
So `sk = TASK#<id>`, and **the order of the list is the lexicographic order of `id`**.
Put a random UUID there and the list comes out in UUID order — an order no human can read.

`newId()` builds the first 12 characters from a millisecond timestamp (hex) and the last 16 from randomness.
Lexicographic order becomes chronological order, and `ScanIndexForward: false` alone yields a newest-first list.

| measurement | result |
| --- | --- |
| length and character set | 28 characters, lowercase hex only — usable as-is in a URL path <!-- verified: node v24.7.0, 200,000 generations --> |
| collisions across 200,000 generations | 0 (including many within the same millisecond) <!-- verified: run confirmed — 64 bits of randomness --> |
| lexicographic sort = time-prefix order | true <!-- verified: run confirmed --> |
| an id generated 5ms later sorts higher | true (`01a02e21054d` < `01a02e210554`) <!-- verified: run confirmed --> |

A millisecond timestamp in 12 hex digits has room to spare into the year 10000. Without `padStart(12, '0')`
the lexicographic order collapses the moment the digit count changes — which is why the padding is not decoration.

## 4. Choosing a GSI — build one only when the partition key has to differ

A GSI is **a copy of the item**. The write happens twice and the storage doubles. So there is one criterion:
**is this query impossible to pin by equality using the base table's partition key.**

Here that is AP3 ("only the `open` ones among my tasks, newest first"). The base table's partition is the owner
and nothing else, so the status cannot be caught by equality. So GSI1 is built **with the status in the partition too**.

| | partition key | sort key |
| --- | --- | --- |
| base table | `USER#<ownerId>` | `TASK#<id>` |
| GSI1 | `USER#<ownerId>#STATUS#<status>` | `TASK#<id>` |

That `gsi1sk` is the same value as the base table's `sk` is deliberate — only when both indexes sort the same way
does "newest first" keep one meaning everywhere.

**When the status changes the item moves to a different GSI partition.** That move is not automatic; it happens only if
`gsi1pk` is updated along with it (`updateTask` in `resources/data-access.md`). Miss the update and
a task switched to `done` keeps showing up in the `open` list.

```ts
// ❌ fix status alone and the GSI1 partition stays on the old value
UpdateExpression: 'SET #s = :s'
// ✅ move the index attribute along in the same transaction (the same UpdateItem)
UpdateExpression: 'SET #s = :s, #g = :g'
```

Measured: after moving 10 items to `done`, the `open` list held **0** of them and the `done` list held 10.
<!-- verified: DynamoDB Local (-inMemory), @aws-sdk/lib-dynamodb@3.1116.0 — run confirmed -->

## 5. The owner goes into the partition key — a filter is not a defense

This axis has no row-level policy engine. The application layer is **the only real boundary**, and
the physical place that boundary sits is the `KeyConditionExpression`.

`FilterExpression` is applied **after the read**. The numbers below were taken over the same data (25 items for A · 25 for B).
A shape that applies ownership through a filter really does read someone else's partition, and that read is billed.

| shape | returned | ScannedCount | consumed capacity |
| --- | --- | --- | --- |
| `Query`(pk = A) | 25 | 25 | 1.0 |
| `Scan` + `FilterExpression: ownerId = A` | 25 | 50 | 1.5 <!-- verified: run confirmed --> |
| `Scan` + `FilterExpression: ownerId = B` + `Limit: 10` | **0** | 10 | 0.5 <!-- verified: Limit is applied before the filter. The first 10 items of the scan all belonged to A — run confirmed --> |
| `Query`(pk = **B**) + `FilterExpression: ownerId = A` | 0 | **25** | **1.0** <!-- verified: 0 results, yet all 25 items of B's partition were read and billed — run confirmed --> |

**The table's numbers are measured on DynamoDB Local (`-inMemory`).** The relative comparison (a filter does not reduce
the reads) holds as it stands, but do not read the absolute values as production RCU — item size, consistency
settings and index projection all multiply into them.

The third row is where pagination breaks. `Limit` is applied **before the filter**, so
a request for "give me 10" returns 0 while leaving a cursor behind — empty pages then continue forever.
It appears **when the requester's partition sits late in the scan order**, so it stays invisible on development data
and surfaces once data piles up. Apply the same filter for an owner sitting early in the scan and all 10 came back.

The fourth row is worse. **It returned 0 while reading, and being billed for, all 25 items of someone else's partition** —
if a filter were a defense, that read should never have happened.

```ts
// ❌ the biggest risk on this axis. Ownership sits in a post-filter
new ScanCommand({ TableName: TABLE, FilterExpression: 'ownerId = :o' })
// ✅ the owner is in the partition key — someone else's partition is never even read
KeyConditionExpression: 'pk = :pk AND begins_with(sk, :sk)'
```

`FilterExpression` itself is not forbidden. Sifting incidentally **inside a partition that is already mine** is
normal. What is forbidden is **applying ownership through a filter**, and a machine cannot tell those apart —
reading the line, a human confirms "did the value going into `:pk` here come from the session".

## 6. Evolving the item shape — what having no schema means

In DynamoDB the attribute set can differ from item to item. In exchange for having no migration, **the reader
meets old items.** Three rules carry that.

- **Start a new attribute optional (`?`).** Existing items do not have it.
  To make it required, backfill first
- **Do not delete an attribute; stop writing it.** A deleting write is a full scan, and once the reader ignores it the value is as good as absent
- **Put `schemaVersion` on the item only after the kinds have multiplied.** Add it from the start and
  it only multiplies branches with nothing using them

`gsi1pk`/`gsi1sk` being optional attributes is the same reason. **A GSI indexes only items that carry both
key attributes** (a sparse index) — so when items of another kind land in the same table later,
GSI1 still holds nothing but tasks.

Be careful about passing `undefined` straight through. Measured, an `undefined` on a **top-level** attribute
passed even under the default settings (it is stored with the attribute missing), but a **nested** `undefined`
threw `Pass options.removeUndefinedValues=true ...`.
<!-- verified: @aws-sdk/lib-dynamodb@3.1116.0 — run confirmed -->
So turn `removeUndefinedValues: true` on when building the client
(`resources/data-access.md` §2).

## Misuse list ① — relational habit → single-table contrast table

| old habit (relational) | current shape (DynamoDB single table) |
| --- | --- |
| one table per entity | one table + kinds told apart by `pk`/`sk` prefixes |
| following a relation with a `JOIN` | put them side by side in one partition and read them with a single `Query` |
| a foreign key constraint protects integrity | there are no constraints — `ConditionExpression` takes that place |
| normalize, then write the queries you need | write the access patterns first and derive the key from them |
| `ORDER BY created_at DESC` | the SK decides the order — put the time order **into the id** |
| `WHERE owner_id = ?` (the index handles it) | put the owner **in the partition key**. The `FilterExpression` that corresponds to `WHERE` comes after the read |
| `SELECT *` then sift in the app | you are billed for everything you sift — narrow it with a key condition |
| indexes can be added later | the partition key cannot be changed — it is either a new GSI or a migration |
| `AUTO_INCREMENT` | a monotonically increasing key funnels writes into one partition and makes a hot partition |

## Misuse list ② — confusable pairs

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| `KeyConditionExpression` vs `FilterExpression` | the former decides the range to read, the latter sifts after the read. **Ownership always takes the former** |
| GSI vs LSI | a GSI when the partition key has to differ. An LSI is for the same partition key with only a different sort, and it cannot be added after the table is created |
| `begins_with(sk, ...)` vs `contains(...)` | only `begins_with` can be a key condition. `contains` is a filter and therefore applies after the fact |
| a random UUID vs a time-ordered id | the id used in the SK decides the sort. If you need newest-first, put a time prefix in it |
| `attribute_not_exists(pk)` vs `attribute_exists(pk)` | the former is for create (preventing an overwrite), the latter for update and delete (detecting absence). Swap them and every update fails |
| a sparse GSI vs a full GSI | leave the key attribute optional and only items that carry it are indexed — in a table of mixed kinds this is the default choice |
| `Limit` vs page size | `Limit` is **the number of items to read**. With a filter present it differs from the number returned |
