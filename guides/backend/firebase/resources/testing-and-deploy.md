<!-- orangekit-pack: backend/firebase v3.14.0 -->
# Testing and deploy — the emulator is the only evidence

`firebase.json` · `functions/test/emulator.ts`(`emulatorEnv` · `withRulesTest` · `RULES`) ·
`functions/test/tasks.test.ts` (function and repository regression) and the index deploy order.

**This file does not own the rules unit tests** — `functions/test/rules.test.ts` is the share of
`resources/security-rules.md` (one owner per path). The schemas belong to
`resources/input-validation.md`, the repository to `resources/data-access.md`, and `AppError` and `authFor` are owned by
**the seam** (`functions/src/http/`).

## 1. Decision tree — what is proved with which harness

| what to prove | harness | owner |
| --- | --- | --- |
| The ownership invariants of `firestore.rules` | `withRulesTest` + `assertFails`/`assertSucceeds` pairs | `security-rules.md` |
| The entry point's ownership, validation and error envelope | `onCall(...).run(req)` + the Firestore emulator | This file |
| Schemas and configuration parameter resolution | Direct calls to `parseCallable` and `config()` | This file |
| The wire contract (status, body) | `emulators:exec` + a real request | This file |
| Composite indexes | **Cannot be done with the emulator** | Only a real project deploy |

**Do not use `firebase-functions-test`.** 3.5.0's peer is `firebase-admin@^8…^13`, which collides with admin 14 as
ERESOLVE and fails the whole toolchain install. The alternative path is `.run(request)` on the object `onCall` returns,
and the type declaration describes it as *"Used for unit testing"*.
<!-- verified: firebase-functions@7.3.2 v2/providers/https.d.ts:181-186 -->

## 2. Emulator suite (`firebase.json`)

<!-- file: firebase.json -->
```json
{
  "firestore": { "rules": "firestore.rules", "indexes": "firestore.indexes.json" },
  "functions": [{ "source": "functions", "codebase": "default", "runtime": "nodejs22" }],
  "emulators": {
    "auth": { "port": 9099 }, "firestore": { "port": 8080 }, "functions": { "port": 5001 },
    "singleProjectMode": true, "ui": { "enabled": false }
  }
}
```

With a `demo-` prefixed project ID (`demo-tasks`) the CLI attaches in demo mode and refuses every real-service
access. In CI, `emulators:exec` is canonical — **it propagates the exit code verbatim**. `firebase-tools@15`
requires **JDK 21 or newer** (Temurin 17 refuses to start). <!-- verified: measured in the pilot (C1) · fact settled by L0 -->

```bash
firebase emulators:exec --project demo-tasks --only firestore,auth,functions "cd functions && npm test"
```

**When a parameter does not resolve from `.env`, the CLI creates `functions/.env.local` with the declared defaults
and leaves it there.** From the next run on, `.env.local` beats `.env`, so editing `.env` changes nothing. Put both files and
`.secret.local` in `.gitignore`.
<!-- verified: deleted .env and measured .env.local being generated automatically and taking precedence after one emulators:exec -->

## 3. Test wiring (`functions/test/emulator.ts`)

<!-- file: functions/test/emulator.ts -->
```ts
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { initializeTestEnvironment, type RulesTestEnvironment } from '@firebase/rules-unit-testing';

const ROOT = resolve(__dirname, '../..');
const FUNCTIONS = resolve(__dirname, '..');
type Ports = { emulators: { firestore: { port: number }; auth: { port: number } } };
const CONFIG = JSON.parse(readFileSync(resolve(ROOT, 'firebase.json'), 'utf8')) as Ports;
export const PROJECT_ID = 'demo-tasks';
export const RULES = readFileSync(resolve(ROOT, 'firestore.rules'), 'utf8');

export function emulatorEnv(): void {
  const { firestore, auth } = CONFIG.emulators;
  process.env['GCLOUD_PROJECT'] = PROJECT_ID;
  process.env['FIRESTORE_EMULATOR_HOST'] = `127.0.0.1:${firestore.port}`;
  process.env['FIREBASE_AUTH_EMULATOR_HOST'] = `127.0.0.1:${auth.port}`;
  // The emulator variables alone do not stop the admin SDK from looking up real credentials
  process.env['GCE_METADATA_HOST'] = '0';
  // vitest is not firebase-tools — it has to read the parameter files itself for .value() to be filled
  for (const f of ['.env', '.env.local', '.secret.local']) {
    const p = resolve(FUNCTIONS, f);
    if (existsSync(p)) process.loadEnvFile(p);
  }
}

export async function withRulesTest(fn: (env: RulesTestEnvironment) => Promise<void>) {
  emulatorEnv();
  const env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: RULES, host: '127.0.0.1', port: CONFIG.emulators.firestore.port },
  });
  try {
    await env.clearFirestore();
    await fn(env);
  } finally {
    await env.cleanup();
  }
}
```

ⓐ Read the ports from `firebase.json` — copy them as constants and the suite and the tests go green while looking at
different ports. ⓑ Read the rules **from the shipped file** (`RULES`) — inline them and nobody checks the file that
is deployed. ⓒ Put `cleanup()` in `finally`. ⓓ `vitest` is not `firebase-tools` and does not read
`functions/.env` — before this wiring, `config()` saw empty values and died.
<!-- verified: ⓓ — before the wiring the configuration check failed with "Too small: expected string to have >=16" -->

<!-- file: functions/test/setup.ts -->
```ts
import { emulatorEnv } from './emulator';
emulatorEnv(); // has to run before importing src/ — beforeAll is too late
```

<!-- file: functions/vitest.config.mts -->
```ts
import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    setupFiles: ['./test/setup.ts'],
    fileParallelism: false,   // two files would delete the same emulator documents
    testTimeout: 20_000,
    hookTimeout: 20_000,
  },
});
```

The extension is `.mts` because `functions/package.json` says `"type": "commonjs"`, and
`setupFiles` is needed because `emulatorEnv()` has to run **before any `src/` import** —
the Firestore client is grabbed at module top level, so `beforeAll` is too late.

## 4. Function and schema regression (`functions/test/tasks.test.ts`)

<!-- file: functions/test/tasks.test.ts -->
```ts
import { describe, expect, it } from 'vitest';
import type { CallableRequest } from 'firebase-functions/v2/https';
import { tasksCreate, tasksGet } from '../src/index';
import { TaskUpdateSchema, parseCallable } from '../src/schemas/task';
import { config } from '../src/params';

// A local fixture — `authFor` is owned by the seam (functions/src/http/auth.ts), so the name is avoided
const fakeAuth = (uid: string): NonNullable<CallableRequest['auth']> =>
  ({ uid, rawToken: '', token: { uid } as unknown as NonNullable<CallableRequest['auth']>['token'] });
const call = (uid: string | null, data: unknown) =>
  ({ ...(uid ? { auth: fakeAuth(uid) } : {}), data, rawRequest: {} }) as CallableRequest;

describe('function entry points — called directly through .run()', () => {
  it('the owner reads their own task and others get not-found', async () => {
    const made = await tasksCreate.run(call('alice', { title: 'Task one' }));
    expect(made.status).toBe('open');
    const done = await tasksCreate.run(call('alice', { title: 'Finished task', status: 'done' }));
    expect(done.status).toBe('done'); // the value that was sent is not discarded
    expect((await tasksGet.run(call('alice', { taskId: made.id }))).title).toBe('Task one');
    await expect(tasksGet.run(call('mallory', { taskId: made.id })))
      .rejects.toMatchObject({ code: 'not-found' });
  });

  it('a missing token and an unknown field fold into their own codes', async () => {
    await expect(tasksCreate.run(call(null, { title: 'x' })))
      .rejects.toMatchObject({ code: 'unauthenticated' });
    await expect(tasksCreate.run(call('alice', { title: 'x', ownerId: 'mallory' })))
      .rejects.toMatchObject({ code: 'invalid-argument' });
  });

  it('a partial update keeps only the fields sent and an empty patch is refused', () => {
    expect(parseCallable(TaskUpdateSchema, { title: 'New title' })).toEqual({ title: 'New title' });
    expect(() => parseCallable(TaskUpdateSchema, {})).toThrow();
  });

  it('the configuration is validated only once per instance', () => {
    expect(config().TASKS_WEBHOOK_KEY.length).toBeGreaterThanOrEqual(16);
    expect(config()).toBe(config());
  });
});
```

**The entry point names differ from the repository symbols** — import `tasksGet`/`tasksCreate`.
Write `getTask`/`createTask` and it is `TS2459`, and measured, that name collision kept the suite from even
loading. **`tasksGet` does not return `null`**: when the document is absent or owned by someone else it throws `AppError('NOT_FOUND')`
and `withErrors` moves it onto `HttpsError('not-found')` — returning `null` is the contract of the repository's `getTask`,
not of the callable. `AuthData` is not re-exported, so it is referenced as
`NonNullable<CallableRequest['auth']>`, and `rawToken` is required (omit it and you get TS2741).
`.run()` skips the HTTP layer and exercises **the admin path that bypasses the rules** — which is why the negative
ownership assertions are the most valuable ones.

## 5. Block proof — the table of what went red when deleted

A test that is alive and a test that works are different things. Below is **the result of planting one defect at a time in the
`tasks.test.ts` this file ships (4 green) and running `emulators:exec`.**

| planted defect | result |
| --- | --- |
| `TaskCreateSchema` as `z.object` | 1 FAIL — `promise resolved "{ id: … }" instead of rejecting` |
| `TaskUpdateSchema` derived from `TaskCreateSchema.partial()` | 1 FAIL — `{title,status:'open'}` ≠ `{title}` |
| Removing `TaskUpdateSchema`'s `.refine` | 1 FAIL — `expected [Function] to throw an error` |
| Removing `getTask`'s ownership check | 1 FAIL — someone else's document comes back |
| `getTask` turned wholesale into `return null` | 1 FAIL — **the positive pair caught it** |
| `createTask` hard-coding `status` | 1 FAIL — `expected 'open' to be 'done'` |
| `requireUid` as `req.auth?.uid ?? 'anonymous'` | 1 FAIL — a token-less call passes |
| `tasksGet` returning `null` instead of `NOT_FOUND` | 1 FAIL — `promise resolved "null" instead of rejecting` |
| `.secret.local` under 16 characters | **2** FAIL — the configuration validation blocked two paths |

<!-- verified: planted each of the 9 defects and ran emulators:exec, measuring the exit code and the failure message -->

**Rules-family defects are not measured here** — `functions/test/rules.test.ts` is owned by `security-rules.md`,
so its block proof table belongs to that file too. Have two files each measure the same defect and the two tables'
conclusions diverge — and measured, they actually did.

## 6. Indexes · deploy order · irreversible changes

**The emulator does not enforce composite indexes.** With `"indexes": []`,
`where('ownerId','==') + orderBy('createdAt','desc')` passed, and even with `firestore.indexes.json`
**carrying a JSON syntax error (`{ "indexes": [ broken ] }`) it started up and ran every query.** That the silence is not a
measurement failure is guaranteed by **two positive controls** on the same apparatus: an `in` with 31 values was refused as
`INVALID_ARGUMENT: 'IN' supports up to 30 comparison values.`, and breaking `firestore.rules`
was reported as `Error compiling rules: L2:1 mismatched input '<EOF>'`. **Only the indexes stayed silent.**
<!-- verified: left indexes.json as an empty array / with a syntax error and measured 4 kinds of admin SDK query · including the 2 controls -->

The target order of `firebase deploy` is not the order written in `--only` but a fixed order the CLI carries:
database → storage → **firestore → functions** → hosting. Within firestore it is **rules → indexes**,
and index creation is a single POST, so **it does not wait for completion.**
<!-- verified: firebase-tools@15.28.1 deploy/index.js:30-42 · filterTargets.js:6-16 · deploy/firestore/deploy.js · firestore/api.js:356-366 -->

The order is kept but completion is not guaranteed — for a function using a new query, deploy the index first and
ship it after seeing `Enabled` in the console. <!-- unverified: this needs a real project deploy, so it could not be measured -->
Existing indexes absent from the file are **not deleted by default**: interactively it asks for confirmation (defaulting to no),
`--non-interactive` only logs, and only `--force` deletes — make `--force` a habit in CI and
from then on the index file holds delete authority.
<!-- verified: firebase-tools@15.28.1 firestore/api.js:85-121 -->

`firebase deploy` authenticates first, so **offline it never even reaches the index file validation** —
even a JSON syntax error comes after `Failed to authenticate`. The only local validation is calling the CLI's internal
`validateSpec` directly, and that is pinned as a pre-deploy script.

<!-- file: scripts/check-indexes.mjs -->
```js
import { readFileSync } from 'node:fs';
import { FirestoreApi } from 'firebase-tools/lib/firestore/api.js';
const api = new FirestoreApi();
try {
  api.validateSpec(api.upgradeOldSpec(JSON.parse(readFileSync('firestore.indexes.json', 'utf8'))));
} catch (e) {
  console.error(`firestore.indexes.json is invalid: ${e.message}`);
  process.exit(1);
}
```

It catches `order: "ASC"` (the correct value is `ASCENDING`) and exits 1. **It misses a missing `queryScope`** — it is a
value-typo filter, not a substitute for server validation. <!-- verified: planted each of the two defects and measured exit codes 1 and 0 -->
The deploy is pinned to the order `check-indexes` → `emulators:exec` tests → `--only firestore:rules,firestore:indexes` →
(confirm `Enabled` in the console) → `--only functions`.

Four irreversible things. ① **Deleting an index** backfills the whole collection when it is rebuilt. ② **Renaming an export**
means a function deletion plus a new creation, because the manifest's endpoint key is the export name, and the URL and minimum
instances are reset. ③ **A rules deploy is a full replacement**, so a block you left out disappears. ④ **A subcollection
is left orphaned even after its parent is deleted.** <!-- verified: ② from the manifest's endpoints.tasksCreate.entryPoint · ④ measured in the pilot (C1) (L0) -->

## Misuse list ① — `firebase-functions-test` → emulator

| old habit | current form |
| --- | --- |
| Wrapping with `firebase-functions-test` · `test.wrap(fn)` | Call `onCall(...).run(request)` directly |
| `firebase.initializeTestApp({ auth })` · `firebase.loadFirestoreRules({ rules })` | `env.authenticatedContext(uid)` · `initializeTestEnvironment({ firestore: { rules } })` |
| `firebase.clearFirestoreData()` · `firebase.apps().map((a) => a.delete())` | `env.clearFirestore()` · `env.cleanup()` |
| Inlining the rules string inside the test | `readFileSync('firestore.rules')` — check the shipped file |
| `vitest --reporter=basic` | `vitest@4` removed it. Use the default reporter <!-- verified: confirmed by the loader error in the pilot (C1) · fact settled by L0 --> |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `emulators:start` vs `emulators:exec` | The first during development, the second in CI. Only `exec` propagates the exit code |
| `getTask` (repository) vs `tasksGet` (entry point) | The first returns `null`, the second throws `not-found`. What the tests import is the second |
| `authFor` vs `fakeAuth` | The first is seam-owned. When a pack test makes a principal, it uses a different name |
| `assertSucceeds` vs `await` · `clearFirestore()` vs `cleanup()` | The first pair is the same (a no-op) · the second is data only vs the environment itself |
| Emulator green = indexes fine | It is not. They are neither enforced nor checked |
| `vitest.config.ts` vs `.mts` | In a `"type": "commonjs"` package, `.mts` |
| `.env` vs `.env.local` | When the CLI generates it, that one wins. `.gitignore` both |
