<!-- orangekit-pack: backend/node-nest v3.16.0 -->
# Error handling — status codes come from one table only

This file owns **the rule that moves a domain failure onto an HTTP status**. The exception filter that actually
emits the envelope and the `AppError` class are **the seam's share** (`src/common/all-exceptions.filter.ts`
· `src/common/app-error.ts`) — because the envelope shape is a function of the combination.

## 1. The three roads a failure arrives on

| source | shape | what happens here |
| --- | --- | --- |
| Our code | `AppError('NOT_FOUND')` | Look the status up in `ERROR_STATUS` |
| The validation pipe | `BadRequestException({ code, details })` | Already an HTTP exception — it goes out as-is |
| Driver or library | `QueryFailedError` and the like | `toAppError` normalizes it |

The point is to **merge the three roads in one place**. With several merge points the same failure goes out
under different codes depending on where it happened, and the client discovers that difference first.

## 2. The mapping table and the detectors (`src/common/error-status.ts`)

<!-- file: src/common/error-status.ts -->
```ts
import { ValidationError } from 'class-validator';
import { QueryFailedError } from 'typeorm';
import { AppError } from './app-error';

export const ERROR_STATUS: Record<string, number> = {
  VALIDATION_FAILED: 400,
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  INTERNAL: 500,
};

type PgError = { code?: string; constraint?: string };

export function isUniqueViolation(e: unknown): boolean {
  return e instanceof QueryFailedError && (e.driverError as PgError)?.code === '23505';
}

export function isForeignKeyViolation(e: unknown): boolean {
  return e instanceof QueryFailedError && (e.driverError as PgError)?.code === '23503';
}

export function fieldErrors(errors: ValidationError[]): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  const walk = (list: ValidationError[], prefix: string) => {
    for (const e of list) {
      const path = prefix ? `${prefix}.${e.property}` : e.property;
      const msgs = Object.values(e.constraints ?? {});
      if (msgs.length > 0) out[path] = msgs;
      if (e.children?.length) walk(e.children, path);
    }
  };
  walk(errors, '');
  return out;
}

export function toAppError(e: unknown): AppError {
  if (e instanceof AppError) return e;
  if (isUniqueViolation(e)) return new AppError('CONFLICT', 'Value already exists');
  return new AppError('INTERNAL', 'Internal error');
}
```

## 3. Detect by driver code — not by the message string

<!-- verified: PostgreSQL 18.4 + typeorm@1.1.0, run — violating the (ownerId, title) UNIQUE gave QueryFailedError.driverError.code === '23505' with .constraint === 'UQ_tasks_owner_title' -->

```ts
// src/common/error-status.ts
// ❌ Look for the message as a string — a driver version or locale change silently stops matching
if ((e as Error).message.includes('duplicate key')) return new AppError('CONFLICT');
// ✅ Detect by the SQLSTATE code
if (isUniqueViolation(e)) return new AppError('CONFLICT', 'Value already exists');
```

| SQLSTATE | meaning | how this pack handles it |
| --- | --- | --- |
| `23505` | Unique constraint violation | `CONFLICT` (409) |
| `23503` | Foreign key violation | The calling context decides — 404 when the referenced row is absent, 409 when children remain |
| `23514` | CHECK violation | On a normal path the DTO should have caught it first. Leave it a 500 and read the logs |

`driverError` is a field of `QueryFailedError` holding the driver's (pg's) original error.
Looking as far as the `constraint` name lets you branch on "which constraint", but **the constraint name is a value
the migration decides**, so use that branch knowing it moves together with the migration.

## 4. `AppError` knows nothing about HTTP

Keeping the status code out of `AppError` is the point of this design — once the service layer starts knowing
about HTTP, the same failure cannot be reused from a CLI, a queue consumer or a batch job. `ERROR_STATUS`
attaches the status once, at the boundary.

**`AppError` is not an `HttpException`.** So without the seam's exception filter,
<!-- verified: @nestjs/core@11.2.1, run — on an app with no filter attached, AppError('NOT_FOUND') went out as a 500 {"statusCode":500,"message":"Internal server error"} -->
Nest's default filter sends **everything out as a 500**. When status codes look wrong with only the pack
assembled, this is the first place to look.

A controller throwing `NotFoundException` directly also works, but then domain code is tied to
Nest and the envelope splits into two roads (via `AppError` and direct). This pack standardizes on
`AppError`.

## 5. Do not distinguish absent from unauthorized

<!-- verified: PostgreSQL 18.4, run — read, update and delete against a row owned by someone else were all 404 {"error":{"code":"NOT_FOUND"}} -->

```ts
// src/tasks/tasks.service.ts
// ❌ It reveals existence — sweeping ids enumerates another user's resources
if (!task) throw new AppError('NOT_FOUND');
if (task.ownerId !== ownerId) throw new AppError('FORBIDDEN');
// ✅ Putting ownership in the fetch condition makes both cases the same result
const task = await this.tasks.findOne({ where: { id, ownerId }, select: TASK_VIEW });
if (!task) throw new AppError('NOT_FOUND', 'Task not found');
```

`FORBIDDEN` (403) is used only for refusing an action on a resource whose existence **is already known** —
an insufficient role is that case. It is never used for an ownership verdict.

## 6. The internal cause goes to the logs, not the response

`toAppError` folding an unknown exception into `INTERNAL` exists to cut off information. A stack, SQL or
constraint name riding in the response leaks the schema and the internal structure verbatim. The cause is left by
`SlowQueryLogger.logQueryError` and the exception filter's logs (`operations.md` §5).

## Misuse list ① — Express error idiom → NestJS form

| old habit (Express) | current form (NestJS 11) |
| --- | --- |
| Passing it on with `next(err)` | Just `throw`. The pipeline sends it to the filter |
| Four-argument middleware `(err, req, res, next)` | `@Catch()` + `implements ExceptionFilter` |
| Deciding the status with try/catch per router | The service throws only `AppError` and the status is set once at the boundary |
| `res.status(409).json(...)` | Throw and let the filter build the envelope. A controller building the envelope splits it |
| Relying on `process.on('unhandledRejection')` | Nest sends an async handler's rejection to the filter |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `AppError` vs `HttpException` | A domain failure takes the first; something whose HTTP meaning is already settled (the pipe's 400) takes the second |
| `@Catch()` vs `@Catch(HttpException)` | The argument-less one receives **every** exception. Narrow it and `AppError` leaks to the default filter and becomes a 500 |
| 404 vs 403 | Ownership is 404, insufficient role is 403 (§5) |
| 409 vs 422 | A unique constraint collision is 409. 422 has no reach path on this axis |
| `instanceof QueryFailedError` vs inspecting the message | Use only the first. The message changes with the driver version |
| Re-throwing from an exception filter | Either two responses go out or none does. A filter always finishes the response |
