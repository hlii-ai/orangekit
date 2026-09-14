<!-- orangekit-pack: frontend/vanilla v3.14.0 -->
# Types and testing — the comment asserts, zod validates, tsc renders the verdict

Owns: the checker settings in `jsconfig.json` · the domain schema and types in `src/schemas/task.js` ·
the validated environment values in `src/config.js` · the Vitest harness in `vite.config.js` and `test/`. What it does not own —
the store's generics belong to `resources/state-management.md`, DOM creation and cleanup to
`resources/component-patterns.md`, and the actual API call to the seam's `data-fetching` slot.

## 1. Decision tree — assertion or validation

**Where the value came from** is the only criterion. The types are not in the code but only in the comments, so draw
the boundary wrong and code the checker passed receives a different shape at runtime.

| where the value came from | what to use | why |
| --- | --- | --- |
| a literal·computed result this codebase produced | `@param` · `@returns` | tsc follows the flow. Zero runtime cost |
| a network response · `localStorage` · `URLSearchParams` · `postMessage` | a zod parser such as `parseTask` | a comment does not exist at runtime |
| `import.meta.env` | `config` from `src/config.js` | it is inlined as a string at build time — keep the reading site single |
| the return of `JSON.parse` | a zod parser | the return is `any`, so **the type is cut off here** |

The last row is where this axis leaks most often. `any` raises no error and spreads silently.

## 2. Turn the checker on (`jsconfig.json`)

Turning on `checkJs` alone is not enough. **Without `strict`, a function whose comment is missing passes with
no error** — it is not "there is no type" but "it is not checked".

<!-- file: jsconfig.json -->
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "allowJs": true,
    "checkJs": true,
    "noEmit": true,
    "strict": true,
    "types": ["vite/client", "vitest/globals"]
  },
  "include": ["src", "test", "*.js"]
}
```

`scripts.typecheck` is `tsc --noEmit -p jsconfig.json`. tsc is **only the checker, not the language that
ships** — Vite builds the artifact and the `.js` goes out as it is. Run the same file with `strict: false` and
an uncommented parameter is **not reported even once.**
<!-- verified: run-compared with typescript@7.0.2 — strict on = TS7006 / off = no errors -->

## 3. The JSDoc type convention (common to every file except `src/schemas/task.js`)

- **An exported function carries both `@param` and `@returns`.** Miss either one and `any` starts
  right there, and from the caller's side it looks as though the error disappeared
- Bring type names in by **inline import** — add the `.js` extension
- An assertion is `/** @type {T} */ (value)` — **the parentheses are part of the syntax.** For a callback, attach it right at the argument

```js
// the consuming side — bring it in by inline import
/** @typedef {import('../schemas/task.js').Task} Task */

/** @type {Task[]} */
const tasks = [];
const titles = tasks.map(/** @param {Task} t @returns {string} */ ((t) => t.title));
```

tsc confirms that `titles` narrows to `string[]` — `titles[0].toFixed(2)` is an error.

## 4. The domain schema (`src/schemas/task.js`)

**The schema is the truth and the type is derived from it.** Put a hand-written `@typedef` beside the schema and
you have two copies, and two copies always diverge.

<!-- file: src/schemas/task.js -->
```js
// src/schemas/task.js
import { z } from 'zod';

export const TaskStatus = z.enum(['open', 'done']);

const taskInputFields = {
  title: z.string().min(1).max(200),
  status: TaskStatus,
};

export const TaskSchema = z.object({
  id: z.string().min(1),
  ownerId: z.string().min(1),
  ...taskInputFields,
  createdAt: z.iso.datetime(),
}).strict();

/** @typedef {import('zod').infer<typeof TaskSchema>} Task */

export const TaskCreateSchema = z.object({
  ...taskInputFields,
  status: TaskStatus.default('open'),
}).strict();

/** @typedef {import('zod').infer<typeof TaskCreateSchema>} TaskCreate */

export const TaskUpdateSchema = z.object(taskInputFields).partial().strict();

/**
 * @param {unknown} raw
 * @returns {Task}
 */
export function parseTask(raw) {
  const result = TaskSchema.safeParse(raw);
  if (!result.success) {
    const where = result.error.issues.map((i) => i.path.join('.')).join(', ');
    throw new Error(`Not the shape of a Task: ${where}`);
  }
  return result.data;
}
```

- **Do not build `TaskUpdateSchema` with `TaskCreateSchema.partial()`.** `.partial()` does not
  strip `.default('open')`, so a partial update that does not send `status` becomes `{ status: 'open' }`
  — a task that was marked done quietly comes back to life. Build each from a bundle of fields with no defaults
  <!-- verified: observed in node with zod@4.4.3 that Create.partial().parse({}) === {status:'open'} -->
- `createdAt` is **left as an ISO string and not turned into a `Date`.** It keeps the serialization boundary single
- `.strict()` blocks unknown keys — a field like `isAdmin` that the server added later does not flow
  straight in

The values of `TaskStatus` are **the lowercase `'open'`·`'done'`.** What goes on the wire·into a `data-*` attribute·into a test
assertion is this value, not the symbol name.

## 5. The boundary parser `parseTask` — where `@type` ends

`safeParse` does not throw; it gives back `{ success, data | error }`. Here **the contract is that the parser
throws** — it leaves the caller no way to ignore the failure and carry on. `error.issues[].path`
points at the field that is off.

```js
// ❌ the checker passes it but the runtime guarantee is zero
const task = /** @type {Task} */ (await res.json());
// ✅ parse again at the boundary
const task = parseTask(await res.json());
```

Feed `{ id: 't1', title: 'x' }` into each of the two lines and the first flows on with `task.status`
left `undefined`, while the second throws pointing at `ownerId, status, createdAt`. <!-- verified: both paths run with node -->

## 6. Validated environment values (`src/config.js`)

**It is the only file that reads the environment.** It parses at module top level, so a value that is off makes the boot fail —
blow up at the first request instead and the user sees a half-alive screen.

<!-- file: src/config.js -->
```js
// src/config.js
import { z } from 'zod';

const EnvSchema = z.object({
  VITE_API_BASE: z.url(),
  VITE_ENV: z.enum(['development', 'staging', 'production']),
});

const parsed = EnvSchema.safeParse(import.meta.env);

if (!parsed.success) {
  const missing = parsed.error.issues.map((i) => i.path.join('.')).join(', ');
  throw new Error(`Environment values are not valid: ${missing}`);
}

/** @typedef {import('zod').infer<typeof EnvSchema>} Config */

/** @type {Config} */
export const config = parsed.data;
```

**A value carrying the `VITE_` prefix is baked into the bundle as a string.** A secret cannot live here —
it stays as it is in the code that goes down to the browser. One reading site is what keeps that review in one place.

## 7. The test harness (`vite.config.js` · `test/setup.js`)

<!-- file: vite.config.js -->
```js
// vite.config.js
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'happy-dom',
    setupFiles: ['./test/setup.js'],
    include: ['test/**/*.test.js'],
  },
});
```

**Import `defineConfig` from `vitest/config`, not from `vite`.** Use the `test` key with the one from
`vite` and it runs, but the typecheck dies with `TS2769` — in this pack, which has the checker on, that blocks CI.
<!-- verified: reproduced with vite@8.2.2 + vitest@4.1.11 and confirmed resolved by swapping the import -->

<!-- file: test/setup.js -->
```js
// test/setup.js
import { afterEach } from 'vitest';

afterEach(() => {
  document.body.replaceChildren();
  window.history.replaceState(null, '', '/tasks');
});
```

happy-dom does not reset the DOM and History between files. A leftover node and a leftover URL passing the next
file's assertion is the most common false positive on this axis.

## 8. Tests that prove the block (`test/schemas.test.js`)

**A test that has only negative assertions is not a guard.** Replace the schema wholesale with `z.any()` and
a test holding only `expect(...).success).toBe(false)` can still be green. Pair the positive path with it **inside
the same `it`**.

<!-- file: test/schemas.test.js -->
```js
// test/schemas.test.js
import { describe, it, expect } from 'vitest';
import { TaskSchema, TaskCreateSchema, TaskUpdateSchema, parseTask } from '../src/schemas/task.js';

const valid = {
  id: 't1', ownerId: 'u1', title: 'Report draft',
  status: 'open', createdAt: '2026-08-24T03:00:00Z',
};

describe('TaskSchema', () => {
  it('a valid Task passes and an unknown key is blocked', () => {
    expect(TaskSchema.safeParse(valid).success).toBe(true);
    expect(TaskSchema.safeParse({ ...valid, isAdmin: true }).success).toBe(false);
  });

  it('status accepts lowercase only', () => {
    expect(TaskSchema.safeParse({ ...valid, status: 'done' }).success).toBe(true);
    expect(TaskSchema.safeParse({ ...valid, status: 'OPEN' }).success).toBe(false);
  });
});

describe('partial update', () => {
  it('create fills status in, update does not create a field that was not sent', () => {
    expect(TaskCreateSchema.parse({ title: 'a' })).toEqual({ title: 'a', status: 'open' });
    expect(TaskUpdateSchema.parse({ title: 'b' })).toEqual({ title: 'b' });
  });
});

describe('parseTask', () => {
  it('passes it at the boundary and throws when the shape differs', () => {
    expect(parseTask(valid).id).toBe('t1');
    expect(() => parseTask({ ...valid, createdAt: '2026-08-24' })).toThrow(/createdAt/);
  });
});
```

The second `describe` is the most expensive assertion in this file. Revert `TaskUpdateSchema` to
`TaskCreateSchema.partial()` and `toEqual({ title: 'b' })` goes red immediately —
that is the proof that "the block is alive". <!-- verified: vitest run executed on each of the two forms and compared -->

## 9. What not to test

| not written | instead |
| --- | --- |
| whether `z.string().min(1)` blocks an empty string | that is zod's test. Assert only **the composition of our own schemas** |
| a runtime assertion that checks whether a JSDoc type is right | `tsc --noEmit` renders that verdict. Put that command in CI |
| computed CSS values·the actual render result | happy-dom is a **proxy**. This axis cannot verify a real-browser round trip |
| the shape of the seam's `fetchTasks` response | it comes into being after assembly. The pack asserts only that `parseTask` blocks it |

## Misuse list ① — TypeScript · zod 3 habits → JSDoc + zod 4 idiom conversion table

| Old habit | The current form |
| --- | --- |
| `interface Task { … }` | `/** @typedef {import('zod').infer<typeof TaskSchema>} Task */` |
| `function f(x: string): Task {}` | `/** @param {string} x */` + `/** @returns {Task} */` |
| `value as Task` | `/** @type {Task} */ (value)` — the parentheses are required |
| `z.string().url()` · `z.string().datetime()` | `z.url()` · `z.iso.datetime()` <!-- verified: both forms run and compared with zod@4.4.3 --> |
| deriving the update schema with `.partial()` | build each from a bundle of fields with no defaults (§4) |
| `defineConfig` from `vite` + the `test` key | `defineConfig` from `vitest/config` (§7) |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `@type` vs `parseTask` | the former for a value I made, the latter for a value that came from outside the process |
| `.parse()` vs `.safeParse()` | the former when a failure means stopping (boot·tests), the latter when the flow has to continue |
| `TaskCreateSchema` vs `TaskUpdateSchema` | create fills the default in. Update **does not** |
| `checkJs` vs `strict` | the former turns the check on, the latter makes an uncommented parameter an error |
| `environment: 'happy-dom'` vs `'node'` | the former when you touch DOM·History, the latter is enough for a pure schema test |
| reading `import.meta.env` directly vs `config` | **always the latter.** Reading it directly is allowed only in `src/config.js` |
