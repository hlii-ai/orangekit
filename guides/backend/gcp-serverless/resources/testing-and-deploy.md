<!-- orangekit-pack: backend/gcp-serverless v3.14.0 -->
# Testing and deploy — run the app with no network, prove the block, and ship it as a container

What this file owns is three things: **the test harness** (`test/helpers.ts` — `appFetch`·`withEmulator`) ·
**the container definition** (`Dockerfile`) · **the runtime service account permissions**. A unit test file is
**owned by the resource that owns its target** — `test/errors.test.ts` by `error-handling.md`,
`test/schemas.test.ts` by `input-validation.md`. `startServer`·`shutdown` are owned by `project-structure.md`,
the repository by `data-access.md`, and the index declarations by `data-modeling.md`, while
`currentUser`·`authFor`·`apiRouter`·`AppError` are defined by **the seam** — here they are only called and replaced.

**This axis has no backup.** `firestore.rules` is a blanket deny and the server attaches with a service account and bypasses
the rules entirely. These tests are the only thing that observes the ownership boundary, and **that account is the real permission boundary.**

## 1. What gets run at which layer

| what is being confirmed | how it is run | emulator | what you miss by skipping this layer |
| --- | --- | --- | --- |
| schema rejection · the field error map | call the function directly | not needed | — (owned by `input-validation.md`) |
| gRPC code detection · status mapping | call the function directly + fixtures | not needed | — (owned by `error-handling.md`) |
| **ownership blocking · the list filter · cursors** | `appFetch(createApp(), …)` | **required** | swap the repository for a stub and a missing `where('ownerId', …)` becomes invisible |
| **a missing composite index** | **no layer catches it** | — | the emulator does not require an index — the first request in production dies with gRPC 9 |
| container boot · signal drain | actually bring the image up | — | not honoring `PORT`, and a drain that does not work, surface only in the deploy health check |

**The third row is the whole of this axis.** Ownership lives in the **query**, not in JavaScript — a test that swapped the repository
for a fake is green while keeping nothing. **The fourth row is a gap and it does not get filled**:
an index deploys as a separate artifact (section 6) and the emulator answers a composite query without one.

## 2. `appFetch` — it does not stand up a server (`test/helpers.ts`)

A Hono app is a function that takes a web-standard `Request` and returns a `Response`. `app.request()` calls that function
directly — no port, no socket, no `serve()`.

<!-- verified: on hono 4.13.4, instrumented net.Socket.connect · globalThis.fetch · net.Server.listen — all three 0 times across two requests -->
Confirmed by running it: while `GET /healthz` and `POST /echo` went through, socket connections·the global `fetch`·`server.listen` were all **0 times**.

<!-- verified: hono 4.13.4 dist/types/hono-base.d.ts:201 — the return is Response | Promise<Response>, and a non-Promise Response really does come out of a synchronous handler, as observed -->
**The return type of `app.request()` is `Response | Promise<Response>`.** That is why `appFetch` is **declared
`async`** — `return` it as it is and it does not match the ledger's `Promise<Response>`, so the strict check blocks it with `TS2322`.

<!-- file: test/helpers.ts -->
```ts
// test/helpers.ts
import type { Hono } from 'hono';
import { settings } from '../src/settings.js';

/** Runs the app directly with no network. async absorbs Response | Promise<Response>. */
export async function appFetch(app: Hono, path: string, init?: RequestInit): Promise<Response> {
  return app.request(path, init);
}

/** An emulator-only path. This guard is the only line that keeps the reset from aiming at the real database. */
function clearUrl(): string {
  const host = settings.FIRESTORE_EMULATOR_HOST;
  if (!host) throw new Error('FIRESTORE_EMULATOR_HOST is not set — this nearly attached to the real database');
  return `http://${host}/emulator/v1/projects/${settings.GCP_PROJECT_ID}/databases/(default)/documents`;
}

async function clearAll(): Promise<void> {
  const res = await fetch(clearUrl(), { method: 'DELETE' });
  if (!res.ok) throw new Error(`emulator reset failed: ${res.status}`);
}

export async function withEmulator(fn: () => Promise<void>): Promise<void> {
  await clearAll();
  try {
    await fn();
  } finally {
    await clearAll(); // a failed test does not contaminate the next one
  }
}
```

`settings` is owned by `src/settings.ts` — **the harness does not read the environment directly either.** Only the place it is injected (section 3) is the exception.

## 3. `withEmulator` — without a reset, the next test sees the previous document

**Look at the positive control first.** Two tests were chained with no isolation, and the second was made to count the list length.

<!-- verified: on firestore emulator v1.19.8 + vitest 4.1.11, chained three tests in one file and printed the list length -->
| test | what it did | list length |
| --- | --- | --- |
| A | created 1 document without `withEmulator` | 1 |
| B | created nothing and only queried the list | **1 — it is the previous test's document** |
| C | the same query inside `withEmulator` | **0** |

B is the basis of this section. The leak is not "sometimes" but **always**, and the direction happens to be documents **increasing**, so
list·pagination tests quietly measure something else. **Do not delete the collections one by one**: the reset
endpoint empties the whole database at once, and a hand-written list of collections goes stale the day a new collection appears.

**Do not run the test files in parallel.** They share one and the same emulator database, so one file's
reset lands **in the middle** of another file's test.

<!-- verified: ran the same three files changing only fileParallelism — with true all 3 failed (documents seen: 1·1·4), with false all 3 passed -->
Confirmed by running it: three files that create 5 documents and count them, run with `fileParallelism: true`, **all three failed** (they saw 1·1·4
respectively). The failure wording is "the lengths differ", so **it never surfaces that the cause is isolation.**

<!-- file: vitest.config.ts -->
```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    env: { // settings parses at module top level — put it in beforeAll and it is too late
      GCP_PROJECT_ID: 'demo-tasks',
      IDENTITY_PLATFORM_PROJECT_ID: 'demo-tasks',
      FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
    },
    fileParallelism: false, // there is one emulator database
    testTimeout: 30_000,    // a worker's first Firestore round trip goes over 3 seconds
  },
});
```

<!-- verified: observed a test including the first Firestore round trip at 3.1–3.5 seconds, and the tests after it at 20–350ms -->
`testTimeout` came from the measurement — the first round trip was 3.1–3.5 seconds and the rest 20–350ms. The default 5 seconds trips
on that one alone and **makes a red caused by a timeout read as an isolation defect.**

## 4. Dependency override and block proof (`test/tasks.test.ts`)

`createApp()` **takes no argument** (the ledger) and the router imports `currentUser` straight from the module.
There is no injection point, so **module replacement is the only place**. The replacement is not a convenience — a valid Identity Platform
ID token has its signing key at Google, so a test cannot build one (the verification logic is confirmed by `identity-tokens.md`).
`authFor(ownerId, roles?)` is **synchronous** — do not `await` it.

**Attach the positive pair inside the same `it`.** Only an assertion that the owner receives a 200 separates a 404 that means "blocked" from one that means "everything is broken" (section 5).

<!-- file: test/tasks.test.ts -->
```ts
// test/tasks.test.ts
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Context, Next } from 'hono';
import { appFetch, withEmulator } from './helpers.js';
import { authFor, type AuthUser } from '../src/http/auth.js';
import { createApp } from '../src/app.js';
import { createTask } from '../src/firestore/tasks.js';

// The vi.mock factory is hoisted to the top — hoist the subject box with vi.hoisted along with it.
const ctx = vi.hoisted(() => ({ user: null as AuthUser | null }));
vi.mock('../src/http/auth.js', async (orig) => ({
  ...(await orig<typeof import('../src/http/auth.js')>()),
  currentUser: async (c: Context, next: Next) => { c.set('user', ctx.user); await next(); },
}));

const asUser = (id: string) => { ctx.user = authFor(id); };
const read = (taskId: string) => appFetch(createApp(), `/api/tasks/${taskId}`);
beforeEach(() => asUser('alice'));

describe('ownership blocking', () => {
  it('the owner receives a 200 and everyone else a 404', async () => {
    await withEmulator(async () => {
      const mine = await createTask('alice', { title: 'my task', status: 'open' });
      // ✅ the positive pair. Without this line the 404 below could be "everything is broken", not "blocked"
      expect((await read(mine.id)).status).toBe(200);
      asUser('bob');
      const res = await read(mine.id);
      expect(res.status).toBe(404);
      expect(res.status).not.toBe(403); // a 403 is proof of existence — it says "that document is there"
    });
  });
});
```

<!-- verified: ran the same test as a static-import version and a dynamic-import version — the replacement applied in both and both passed -->
**A static import is enough** — `vi.mock` swaps the module registry first, so there is no need to pull it in late with
`await import()`. Both versions were run and confirmed.

**The replacement stops at `currentUser`.** Replace the repository or `firestore` too and the place ownership lives
disappears from the test — you are watching your own stub answer the way you expected it to. What may be replaced is
**what the axis does not own**, that is, the seam's credential wiring and nothing else.

## 5. Confirm it with mutations — the result of running it beside a version with the pair removed

A version with the single positive-pair line removed was built from the same test and run alongside it.
```ts
// ❌ the negative assertion only — this is not a guard
it("reading someone else's gives a 404", async () => {
  const mine = await createTask('alice', { title: 'my task', status: 'open' });
  asUser('bob');
  expect((await read(mine.id)).status).toBe(404);
});
```

<!-- verified: on firestore emulator v1.19.8, put both versions in the same run and instrumented 3 kinds of mutation one at a time -->
| the mutation planted (**all three pass the type check**) | negative assertion only | the paired assertion |
| --- | --- | --- |
| the whole body of `getTask` replaced with `return null` | **green** | red |
| deleting the **one line** of the `doc.ownerId !== ownerId` check | red | red |
| flipping the call site to `getTask(taskId, ownerId)` | **green** | red |

**The first and third rows are the point.** Disable the implementation wholesale, or flip the argument order the ledger warned about, and
a test with only the negative assertion **stays green** — because in that state every read gives a 404.
In the third row both arguments are `string`, so the type check does not filter it out either — the wall that remains is **the one line saying
the owner receives a 200**. The second row shows the negative assertion catches something too, but what it catches is **only that one deleted line**.

**Make it a habit: delete one line of a check and run again.** If it does not go red, that test is not keeping
that check. A guard that survives is not something to delete but **something whose description needs fixing** — the pilot
saw the `typeof code === 'number'` guard in `src/firestore/errors.ts` survive and corrected its description
from "the only wall" to "defense in depth" (section 2 of `error-handling.md`).

## 6. The container and the deployment artifacts (`Dockerfile`)

There are three contracts — **`PORT` is read from the environment** · **node is PID 1** · **the indexes go out separately.**

<!-- file: Dockerfile -->
```dockerfile
# Dockerfile
FROM node:22-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npx tsc   # tsconfig's outDir has to be dist. Keep noEmit in the type-check-only script

FROM node:22-slim
ENV NODE_ENV=production
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
USER node
# It is the exec form. node has to be PID 1 for SIGTERM to reach the drain handler (src/main.ts).
CMD ["node", "dist/main.js"]
```

**Do not write the port into the image.** Cloud Run injects `PORT` and `settings.PORT` reads it — a hard-coded
8080 fails the health check the moment it diverges from the injected value, and there is no error at all in the log.

**What is dangerous is not the "shell form" but node not being PID 1.**

<!-- verified: on darwin · node 24.7.0 · npm 11.5.1, sent SIGTERM to each startup form and instrumented whether the handler was reached and the exit code. This is not the PID 1 environment of a Linux container -->
| startup form | does the drain handler run | exit code |
| --- | --- | --- |
| `["node", "dist/main.js"]` | **it runs** | 0 |
| `sh -c 'node dist/main.js'` | it runs — the shell replaces itself with `exec` | 0 |
| `sh -c 'node dist/main.js; echo done'` | **it does not run** — a command follows, so no `exec` happens | the shell dies on SIGTERM |
| `["npm", "start"]` | it runs (npm forwards it) | **1 — a normal drain is recorded as a failure** |

The third row removes the 10-second drain entirely. In the fourth the drain happens, but the log does not tell a normal exit from
a crash. **The indexes are not in the image** — `firestore.indexes.json` is **a separate artifact** deployed to Firestore, and the order is fixed too: the indexes come first.

<!-- unverified: this environment has no gcloud·firebase CLI and no docker daemon, so the two commands below could not be run -->
```bash
firebase deploy --only firestore:indexes,firestore:rules   # first. The rules are a blanket deny
gcloud run deploy tasks-api --source . --region=asia-northeast3 \
  --service-account=tasks-api-run@PROJECT.iam.gserviceaccount.com --no-allow-unauthenticated
```

## 7. Service account least privilege — it is the credential that bypasses the rules

This account bypasses `firestore.rules` entirely. **That is why this is the real permission boundary**, and tightening the rules
changes nothing on this axis.

| for what | role | why that line |
| --- | --- | --- |
| the runtime (Cloud Run) | `roles/datastore.user` | document CRUD, and no further |
| what the runtime **is not given** | `roles/datastore.owner` | it contains database administration·deletion — a compromised container would be able to delete <!-- unverified: the per-role permission lists were not compared --> |
| index·rule deploys | `roles/datastore.indexAdmin` <!-- unverified: the role name was not confirmed --> | give it to the deploy pipeline account. **Do not use the same account** as the runtime |
| ID token verification | **no role is needed** | JWKS is a public endpoint — this axis's authentication uses IAM not at all |
| service-to-service calls | `roles/run.invoker` | service IAM decides it, not the application (section 1 of `identity-tokens.md`) |

**Always state `--service-account`.** Leave it out and the project default account attaches, and its permissions are written nowhere in the deploy command, so **they cannot be reviewed** <!-- unverified: the current default roles of the default account were not confirmed -->.

<!-- verified: attached to the emulator with no credentials and a project ID that does not exist, and observed reads·writes·transactions all succeed -->
**The tests do not use this account.** Confirmed by running it, **with no credentials and a project ID that does not exist**,
reads·writes·transactions all succeeded — a green integration test **in no way means** the permissions are right, and
a permission defect only surfaces at the first write after deploy.

## Misuse list ① — old idioms → current shape comparison table

| old habit | the current shape (this axis) |
| --- | --- |
| standing up a server with supertest and making a request | `appFetch(createApp(), path)` — it takes no port |
| testing the rules with `@firebase/rules-unit-testing` | this axis's rules are a blanket deny and the server bypasses them — there are no rules to test |
| jest's `jest.mock` + a `__mocks__` directory | `vi.mock` + `vi.hoisted` — the factory runs before a top-level `const` |
| `CMD npm start` | `CMD ["node", "dist/main.js"]` — exit code 0 is what leaves it recorded as a normal drain |
| `EXPOSE 8080` + a hard-coded port | `settings.PORT` reads the value Cloud Run injects |

## Misuse list ② — confusion pairs

| what gets picked wrong often | the exact condition for applying it |
| --- | --- |
| a negative assertion vs a paired assertion | a 404 on its own is indistinguishable from "everything is broken". It is a block only with the 200 pair |
| replacing `currentUser` vs replacing the repository | the first is the seam's, so replacing it is fine. Replace the second and there is nothing left to keep |
| passing the emulator vs the index existing | the emulator does not require an index — passing proves nothing about an index |
| passing the emulator vs IAM permissions | the emulator does not look at credentials — passing proves nothing about permissions |
| the leading reset vs the `finally` reset | attach both. The first blocks the residue of an earlier run, `finally` the residue of a failed test |
