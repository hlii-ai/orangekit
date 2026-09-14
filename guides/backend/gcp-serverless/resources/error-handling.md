<!-- orangekit-pack: backend/gcp-serverless v3.14.0 -->
# Error handling — fold whatever was thrown into one, and the status comes from one table only

What this file owns is two things: **the place gRPC errors are detected** (`src/firestore/errors.ts`) and **the table that
folds whatever was thrown into an `AppError` and turns a domain code into an HTTP status** (`src/http/errors.ts`).
`AppError` itself, the response envelope, and the `app.onError` wiring are **owned by the seam** (`src/errors.ts` ·
`src/http/handlers.ts`) — the envelope is decided by the combination, not the axis. Why token verification failures
fold into a single class is owned by `identity-tokens.md`.

**This axis has no backup.** The ownership decision lives only in the application layer, and the moment an error response says
"that document exists but is not yours", that response is itself proof of existence.

## 1. What gets thrown — the classes and the order they are handled in

`toAppError` decides **from top to bottom**. The order is the contract — put the `AppError` check later and
the `NOT_FOUND` a service threw on purpose gets eaten by the `INTERNAL` of the default branch.

| order | what was thrown | where it comes from | the code it folds into | status |
| --- | --- | --- | --- | --- |
| 1 | `AppError` | services · the repository · `verifyIdToken` · `decodeCursor` | **it passes straight through** | as the table says |
| 2 | `ZodError` | body·query·cursor·document re-parse | `VALIDATION_FAILED` + `fieldErrors` | 422 |
| 3 | gRPC **5** `NOT_FOUND` | Firestore | `NOT_FOUND` | 404 |
| 4 | gRPC **6** `ALREADY_EXISTS` | Firestore | `CONFLICT` | 409 |
| 5 | gRPC **10** `ABORTED` | Firestore (transaction contention, retries exhausted) | `CONFLICT` | 409 |
| 6 | gRPC **3** `INVALID_ARGUMENT` | Firestore (a document over the size limit, and such) | `VALIDATION_FAILED` | 422 |
| 7 | gRPC **9** `FAILED_PRECONDITION` | Firestore (almost always a missing index) | **`INTERNAL`** — it is not folded into a 4xx | 500 |
| 8 | **everything** else | from anywhere | `INTERNAL` | 500 |

**The point of this table is why 9 and 10 part ways.** Both have infrastructure causes, but **10 is fixed by sending it again and
9 fails forever until the deployment is fixed.** Send 9 out as a 4xx and the client sets about fixing its own input
while the missing index never reaches anyone's dashboard. **There is no default that lets the unknown through.**

<!-- verified: on emulator 1.19.8 a 1100 KiB document was refused with gRPC 3 `longer than 1048487 bytes` (observed by C2). Unverified against real GCP -->
**3 is the exact opposite of 9.** Code 3 means **what the client sent went over a limit** — a single document over
1 MiB (1048487 bytes) comes here — and the caller can fix it by shrinking the body. Fold this into a 500
and **you make something fixable look unfixable.**

## 2. gRPC code detection (`src/firestore/errors.ts`)

This file **knows nothing about HTTP.** The repository (`src/firestore/tasks.ts`) calls it, and put it under `http/` and
the data layer drags in an HTTP module, so that layer's tests only run once they stand up the app.

<!-- verified: the two enums, @grpc/grpc-js 1.14.4 build/src/constants.d.ts and google-gax 5 build/src/status.d.ts, are identical — 5·6·9·10 -->
The numbers were confirmed in the enums of the installed `@grpc/grpc-js` and `google-gax` — the two enums give the same values.
<!-- verified: attached firestore 9.0.0 to a local gRPC server, made Commit return each status, and instrumented the object the client received -->
And what the client receives is **not** a `GoogleError` but an ordinary `Error` with `code`·`details`
attached (`err.constructor.name === 'Error'`) — **`instanceof` cannot detect it.**

<!-- file: src/firestore/errors.ts -->
```ts
// src/firestore/errors.ts
// These are gRPC status codes. Not HTTP statuses — this file knows nothing about HTTP.
const GRPC_INVALID_ARGUMENT = 3;
const GRPC_NOT_FOUND = 5;
const GRPC_ALREADY_EXISTS = 6;
const GRPC_FAILED_PRECONDITION = 9;
const GRPC_ABORTED = 10;

function grpcCode(err: unknown): number | null {
  if (typeof err !== 'object' || err === null) return null;
  const code = (err as { code?: unknown }).code;
  // Node's system errors carry a code too, but a string one ('ECONNREFUSED'). Take numbers only.
  return typeof code === 'number' ? code : null;
}

export function isInvalidArgument(err: unknown): boolean { return grpcCode(err) === GRPC_INVALID_ARGUMENT; }
export function isNotFound(err: unknown): boolean { return grpcCode(err) === GRPC_NOT_FOUND; }
export function isAlreadyExists(err: unknown): boolean { return grpcCode(err) === GRPC_ALREADY_EXISTS; }
export function isFailedPrecondition(err: unknown): boolean { return grpcCode(err) === GRPC_FAILED_PRECONDITION; }
export function isAborted(err: unknown): boolean { return grpcCode(err) === GRPC_ABORTED; }
```

<!-- verified: ran the section 8 tests against a mutation with the guard deleted and observed them green — === already filters strings out -->
The `typeof code === 'number'` guard is **defense in depth** — delete it, run again, and it was still green. `===` already
makes `'ECONNREFUSED' === 5` false. It stays anyway: loosen the comparison to `==` and `'5' == 5` becomes
true, and the `number | null` return type moves that mistake to where the type check can see it.

**Do not decide on a message string.**

```ts
// ❌ change the message format in the SDK and it dies quietly. Locale·detail wording is not a contract
if (String(err).includes('NOT_FOUND')) return notFound();
// ❌ this has the same defect — details is prose the backend built
if ((err as { details?: string }).details?.startsWith('no entity')) return notFound();
// ✅ the code is the wire contract
if (isNotFound(err)) return notFound();
```

## 3. `ERROR_STATUS` — the only place a status lives

The table from domain code to HTTP status is **the only one there is.** Let a router start writing `c.json(…, 404)`
on the spot and the same code goes out with a different status per path, and nobody ever undoes that difference.

| domain code | status | why that value |
| --- | --- | --- |
| `VALIDATION_FAILED` | **422** | the body parsed and a field is wrong. 400 is indistinguishable from "this is not JSON", and the client has to react differently to those two |
| `UNAUTHENTICATED` | **401** | there is no credential, or it is not valid. Every failure of `verifyIdToken` comes here |
| `FORBIDDEN` | **403** | identity is confirmed and the **role·scope** falls short. An ownership failure is **not** here (section 7) |
| `NOT_FOUND` | **404** | it is missing, or it exists and is someone else's — the two are not distinguished |
| `CONFLICT` | **409** | duplicate creation (gRPC 6) and contention exhaustion (gRPC 10). The only class the client **can send again** |
| `INTERNAL` | **500** | all the rest. A missing index (gRPC 9) is here too |

**A code absent from the table is a 500.** Use a bare subscript and a typo'd code puts `undefined` where the status goes,
and that runtime error folds back into a 500, so **the original code disappears.** That is why the table is never read directly and
**only `statusFor(code)` is used** — there is no exception for the seam or the pack (section 4).

## 4. `toAppError` (`src/http/errors.ts`)

This is the function the error handler calls **first of all.** Let even one path skip it and only that path's envelope
comes out in a different shape, and the client has to parse two formats.

<!-- file: src/http/errors.ts -->
```ts
// src/http/errors.ts
import { ZodError } from 'zod';
import { AppError } from '../errors.js';
import { fieldErrors } from '../schemas/errors.js';
import { isAborted, isAlreadyExists, isFailedPrecondition, isInvalidArgument, isNotFound } from '../firestore/errors.js';
import { log } from '../obs/log.js';

/** Domain code → HTTP status. The only mapping table. */
export const ERROR_STATUS: Record<string, number> = {
  VALIDATION_FAILED: 422,
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  INTERNAL: 500,
};

/** The only route to a status. Policy forbids subscript access. */
export function statusFor(code: string): number {
  return ERROR_STATUS[code] ?? 500;
}

export function toAppError(err: unknown): AppError {
  if (err instanceof AppError) return err;

  if (err instanceof ZodError) {
    return new AppError('VALIDATION_FAILED', 'the input is not valid', fieldErrors(err));
  }

  if (isNotFound(err)) return new AppError('NOT_FOUND', 'task not found');
  if (isAlreadyExists(err)) return new AppError('CONFLICT', 'that task already exists');
  if (isAborted(err)) return new AppError('CONFLICT', 'contention prevented processing. Try again');
  if (isInvalidArgument(err)) return new AppError('VALIDATION_FAILED', 'the request went over a limit');

  if (isFailedPrecondition(err)) {
    // Almost always a missing composite index — a deployment defect, not a user input problem.
    // Leave the diagnosis in the log only and fold the response into a 500.
    log('error', 'firestore failed precondition', { grpcCode: 9 });
    return new AppError('INTERNAL', 'could not process the request');
  }

  log('error', 'unhandled error', { kind: err instanceof Error ? err.name : typeof err });
  return new AppError('INTERNAL', 'could not process the request');
}
```

The seam defines `AppError` in `src/errors.ts`, and `installErrorHandlers` normalizes with `toAppError(err)` and then
**decides the status with `statusFor(appErr.code)` — this is the only route to a status, and
subscript access to `ERROR_STATUS` is forbidden by policy even with `?? 500` attached.** The moment the table is opened, that spot
becomes the starting point of a new mapping. **The pack does not write a status into a response** — because the envelope is a function of the combination.

## 5. Do not load the original message into the response

The reason row 8 does not carry `err.message` over is that **the original is a string we did not choose.**

<!-- verified: made a local gRPC server return details and instrumented the client's err.message — the SDK attaches only a "<code> <name>: " prefix and joins the backend string on as-is -->
- The Firestore SDK joins the `details` the backend gave onto `err.message` **without processing it**
<!-- verified: observed that the details the emulator sent carried the project identifier (`dev~demo-tasks`) and the document path verbatim (C2). The wording of a real GCP backend is unverified -->
- That wording **carries the project identifier and the document path verbatim** — observed on the emulator
<!-- verified: observed on zod 4.4.3 that ZodError.message is a JSON dump of the issues array -->
- `ZodError.message` is **a JSON dump of the entire issue array**. Load it as it is and the internal structure of the schema
  goes out wholesale, and the client has two formats to parse

The message of `INTERNAL` is **a fixed string**. Leave the diagnosis with `log`, but do not load tokens·whole
documents·email addresses — a log is a leak path too.

## 6. zod error normalization — there are places where `path` comes out empty

`fieldErrors` is owned by `src/schemas/errors.ts` (`input-validation.md`) — this file only calls it.

| what was wrong | the `issue.path` observed | the key in `fieldErrors` |
| --- | --- | --- |
| `title` is an empty string | `['title']` | `title` <!-- verified: ran an empty string through zod 4.4.3 and observed it --> |
| a field inside an array item | `['items', 0, 'title']` | `items.0.title` — **the index is not stripped** <!-- verified: printed the issue.path of zod 4.4.3 directly --> |
| `.strict()` refusing an unknown key | **`[]` (an empty array)** | there is no field to attach it to <!-- verified: observed that path is an empty array in the unrecognized_keys issue of zod 4.4.3 --> |

The last row is the trap. zod 4's `unrecognized_keys` issue **does not carry which field is the problem in its
`path`** (the problem is the whole object). A form that looks only at the field map cannot attach that error, and the user falls into
the state of "it will not save and there is no red text" — besides `fieldErrors` you need **an object-level message**.

<!-- verified: observed 'errors' in err === false on zod 4.4.3 -->
`ZodError` **has only `.issues`.** zod 3's `.errors` is gone, and accessing it gives `undefined` —
the type check catches it, but on a path that went through `any` it survives all the way to runtime.

## 7. Do not leak existence

**Answer `FORBIDDEN` when someone touched another person's document and that response is itself a confirmation that "the document exists".**
This axis has no policy engine — `firestore.rules` is a blanket deny and the server attaches with a service account and
bypasses the rules, so there is no layer behind this one to stop what leaks here.

| request | the actual situation | response |
| --- | --- | --- |
| `GET /api/tasks/{id}` | there is no such document | **404** |
| `GET /api/tasks/{id}` | it exists but `ownerId` differs | **404** — **exactly the same envelope** as above |
| `PATCH` · `DELETE` | it exists but `ownerId` differs | **404** (`AppError('NOT_FOUND', …)`) |
| any of them | the token is missing or not valid | **401** |
| authenticated and the role falls short | an admin-only path, and such | **403** — a **role** decision, not ownership |

The reason `FORBIDDEN` is in the code table is not the third row but **the last row** — a role has nothing to do with whether
a resource exists, so that 403 leaks nothing. **The message has to be the same too**: line the statuses up and then
tell them again in the wording of the body and you have folded nothing.

## 8. Prove the block (`test/errors.test.ts`)

**A test that carries only the negative assertion is not a guard** — swap the whole of `toAppError` for a `NOT_FOUND` return
and "5 becomes NOT_FOUND" stays green. Inside the same `it`, attach as its pair **whether what must not fold stays unfolded**.

<!-- file: test/errors.test.ts -->
```ts
// test/errors.test.ts
import { describe, expect, it } from 'vitest';
import { statusFor, toAppError } from '../src/http/errors.js';
import { isNotFound } from '../src/firestore/errors.js';

// A fixture imitating the observed shape exactly: code is a number, details is the backend string,
// and message is "<code> <name>: <details>". The basis for this shape is the instrumentation in section 2.
const grpcErr = (code: number, name: string, details: string) =>
  Object.assign(new Error(`${code} ${name}: ${details}`), { code, details });

describe('toAppError', () => {
  it('only gRPC 5 folds into NOT_FOUND — a string code does not fold', () => {
    expect(toAppError(grpcErr(5, 'NOT_FOUND', 'no entity to update')).code).toBe('NOT_FOUND');
    // ✅ without the positive pair, an implementation of "everything is NOT_FOUND" passes too
    const sys = Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' });
    expect(isNotFound(sys)).toBe(false);
    expect(toAppError(sys).code).toBe('INTERNAL');
    // loosen the comparison to == and this line goes red
    expect(isNotFound({ code: '5' })).toBe(false);
  });

  it('only 9 stays a 5xx while 10·3 fold into 4xx', () => {
    expect(statusFor(toAppError(grpcErr(9, 'FAILED_PRECONDITION', 'index')).code)).toBe(500);
    // ✅ two controls: 10 the caller fixes by retrying, 3 by shrinking the body
    expect(statusFor(toAppError(grpcErr(10, 'ABORTED', 'contention')).code)).toBe(409);
    expect(statusFor(toAppError(grpcErr(3, 'INVALID_ARGUMENT', 'longer than 1048487 bytes')).code)).toBe(422);
  });

  it('the original string does not leak into the response message', () => {
    const appErr = toAppError(grpcErr(13, 'INTERNAL', 'app: "s~acme-prod-42" path <tasks/x>'));
    // ✅ the positive pair: if the message were empty, the not.toContain below would mean nothing
    expect(appErr.message.length).toBeGreaterThan(0);
    expect(appErr.message).not.toContain('acme-prod-42');
    expect(statusFor('NO_SUCH_CODE')).toBe(500);
  });
});
```

<!-- verified: planted 5 kinds of mutation and ran vitest — 4 of them went red (the one that survived is section 2) -->
Confirmed by running it, planting the mutations gave **block confirmed** — returning `NOT_FOUND` for everything (2 failures) · folding 9 into a 4xx (1) ·
`INTERNAL` passing the original message along (1) · loosening `===` to `==` (1) all went red.
<!-- verified: with firestore 9.0.0 against a local gRPC server, made runTransaction's Commit receive ABORTED and instrumented the call count the server counted and the elapsed time -->
For gRPC 10 to reach this far meant the SDK had **retried Commit 5 times and spent 12.3 seconds** — it is an exception whose
retries are already exhausted, so the application does not wrap it and retry again.

## Misuse list ① — old idioms → current shape comparison table

| old habit | the current shape (this axis) |
| --- | --- |
| deciding with `err instanceof GoogleError` | it does not work — confirmed by running it, what came back was an ordinary `Error`. Narrow with `typeof err.code === 'number'` |
| `err.message.includes('NOT_FOUND')` | `isNotFound(err)` — the message is not a contract |
| `err.code === 'not-found'` (the firebase-admin string code) | it is the number `5`. This axis attaches with `@google-cloud/firestore` |
| zod 3's `err.errors` | `err.issues` — `.errors` is gone in zod 4 <!-- verified: on zod 4.4.3, 'errors' in err === false --> |
| `c.json({...}, 404)` in every router | throw a single `AppError`. `statusFor` decides the status |
| `catch (e) { return c.json({ error: e.message }) }` | `toAppError(e)` — the original string is not ours |

## Misuse list ② — confusion pairs

| what gets picked wrong often | the exact condition for applying it |
| --- | --- |
| gRPC code vs HTTP status | both are integers, so they get mixed up. `5` is NOT_FOUND, not `500` |
| gRPC **9** vs gRPC **10** | 9 fails forever until it is fixed (500) · 10 is fixed by sending it again (409) |
| `FORBIDDEN` vs `NOT_FOUND` | an ownership failure is a 404. 403 is used for a **role** decision only |
| `ERROR_STATUS[code]` vs `statusFor(code)` | do not open the table directly. The subscript is forbidden even with `?? 500` attached |
| `src/firestore/errors.ts` vs `src/http/errors.ts` | the first knows nothing about HTTP. What the repository calls is the first alone |
| `VALIDATION_FAILED` (422) vs a parse failure (400) | if the body is not JSON it never even reaches the schema — a different event |
