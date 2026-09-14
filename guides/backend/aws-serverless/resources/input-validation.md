<!-- orangekit-pack: backend/aws-serverless v3.13.0 -->
# Input validation — cutting the event and the environment off at the boundary

It owns the Zod 4 schemas · parsing the API Gateway HTTP API v2 event · cold-start validation of environment variables.
The table that moves a validation failure to a status code (`ERROR_STATUS`) and `fieldErrors` are owned by `resources/error-handling.md`
(`src/http/errors.ts`), and `AppError` and the response envelope `respond` are owned by **the seam**
(`src/http/app-error.ts` · `src/http/respond.ts`). Key design and queries are in
`resources/data-modeling.md` · `resources/data-access.md`.

## 1. What gets validated where

**The origin of the input decides where it is validated and when it fails.** A value the deployment settles is validated at the
cold start; a value the requester sent is validated on every request.

| input | event/process field | where it is validated | when it fails | result |
| --- | --- | --- | --- | --- |
| environment variables | `process.env` | `EnvSchema` (module top level) | **the cold start** | the function never comes up |
| the body | `event.body` | `parseBody` | the request | `VALIDATION_FAILED` 400 |
| the query | `event.queryStringParameters` | `parseQuery` | the request | `VALIDATION_FAILED` 400 |
| the path | `event.pathParameters` | `pathParam` | the request | `VALIDATION_FAILED` 400 |
| the subject (who it is) | `event.requestContext.authorizer` | `requireAuth` (the seam) | the request | `UNAUTHENTICATED` 401 |

The decision takes three lines.

- **Can the requester choose the value** → put it through a schema. Until it passes, leave the value `unknown`
- **Does the deployment pin the value** → read it in the one place, `src/env.ts`. App code sees only `env`
- **Is it the owner id** → **do not read it from the input.** Use `requireAuth(event).id` and nothing else.
  This axis has no data-layer policy engine, so the application layer is the only real boundary —
  trust an `ownerId` from the body or the query and that spot is the leak

How unknown keys are handled splits here too. **The body refuses them (`z.strictObject`), the query strips them (`z.object`)**.
An unknown key in the body means the client has the contract wrong, so telling it is better; a query string always
has tracking parameters mixed into it, and refusing those kills legitimate requests.

## 2. Environment variables (`src/env.ts`) — make them fail at the cold start

<!-- file: src/env.ts -->
```ts
// src/env.ts
import { z } from 'zod';

export const EnvSchema = z.object({
  TABLE_NAME: z.string().min(1),
  AWS_REGION: z.string().min(1),
  LOG_LEVEL: z.enum(['DEBUG', 'INFO', 'WARN', 'ERROR']).default('INFO'),
  NODE_ENV: z.enum(['development', 'test', 'production']).default('production'),
});

export type Env = z.infer<typeof EnvSchema>;

const parsed = EnvSchema.safeParse(process.env);
if (!parsed.success) {
  throw new Error(`environment variable validation failed\n${z.prettifyError(parsed.error)}`);
}

export const env: Env = parsed.data;
```

**Run `safeParse` at module top level.** Validate inside the handler and a bad deploy stays alive until the first
request, and that first request is a user. Throw at top level and initialization fails, so the function never comes up at all.
Throwing a bare `Error` rather than an `AppError` is the same reason — at this point there is no request to answer and
`respond` does not exist yet.

`TABLE_NAME` is passed in by CDK through `environment` (`resources/deploy-and-iam.md`).
`AWS_REGION` is filled in by the Lambda runtime <!-- unverified -->.

**A Lambda environment variable is not a secret store.** The value is plainly visible in the CloudFormation template and the
console, so keep API keys and signing keys in Secrets Manager/SSM and pass **only the ARN** as an environment variable.
What the schema holds is that ARN, not the secret itself.

## 3. Body and query schemas (`src/schemas/task.ts`)

<!-- file: src/schemas/task.ts -->
```ts
// src/schemas/task.ts
import { z } from 'zod';

export const TaskStatusSchema = z.enum(['open', 'done']);
export type TaskStatus = z.output<typeof TaskStatusSchema>;

export const TaskCreateSchema = z.strictObject({
  title: z.string().trim().min(1).max(200),
  status: TaskStatusSchema.default('open'),
});

export const TaskUpdateSchema = z
  .strictObject({
    title: z.string().trim().min(1).max(200).optional(),
    status: TaskStatusSchema.optional(),
  })
  .refine((v) => Object.keys(v).length > 0, { message: 'send at least one field to update' });

export const TaskQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(20),
  cursor: z.string().min(1).optional(),
  status: TaskStatusSchema.optional(),
});

export type TaskCreate = z.output<typeof TaskCreateSchema>;
export type TaskUpdate = z.output<typeof TaskUpdateSchema>;
export type TaskQuery = z.output<typeof TaskQuerySchema>;
```

The three schemas use different constructors because their unknown-key policies differ.

| constructor | unknown keys | where it is used | confirmed behavior |
| --- | --- | --- | --- |
| `z.strictObject` | **refuse** (`unrecognized_keys`) | the body | `{title,ownerId}` → 400, a field error on `ownerId` <!-- verified: zod 4.4.3 run, safeParse output --> |
| `z.object` | **strip** | the query | `{ownerId:'…'}` → `{limit:20}` <!-- verified: zod 4.4.3 run --> |
| `z.looseObject` | preserve | not used | an unvalidated value passes straight through |

`z.coerce.number()` is attached to `limit` because a query string value is **always a string**.
`.default(20)` is safe here — a list read is not a partial update but **a complete query**, so filling
a default in for a value that was not sent is exactly the intent. §4 is the opposite case.

`cursor` is an opaque string that `decodeCursor` in `resources/data-access.md` interprets, so
only its length is checked here. The format judgement stays in the one place, the decoder.

## 4. Partial update — `.partial()` does not erase `.default()`

**The most expensive validation defect on this axis.** The syntax is perfect and the types pass, and all that surfaces
is a report that a user edited only the title and the status reverted to `open`.

```ts
// ❌ src/schemas/task.ts — reusing the create schema through .partial()
export const TaskUpdateSchema = TaskCreateSchema.partial();
// ❌ sent {}                      → received {"status":"open"}
// ❌ sent {"title":"edited"}       → received {"title":"edited","status":"open"}
```

`.partial()` wraps each field in `ZodOptional` but does not peel the inner `ZodDefault` off —
the wrapper becomes `optional(default(enum))`, and with the key absent the default is filled in. The output above is the run
result verbatim <!-- verified: zod 4.4.3, TaskCreateSchema.partial().safeParse output -->.
That value then rides into the `UpdateExpression` of `updateTask(ownerId, id, patch)` and **overwrites a field that
was never sent.**

Do not derive the update schema from the create schema — **declare it separately with `.optional()` fields** (§3).
Then the same three inputs come out like this.

| input | result | confirmation |
| --- | --- | --- |
| `{}` | 400 — `_: ["send at least one field to update"]` | `.refine` catches it <!-- verified: run output --> |
| `{"title":"edited"}` | `{"title":"edited"}` — **no `status` is attached** | <!-- verified: run output --> |
| `{"title":"edited","zzz":1}` | 400 — `zzz: ["not an allowed field"]` | strict is preserved <!-- verified: run output --> |

Blocking the empty object with `.refine` is about meaning, not form. Let `{}` through and a 0-field
update goes out as a success response, and the client believes it was saved.

## 5. Pulling values out of the event (`src/http/parse.ts`)

<!-- file: src/http/parse.ts -->
```ts
// src/http/parse.ts
import { Buffer } from 'node:buffer';
import type { APIGatewayProxyEventV2 } from 'aws-lambda';
import { z } from 'zod';
import { AppError } from './app-error';
import { fieldErrors } from './errors';

function decodeBody(event: APIGatewayProxyEventV2): string {
  const raw = event.body;
  if (raw === undefined || raw === null || raw === '') {
    throw new AppError('VALIDATION_FAILED', 'the request body is empty');
  }
  return event.isBase64Encoded ? Buffer.from(raw, 'base64').toString('utf8') : raw;
}

export function parseBody<S extends z.ZodType>(schema: S, event: APIGatewayProxyEventV2): z.output<S> {
  let json: unknown;
  try {
    json = JSON.parse(decodeBody(event));
  } catch (e) {
    if (e instanceof AppError) throw e;
    throw new AppError('VALIDATION_FAILED', 'the request body is not JSON');
  }
  const r = schema.safeParse(json);
  if (r.success) return r.data;
  throw new AppError('VALIDATION_FAILED', 'the request body does not match the schema', fieldErrors(r.error));
}

export function parseQuery<S extends z.ZodType>(schema: S, event: APIGatewayProxyEventV2): z.output<S> {
  const r = schema.safeParse(event.queryStringParameters ?? {});
  if (r.success) return r.data;
  throw new AppError('VALIDATION_FAILED', 'the query string does not match the schema', fieldErrors(r.error));
}

export function pathParam(event: APIGatewayProxyEventV2, name: string): string {
  const v = event.pathParameters?.[name];
  if (typeof v !== 'string' || v.trim() === '') {
    throw new AppError('VALIDATION_FAILED', `path parameter ${name} is missing`);
  }
  return v;
}
```

All three functions are written on the premise that **an event field may be absent**. In the V2 event of
`@types/aws-lambda@8.10.162`, `body` · `queryStringParameters` · `pathParameters` are all optional fields (`?:`)
<!-- verified: node_modules/@types/aws-lambda/trigger/api-gateway-proxy.d.ts:219-231 compared directly -->.
`?? {}` and `?.` drop the value into the same place whether it arrives as `undefined` or as `null` — the shape was
chosen to be safe without confirming at runtime which of the two comes.

Without `if (e instanceof AppError) throw e;` in the `catch` block, the "the request body is empty" that
`decodeBody` threw is disguised as a JSON parse failure. The habit of keeping the range a `try` wraps narrow
earns its keep right here.

`Buffer.from(raw, 'base64')` is there for a request API Gateway judged to be binary.
Ignore `isBase64Encoded` and the base64 string goes straight into `JSON.parse` and becomes a 400.

## 6. Handler wiring and tests

The handler gets **the subject on the first line and the input on the next**. Lambda has no middleware
chain, so the only thing enforcing that order is discipline.

```ts
// src/handlers/tasks-update.ts
export const handler = withContext(async (event) => {
  try {
    const user = requireAuth(event);
    const id = pathParam(event, 'id');
    const patch = parseBody(TaskUpdateSchema, event);
    return respond(await updateTask(user.id, id, patch));
  } catch (e) {
    return respond.fail(e);
  }
});
```

**Drop the `try/catch` and every bit of validation in this section becomes meaningless.** `withContext` logs an unhandled
exception and then **rethrows it** (the shape column of the ledger), so without the wrapping, `requireAuth`'s 401 ·
`parseBody`'s 400 · `updateTask`'s 404 **all fold into a Lambda failure and go out as 5xx**.
What turns it into an envelope is `respond.fail` inside the handler, not the wrapper —
`resources/error-handling.md` §6 uses the same shape.

Tests put **a positive and a negative in a pair inside the same `it`**. Assert only the negative and swapping the
schema for `z.never()` still comes out green — because everything is a 400.

```ts
// test/schemas.task.test.ts
it('a partial update does not touch a field that was not sent', () => {
  expect(TaskUpdateSchema.parse({ title: 'edited' })).toEqual({ title: 'edited' }); // ✅ positive
  expect(TaskUpdateSchema.safeParse({}).success).toBe(false);                   // ✅ negative
  expect(TaskUpdateSchema.safeParse({ title: 'x', zzz: 1 }).success).toBe(false);
});
```

## Misuse list ① — Express + Zod 3 idiom → Lambda (HTTP API v2) + Zod 4 contrast table

| old habit | current shape |
| --- | --- |
| the `express.json()` middleware parses the body for you | `event.body` is a string or absent. `parseBody` calls `JSON.parse` itself |
| `req.query.limit` is already parsed | every value is a string — force it with `z.coerce.number()` |
| the `app.use(validate(schema))` validation middleware | there is no middleware chain. Call a function on the handler's first line |
| the validation middleware overwrites `req.body` | use only the **return value** of `parseBody`. The event is not modified |
| reading `.env` with `dotenv` | CDK injects the environment variables into the function. `src/env.ts` only validates them |
| `z.object({...}).strict()` | `z.strictObject({...})` — settle it with the constructor (`.strict()` is still there) <!-- verified: zod 4.4.3, o.strict === function --> |
| `schema.deepPartial()` | **it is gone.** Declare a separate schema for a nested partial update <!-- verified: zod 4.4.3, o.deepPartial === undefined --> |
| `z.string({ required_error: '…' })` | **silently ignored.** Use `z.string({ error: '…' })` <!-- verified: zod 4.4.3, passing required_error produced the default message --> |
| iterating the `err.errors` array | it is `err.issues`. `err.errors` is `undefined` <!-- verified: zod 4.4.3 run --> |
| `z.string().email()` | `z.email()` — it moved up to a top-level function (the old shape still works) <!-- verified: zod 4.4.3, both are function --> |

## Misuse list ② — confusable pairs

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| `TaskCreateSchema.partial()` vs a standalone `.optional()` declaration | if the original carries even one `.default()`, `.partial()` **cannot be used** — §4 |
| `z.strictObject` vs `z.object` | the body takes strict (it reports a contract violation), the query takes object (tracking parameters get mixed in) |
| `z.object` vs `z.looseObject` | `looseObject` lets an unvalidated key through — not used at an input boundary |
| `.default(v)` vs `.optional()` | `.default()` for a complete query (the list query), `.optional()` for a partial update |
| `z.infer` vs `z.output` | with no transform they are the same. The **result** type of a schema carrying `.transform()` or `.coerce` is `z.output` |
| `.min(1)` vs `.trim().min(1)` | `"   "` passes under `.min(1)` alone. For a string body, apply `.trim()` first |
| an absent `event.body` vs the string `'null'` | the former is "the request body is empty", the latter has `JSON.parse` produce `null` and becomes a schema error |
| `queryStringParameters` vs `rawQueryString` | the latter is the raw string. With a repeated key the former hands back only one comma-joined value |
| an empty `?limit=` in `parseQuery` | `z.coerce.number()` turns `''` into `0` — without `.min(1)` it passes <!-- verified: zod 4.4.3, coerce.number().safeParse('') === 0 --> |
| `pathParam` vs schema validation | `pathParam` only checks presence. If the id needs a format constraint, put the return value through a schema again |
