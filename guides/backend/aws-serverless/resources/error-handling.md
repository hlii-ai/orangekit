<!-- orangekit-pack: backend/aws-serverless v3.13.0 -->
# Error handling — gathering every failure into one table

The domain code → HTTP status mapping table (`ERROR_STATUS`) · DynamoDB exception detection · `ZodError` normalization
are owned by the single file `src/http/errors.ts`. `AppError` and the `respond` that builds the envelope are owned by **the seam**
(`src/http/app-error.ts` · `src/http/respond.ts`) and are only consumed here. Request logging and
catching unhandled exceptions live in `resources/handler-patterns.md`, and the place condition expressions are applied is
`resources/data-access.md`.

## 1. Deciding which code to send out

**The origin of the failure decides the code.** The same exception becomes a different code depending on where it happens (§4), so the
decision starts not from "what failed" but from "**what was asked for**".

| failure | domain code | status | retry |
| --- | --- | --- | --- |
| the schema or the format was wrong | `VALIDATION_FAILED` | 400 | no |
| the token is missing or failed verification | `UNAUTHENTICATED` | 401 | no |
| the subject is right but the role is insufficient | `FORBIDDEN` | 403 | no |
| there is no item I own · **it is someone else's item** | `NOT_FOUND` | 404 | no |
| an attempt to create something that already exists | `CONFLICT` | 409 | no |
| DynamoDB throttled | `THROTTLED` | 429 | **yes** |
| everything else | `INTERNAL` | 500 | the caller's call |

Three things to read out of the table. **Use `FORBIDDEN` only for an insufficient role** — answer someone else's item with a
403 and an unauthorized user sweeps ids to enumerate which resources exist. **Only `THROTTLED` is a retry target**
— API Gateway does not retry Lambda, so a client that received the 429 sending it again is the
only recovery path. **`INTERNAL`'s message is a fixed phrase** and the cause is left only in the log.

## 2. The single mapping table and normalization (`src/http/errors.ts`)

<!-- file: src/http/errors.ts -->
```ts
// src/http/errors.ts
import { z } from 'zod';
import { AppError } from './app-error';

export const ERROR_STATUS: Record<string, number> = {
  VALIDATION_FAILED: 400,
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  THROTTLED: 429,
  INTERNAL: 500,
};

const THROTTLE_NAMES = new Set([
  'ProvisionedThroughputExceededException',
  'RequestLimitExceeded',
  'ThrottlingException',
]);

function awsName(e: unknown): string | undefined {
  const n = (e as { name?: unknown } | null)?.name;
  return typeof n === 'string' ? n : undefined;
}

function awsStatus(e: unknown): number | undefined {
  const s = (e as { $metadata?: { httpStatusCode?: unknown } } | null)?.$metadata?.httpStatusCode;
  return typeof s === 'number' ? s : undefined;
}

function cancellationCodes(e: unknown): string[] {
  const r = (e as { CancellationReasons?: unknown } | null)?.CancellationReasons;
  if (!Array.isArray(r)) return [];
  return r.map((x) => (x as { Code?: unknown })?.Code).filter((c): c is string => typeof c === 'string');
}

export function isConditionalCheckFailed(e: unknown): boolean {
  if (awsName(e) === 'ConditionalCheckFailedException') return true;
  return awsName(e) === 'TransactionCanceledException' && cancellationCodes(e).includes('ConditionalCheckFailed');
}

export function isThroughputExceeded(e: unknown): boolean {
  const n = awsName(e);
  return (n !== undefined && THROTTLE_NAMES.has(n)) || awsStatus(e) === 429;
}

export function isInvalidRequest(e: unknown): boolean {
  return awsName(e) === 'ValidationException';
}

export function fieldErrors(e: z.ZodError): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  const push = (k: string, m: string) => { (out[k] ??= []).push(m); };
  for (const issue of e.issues) {
    if (issue.code === 'unrecognized_keys') {
      for (const k of issue.keys) push(k, 'not an allowed field');
      continue;
    }
    push(issue.path.length > 0 ? issue.path.map(String).join('.') : '_', issue.message);
  }
  return out;
}

export function toAppError(e: unknown): AppError {
  if (e instanceof AppError) return e;
  if (e instanceof z.ZodError) {
    return new AppError('VALIDATION_FAILED', 'the request does not match the schema', fieldErrors(e));
  }
  if (isConditionalCheckFailed(e)) {
    return new AppError('CONFLICT', 'the resource state does not match the condition');
  }
  if (isThroughputExceeded(e)) {
    return new AppError('THROTTLED', 'try again in a moment');
  }
  if (isInvalidRequest(e)) {
    return new AppError('VALIDATION_FAILED', 'the request shape is not valid');
  }
  return new AppError('INTERNAL', 'the request could not be processed');
}
```

**A `ValidationException` is a 400, not a 500.** It arrives when a request does not match DynamoDB's
syntax or constraints, and **ordinary client misuse belongs to that class** — resend a cursor obtained from a different
index and `The provided starting key does not match the range key predicate` comes back
<!-- verified: DynamoDB Local 3.3.1 run. The same vector as resources/data-access.md §5 -->.
Without the mapping, a common paging mistake goes out as a 5xx and sets an alarm off. **The price**: the same name also
arrives from a code defect (a badly assembled `UpdateExpression`), and a 400 sets off no alarm. So
anything client-originated is **refused in the app layer first** (the cursor re-pinning check) — when the
`ValidationException`s reaching the adapter increase, the place to read is that check, not the log.

**The last line of `toAppError` is why this file exists.** Anything unknown is folded into `INTERNAL`
— what `catch (e)` receives is `unknown`, and a string or even `undefined` can arrive.
Send `e.message` out as-is and the table name, an ARN and query fragments leak to the client.

This file does not import `@aws-sdk/*`. It reads only the `name` string, so `src/http/`
does not depend on the data layer and the SDK is not dragged into the bundle a second time.

## 3. Tell DynamoDB exceptions apart by `name`

An SDK v3 exception carries `name` · `$metadata` · `__type`. This is the object that came back from throwing a real
conditional write at DynamoDB Local 3.3.1 <!-- verified: DynamoDB Local 3.3.1 + @aws-sdk/lib-dynamodb 3.1116.0 run, object dump -->.

| field | value | is it usable |
| --- | --- | --- |
| `name` | `'ConditionalCheckFailedException'` | **use it as the basis for detection** |
| `__type` | `'com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException'` | an internal field. A hand-built object does not have it |
| `$metadata.httpStatusCode` | `400` | a secondary basis for detecting a throttle (429) |
| `$fault` | `'client'` | not used to decide a retry |
| `code` | `undefined` — **a v2 idiom** | use it and it is always `false` |

The three throttle names are the list the SDK's own retry classifier uses (`THROTTLING_ERROR_CODES` in
`@smithy/core`). `isThrottlingError` in the same file also reads `$metadata.httpStatusCode === 429`,
so `isThroughputExceeded` carries that condition too
<!-- verified: @smithy/core dist-es/submodules/retry/service-error-classification/constants.js:10-25 and service-error-classification.js:19-21 compared -->.
**The throttle itself, though, could not be confirmed against the real service** — DynamoDB Local does not throttle, so the name
list is backed only by the SDK source comparison above.

`instanceof ConditionalCheckFailedException` gives the same verdict **only for exceptions the SDK built**.
`[Symbol.hasInstance]` calls `ServiceException.isInstance` before it falls through to a name comparison, and
that, absent the prototype chain, demands **that `$fault` and `$metadata` both exist and that
`$fault` be `'client'` or `'server'`**
<!-- verified: @smithy/smithy-client 4.4.5 dist-es/exceptions.js:9-31 compared directly -->.
So **an object carrying only a name**, like `{ name: 'ConditionalCheckFailedException' }`, is
**false under `instanceof`** — and that is exactly the object the §6 test uses. Reading only the `name` string
gives the same answer for both shapes, and as a bonus removes the need to import the SDK.

## 4. The same exception becomes a 409 and a 404 alike

`ConditionalCheckFailedException` says only "the condition expression was false". **Only the call site knows which condition
was applied**, so the conversion happens in the data layer.

| call | condition expression | what the failure means | what to throw |
| --- | --- | --- | --- |
| `putTask` | `attribute_not_exists(pk)` | it already exists | `AppError('CONFLICT', …)` |
| `updateTask` | `attribute_exists(pk)` | it is not in my partition | `AppError('NOT_FOUND', …)` |
| `deleteTask` | `attribute_exists(pk)` | it is not in my partition | `AppError('NOT_FOUND', …)` |

```ts
// src/db/tasks.ts — the call site attaches the meaning
try {
  await ddb.send(new DeleteCommand({ TableName: TABLE, Key: keys.task(ownerId, id),
    ConditionExpression: 'attribute_exists(pk)' }));
} catch (e) {
  if (isConditionalCheckFailed(e)) throw new AppError('NOT_FOUND', 'task not found');
  throw e;
}
```

All three calls got `isConditionalCheckFailed(e) === true` against the real service, and through the conversion they
split into 409 · 404 · 404 <!-- verified: three conditional writes (put/update/delete) run against DynamoDB Local 3.3.1 -->.
Miss the conversion and `toAppError` folds every one of them into a 409 — that 409 is the signal that "the wiring is missing".

**Because the owner sits in the partition key, a condition failure tells nothing about whether someone else's item exists.**
`keys.task(ownerId, id)` points only at that owner's partition, so a request to delete someone else's
stops at "it is not there". That a 404 satisfies both hiding existence and stating the truth is **thanks to the key design,
not to picking a response code** — apply the owner through a `FilterExpression` and this property collapses.

**A condition failure inside a transaction carries a different name.** On cancellation a `TransactionCanceledException` arrives and
the reason is in `CancellationReasons[i].Code` — the measured value was
`[{"Code":"ConditionalCheckFailed"},{"Code":"None"}]`
<!-- verified: TransactWriteCommand run against DynamoDB Local 3.3.1, error dump -->.
A detector that reads only the name misses this and emits a 500. `cancellationCodes` in §2 is the place for it.

## 5. `ZodError` → the field-error envelope

`fieldErrors` joins `issue.path` with dots to make the key, and because `unrecognized_keys` has an empty
path it spreads that out by the names in `issue.keys`. Everything else with no path is gathered under `_`.

| input | `fieldErrors` result |
| --- | --- |
| `{"title":123}` | `{"title":["Invalid input: expected string, received number"]}` |
| `{"title":"a","zzz":1}` | `{"zzz":["not an allowed field"]}` |
| `[1,2]` | `{"_":["Invalid input: expected object, received array"]}` |
| `{items:[{t:1},{t:2}]}` | `{"items.0.t":[…],"items.1.t":[…]}` — the index survives |

That last row is why `z.flattenError(e).fieldErrors` is not used — that one folds the same input into
`{"items":[…,…]}`, **erasing which element was wrong**, and puts top-level errors in a separate
`formErrors`, so using only `fieldErrors` makes the unknown-key error disappear entirely
<!-- verified: the outputs of the two functions compared on zod 4.4.3. formErrors present in the flattenError output -->.

**Do not put request values into the envelope.** Zod 4's default message states only the type and the limit — send a 300-character
secret string as `title` (`max(200)`) and the message was
`Too big: expected string to have <=200 characters`, with the input value nowhere in it
<!-- verified: zod 4.4.3, run against a schema shaped like TaskCreateSchema -->. What `z.strictObject`'s
unknown-key error does do is **hand the submitted key name straight back** — a name and not a value, but start putting
input values into messages you write yourself and this property breaks.

## 6. Logging and responding — reducing the leak surface to one

The handler does not build the envelope itself. `respond.fail` is the only place that normalizes through `toAppError`
and then reads the status out of `ERROR_STATUS`.

```ts
// src/handlers/tasks-delete.ts
export const handler = withContext(async (event) => {
  try {
    const user = requireAuth(event);
    await deleteTask(user.id, pathParam(event, 'id'));
    return respond(null, { status: 204 });
  } catch (e) {
    return respond.fail(e);
  }
});
```

Send the cause to the log and the code to the response. Only when the status is 500 is the original carried, left in CloudWatch
in a queryable shape — print every 400 and 404 as an error and the alarm rings on a user's typo.

```ts
// src/http/respond.ts — owned by the seam. Only the logging position is shown
const app = toAppError(e);
const status = ERROR_STATUS[app.code] ?? 500;
if (status >= 500) logger.error('unhandled', { code: app.code, err: e });
else logger.warn('rejected', { code: app.code });
```

Tests put **a positive and a negative inside the same `it`**. A test carrying only `expect(404)` stays green even when the
query is swapped wholesale for `return null` — because everything is a 404.

```ts
// test/errors.test.ts
it('a condition failure splits by meaning and the unknown gets folded', () => {
  expect(toAppError({ name: 'ConditionalCheckFailedException' }).code).toBe('CONFLICT'); // ✅ positive
  expect(toAppError(new AppError('NOT_FOUND', 'x')).code).toBe('NOT_FOUND');             // ✅ passes through
  expect(toAppError({ name: 'ValidationException' }).code).toBe('VALIDATION_FAILED');    // ✅ positive
  expect(toAppError({ name: 'ResourceNotFoundException' }).code).toBe('INTERNAL');       // ✅ folded
  expect(toAppError(new Error('table arn secret')).message).not.toContain('arn');        // ✅ negative
});
```

## Misuse list ① — Express + SDK v2 idiom → Lambda + SDK v3 contrast table

| old habit | current shape |
| --- | --- |
| the `app.use((err, req, res, next) => …)` error middleware | there is no middleware chain. The handler calls `respond.fail(e)` from a `try/catch` |
| `err.code === 'ConditionalCheckFailedException'` (v2) | it is `err.name`. A v3 exception has no `code` <!-- verified: no code in the real error dump --> |
| `err.statusCode` | `err.$metadata.httpStatusCode` <!-- verified: the real error dump --> |
| `err.retryable` | `err.$retryable` — `undefined` for a condition failure <!-- verified: the real error dump --> |
| the `AWS.DynamoDB.DocumentClient` callback / `.promise()` | `ddb.send(new PutCommand(…))` hands back a Promise |
| `res.status(500).json({ error: err.message })` | gather it into the single `respond.fail(e)`. The original message goes to the log only |
| iterating Zod errors through `error.errors` | it is `error.issues`. `error.errors` is `undefined` <!-- verified: zod 4.4.3 run --> |
| putting `error.flatten().fieldErrors` straight into the envelope | `formErrors` is thrown away — the unknown-key error disappears (§5) |
| handling a fatal error with `process.exit(1)` | `throw` at module top level — initialization fails and the function never comes up |

## Misuse list ② — confusable pairs

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| `CONFLICT` (409) vs `NOT_FOUND` (404) | a condition expression of `attribute_not_exists` gives 409, `attribute_exists` gives 404 (§4) |
| `ConditionalCheckFailedException` vs `TransactionCanceledException` | a condition failure inside a transaction is the latter. The reason is in `CancellationReasons[].Code` |
| `ResourceNotFoundException` vs `NOT_FOUND` | the former means **the table is missing** — a deployment error, so a 500 |
| `$fault === 'client'` vs retryable | a condition failure is `client` too. Decide a retry from `THROTTLE_NAMES` and 429 |
| `toAppError` vs branching in the `catch` directly | if there is a domain meaning, convert to `AppError` at the call site. `toAppError` is the last-resort normalization |
| `z.flattenError` vs `z.treeifyError` | the former for a flat envelope, the latter when sending the nested structure as-is. The former erases array indexes |
| putting `z.prettifyError` into a response | it is a multi-line string for a human to read. It is for the boot log; the envelope takes `fieldErrors` |
| `logger.error` vs `logger.warn` | only a 500 is error. Print a 400 or a 404 as error and the alarm rings on a user's typo |
| the argument order of `AppError(code, message)` | both trailing arguments are `string`, so swapping them still compiles — the code comes first |
