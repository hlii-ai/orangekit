<!-- orangekit-pack: backend/firebase v3.14.0 -->
# Input validation — schemas and configuration parameters

This file owns `functions/src/schemas/task.ts` (Zod schemas · `parseCallable`) and `functions/src/params.ts`
(`defineString`/`defineInt`/`defineSecret` · boot validation).

The error code table (`AppError`) and the translation into `HttpsError` are **owned by the seam**
(`functions/src/http/app-error.ts` · `functions/src/http/https.ts`). The handler wrapper (`withErrors`) and
principal extraction (`requireUid`) are owned by `resources/functions-patterns.md`, and the document shape by
`resources/data-modeling.md`. The proof of the schemas is in `resources/testing-and-deploy.md`.

## 1. Decision tree — which value is blocked where

**This axis has two boundaries and they block different code paths.** Security Rules block only the client SDK,
and `firebase-admin` bypasses the rules entirely. On the function path **the table below is the only boundary.**

| source of the value | where it is blocked | tool | on failure |
| --- | --- | --- | --- |
| `request.data` (call body) | First line of the handler | `parseCallable(schema, req.data)` | `AppError('VALIDATION_FAILED')` |
| `request.auth.uid` (principal) | First line of the handler | `requireUid(req)` | `AppError('UNAUTHENTICATED')` |
| Cursor and list parameters | The same schema | `TaskQuerySchema` | Same as above |
| Configuration injected at deploy | Once per instance | `config()` | `INTERNAL` on the first call |
| Direct writes from the client SDK | `firestore.rules` | The rules | `permission-denied` |

**Do not put `ownerId` in any schema.** The moment it is taken from the body, the client gets to choose the
owner. The owner is made only by `requireUid(req)` out of the auth context.

## 2. Schemas (`functions/src/schemas/task.ts`)

<!-- file: functions/src/schemas/task.ts -->
```ts
import { z } from 'zod';
import { AppError } from '../http/app-error';

export const TaskStatusSchema = z.enum(['open', 'done']);

export const TaskCreateSchema = z.strictObject({
  title: z.string().trim().min(1).max(200),
  status: TaskStatusSchema.default('open'),
});

export const TaskUpdateSchema = z
  .strictObject({
    title: z.string().trim().min(1).max(200).optional(),
    status: TaskStatusSchema.optional(),
  })
  .refine((p) => Object.keys(p).length > 0, { message: 'at least one field to update is required' });

export const TaskQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(20),
  cursor: z.string().min(1).optional(),
  status: TaskStatusSchema.optional(),
});

export type TaskCreate = z.output<typeof TaskCreateSchema>;
export type TaskUpdate = z.output<typeof TaskUpdateSchema>;
export type TaskQuery = z.output<typeof TaskQuerySchema>;

export function parseCallable<S extends z.ZodType>(schema: S, data: unknown): z.output<S> {
  const r = schema.safeParse(data);
  if (r.success) return r.data;
  const { fieldErrors, formErrors } = z.flattenError(r.error);
  const details: Record<string, string[]> = { ...fieldErrors } as Record<string, string[]>;
  if (formErrors.length > 0) details['_'] = formErrors;
  throw new AppError('VALIDATION_FAILED', 'input does not match the schema', details);
}
```

The literal set of `TaskStatusSchema` is **the same list** as `d.status in ['open', 'done']` in
`firestore.rules`. Extend it in both places together — the rules do not look at TypeScript.

## 3. Partial updates — `.partial()` does not remove defaults

**Do not derive `TaskUpdateSchema` from `TaskCreateSchema.partial()`.** `partial()` only makes fields
optional; it does not strip `.default()`, so a field that was not sent comes back to life as the default.
A title edit that never touched `status` silently reverts a `done` task to `open`.

<!-- verified: compared the zod@4.4.3 parse results directly (a pure function, so independent of the Node runtime) -->
```ts
// ❌ Derive it and a status you never sent gets filled in — run: {"title":"t","status":"open"}
const Bad = TaskCreateSchema.partial();
Bad.parse({ title: 't' });
// ❌ Stacking .optional() and .default() is the same — swapping the order still fills it in
z.object({ status: TaskStatusSchema.optional().default('open') }).parse({});
// ✅ Declare the update schema separately — run: {"title":"t"}
TaskUpdateSchema.parse({ title: 't' });
```

An empty object (`{}`) **passes** Zod — with only optional fields there is no violation. Without a `.refine`
block, an update that changes nothing bumps only `updatedAt` and answers success.

## 4. Unknown keys — the three object types behave differently

| schema | unknown keys | result of parsing `{ title:'t', ownerId:'attacker' }` |
| --- | --- | --- |
| `z.strictObject` | **Rejected** | `unrecognized_keys`, `issue.keys = ['ownerId']` <!-- verified: zod@4.4.3 run --> |
| `z.object` | **Silently stripped** | `{ title:'t', status:'open' }` — it passes <!-- verified: zod@4.4.3 run --> |
| `z.looseObject` | Passed through | `ownerId: 'attacker'` survives as-is <!-- verified: zod@4.4.3 run --> |

**A write body is `z.strictObject`.** `z.object` stripping it looks safe, but the stripping is
**silent** — a client that sends `ownerId` and gets a 200 believes it changed the owner.
Rejecting is what ends that misunderstanding at the first request. Conversely `TaskQuerySchema` is `z.object`: a list
query string mixes in harmless extras such as tracking parameters, so stripping is right there.

**There is one exception — do not trust `strictObject` as a security control.** A `__proto__` key produced by
`JSON.parse` passes even though it is visible to `Object.keys` (the value is discarded and the prototype is not
polluted either). That the silence is not a measurement failure is guaranteed by a **positive control**: on the same schema and
the same path, `xyz`, `constructor` and `toString` were all rejected as `unrecognized_keys`.
<!-- verified: on zod@4.4.3, JSON.parse('{"title":"t","__proto__":{"isAdmin":true}}') passed while the 3 controls were measured as rejected alongside it -->

A `{}` missing required fields is rejected as `invalid_type` (`expected: 'string'`). `null`, a string,
a number and an array are all `invalid_type` (`expected: 'object'`) too — an array is not treated as an object.

## 5. Validating the `onCall` body — `request.data` is not trusted input

`onCall` verifies the ID token in the Authorization header but **does not block a request that carries none.**
A request called without auth reaches inside the function too — the emulator log left
`{"verifications":{"app":"MISSING","auth":"MISSING"},...,"message":"Callable request verification passed"}`
and ran the handler. <!-- verified: firebase-functions@7.3.2 · token-less POST to the emulator -->

```ts
// functions/src/index.ts (excerpt) — L0 pins the entry point names (tasksCreate ≠ createTask)
export const tasksCreate = onCall(
  { region: REGION, secrets: [WEBHOOK_KEY], maxInstances: 10 },
  withErrors(async (req) => {
    const uid = requireUid(req);                             // ① principal
    const input = parseCallable(TaskCreateSchema, req.data); // ② body
    logger.info('task.create', { uid, pageMax: config().TASKS_PAGE_MAX });
    return createTask(uid, input);                           // ③ ownerId comes only from uid
  }),
);
```

The entry point (`tasksCreate`) and the repository (`createTask`) **have different names.** Overlap them and the tests
split over which one they import — measured, that is exactly why the suite would not even load.

The order is the response code. A token-less request is folded to 401 `UNAUTHENTICATED` and a request carrying an unknown key to 400
`INVALID_ARGUMENT` — confirmed by actually firing at the emulator.
<!-- verified: measured the 401/400/200 response bodies with emulators:exec + fetch -->

The `fieldErrors` that `z.flattenError` produces is a `Record<string, string[]>`, so it goes straight into `AppError`'s third
argument. An unknown key is not a field, so it goes to `formErrors` — which is why it is carried separately under the
`'_'` key.

## 6. Configuration parameters (`functions/src/params.ts`)

<!-- file: functions/src/params.ts -->
```ts
import { defineInt, defineSecret, defineString } from 'firebase-functions/params';
import { z } from 'zod';

export const REGION = defineString('TASKS_REGION', { default: 'asia-northeast3' });
export const PAGE_MAX = defineInt('TASKS_PAGE_MAX', { default: 100 });
export const WEBHOOK_KEY = defineSecret('TASKS_WEBHOOK_KEY');

const ConfigSchema = z.strictObject({
  TASKS_PAGE_MAX: z.number().int().min(1).max(1000),
  TASKS_WEBHOOK_KEY: z.string().min(16),
});
export type Config = z.output<typeof ConfigSchema>;

let cached: Config | undefined;

export function config(): Config {
  if (cached) return cached;
  const r = ConfigSchema.safeParse({
    TASKS_PAGE_MAX: PAGE_MAX.value(),
    TASKS_WEBHOOK_KEY: WEBHOOK_KEY.value(),
  });
  if (!r.success) {
    const flat = JSON.stringify(z.flattenError(r.error).fieldErrors);
    throw new Error(`configuration is invalid: ${flat}`);
  }
  cached = r.data;
  return cached;
}
```

**Declare at module top level, call inside the handler.** `defineX` has to be at the top level to ride in the
deploy manifest's `params` array — it rides on the declaration alone, even when unused in the options.
<!-- verified: extracted the manifest with FUNCTIONS_MANIFEST_OUTPUT_PATH and confirmed 3 params -->

For a value that goes into the function options, such as the region, **pass the Param object through without calling `.value()`.**
That is what makes it ride in the manifest as the CEL expression `"{{ params.TASKS_REGION }}"` and resolve at deploy time.

## 7. Boot-time failure — what a top-level `.value()` actually does

In the pre-deploy **analysis phase** (`index.js` is imported wholesale with `FUNCTIONS_CONTROL_API=true`),
how `.value()` behaves differs per parameter kind.

<!-- verified: compared against firebase-functions@7.3.2 params/types.js:19-26,320-325 plus a run of the analysis phase -->

| called at top level | kind | measured result |
| --- | --- | --- |
| `WEBHOOK_KEY.value()` | `defineSecret` | **The analysis phase dies with an exception** — `Cannot access the value of secret "TASKS_WEBHOOK_KEY" during function deployment.` No manifest is produced |
| `REGION.value()` | `defineString` | **It only warns and returns `""`.** The declared `default` is ignored too — `region: [""]` is baked into the manifest and the deploy succeeds |
| `PAGE_MAX.value()` | `defineInt` | The same warning, then `0` |

```ts
// ❌ A secret kills the deploy; a string or an int deploys silently with an empty value
const key = WEBHOOK_KEY.value();
const region = REGION.value();
```

**The silent one is more dangerous.** A secret stops the deploy, so you know immediately. `defineString` gets all the way
through the deploy with an empty region. So run the configuration validation through `config()` **once per instance, inside the
handler** — 2nd gen functions reuse the instance between runs, so after the first call there is no cost, and a bad configuration
is cut off at the first request as `INTERNAL`. Changing the value to a short secret actually produced a 500 with
`{"TASKS_WEBHOOK_KEY":["Too small: expected string to have >=16 characters"]}`.
<!-- verified: changed .secret.local to short and requested against the emulator → measured 500 INTERNAL -->

## Misuse list ① — Zod 3 → Zod 4

| old habit (Zod 3) | current form (Zod 4) |
| --- | --- |
| `z.object({...}).strict()` | `z.strictObject({...})` |
| `z.object({...}).passthrough()` | `z.looseObject({...})` |
| `err.flatten()` | `z.flattenError(err)` |
| `err.format()` | `z.treeifyError(err)` |
| `z.string().nonempty()` | `z.string().min(1)` |
| `issue.code === 'invalid_enum_value'` | `issue.code === 'invalid_value'` |
| Using only `z.infer<typeof S>` | When there is a transform, split `z.output<S>` (output) from `z.input<S>` (input) |
| Digging out the type with `schema._type` | `z.output<S>` — the generic bound is `S extends z.ZodType` |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `z.strictObject` vs `z.object` | Write bodies take the first (reject unknown keys), list queries the second (strip extras) |
| `TaskCreateSchema.partial()` vs a separate declaration | With even one default present, **always declare separately** |
| `.optional()` vs `.default()` | An update schema takes only the first. Stack them and a field you did not send overwrites what is stored |
| Top-level `.value()` vs `.value()` inside the handler | Declare at the top level, call inside the handler. A value going into the options stays a Param object |
| Missing `secrets: [WEBHOOK_KEY]` | Absent from the array, `.value()` at runtime gives "No value found for secret" |
| `req.data.ownerId` vs `requireUid(req)` | The owner is always the latter. An `ownerId` in the body is something to reject |
| Believing `z.coerce.number()` accepts only numbers | It does not. `[7]`→7 · `true`→1 · `' 42 '`→42 all pass silently <!-- verified: zod@4.4.3 run · narrowing with z.union rejected the first two, as a comparison --> |
| Believing Security Rules cover it | The rules block only the client SDK. A function is admin, so **this file is the only boundary** |
