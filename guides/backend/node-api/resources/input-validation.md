<!-- orangekit-pack: backend/node-api v3.13.0 -->
# Input validation — Zod 4 schemas and request parsing

This file owns three code files: `src/env.ts` · `src/schemas/task.ts` · `src/http/parse.ts`.
The error code → HTTP status mapping and `ZodError` normalization are owned by `error-handling.md`.
Where the parsing helper is inserted in the router belongs to the seam (the `api-endpoints` slot).

## 1. What is validated where

**The validation point is a decision about when the failure happens.** The later you validate, the further the failure travels
into a user's request. This axis has no data-layer policy engine, so **the application is the only boundary** —
a value let through here is never looked at again.

| input | validation point | when it fails | failure shape |
| --- | --- | --- | --- |
| environment variable | `src/env.ts` (`EnvSchema`) | process boot | stderr + `exit(1)` |
| request body | `parseBody(TaskCreateSchema, req)` | request handling | `AppError('VALIDATION_FAILED')` → 400 |
| query string | `parseQuery(TaskQuerySchema, req)` | request handling | same |
| path parameter | `z.cuid()`/`z.uuid()` in the router | request handling | same |
| uniqueness of a value | DB constraint (`@@unique`) | write | Prisma `P2002` → 409 |
| **ownership** | the query condition (`data-access.md`) | write/read | 0 rows → 404 |

The last row is not validation but **authorization**. Zod cannot decide it — a schema knows only what the request
says, never who the requester is. Read `ownerId` from the request body and the moment the schema
lets it through you are writing someone else's row. The subject comes only from a verified session (`req.user`).

There is one criterion for choosing: **when this value is wrong, who has to find out first.** If the deployer has to find out
first, it is boot time (§2); if the caller has to, it is request time (§6).

## 2. The environment variable schema (`src/env.ts`)

**This is the only file in the repository that reads `process.env`.** If another file reads it directly, typing,
validation, and boot-time failure are all bypassed.

<!-- file: src/env.ts -->
```ts
import { z } from 'zod';

// a millisecond setting where 0 is a legitimate value. Check the string before coercing so an empty value does not leak through as 0
const ms = (max: number) =>
  z.string().regex(/^\d+$/, 'must be an integer (ms) of 0 or more').transform(Number)
    .pipe(z.number().int().max(max));

export const EnvSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  DATABASE_URL: z.url({ protocol: /^postgres(ql)?$/ }),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug']).default('info'),
  SHUTDOWN_TIMEOUT_MS: ms(120_000).prefault('10000'),
  DRAIN_DELAY_MS: ms(60_000).prefault('800'),
});

export type Env = z.infer<typeof EnvSchema>;

const parsed = EnvSchema.safeParse(process.env);

if (!parsed.success) {
  process.stderr.write(`environment variable validation failed\n${z.prettifyError(parsed.error)}\n`);
  process.exit(1);
}

export const env: Env = parsed.data;
```

There is a reason for using `process.stderr.write`. The structured logger (`logger`, `operations.md`) depends on
`env.LOG_LEVEL`, so **it does not exist yet at this point.** Call the logger here and you get a
circular import, which is why an environment failure is the one failure in this repository reported without the logger.

Putting the `protocol` option on `DATABASE_URL` is deliberate too. With a bare `z.url()`,
`https://evil.example/db` passes through and the connection failure happens on the first query, not at boot.
Because the URL carries a secret, the error message matters too, and Zod's `invalid_format` message is
only `Invalid URL`, so it does not carry the value.
<!-- verified: ran zod 4.4.3 — fed postgres:// · postgresql:// · https:// and a non-URL into z.url({protocol:/^postgres(ql)?$/}) and observed the passes, rejections, and error messages -->

## 3. The environment variable trap — the empty string and `.default()`

Every value in `process.env` is a string, and **not being set is different from being an empty string.**
`.default()` fires only on `undefined`, so `PORT=` (an empty value) does not fall back to the default.

```ts
// ❌ with PORT= , Number('') === 0 and it comes up on port 0
PORT: z.coerce.number().default(3000),
```

```ts
// ✅ put a range on it and the 0 is caught at boot
PORT: z.coerce.number().int().min(1).max(65535).default(3000),
```

<!-- verified: ran zod 4.4.3 — passed the three inputs unset/empty/abc for PORT through both schema shapes and compared -->
| input | `.default(3000)` alone | with `.int().min(1)` added |
| --- | --- | --- |
| `PORT` unset | `3000` | `3000` |
| `PORT=` | **`0`** | `Too small: expected number to be >=1` → exit 1 |
| `PORT=abc` | `expected number, received NaN` | same |

**`.default()` does not re-validate the value it injects.** `z.string().trim().default('  x  ')` returns
`'  x  '` untouched. To run the pipeline on the default too, use `.prefault()` —
the same input becomes `'x'`. <!-- verified: ran zod 4.4.3 — put .default('  x  ') and .prefault('  x  ') on z.string().trim() and parsed undefined: the former gave '  x  ', the latter 'x' -->

**When 0 is a legitimate value, a range check cannot catch it.** `.min(1)` filtered the empty value out for `PORT`, but
`DRAIN_DELAY_MS=0` (turning the drain delay off) is a valid setting, so the same defense does not work —
`DRAIN_DELAY_MS=` (an empty value from a typo) also becomes 0 and **the feature is silently turned off.** In that case do not
leave it to coercion; **check the string first and convert afterwards.** The `ms()` helper in §2 is that shape.

| input | `z.coerce.number().int().min(0)` | `ms()` (check the string, then convert) |
| --- | --- | --- |
| unset | the default | the default (`.prefault` runs the pipeline) |
| `=0` (an intentional 0) | `0` | `0` |
| `=` (a typo) | **`0` — indistinguishable** | `must be an integer (ms) of 0 or more` → exit 1 |
| `=99999999` | passes | `Too big: expected number to be <=60000` |

## 4. Request schemas (`src/schemas/task.ts`)

<!-- file: src/schemas/task.ts -->
```ts
import { z } from 'zod';

const title = z.string().trim().min(1, 'Title cannot be empty').max(200);
const status = z.enum(['open', 'done']);

export const TaskCreateSchema = z.strictObject({
  title,
  status: status.default('open'),
  dueAt: z.iso.datetime({ offset: true }).optional(),
});

export const TaskUpdateSchema = z
  .strictObject({
    title: title.optional(),
    status: status.optional(),
    dueAt: z.iso.datetime({ offset: true }).nullable().optional(),
  })
  .refine((v) => Object.keys(v).length > 0, {
    error: 'at least one field to update is required',
  });

export const TaskQuerySchema = z.object({
  status: status.optional(),
  limit: z.coerce.number().int().min(1).max(100).default(20),
  cursor: z.string().min(1).optional(),
});

export type TaskCreate = z.infer<typeof TaskCreateSchema>;
export type TaskUpdate = z.infer<typeof TaskUpdateSchema>;
export type TaskQuery = z.infer<typeof TaskQuerySchema>;
```

Use `z.strictObject` for the body and not for the query. **The default behavior is to silently strip unknown keys**
(`{ title:'a', evil:1 }` → `{ title:'a', status:'open' }`), so
a typo'd field is ignored and a 200 goes out. A query string gets tracking parameters (`utm_*`) mixed in, so stripping is
right there, while the body is a contract the client knows exactly, so rejection is right.

The reason `limit` has `.max(100)` is that page size is DB load. An unbounded
`limit` becomes a path to reading the entire table in one request.

## 5. Partial updates — do not stack `.partial()` and `.default()`

**This is the most expensive defect on this axis.** The syntax is perfect, the types pass, and only running it reveals the problem.

```ts
// ❌ TaskCreateSchema.partial() — the .default('open') on status survives
const TaskUpdateSchema = TaskCreateSchema.partial();
```

`.partial()` only wraps each field in `.optional()`; it **does not strip the `.default()` inside.**
Send only `{ "title": "updated" }` to `PATCH /api/tasks/1` and the parse result is
`{ title: 'updated', status: 'open' }`, silently resurrecting a task that had been completed.
With no field carrying a `.default()` there is no problem either, so **the moment `.default()` is added later**
a perfectly good PATCH breaks. Put `.optional()` on each field yourself, as in §4, and there is nowhere for them to stack.

<!-- verified: express 5.2.1 + zod 4.4.3 integration run — hooked both schema shapes to the same router and compared three inputs as real HTTP requests -->
These are the three inputs tested as real requests with both shapes hooked to the same router. The right column shows **not the envelope**
but only the status code and `details` (or the parsed value) — the envelope is decided by the seam:

| # | input | status · `details` or parse result |
| --- | --- | --- |
| ① | `{}` | 400 · `{"_":["at least one field to update is required"]}` |
| ② | `{"title":"updated"}` | 200 · `{"title":"updated"}` — **`status` is not filled in** |
| ③ | `{"title":"a","evil":1}` | 400 · `{"_":["Unrecognized key: \"evil\""]}` |

Under the `.partial()` shape, ② becomes `{"title":"updated","status":"open"}`. ① is worse —
an empty body **passes** as `{"status":"open"}` instead of being a 400. Until you run both shapes side by side,
no amount of reading shows this difference.

The `.refine()` in ① is mandatory too. Let an empty object through and an `UPDATE` with 0 fields goes out, and a row
with only `updatedAt` changed is answered with a 200.

## 6. The parsing helper (`src/http/parse.ts`)

<!-- file: src/http/parse.ts -->
```ts
import type { Request } from 'express';
import type { z } from 'zod';
import { AppError } from './app-error';
import { fieldErrors } from './errors';

function run<S extends z.ZodType>(schema: S, raw: unknown, where: string): z.output<S> {
  const r = schema.safeParse(raw);
  if (r.success) return r.data;
  throw new AppError('VALIDATION_FAILED', `${where} failed validation`, fieldErrors(r.error));
}

export function parseBody<S extends z.ZodType>(schema: S, req: Request): z.output<S> {
  return run(schema, req.body, 'request body');
}

export function parseQuery<S extends z.ZodType>(schema: S, req: Request): z.output<S> {
  return run(schema, req.query, 'query string');
}
```

This pack does not define `AppError` — the seam owns it in `src/http/app-error.ts`.
`fieldErrors` is owned by `error-handling.md`.

There is a reason for using the return value and not assigning back to `req.query`. **The `req.query` of Express 5 is a
getter with no setter, so the assignment fails either way** — but the *manner* of failure differs by module
kind.
<!-- verified: ran express 5.2.1 — ran the same handler as CJS and as ESM and observed req.query after the assignment -->

Under ESM and strict mode you get `TypeError: Cannot set property query…`, but **under CJS sloppy mode it does not
throw and is silently ignored.** Either way, `req.query` after the assignment is the original value.

**The silent failure is the more dangerous one.** Under CJS, code that believes it validated keeps reading the original
string and gives no signal at all. Since the assignment is never reflected either way, take the validated value into a
local variable and use that.

Using `z.output<S>` is deliberate too. The value is the same as `z.infer`, but on a schema carrying a `.transform()` or a `.default()`
the name makes visible **the place where the input type and the output type diverge.**

The caller does not use `try/catch`. Express 5 forwards an exception thrown by a handler — synchronous or as a rejected
promise — to the error middleware automatically. Middleware order is owned by
`project-structure.md`.

## 7. Double up with the DB constraints

Zod blocks the request and the DB constraint blocks the race. **Either one alone is not enough.**

| Zod (`schemas/task.ts`) | Prisma (`prisma/schema.prisma`) | with only one of them |
| --- | --- | --- |
| `title.max(200)` | `@db.VarChar(200)` | Zod only: another path (a seed, a batch job) bypasses it |
| `z.enum(['open','done'])` | `enum TaskStatus { open done }` | DB only: what should be a 400 becomes a 500 |
| — (undecidable) | `@@unique([ownerId, title])` | check-then-insert is open to a race |

The third row is the crux. "Read first, insert if absent" lets both through when two requests arrive at once.
Uniqueness **can only be decided atomically by the DB**, and the application's only job is to translate that
failure (`P2002`) into a 409 — `isUniqueViolation` in `error-handling.md` is that place.

## Misuse list ① — Zod 3 → Zod 4 idioms

Built by comparing the `.d.ts` of the installed build (zod 4.4.3) line by line. The left-hand shapes still work and produce no
compile error — which is why they quietly remain. **The seven annotated rows were confirmed against the `@deprecated`
comment down to the line number, while the two unannotated rows (`.strict()` · `.default()`) are not APIs the library
withdrew but misuses observed in this stack.** The evidence differs, so do not read them as one.

| old habit (Zod 3) | current shape (Zod 4) |
| --- | --- |
| `z.string().email()` | `z.email()` <!-- verified: zod 4.4.3 classic/schemas.d.cts:110 @deprecated --> |
| `z.string().url()` | `z.url()` <!-- verified: line 112 of the same file, @deprecated --> |
| `z.string().uuid()` / `.cuid2()` / `.ulid()` | `z.uuid()` / `z.cuid2()` / `z.ulid()` <!-- verified: lines 120·138·140 of the same file, @deprecated --> |
| `z.string().datetime()` | `z.iso.datetime()` <!-- verified: line 160 of the same file, @deprecated --> |
| `z.object({}).passthrough()` | `z.looseObject({})` or `.loose()` <!-- verified: line 460 of the same file, @deprecated --> |
| `err.flatten()` · `err.format()` | `z.flattenError(err)` · `z.treeifyError(err)` <!-- verified: zod 4.4.3 classic/errors.d.cts:7·10 @deprecated --> |
| `{ message: '...' }` (check option) | `{ error: '...' }` <!-- verified: zod 4.4.3 core/api.d.cts:9 @deprecated — though message still takes precedence (confirmed by running it) --> |
| `z.object({}).strict()` | `z.strictObject({})` — not deprecated. The type annotation only advises it with `Consider` |
| expecting `.default()` to run the transform too | `.prefault()` — `.default()` does not re-validate the injected value |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `.partial()` vs per-field `.optional()` | if even one `.default()` is present, do not use `.partial()` (§5) |
| `.parse()` vs `.safeParse()` | inside a helper, `safeParse` — the `ZodError` of `parse` has the whole issue array as JSON in `message`, so putting it into a response leaks the internal structure |
| `z.object` vs `z.strictObject` | the body takes `strictObject` (reject typos), the query takes `z.object` (strip tracking parameters) |
| `.optional()` vs `.nullable()` | "not sent" is `.optional()`, "clear the value" is `.nullable()`. To clear a field in a PATCH you need **both** |
| `.default()` vs `.catch()` | `.default()` covers only `undefined`, `.catch()` swallows **every failure** — use `.catch()` in request validation and bad input silently becomes the default |
| `z.infer` vs `z.input` | the value after passing the schema is `z.infer` (= `z.output`). The shape the client sends is `z.input` |
| `z.coerce.number()` vs `z.number()` | queries and environment variables are always strings, so `coerce`. Use it on a number in a JSON body and `"5"` passes too, blurring the contract |
| `env.PORT` vs `process.env.PORT` | application code always uses `env` — the only files allowed to read `process.env` are `src/env.ts` and the test setup |
