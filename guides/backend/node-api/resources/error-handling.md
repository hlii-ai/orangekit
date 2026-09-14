<!-- orangekit-pack: backend/node-api v3.13.0 -->
# Error handling — from a domain code to an HTTP status

This file owns exactly one code file, `src/http/errors.ts`: the status code table · Prisma error
detection · `ZodError` normalization · normalizing an unknown throw. The `AppError` class and the
`errorHandler` that emits the envelope are **owned by the seam** (`src/http/app-error.ts` · `src/http/routers/`) —
because the envelope shape is a function of the combination, not of the axis. Middleware order is decided by `project-structure.md`.

## 1. On hitting a failure, which layer does what

| layer | example failure | what that layer does | final status |
| --- | --- | --- | --- |
| schema (`parseBody`) | a bad body | throws `AppError('VALIDATION_FAILED', …)` | 400 |
| query function (`db/tasks.ts`) | 0 rows changed | throws `AppError('NOT_FOUND')` | 404 |
| query function | uniqueness conflict | **does nothing** — Prisma throws `P2002` | 409 |
| service | domain rule violation | `AppError` with a code from the table | see the table |
| error middleware (seam) | all of the above + the unexpected | `toAppError` → `ERROR_STATUS` → envelope | — |

There are three principles. **① A failure is an exception, not a return value** — Express 5 forwards both a synchronous throw and a
rejected promise to the error middleware, so there is no reason to carry a `Result` type by hand.
**② Exactly one layer knows the status code** — neither the query function nor the service knows the number; they throw only a code.
**③ Do not catch and rethrow** — `catch (e) { throw e }` only muddies the stack.

There are only two places for a `try/catch`: when **translating** a library failure into a domain code, and
when a resource has to be closed. Everywhere else, just let it rise.

## 2. The code table and normalization (`src/http/errors.ts`)

<!-- file: src/http/errors.ts -->
```ts
import { Prisma } from '@prisma/client';
import { z } from 'zod';
import { AppError } from './app-error';

export const ERROR_STATUS: Record<string, number> = {
  VALIDATION_FAILED: 400,
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  PAYLOAD_TOO_LARGE: 413,
  INTERNAL: 500,
};

// errors thrown by express.json(). They are not AppError, so without normalization they all become 500
function bodyParserType(e: unknown): string | undefined {
  const c = e as { type?: unknown; status?: unknown };
  return e instanceof Error && typeof c.type === 'string' && typeof c.status === 'number'
    ? c.type
    : undefined;
}

export function isUniqueViolation(e: unknown): e is Prisma.PrismaClientKnownRequestError {
  return e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002';
}

export function isRecordNotFound(e: unknown): e is Prisma.PrismaClientKnownRequestError {
  return e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2025';
}

export function fieldErrors(e: z.ZodError): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const issue of e.issues) {
    const key = issue.path.length === 0 ? '_' : issue.path.join('.');
    (out[key] ??= []).push(issue.message);
  }
  return out;
}

export function toAppError(e: unknown): AppError {
  if (e instanceof AppError) return e;
  if (e instanceof z.ZodError) {
    return new AppError('VALIDATION_FAILED', 'The request is not valid', fieldErrors(e));
  }
  switch (bodyParserType(e)) {
    case 'entity.parse.failed':
      return new AppError('VALIDATION_FAILED', 'The request body is not valid JSON');
    case 'entity.too.large':
      return new AppError('PAYLOAD_TOO_LARGE', 'The request body is too large');
  }
  if (isUniqueViolation(e)) return new AppError('CONFLICT', 'That value already exists');
  if (isRecordNotFound(e)) return new AppError('NOT_FOUND', 'The target could not be found');
  return new AppError('INTERNAL', 'A server error occurred');
}
```

The last line is this file's security surface. **It discards the original message and replaces it with a fixed string** —
put a message like `TypeError: prisma.task.findMany is not a function` into a response and the internal structure and
dependencies go straight out. A handler that threw `TypeError('x is not a function')` returned a 500 of
`{"error":{"code":"INTERNAL","message":"A server error occurred"}}`. <!-- verified: express 5.2.1 integration run — a throw from an unwrapped async handler passed through errorHandler as a 500 -->
The original text is not discarded but **goes to the log** (§7).

Without the `bodyParserType` branch, **every failure that happens before reaching a handler becomes a 500.**
`express.json()` runs ahead of the routers and throws its own errors, and those are neither `AppError`
nor `ZodError`. One line of malformed JSON then raises a 5xx alert, and a client's mistake
is counted as a server outage. The two errors are told apart by the `type` string — the reason for not deciding by class is that
`PayloadTooLargeError` is not exported from `express`.

| input | what is thrown | before the branch | after the branch |
| --- | --- | --- | --- |
| `{bad` | `SyntaxError` · `type:'entity.parse.failed'` · `status:400` | 500 `INTERNAL` | **400 `VALIDATION_FAILED`** |
| a 1.2MB body | `PayloadTooLargeError` · `type:'entity.too.large'` · `status:413` | 500 `INTERNAL` | **413 `PAYLOAD_TOO_LARGE`** |
<!-- verified: ran express 5.2.1 — sent both inputs to express.json({limit:'100kb'}) and observed all of the shapes and statuses above -->

Translating into a domain code rather than using `err.status` directly as the response status is a discipline.
**Exactly one layer, `ERROR_STATUS`, may know the status**, and once you start letting numbers chosen by a library
through, that discipline splits per library.

Keeping `ERROR_STATUS` as `Record<string, number>` and looking it up with `?? 500` is deliberate.
The seam has to be able to add combination-specific codes (`PAYMENT_REQUIRED` and such), and a code absent from the table
must **fall safely to 500** rather than being a type error.

## 3. Prisma error detection — `P2002` · `P2025`

`PrismaClientKnownRequestError` carries a `code` string. The correspondences below were built by comparing the
code-to-cause mapping directly against the installed build (`@prisma/client` 6.19.3).

| code | Prisma internal name | meaning | how this pack handles it |
| --- | --- | --- | --- |
| `P2002` | `UniqueConstraintViolation` | unique constraint violation | 409 `CONFLICT` |
| `P2025` | the `MISSING_RECORD` family | the target row does not exist | 404 `NOT_FOUND` |
| `P2003` | `ForeignKeyConstraintViolation` | referential integrity violation | 409 or 400 — the combination decides |
| `P2000` | `LengthMismatch` | the value exceeds the column length | 400 — Zod's `.max()` should have caught it first |
| `P2034` | `TransactionWriteConflict` | transaction write conflict | retry material — do not drop it to a 500 |
| `P2037` | `TooManyConnections` | connection exhaustion | 503 — pool sizing is in `operations.md` |

`e.meta` carries the cause — for `P2002` it is shaped like `{ target: ['ownerId', 'title'] }`, for `P2025` like
`{ modelName: 'Task', cause: 'No record was found for an update.' }`.
<!-- verified: measured by audit A (@prisma/client 6.19.3 + real PostgreSQL). The cause string in meta is produced by the query engine, not the client bundle — it cannot be confirmed by grepping the installed build and its wording changes with the engine version -->
**The `cause` wording is not a contract.** The query engine produces it and it changes per version, so **do not parse the string
to branch** — always branch on `code`.

**Do not put `meta` into the response as-is**: the column names in `target` are schema information, and which combination
conflicted is itself proof that another user's data exists. `modelName` exposes the internal model name
directly. If you need field-level guidance, **translate** `target` into field names the client knows
before putting it in.

`P2000` is in the table because it is **a code that should never be reached**. A length overflow reaching the DB
means the `.max(200)` from `input-validation.md` was not on that path.

## 4. `ZodError` normalization — `fieldErrors`

There is a reason to walk it manually when `z.flattenError` exists. **`flattenError` sees only one level** —
it puts an issue whose path is `['nested','n']` under the key `nested` and loses the `.n`. <!-- verified: ran zod 4.4.3 — compared flattenError/treeifyError/manual iteration against a ZodError carrying nested and array paths --> The client then cannot attach
errors of a nested object or an array item to a field. `issue.path.join('.')` produces reachable keys such as
`tags.0` · `nested.n`.

Do not use `e.message` in the response. The `ZodError.message` of Zod 4 is **a JSON string serializing the whole
issue array** <!-- verified: ran zod 4.4.3 — printed ZodError.message and confirmed it is the issue array as JSON -->, so putting it through makes the response several KB and exposes the internal schema
structure. Where a human-readable form is needed (boot logs and such), use `z.prettifyError(e)`.

Below is a real response from `POST /api/tasks` with `{ "title": "", "dueAt": "nope" }` —
only the output of `fieldErrors` is shown, not the whole envelope:

```json
{"error":{"code":"VALIDATION_FAILED","details":{
  "title":["Title cannot be empty"],"dueAt":["Invalid ISO datetime"]}}}
```

Issues with an empty `path` (a `.refine()` on the whole schema, an unknown key under `strictObject`) collect under the
key `_`. The client renders this key as a whole-form error.

## 5. Do not leak existence — 404 and 403

**This axis has no data-layer policy engine.** Row-level security does not back you up, so the application's
decision is the only boundary, and **the moment that decision is spoken as a status code it becomes
information.**

```ts
// ❌ give a 403 on someone else's task and sweeping ids alone reveals which ids really exist
const task = await prisma.task.findUnique({ where: { id } });
if (!task) throw new AppError('NOT_FOUND', 'Task not found');
if (task.ownerId !== user.id) throw new AppError('FORBIDDEN', 'You do not have permission');
```

```ts
// ✅ put ownership in the read condition, and if it is not there it does not exist — two failures merge into one response
const task = await getTask(user.id, id);   // the owner comes first — both arguments are string, so tsc will not catch it
if (!task) throw new AppError('NOT_FOUND', 'Task not found');
```

`FORBIDDEN` remains in the table because it has its own place. Use it only for **a permission failure after existence is
already known** — your own task that cannot be edited because it is archived, or an admin list you cannot reach
because your role is insufficient. The test is one question: **does the person who got the 403 learn anything new
from that fact alone.** If so, it is a 404.

Authentication failure is the same. The message for `UNAUTHENTICATED` is not "wrong password" but
"authentication failed" — distinguish the reason and whether an account exists becomes readable from the response.

## 6. Emit from one place

The code that builds the envelope has to be singular in the repository. If a router does `res.status(400).json(...)`
itself, the same failure goes out in a different shape depending on where it happened, and the client grows branches.

The contract `errorHandler` (seam-owned) has to keep has **five** parts.

- **It must have exactly 4 arguments.** Express identifies error middleware by arity — a 3-argument
  function **is not called in the error flow and is silently skipped.** Delete an unused `next` too.
  <!-- verified: ran express 5.2.1 — the 3-arity middleware skipped the error flow and only handled the 404 -->
- **`app.use(errorHandler)` goes last.** After the 404 middleware (`notFound`).
- **Look at `res.headersSent` first.** A failure after the response has gone out cannot be overwritten, so hand it
  to Express's default handler with `next(err)` and let the connection close.
  <!-- verified: ran express 5.2.1 — a throw after the response kept the 200 and the stack went to stderr -->
- **Normalize with `toAppError(err)` first.** Most of what arrives at this middleware is **not** an
  `AppError` — `ZodError` · Prisma errors · the parser errors of `express.json()` · an unexpected `TypeError`
  all land here. Skip the normalization and read `err.code` directly and all of it becomes a 500.
- **Read the status only from `ERROR_STATUS`**: `ERROR_STATUS[e.code] ?? 500`. Read it from the normalized `e` —
  use the original `err.status` and the discipline above collapses.

```ts
// src/http/routers/tasks.ts — seam-owned. The router builds only the success envelope
router.get('/:id', requireAuth, async (req, res) => {
  const task = await getTask(req.user.id, req.params.id);
  if (!task) throw new AppError('NOT_FOUND', 'Task not found');
  res.json({ data: task });
});
```

There is no `try/catch` and no `next(err)`. Express 5 forwards a rejected promise automatically,
<!-- verified: express 5.2.1 + @prisma/client 6.19.3 integration run — P2002/P2025/TypeError thrown from an unwrapped async handler came out as 409/404/500 respectively -->
so no `asyncHandler`-style wrapper is needed — a `P2002` thrown by an `async` handler came out as a
409 with no wrapper.

## 7. Separate the log from the response

Narrow the response and widen the log. Their purposes are opposite — the response carries **only what the caller needs to
correct its behavior**, the log **everything the operator needs to reproduce it**.

| item | response | log |
| --- | --- | --- |
| domain code (`CONFLICT`) | included | included |
| field errors (`details`) | included | included |
| original exception message and stack | **discarded** | included |
| Prisma `meta` | discarded | included |
| request correlation ID | included | included |
| tokens, secrets, `DATABASE_URL` | discarded | **discarded** |

Log 5xx with `logger.error` and 4xx at `logger.warn` or below. Log a 400 as an error and one misbehaving
client buries the alerts; fail to log a 500 and you learn about it only from user reports.
`logger` is owned by `operations.md` — nowhere in the repository uses `console`.
Request correlation is attached by `pino-http`, so using `req.log` in the error middleware keeps the thread.

## Misuse list ① — Express 4 → Express 5 idioms

Compared by running against the installed build (express 5.2.1). Most of the old shapes still work, so
they pass compilation and tests alike and quietly remain.

| old habit (Express 4) | current shape (Express 5) |
| --- | --- |
| catching rejections with the `asyncHandler(fn)` wrapper | not needed — a rejected promise is forwarded automatically <!-- verified: confirmed by running express 5.2.1 --> |
| attaching `.catch(next)` to every async handler | just throw |
| overwriting with `req.query = validated` | there is no setter, so it does not take effect — ESM gives a `TypeError`, CJS **silently ignores it**. Take the return value into a local variable <!-- verified: ran express 5.2.1 — observed on both CJS and ESM --> |
| assuming `?a[b]=1` parses as `{a:{b:'1'}}` | the default parser does not build nesting — the key is `"a[b]"` <!-- verified: confirmed by running express 5.2.1 --> |
| calling `next(err)` to raise the error | throw it. Use `next(err)` only for the `headersSent` handoff |
| declaring error middleware with 3-arity | anything but 4-arity is not called in the error flow |
| `res.status(500).send(err.message)` | throw only the code and let `errorHandler` build the envelope |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `404 NOT_FOUND` vs `403 FORBIDDEN` | 404 when existence itself is secret. 403 only for a permission failure after existence is already known |
| `401 UNAUTHENTICATED` vs `403 FORBIDDEN` | 401 is "I do not know who you are", 403 is "I know who you are, and no" |
| `P2002` vs `P2025` | conflict (409) and absence (404). `update` can throw both codes |
| `P2025` vs `count === 0` | Prisma throws `P2025` only for `update`/`delete`. `updateMany`/`deleteMany` are quiet at 0 rows, so **you have to look at the affected row count yourself** (`data-access.md`) |
| `e.code` vs `e.name` | branch on `code` (`P2002`). `name` is `PrismaClientKnownRequestError` for all of them |
| `z.flattenError` vs manual iteration | iterate manually when there are nested or array fields. `flattenError` loses the path after one level |
| `err.message` vs `z.prettifyError(err)` | `ZodError.message` is the issue array as JSON. Use `prettifyError` where a human reads it |
| `toAppError` vs checking `instanceof AppError` directly | normalize in one place, the middleware, with `toAppError`. Count the branches in the router and you miss one every time a new exception type appears |
