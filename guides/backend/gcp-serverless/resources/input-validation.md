<!-- orangekit-pack: backend/gcp-serverless v3.14.0 -->
# Input validation — one schema per boundary, and the environment is one of them

What this file owns is **the only place that reads the environment** (`src/settings.ts`) · **the domain schemas**
(`src/schemas/task.ts`) · **the place zod errors are folded into a field map** (`src/schemas/errors.ts`), plus the unit
tests for those three (`test/schemas.test.ts`). **Which status code a `ZodError` goes out as** is owned by
`error-handling.md`, and the converter that actually calls the schema by `data-access.md`.

## 1. Where the schemas go — the boundary decision table

A boundary is **the place trust changes**. If a value came from outside the process, it needs a schema.

| boundary | schema | on failure | why it is not trusted input |
| --- | --- | --- | --- |
| request body | `TaskCreate` · `TaskUpdate` | `VALIDATION_FAILED` (422) | the client wrote the value |
| query parameters | `TaskQuery` | `VALIDATION_FAILED` (422) | the same as above. **They all arrive as strings** |
| process environment | the `Env` of `settings` | **the boot fails** | deployment settings are written by hand |
| Firestore document | `Task` (the converter calls it) | `VALIDATION_FAILED` (422) | a document **changes outside the code** |
| cursor string | `decodeCursor` (`data-access.md`) | `VALIDATION_FAILED` (422) | it is a value the client sent back |

Only the third row fails differently. **The environment arrives before any request, so it has to fail first too** —
blow up at request time and a half-alive container is taking traffic.

## 2. `settings` (`src/settings.ts`) — a validation failure is a boot failure

<!-- file: src/settings.ts -->
```ts
// src/settings.ts
import { z } from 'zod';
import { fieldErrors } from './schemas/errors.js';

// Do not put .strict() on the environment schema — process.env contains PATH·HOME.
const Env = z.object({
  GCP_PROJECT_ID: z.string().min(1),
  IDENTITY_PLATFORM_PROJECT_ID: z.string().min(1),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  LOG_LEVEL: z.enum(['info', 'warn', 'error']).default('info'),
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  FIRESTORE_EMULATOR_HOST: z.string().min(1).optional(),
});

const parsed = Env.safeParse(process.env);
if (!parsed.success) {
  process.stderr.write(
    JSON.stringify({ severity: 'CRITICAL', message: 'invalid environment', fields: fieldErrors(parsed.error) }) + '\n',
  );
  process.exit(1);
}

export const settings = parsed.data;
```

<!-- verified: compiled the file above and ran it 5 times changing only the environment, instrumenting stdout·stderr·the exit code -->
The three cases measured, and the positive control.

| environment | what was observed |
| --- | --- |
| two required values missing | exit code **1**, on stderr `{"severity":"CRITICAL",…,"fields":{"GCP_PROJECT_ID":["Invalid input: expected string, received undefined"],…}}` |
| `PORT=eighty` · `NODE_ENV=prod` | exit code **1** — `expected number, received NaN` · `Invalid option: expected one of "development"\|"test"\|"production"` |
| **normal (positive control)** | exit code **0**, `port: 8080` · `env: "development"` — the defaults really do get filled in |

**Why `z.coerce.number()`**: environment values are all strings. `PORT=8080` comes in as the `number` `8080`,
and when the key is absent `.default(8080)` applies first. **Why `process.stderr.write` comes before
`process.exit(1)`**: confirmed by running it, that line is not lost even when it is received through a pipe —
leave only an exit code with no diagnosis and the "why" disappears from the deploy log.

<!-- verified: parsed process.env with z.object({GCP_PROJECT_ID:z.string()}).strict() and counted the length of unrecognized_keys' keys -->
**Do not put `.strict()` on the environment schema.** Put it on and **59 keys**, `PATH`·`HOME` among them, were
refused all at once. `.strict()` goes only on input whose shape we decided (section 5).

## 3. There is one file that reads the environment

Read the environment outside `settings` and **typing, the default, and boot-time failure are all bypassed**, and that fact
surfaces after deploy, the first time that code path runs.

```ts
// ❌ it bypasses validation. The type is string | undefined, and a typo lives on until runtime
const port = Number(process.env.PORT ?? 8080);
// ❌ "just briefly, only here" is a second entry point — now the default lives in two places
const projectId = process.env.GCP_PROJECT_ID!;
// ✅ use only validated values. The type is number, and if it were wrong this code would never have run at all
import { settings } from './settings.js';
serve({ fetch: createApp().fetch, port: settings.PORT, hostname: '0.0.0.0' });
```

There are **only two** exceptions: this file itself, where the schema is defined, and the place the test injects
`FIRESTORE_EMULATOR_HOST`. The `env-single-entry` policy blocks the rest with a FAIL.

## 4. The domain schemas (`src/schemas/task.ts`)

<!-- file: src/schemas/task.ts -->
```ts
// src/schemas/task.ts
import { Timestamp } from '@google-cloud/firestore';
import { z } from 'zod';

export const TaskStatus = z.enum(['open', 'done']);
export type TaskStatus = z.infer<typeof TaskStatus>;

// z.date() refuses a Timestamp — the message measured: "expected date, received Timestamp".
const timestamp = z.instanceof(Timestamp);

export const Task = z.object({
  id: z.string().min(1),
  ownerId: z.string().min(1),
  title: z.string().min(1).max(200),
  status: TaskStatus,
  createdAt: timestamp,
});
export type Task = z.infer<typeof Task>;

export const TaskCreate = z.object({
  title: z.string().min(1).max(200),
  status: TaskStatus.default('open'),
}).strict();
export type TaskCreate = z.infer<typeof TaskCreate>;

export const TaskUpdate = z.object({
  title: z.string().min(1).max(200).optional(),
  status: TaskStatus.optional(),
}).strict()
  .refine((patch) => Object.keys(patch).length > 0, { message: 'there is not a single field to update' });
export type TaskUpdate = z.infer<typeof TaskUpdate>;

export const TaskQuery = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(20),
  cursor: z.string().min(1).optional(),
  status: TaskStatus.optional(),
}).strict();
export type TaskQuery = z.infer<typeof TaskQuery>;
```

**The values of `TaskStatus` are the lowercase `'open'`·`'done'`.** What the wire·the Firestore document·test assertions
use is the **value**, not the member name — confirmed by running it, `status=DONE` was refused with
`Invalid option: expected one of "open"|"done"`. **`id` is the document ID, not a document
field** (the converter fills it from `snap.id`). `ownerId`, by contrast, is stored as a document field too — the query
filter reads it (`data-access.md`).

## 5. Partial update and unknown keys — the two places that go wrong quietly

Both defects show up as **a wrong success rather than an error.** A 200 goes out and nothing is left in the log.

<!-- verified: on zod 4.4.3, printed the return of TaskCreate.partial().parse({}) and the parse results of the same input under the two schemas, with and without .strict() -->
```ts
// ❌ partial() wraps in ZodOptional but the default inside stays alive
TaskCreate.partial().parse({});      // ❌ measured: { status: 'open' } — a status nobody sent came into being
// ✅ write the optional fields yourself. With no default, an absent key stays absent
TaskUpdate.parse({ title: 'grocery run' }); // ✅ measured: { title: 'grocery run' }
// ❌ without .strict() it passes — measured: parsed as { status: undefined }, so the filter disappears
z.object({ status: TaskStatus.optional() }).parse({ stat: 'done' });
// ✅ the same input is refused — unrecognized_keys
TaskQuery.safeParse({ stat: 'done' });
```

A user who sent only `{"title":"grocery run"}` to `PATCH` **loses their completion mark**, and a client that typo'd
`?stat=done` receives **the whole list with the filter ignored** as a normal response. **An empty object is refused too** —
`.refine()` is that place. Attached **after** `.strict()`, the unknown-key rejection is kept (confirmed by running it).

<!-- verified: on zod 4.4.3, sent two unknown keys at once and printed the issues array -->
zod 4's `unrecognized_keys` issue **does not come out one per key** — for two unknown keys
**one** `{ code: 'unrecognized_keys', keys: ['nope','other'], path: [] }` came out, and the field errors of the
same request did not come with it (it stops there). Put it on the body too: an `ownerId` that `TaskCreate` received
is not to be ignored but **refused** — the owner comes only from the `sub` of a verified token.

## 6. The converter boundary — a document is not trusted input

A Firestore document can be written by the console·another service·an older version of the code. **Re-parse it** as `Task`
in `fromFirestore` (that file is owned by `data-access.md`). What is decided here is the schema side.

<!-- verified: ran Timestamp.now() of @google-cloud/firestore 9.0.0 through zod 4.4.3 and observed the result -->
| what was written | what was observed |
| --- | --- |
| `z.date().safeParse(Timestamp.now())` | **refused** — `Invalid input: expected date, received Timestamp` |
| `z.instanceof(Timestamp).safeParse(Timestamp.now())` | passes. `new Date()` is refused |
| `JSON.stringify({ createdAt: Timestamp.now() })` | `{"createdAt":{"_seconds":…,"_nanoseconds":…}}` |

The first row is the trap — `createdAt: z.date()` compiles, and with a `Date` fixture the tests pass too, but the moment it reads a real
document everything fails. **A value that comes from a document is validated with the type the document gave.** The third row is
an envelope problem: serialize it as it is and the SDK's internal field names become the wire contract.

## 7. `fieldErrors` (`src/schemas/errors.ts`) — there are places where `path` comes out empty

<!-- file: src/schemas/errors.ts -->
```ts
// src/schemas/errors.ts
import type { z } from 'zod';

/** The fixed key that issues with an empty path (= a problem with the whole object) fold into. */
export const ROOT_FIELD = '_root';

export function fieldErrors(err: z.ZodError): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const issue of err.issues) {
    // path is PropertyKey[] — array indices are numbers, so convert to string before joining.
    const key = issue.path.length === 0 ? ROOT_FIELD : issue.path.map(String).join('.');
    (out[key] ??= []).push(issue.message);
  }
  return out;
}
```

<!-- verified: printed the issue.path of a ZodError built by zod 4.4.3 as-is and compared -->
| what was wrong | the `issue.path` observed | key |
| --- | --- | --- |
| `title` is an empty string | `['title']` | `title` |
| a field inside an array item | `['items', 1, 'title']` | `items.1.title` — **the index is not stripped** |
| a `.strict()` violation | **`[]`** | `_root` |
| a `.refine()` failure (an empty update body) | **`[]`** | `_root` |

A nested object joins as `['meta','tag']` → `meta.tag`. Join an empty array as it is and the key becomes `''` —
the form can attach that error nowhere, and the user falls into the state of "it will not save and there is no red
text". `_root` is **the place the client looks for an object-level message**.

<!-- verified: observed 'errors' in err === false on zod 4.4.3 -->
`ZodError` **has only `.issues`.** zod 3's `.errors` is gone. And the type of `path` is
`PropertyKey[]`, so a `join` that does not go through `String()` is blocked by the type check.

## 8. Prove the block (`test/schemas.test.ts`)

**A test that carries only the negative assertion is not a guard** — replace the whole schema with `z.never()` and
"unknown keys are refused" stays green. Attach the assertion that normal input passes as its pair **inside the same `it`**.

<!-- file: test/schemas.test.ts -->
```ts
// test/schemas.test.ts
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { fieldErrors } from '../src/schemas/errors.js';
import { TaskCreate, TaskQuery, TaskUpdate } from '../src/schemas/task.js';

describe('schemas', () => {
  it('unknown keys are refused in both the body and the query, and normal input passes', () => {
    expect(TaskCreate.safeParse({ title: 'grocery run', ownerId: 'mallory' }).success).toBe(false);
    expect(TaskQuery.safeParse({ stat: 'done' }).success).toBe(false);
    expect(TaskQuery.safeParse({ status: 'DONE' }).success).toBe(false);   // the values are lowercase
    // ✅ without the positive pair, swapping the schema for z.never() stays green
    expect(TaskCreate.parse({ title: 'grocery run' })).toEqual({ title: 'grocery run', status: 'open' });
    expect(TaskQuery.parse({ limit: '5', status: 'open' })).toEqual({ limit: 5, status: 'open' });
    // ✅ positive control: without .strict() the same input passes and status is undefined
    const loose = z.object({ status: z.enum(['open', 'done']).optional() });
    expect(loose.parse({ stat: 'done' }).status).toBeUndefined();
  });

  it('a partial update creates no field that was never sent, and an empty body is refused', () => {
    expect(TaskUpdate.parse({ title: 'grocery run' })).toEqual({ title: 'grocery run' });
    expect(TaskUpdate.safeParse({}).success).toBe(false);
    // ✅ two controls: the create schema fills the default into the same body, and a one-field update passes
    expect(TaskCreate.parse({ title: 'grocery run' }).status).toBe('open');
    expect(TaskUpdate.safeParse({ status: 'done' }).success).toBe(true);
  });

  it('fieldErrors — an empty path folds into _root and array indices are kept', () => {
    const strictErr = TaskCreate.safeParse({ title: 'x', nope: 1 }).error as z.ZodError;
    expect(Object.keys(fieldErrors(strictErr))).toEqual(['_root']);
    const nested = z.object({ items: z.array(z.object({ title: z.string().min(1) })) });
    const arrErr = nested.safeParse({ items: [{ title: 'ok' }, { title: '' }] }).error as z.ZodError;
    expect(Object.keys(fieldErrors(arrErr))).toEqual(['items.1.title']);
    // ✅ the positive pair: normal input carries no error — it rules out an implementation that folds everything into _root
    expect(TaskCreate.safeParse({ title: 'x' }).success).toBe(true);
  });
});
```

<!-- verified: planted 8 kinds of mutation and ran vitest — all of them went red, and the failure reasons were the intended ones -->
Confirmed by running it: all 8 kinds of mutation **were caught** — removing `.strict()` (`TaskCreate`·`TaskQuery`) ·
`TaskUpdate = TaskCreate.partial()` · removing `.refine()` · uppercasing the enum values · removing `z.coerce` ·
deleting the empty-`path` handling in `fieldErrors` (the key becomes `''`) · stripping the array index (`items.title`).

## Misuse list ① — zod 3 → zod 4 idiom comparison table

| old habit (zod 3) | the current shape (zod 4) |
| --- | --- |
| `err.errors` | `err.issues` — there is no `.errors` <!-- verified: on zod 4.4.3, 'errors' in err === false --> |
| `err.flatten().fieldErrors` | `fieldErrors(err)` — it folds an empty `path` into `_root` |
| `issue.path.join('.')` | `issue.path.map(String).join('.')` — the type is `PropertyKey[]` |
| wrapping `schema.parse()` in try/catch to build the response | just throw. `toAppError` folds it (`error-handling.md`) |
| sweeping the environment with `z.record(z.string())` | declare only the keys you need. A key you do not use is not in the schema |

## Misuse list ② — confusion pairs

| what gets picked wrong often | the exact condition for applying it |
| --- | --- |
| `.strict()` on request input vs on the environment | on the request only. Put it on the environment and even `PATH` is refused (59 of them, measured) |
| `TaskCreate.partial()` vs a hand-written `TaskUpdate` | the first keeps the inner `default` alive and overwrites on a partial update |
| `z.date()` vs `z.instanceof(Timestamp)` | for a value that comes from a document, the second. The first refuses a `Timestamp` |
| the **value** of `TaskStatus` vs the member name | what the wire·the document·assertions use is the lowercase value |
| `settings` vs reading directly | the only exceptions are `src/settings.ts` and the emulator-injection test |
| ignoring unknown keys vs refusing them | ignoring them creates **a wrong success** — an unfiltered list goes out as a 200 |
