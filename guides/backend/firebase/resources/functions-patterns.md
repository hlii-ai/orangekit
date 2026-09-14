<!-- orangekit-pack: backend/firebase v3.14.0 -->
# Function patterns — 2nd gen `onCall` · `onRequest` and the auth context

This file owns `functions/src/obs/logger.ts` and `functions/src/index.ts`. Firestore
access (`db` · `listTasks` · `runTransaction`) is `functions/src/firestore/` —
owned by `resources/data-access.md`. The Zod schemas and `parseCallable` are
`functions/src/schemas/task.ts`, and the `defineString`/`defineSecret` parameters are
`functions/src/params.ts`, both of them the share of `resources/input-validation.md`.
`AppError` · `toHttpsError` · `AuthUser` · `authFor` are owned by the seam in
`functions/src/http/` — the pack only calls them.

**`onCall` verifies the token but does not block a call that carries none.** The handler runs
as usual and only `request.auth` is empty. What confirms the principal is `requireUid`.

## 1. Decision tree — `onCall` or `onRequest`

| envelope | `onCall` | `onRequest` |
| --- | --- | --- |
| Request body | Must be wrapped as `{ "data": ... }` (otherwise 400 `INVALID_ARGUMENT`) | Raw as-is |
| Success response | `{ "result": ... }` | Whatever the handler writes |
| Auth | The SDK verifies `Authorization: Bearer <ID token>` and puts it on `request.auth` | Nothing at all — the header arrives raw |
| Unhandled exception | 500 `{"error":{"message":"INTERNAL","status":"INTERNAL"}}` — the message is folded | 500 `Internal Server Error` (plain text) |
| Method | POST only (GET is 400) | All |
| CORS | **Every origin allowed** by default | As the `cors` option says |

<!-- verified: actually called against the functions emulator — the status codes and bodies in the table above are verbatim curl/fetch responses. A marker string placed in the unhandled exception's message was confirmed absent from the response, and as a control an HttpsError message on the same path arrived intact -->
**Use `onCall` when the frontend uses the Firebase client SDK**, and `onRequest` when the caller is something
whose envelope you cannot dictate, such as a webhook or third-party callback. That choice and the wire envelope are the
combination's share, so the seam's `api-endpoints` slot settles them.

## 2. Auth context — when it is absent it is `undefined`, not `null`

| call | `request.auth` | result |
| --- | --- | --- |
| No token | `undefined` | The handler **runs as usual**, 200 |
| A valid ID token | `{ uid, token }` | Custom claims are laid flat onto `token` (`role` · `roles`) |
| An unverifiable token (production) | The handler does not run at all | 401 `{"error":{"message":"Unauthenticated","status":"UNAUTHENTICATED"}}` |
| A token that is **not** JWT-shaped (emulator) | The handler does not run | 401 — positive control |
| **A forged JWT-shaped token** (emulator) | `uid` is **whatever the payload says** · claims verbatim too | **200** |

<!-- verified: rows 1-3 and 5 were measured by sending the same forged token bytes to two places — wiring a firebase-functions 7.3.2 handler directly into an express outside the emulator gave 401 `Auth token was rejected` (verifications.auth=INVALID), while the same bytes sent to the functions emulator gave 200. Row 4 is the positive control (the emulator too gives 401 when it is not JWT-shaped). Compared against a real token made through the Auth emulator for a real user with custom claims attached -->
`requireUid` looks at **`req.auth?.uid`** rather than `req.auth` because of row 3.
**But `req.auth?.uid` does not block row 5** — a forged token has a perfectly good `uid` in it.
Signature verification is the runtime's job and **the emulator does not do it.**

**So green in the emulator does not mean authentication works.** Measured: calling `tasksCreate` with a forged
token whose signature was garbage returned 200 and **actually stored** a document with
`ownerId: "hacker"` in Firestore — the attacker chose the `uid`. Sending the same bytes down the production
code path gives 401, so this is an **emulator-only divergence**, but the consequence is that
**tests running on the emulator cannot prove the ownership boundary.** What those tests prove reaches only
"given a `uid`, is the query narrowed correctly", and "is that `uid` genuine" is outside
their proof. The extracted `uid` goes straight down to the query boundary — the admin SDK bypasses the
rules, so this one line is the only boundary on document access.

```ts
// functions/src/firestore/tasks.ts — where the boundary closes
let query: Query<TaskDoc> = col().where('ownerId', '==', ownerId);
```

## 3. The wrapper and the error envelope (`functions/src/obs/logger.ts`)

`onCall` folds an unhandled exception into `INTERNAL`. That is safe, but **the cause disappears with it**, so
there has to be a place that logs before the folding.

<!-- file: functions/src/obs/logger.ts -->
```ts
// functions/src/obs/logger.ts
import * as fnLogger from 'firebase-functions/logger';
import type { CallableRequest } from 'firebase-functions/v2/https';
import { AppError } from '../http/app-error.js';
import { toHttpsError } from '../http/https.js';

export const logger = fnLogger;

export function requireUid(req: CallableRequest): string {
  const uid = req.auth?.uid;
  if (!uid) throw new AppError('UNAUTHENTICATED', 'sign-in required');
  return uid;
}

export function withErrors<T>(
  h: (req: CallableRequest) => Promise<T>,
): (req: CallableRequest) => Promise<T> {
  return async (req) => {
    try {
      return await h(req);
    } catch (e) {
      if (e instanceof AppError) throw toHttpsError(e);
      logger.error('unhandled handler failure', {
        uid: req.auth?.uid ?? null,
        err: e instanceof Error ? e.message : String(e),
      });
      throw toHttpsError(new AppError('INTERNAL', 'internal error'));
    }
  };
}
```

Not using `console.log` is not a matter of taste. `logger`'s second argument rides as structured
fields and can be queried in Cloud Logging, whereas `console.log` is mashed into a single-line string
and cannot be filtered by `uid`.

An `HttpsError` code decides both the HTTP status and the client's `error.code`.

| `HttpsError` code | HTTP | `error.code` the client sees |
| --- | --- | --- |
| `invalid-argument` · `failed-precondition` · `out-of-range` | 400 | `functions/invalid-argument` … |
| `unauthenticated` | 401 | `functions/unauthenticated` |
| `permission-denied` | 403 | `functions/permission-denied` |
| `not-found` | 404 | `functions/not-found` |
| `already-exists` · `aborted` | 409 | `functions/already-exists` … |
| `resource-exhausted` | 429 | `functions/resource-exhausted` |
| `internal` · `unknown` · `data-loss` | 500 | `functions/internal` … |

<!-- verified: the status codes were read verbatim from errorCodeMap in the installed firebase-functions/lib/common/providers/https.js, and the code prefix and details delivery were confirmed by calling the emulator with the firebase@12 client SDK — permission-denied arrived as code 'functions/permission-denied' with details {"field":["ownerId"]}, and an unhandled exception arrived as 'functions/internal' with details undefined -->
`details` reaches the client **only when thrown as an `HttpsError`**. A value leaking out as an unhandled exception
disappears in the folding, so anything the client needs to see must ride on an `AppError` and go through
`toHttpsError`.

## 4. The export surface (`functions/src/index.ts`)

The deploy analysis reads this file. **Put no logic here** — export only the wrapped handlers. And
**always import `params.ts` here** — the analysis sweeps only the modules reachable from this file,
so without the import the declared parameters never reach the manifest.

<!-- file: functions/src/index.ts -->
```ts
// functions/src/index.ts
import { setGlobalOptions } from 'firebase-functions/v2';
import { onCall } from 'firebase-functions/v2/https';
import { REGION, WEBHOOK_KEY, config } from './params.js';
import { requireUid, withErrors } from './obs/logger.js';
import { parseCallable, TaskCreateSchema, TaskQuerySchema, TaskUpdateSchema } from './schemas/task.js';
import { createTask, deleteTask, getTask, listTasks, updateTask } from './firestore/tasks.js';
import { AppError } from './http/app-error.js';
import { z } from 'zod';

// REGION is an Expression — pass it through without calling .value().
setGlobalOptions({ region: REGION, maxInstances: 20, concurrency: 80 });

const IdSchema = z.strictObject({ taskId: z.string().min(1) });
const UpdateArgs = z.strictObject({ taskId: z.string().min(1), patch: TaskUpdateSchema });

export const tasksList = onCall(withErrors(async (req) => {
  const uid = requireUid(req);
  const q = parseCallable(TaskQuerySchema, req.data);
  const { TASKS_PAGE_MAX: pageMax } = config(); // Inside the handler — a top-level call breaks the deploy analysis
  return await listTasks(uid, { ...q, limit: Math.min(q.limit, pageMax) });
}));

export const tasksGet = onCall(withErrors(async (req) => {
  const uid = requireUid(req);
  const { taskId } = parseCallable(IdSchema, req.data);
  const task = await getTask(uid, taskId);
  if (!task) throw new AppError('NOT_FOUND', 'task not found');
  return task;
}));

export const tasksCreate = onCall({ secrets: [WEBHOOK_KEY] }, withErrors(async (req) => {
  const uid = requireUid(req);
  return await createTask(uid, parseCallable(TaskCreateSchema, req.data));
}));

export const tasksUpdate = onCall(withErrors(async (req) => {
  const uid = requireUid(req);
  const { taskId, patch } = parseCallable(UpdateArgs, req.data);
  return await updateTask(uid, taskId, patch);
}));

export const tasksDelete = onCall(withErrors(async (req) => {
  const uid = requireUid(req);
  const { taskId } = parseCallable(IdSchema, req.data);
  await deleteTask(uid, taskId);
  return { deleted: true };
}));
```

The order is the boundary. **`requireUid` → `parseCallable` → repository.** `ownerId` always comes
from the auth context and never from the request body — take it from the body and a client can write
someone else's `ownerId` into it.

Whether the parameter wiring actually reaches the manifest is confirmed **by running it, not by declaring it**.

| `index.ts` importing `params.ts` | manifest `params` | `tasksCreate.secretEnvironmentVariables` | `tasksList.region` |
| --- | --- | --- | --- |
| Not imported (region hard-coded) | **0** | `null` | `["asia-northeast3"]` |
| Imported as in the code above | **3** — `TASKS_REGION` · `TASKS_PAGE_MAX` · `TASKS_WEBHOOK_KEY` | `[{"key":"TASKS_WEBHOOK_KEY"}]` | `"{{ params.TASKS_REGION }}"` |

<!-- verified: both builds were loadStack'd with runtime/loader.js of firebase-functions 7.3.2 and their manifests extracted with stackToWire and compared. The first row is the negative control -->
Attach `secrets: [WEBHOOK_KEY]` **only to the functions that read that secret** — without it the parameter is declared but
never injected into that function's runtime. `.value()` is always inside the handler.

**The five here are an example of the arrangement, not a settled roster.** Which functions to expose and the
request/response envelope are decided by the seam's `api-endpoints` slot — in a combination where the frontend reads
Firestore directly through the client SDK, `tasksList` and `tasksGet` disappear entirely and the rules take
their place. What this file pins is **only the order inside one function**.

## 5. Global initialization and the cold start

Code **outside** the handler runs once on the cold start and is reused for the life of that instance.
<!-- verified: functions emulator run — a random ID created at module load was identical across 6 consecutive invocations, and while the time elapsed since module load grew from 48ms to 902ms the invocation counter accumulated 1→6 -->
So the Firestore client is built at the module top level of `functions/src/firestore/client.ts`
(`resources/data-access.md`). Build it inside the handler and it is rebuilt on every invocation.

For the same reason, **call `.value()` of `functions/src/params.ts` inside the handler.** Called at module
top level, the deploy analysis phase blows up loading the module with no values. Declare at the top level,
read inside the handler — the declaration shape is owned by `resources/input-validation.md`.

Calling app initialization twice can end in **silence rather than an exception**. With identical options
the first app quietly comes back and the second set of options is discarded. Keeping the initialization point in
`client.ts` alone is the only defense.

## 6. Region · concurrency · minimum instances · retry semantics

| option | value | what it affects |
| --- | --- | --- |
| `region` | Once, through `setGlobalOptions` | The further it is from the Firestore location, the longer the round trip |
| `concurrency` | 80 by default (CPU ≥ 1); 1 when CPU < 1 · maximum 1000 | One instance handles several requests **at the same time** |
| `minInstances` | The platform default when unset <!-- unverified: the installed types and comments mention no default. The emulator creates no instances, so there is no measurement path --> | Removes the cold start at the price of billing while idle |
| `maxInstances` | — | A ceiling that protects what is downstream (Firestore, external APIs) |

<!-- verified: the concurrency default and ceiling were read verbatim from the comments in the installed firebase-functions/lib/v2/options.d.ts -->
**When `concurrency` is greater than 1, module globals are shared between requests.** Put per-request state in a
global and another user's values mix in. Keep **only stateless things**, such as the client, in globals.
<!-- unverified: only the existence, default and ceiling of the options were confirmed from the installed type surface. "Globals really are shared" is production behavior, and the emulator does not implement concurrency, so it could not be measured here -->

**`onCall` and `onRequest` have no `retry` option** <!-- verified: installed type surface — https.d.ts has 0 occurrences of retry, while options.d.ts's EventHandlerOptions does and DocumentOptions extends it -->. `retry` belongs to event
triggers (`onDocumentWritten` and the like), and with it on the same event arrives **several times**, so the handler
has to be idempotent. **That HTTP triggers are not retried automatically** is an interpretation that follows from
the option's absence, not a measured value <!-- unverified: retries are platform behavior, so the emulator offers no measurement path -->.

What is easy to confuse is that **transaction retries are a different layer from function retries**. A transaction
runs several times inside a single run of the function.

```ts
// functions/test/repo.test.ts — contention block (excerpt — the full text is functions/test/repo.test.ts)
await Promise.all(Array.from({ length: 8 }, async () => {
  await db.runTransaction(async (tx) => {
    runs.push('x');                                   // grows with every retry
    const n = (await tx.get(ref)).get('n') as number;
    await new Promise((r) => setTimeout(r, 50));
    tx.update(ref, { n: n + 1, updatedAt: FieldValue.serverTimestamp() });
  });
}));
expect((await ref.get()).get('n')).toBe(8);   // 0 lost updates
expect(runs.length).toBeGreaterThan(8);       // the function ran more than 8 times
```

<!-- verified: emulator run — under 8 concurrent transactions the body executed 25 times (17 retries) and the final value was 8. Changing the transaction to read-then-write in the same test dropped the final value to 1 and went red -->
So **put no side effects in a transaction body.** Logs, mail and billing inside it happen as many times as it
retries. The two assertions above are a pair — measure only "0 lost" and it passes even with the transaction
deleted; measure only the retries and correctness goes unmeasured.

## Misuse list ① — 1st gen `firebase-functions` → 2nd gen

| old habit (1st gen) | current form (2nd gen · `firebase-functions@7`) |
| --- | --- |
| `functions.https.onCall((data, context) => ...)` | `onCall((request) => ...)` — merged into `request.data` and `request.auth` |
| `context.auth.uid` | `request.auth?.uid` — it is `undefined` when absent, so optional chaining is required |
| `functions.region('...').https.onCall(...)` | `setGlobalOptions({ region })` or the options object |
| `functions.config().svc.key` | `defineString`/`defineSecret` (`functions/src/params.ts`) |
| Assuming one request per instance | `concurrency` defaults to 80 — assume globals are shared |
| The single entry `import * as functions from 'firebase-functions'` | Per-path imports such as `firebase-functions/v2/https` |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `if (!request.auth)` vs `if (!request.auth?.uid)` | The first lets a shell context with no uid through. Always look at `uid` |
| `onCall`'s CORS vs `onRequest`'s `cors` | `onCall` is open to every origin — origin is not the boundary, the token is |
| `HttpsError` vs a plain `Error` | The first carries the code, message and `details` all the way to the client; the second is folded entirely into `INTERNAL` |
| The `retry` option vs transaction retries | The first is event-trigger only; the second happens inside HTTP functions too |
| `minInstances` vs `concurrency` | The first changes the cold start, the second the throughput per instance. The one that costs money is the first |
| `.value()` at module top level vs inside the handler | Declare at the top level, read inside the handler. Read at the top level and the deploy analysis blows up |
