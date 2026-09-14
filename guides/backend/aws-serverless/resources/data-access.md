<!-- orangekit-pack: backend/aws-serverless v3.13.0 -->
# Data access — ownership lives in the key condition

This file owns **the code that calls** DynamoDB: the document client singleton (`src/db/client.ts`) and
all of the task module (`src/db/tasks.ts`) — list, single item, create, update, delete, cursor. Key combinations and index design
are owned by `resources/data-modeling.md`, and the error detectors and the status code table by `resources/error-handling.md`.
This module knows neither the event nor the response — importing `APIGatewayProxyEventV2` here means
the layering has been inverted.

## 1. The decision — what to read with and what to write with

| what you want to do | command | condition |
| --- | --- | --- |
| one item whose key you know | `GetCommand` | `keys.task(ownerId, id)` |
| a list for one owner | `QueryCommand` | `pk` equality + `begins_with(sk, …)` |
| a list narrowed by status | `QueryCommand` + `IndexName: 'gsi1'` | `gsi1pk` equality |
| create | `PutCommand` | `attribute_not_exists(pk) AND attribute_not_exists(sk)` |
| partial update | `UpdateCommand` | `attribute_exists(pk)` |
| delete | `DeleteCommand` | `attribute_exists(pk)` |
| several partitions at once | `TransactWriteCommand` | a condition expression per item (§6) |

One thing is missing from the table. **The command that sweeps a whole table never appears in this pack** —
because the moment you use it, the ownership condition stops being a key condition and becomes a post-filter.
The numbers behind that are in `resources/data-modeling.md` §5.

Three things always travel together: **the owner comes from the session, goes into the key, and a condition expression enforces it.**
Drop any one of the three and the other two are not a defense.

## 2. Build the client outside the handler (`src/db/client.ts`)

Lambda has no resident connection. What it has instead is **a reused execution environment** — a client built at module
top level costs one cold start and every later invocation shares it.

<!-- file: src/db/client.ts -->
```ts
// src/db/client.ts
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';

// module top level — outside the cold start. Build it inside the handler and it stands up again on every call.
const base = new DynamoDBClient({});   // the region and credentials come from the Lambda execution environment

export const ddb = DynamoDBDocumentClient.from(base, {
  // a nested undefined throws under the default settings — a partial-update object is exactly that shape
  marshallOptions: { removeUndefinedValues: true },
});
```

With the document client you never handle the `{ S: '...' }` attribute-value notation. But
send a command from `@aws-sdk/client-dynamodb` (`PutItemCommand` and friends) here and no conversion is applied —
use **only the names `@aws-sdk/lib-dynamodb` exports**.

## 3. The task module (`src/db/tasks.ts`)

<!-- file: src/db/tasks.ts -->
```ts
// src/db/tasks.ts
import { GetCommand, QueryCommand, PutCommand, UpdateCommand, DeleteCommand } from '@aws-sdk/lib-dynamodb';
import { ddb } from './client';
import { TABLE, keys, type Task } from '../keys';
import type { TaskCreate, TaskUpdate, TaskStatus } from '../schemas/task';
import { isConditionalCheckFailed } from '../http/errors';
import { AppError } from '../http/app-error';

/** Turns a LastEvaluatedKey into an opaque string. Not a secret — an unsigned encoding. */
export function encodeCursor(key: Record<string, unknown>): string {
  return Buffer.from(JSON.stringify(key), 'utf8').toString('base64url');
}
export function decodeCursor(cursor: string): Record<string, unknown> {
  try {
    const k: unknown = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'));
    if (!k || typeof k !== 'object' || Array.isArray(k)) throw new Error('shape');
    return k as Record<string, unknown>;
  } catch {
    throw new AppError('VALIDATION_FAILED', 'cannot decode the cursor');
  }
}

export async function listTasks(
  ownerId: string,
  q: { limit: number; cursor?: string; status?: TaskStatus },
): Promise<{ items: Task[]; cursor?: string }> {
  const { pk, skPrefix } = keys.taskList(ownerId);
  const start = q.cursor ? decodeCursor(q.cursor) : undefined;
  // the cursor is a value the client sent — pin it back to the owner's partition
  if (start && start.pk !== pk) throw new AppError('VALIDATION_FAILED', 'cannot decode the cursor');
  const where = q.status !== undefined
    ? { IndexName: 'gsi1', KeyConditionExpression: 'gsi1pk = :g',
        ExpressionAttributeValues: { ':g': keys.statusList(ownerId, q.status).gsi1pk } }
    : { KeyConditionExpression: 'pk = :pk AND begins_with(sk, :sk)',
        ExpressionAttributeValues: { ':pk': pk, ':sk': skPrefix } };
  const res = await ddb.send(new QueryCommand({
    TableName: TABLE, ...where,
    Limit: q.limit, ExclusiveStartKey: start, ScanIndexForward: false,
  }));
  return {
    items: (res.Items ?? []) as Task[],
    cursor: res.LastEvaluatedKey ? encodeCursor(res.LastEvaluatedKey) : undefined,
  };
}

export async function getTask(ownerId: string, id: string): Promise<Task | null> {
  const res = await ddb.send(new GetCommand({ TableName: TABLE, Key: keys.task(ownerId, id) }));
  return (res.Item as Task | undefined) ?? null;   // someone else's has a different key, so it is never caught at all
}

export async function putTask(ownerId: string, input: TaskCreate): Promise<Task> {
  const id = keys.newId();
  // do not spread the body wholesale — moving fields one at a time leaves the body no way to overwrite the key or the owner.
  // But **move everything there is to move.** The only thing coming from the session is ownerId
  const row: Task = {
    ...keys.task(ownerId, id), ...keys.taskGsi1(ownerId, input.status, id),
    id, title: input.title, status: input.status, // these are the body's values — hardcode them and the GSI freezes too
    ownerId,                                       // comes from the session. The body's value is never used
    createdAt: new Date().toISOString(),
  };
  try {
    await ddb.send(new PutCommand({
      TableName: TABLE, Item: row,
      ConditionExpression: 'attribute_not_exists(pk) AND attribute_not_exists(sk)',
    }));
  } catch (e) {
    if (isConditionalCheckFailed(e)) throw new AppError('CONFLICT', 'the task already exists');
    throw e;
  }
  return row;
}

export async function updateTask(ownerId: string, id: string, patch: TaskUpdate): Promise<Task> {
  const entries = Object.entries(patch).filter(([, v]) => v !== undefined);
  if (entries.length === 0) throw new AppError('VALIDATION_FAILED', 'no fields to update');
  const names: Record<string, string> = {};
  const values: Record<string, unknown> = {};
  const sets = entries.map(([k, v], i) => {
    names[`#n${i}`] = k;      // names go through placeholders. `status` is a DynamoDB reserved word
    values[`:v${i}`] = v;
    return `#n${i} = :v${i}`;
  });
  const next = entries.find(([k]) => k === 'status')?.[1];
  if (typeof next === 'string') {
    names['#g'] = 'gsi1pk';   // when the status changes, move the GSI1 partition in the same UpdateItem
    values[':g'] = keys.taskGsi1(ownerId, next as TaskStatus, id).gsi1pk;
    sets.push('#g = :g');
  }
  try {
    const res = await ddb.send(new UpdateCommand({
      TableName: TABLE,
      Key: keys.task(ownerId, id),                 // the owner is in the key
      UpdateExpression: `SET ${sets.join(', ')}`,
      ExpressionAttributeNames: names,
      ExpressionAttributeValues: values,
      ConditionExpression: 'attribute_exists(pk)', // absent (= someone else's) makes it fail
      ReturnValues: 'ALL_NEW',
    }));
    return res.Attributes as Task;
  } catch (e) {
    if (isConditionalCheckFailed(e)) throw new AppError('NOT_FOUND', 'task not found');
    throw e;
  }
}

export async function deleteTask(ownerId: string, id: string): Promise<void> {
  try {
    await ddb.send(new DeleteCommand({
      TableName: TABLE, Key: keys.task(ownerId, id),
      ConditionExpression: 'attribute_exists(pk)', // without the condition it succeeds on a missing key too
    }));
  } catch (e) {
    if (isConditionalCheckFailed(e)) throw new AppError('NOT_FOUND', 'task not found');
    throw e;
  }
}
```

There are two reasons not to build an `UpdateExpression` by string concatenation. One is injection, the other
is **reserved words** — `SET status = :s` is rejected with `reserved keyword: status`.
<!-- verified: DynamoDB Local, @aws-sdk/lib-dynamodb@3.1116.0 — run confirmed -->
Attach `#n0` placeholders mechanically and you never have to memorize the reserved word list. The first line that blocks an
empty `patch` is no decoration either: an expression left as just `SET ` is a syntax error and comes out a 500. <!-- verified: run confirmed -->

**The price of moving fields one at a time is "missing one".** Pin `status` to `'open'` and
`POST {"title":"x","status":"done"}` comes back **201 while the stored value is `open`**, and `keys.taskGsi1` freezes
onto the `'open'` partition too, so it disappears from the `status=done` list forever (audits A and C, measured).
**Consume every field** the schema accepted — the `putTask` shape column of the ledger pins that down.

## 4. Ownership — without a condition expression a delete always succeeds

`DeleteItem` is **idempotent**. Deleting a key that does not exist is not an error but an HTTP 200.
<!-- verified: DynamoDB Local — a DeleteItem with no condition expression returned 200 on a missing key. Run confirmed -->
So delete without a condition expression and **a request to delete someone else's task is answered with a 204 too** — this
axis's signature trap of answering a 0-row mutation as success. `PutItem` is the same: a re-insert with a condition expression gave
`ConditionalCheckFailedException` (HTTP 400), while one without it overwrote silently. <!-- verified: run confirmed -->

**Someone else's is a 404.** Map a condition failure to `NOT_FOUND` and absence and unauthorized are not
distinguishable from outside — answer with a 403 and an unauthorized user enumerates which resources exist by trying ids.
`CONFLICT` only comes out of a create (there is nothing to hide at that point).

The measured ownership behavior. **Only with a positive and a negative in a pair** can a block be told apart from everything being broken.

| action | owner | someone else |
| --- | --- | --- |
| `getTask` | returns the item | `null` <!-- verified: run confirmed --> |
| `updateTask` | returns `ALL_NEW`, the value changes | `AppError('NOT_FOUND')`, the original unchanged <!-- verified: run confirmed --> |
| `deleteTask` | a later read gives `null` | `AppError('NOT_FOUND')`, the original survives <!-- verified: run confirmed --> |
| `listTasks` | its own 25 items | 0 of the other party's items leaked in <!-- verified: run confirmed --> |

**The block proof is owned by `resources/testing.md` §3** — the table there records which assertion
goes red when each of the three guards is actually deleted.

## 5. Cursors — round trip, forgery, plaintext

`LastEvaluatedKey` is an object holding key attributes. Put it into the response as-is and the internal key format becomes the wire
contract, so wrap it in an opaque string. Measured: paging an owner's 25 items to the end at `limit: 7` gave
**4 pages · 25 items · 0 duplicates · 0 omissions**, with the descending sort preserved. <!-- verified: run confirmed -->

**A cursor is not trusted input.** base64url is an encoding, not encryption, so the plaintext is plainly visible:
`{"sk":"TASK#01a0…","pk":"USER#ownerA"}`. So it is blocked in two layers.

Rows 2 and 3 of the table below were **measured with the app check removed, leaving DynamoDB alone**. The `listTasks` of §3
runs `start.pk !== pk` unconditionally on the GSI path too, so with the pack's code as written **all three**
attempts get the result of row 1.

| attempt (relative to the app check) | result |
| --- | --- |
| calling `listTasks` with the cursor's `pk` swapped for someone else's | `AppError('VALIDATION_FAILED')` — the re-pinning check in the §3 code <!-- verified: run confirmed --> |
| **with the app check removed**, straight to DynamoDB with a base-table query | `ValidationException: The provided starting key does not match the range key predicate` <!-- verified: run confirmed --> |
| **with the app check removed**, forging only the base-table `pk` inside a GSI cursor | **DynamoDB does not reject it.** The result still lands inside the `gsi1pk` partition so nothing leaks, but since there is no rejection **the app check is the only defense** <!-- verified: run confirmed -->  |

The third row is why the app-layer re-pinning is kept. DynamoDB's rejection was confirmed only on a base-table
query, and that rejection is a `ValidationException`, so without it in the error code table it goes out as a 500
(`resources/error-handling.md` §2 folds it into a 400).

## 6. Batches and transactions — partial failure is the default

A batch is not atomic. A transaction is atomic, but one broken condition expression cancels the whole thing.

| | ceiling | partial failure | condition expression |
| --- | --- | --- | --- |
| `BatchWriteCommand` | 25 items (26 gives a `ValidationException`) | they come back in `UnprocessedItems` — **the retry is the caller's share** | none. Adding one was ignored without an error <!-- verified: DynamoDB Local — run confirmed. The behavior of the real service is unverified --> |
| `BatchGetCommand` | 100 items (101 gives a `ValidationException`) | `UnprocessedKeys` <!-- verified: run confirmed --> | not applicable |
| `TransactWriteCommand` | 100 items | none — all or nothing | available per item |

A condition failure inside a transaction arrives under a different name. Measured, when only the second of two items failed,
`TransactionCanceledException` · `CancellationReasons = ["None", "ConditionalCheckFailed"]` came
out and **the first item was not stored**. <!-- verified: run confirmed -->
That is why `isConditionalCheckFailed` looks past the name and into the cancellation reasons
(`resources/error-handling.md`). A detector that reads only the name turns a condition failure inside a transaction into a 500.

A throttle is a different animal — a failure a retry is **right** for. Once the SDK's default retries are exhausted,
detect it with `isThroughputExceeded` and send it out as `THROTTLED` (API Gateway does not retry).
A validation failure or a condition failure is not a retry target.

## Misuse list ① — idiom contrast table

| old habit | current shape (SDK v3 · DocumentClient) |
| --- | --- |
| `new DynamoDB.DocumentClient()` (v2) | `DynamoDBDocumentClient.from(new DynamoDBClient({}))` <!-- verified: @aws-sdk/lib-dynamodb@3.1116.0 --> |
| awaiting after attaching `.promise()` | `ddb.send(command)` is already a Promise |
| creating the client inside the handler | once, at module top level |
| hand-assembling the `{ S: value }` attribute-value notation | the document client converts it — put in ordinary JS values |
| comparing with `if (item.ownerId !== user.id)` after the read | put the owner in the key — comparing after the read is pierced by a race |
| ownership through `FilterExpression` | ownership through `KeyConditionExpression` |
| page numbers (`offset`) | the `ExclusiveStartKey` cursor — DynamoDB has no offset |
| concatenating an `UpdateExpression` from strings | generate `#n`/`:v` placeholders mechanically |
| treating a batch result as success | check `UnprocessedItems` and retry |

## Misuse list ② — confusable pairs

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| `PutCommand` vs `UpdateCommand` | `Put` **replaces the item wholesale**. Use it for a partial update and the attributes you did not send disappear |
| `attribute_not_exists` vs `attribute_exists` | create takes the former (preventing an overwrite → `CONFLICT`), update and delete the latter (detecting absence → `NOT_FOUND`) |
| `Limit` vs the number returned | `Limit` is the number of items to read. With a filter attached, fewer than that can come back |
| no `LastEvaluatedKey` vs an empty page | it is the end only when the key is absent. An empty `Items` is not the end — keep paging while there is a cursor |
| `BatchWriteCommand` vs `TransactWriteCommand` | a transaction when you need atomicity. A batch succeeds partially and has no condition expression |
| `ConditionalCheckFailedException` vs `TransactionCanceledException` | a condition failure inside a transaction arrives under the latter name. Look only at the former and it becomes a 500 |
| `ReturnValues: 'ALL_NEW'` vs `'ALL_OLD'` | the value to put in the response is `ALL_NEW`. `ALL_OLD` is the value **before** the update, so returning it as-is sends the old value |
| encoding a cursor vs signing a cursor | base64url neither hides nor protects. Re-pinning the owner is the defense, and if a signature is needed the seam decides it |
