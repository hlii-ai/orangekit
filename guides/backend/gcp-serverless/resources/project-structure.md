<!-- orangekit-pack: backend/gcp-serverless v3.14.0 -->
# Project structure — one-way layering and the lifetime of a single container

What this file owns is three things: **the place the app is assembled** (`src/app.ts`) · **the place the process is
brought up and taken down** (`src/main.ts`) · **the place that records what happened** (`src/obs/log.ts`).
`installErrorHandlers` · `apiRouter` · `AppError` are **owned by the seam** (`src/http/handlers.ts` ·
`src/http/routes.ts` · `src/errors.ts`) — here they are only called. `settings`, which reads environment values, is
owned by `input-validation.md` (`src/settings.ts`), and **this file never reads the environment directly.**

## 1. Where new code goes — the layer decision table

**Layering runs one way**: `routes → services → firestore`. When a lower row imports an upper one, that layering has
already collapsed, and the symptom shows up as "the data-layer tests only run once they stand up HTTP".

| what that code does | where it goes | what that layer may know |
| --- | --- | --- |
| touches the request·response (`Context` · status · headers) | `src/http/` — **owned by the seam** | Hono · the codes of `AppError` |
| decides "who may do what" | `src/services/tasks.ts` | schema types · the repository · `AppError` |
| reads and writes documents | `src/firestore/` | the Firestore SDK · schema types — **knows nothing about HTTP** |
| decides the shape of the input | `src/schemas/` (`input-validation.md`) | zod and domain types, nothing else |
| brings the process up and down | `src/main.ts` · `src/app.ts` | everything |
| records what happened | `src/obs/log.ts` | `settings` and nothing else |

**One rule for when the call is close**: if that code has to know an HTTP status code or a `Context`, do not push it
down — **pull it up.** Let a status into the repository once and from then on the service passes it
straight through, and undoing it means touching every layer again.

## 2. `createApp` (`src/app.ts`) — it takes no request

`createApp()` **takes no argument and only assembles.** The moment it takes a request, the tests can no longer
stand up a fresh app, and the app instance freezes into a process global.

<!-- file: src/app.ts -->
```ts
// src/app.ts
import { Hono } from 'hono';
import { installErrorHandlers } from './http/handlers.js';
import { apiRouter } from './http/routes.js';

/** Takes no request — it only assembles. That is what lets the tests stand up a new app every time. */
export function createApp(): Hono {
  const app = new Hono();
  // The health check goes through neither auth nor Firestore.
  app.get('/healthz', (c) => c.body(null, 204));
  app.route('/api', apiRouter);
  installErrorHandlers(app);
  return app;
}
```

<!-- verified: on hono 4.13.4, registered onError before and after route respectively and drove /api/boom through — both were caught as a 500 -->
**Where `installErrorHandlers(app)` is called has nothing to do with registration order.** `app.onError`·`app.notFound` are
properties of the app rather than links in the middleware chain, so attached before or after `app.route()` they catch what a
child router throws. Confirmed by running it, both orders folded `/api/boom` into a 500.

<!-- verified: on hono 4.13.4, attached its own onError to the sub-router and one to the parent as well — the sub-router's won (599) -->
**But once a child router has its own `onError`, the parent's does not run.** Confirmed by running it, attaching an
`onError` to `apiRouter` meant the handler in `createApp` never executed once — everything under `/api`, the whole API,
goes out in a different envelope. **The one place `onError` is attached is this file.**

**Why the health check touches no dependency**: a `/healthz` that pokes Firestore once sounds plausible, but
the moment it does, a data-layer outage becomes **a failed deploy.** Containers that are alive get replaced along with it.

## 3. `startServer` (`src/main.ts`) — it binds to `0.0.0.0`

The port **comes from `settings.PORT`.** Let this file read the environment directly and validation, the default, and boot-time
failure are all bypassed, and that fact only surfaces once it is deployed.

<!-- verified: brought the same server up twice changing only the hostname and curled the loopback and the interface address respectively -->
Bind to `localhost` (=`127.0.0.1`) and **it cannot be reached from outside the container.** Confirmed by running it, the listen socket was taken
as `127.0.0.1:8801`, the loopback gave 200, and the interface address of the same host (`192.168.0.142:8801`)
failed to connect at all. Bind to `0.0.0.0` and the socket becomes `*:8801`, and both gave 200.
<!-- unverified: with no real Cloud Run deploy, "the health check dies and the deploy rolls back" was not observed — what was observed goes as far as unreachability at the interface level -->
Cloud Run's health check comes from outside the container.

## 4. `shutdown` (`src/main.ts`) — call it **inside** the signal handler

`shutdown(server)` **is the function that performs the drain.** The contract is the call site, not the name.

<!-- file: src/main.ts -->
```ts
// src/main.ts
import { serve, type ServerType } from '@hono/node-server';
import { createApp } from './app.js';
import { firestore } from './firestore/client.js';
import { log } from './obs/log.js';
import { settings } from './settings.js';

/** What Cloud Run gives you after SIGTERM is 10 seconds. Finish inside that. */
const DRAIN_DEADLINE_MS = 8_000;

export function startServer(): ServerType {
  return serve(
    // It is 0.0.0.0. localhost is the loopback inside the container, unreachable from outside.
    { fetch: createApp().fetch, port: settings.PORT, hostname: '0.0.0.0' },
    (info) => log('info', 'listening', { port: info.port, address: info.address }),
  );
}

export async function shutdown(server: ServerType): Promise<void> {
  log('info', 'drain start');
  const drained = new Promise<void>((resolve) => {
    server.close(() => resolve());
    if ('closeIdleConnections' in server) server.closeIdleConnections();
  });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<void>((resolve) => { timer = setTimeout(resolve, DRAIN_DEADLINE_MS); });
  await Promise.race([drained, deadline]);
  clearTimeout(timer);
  await firestore.terminate();
  log('info', 'drain done');
}

const server = startServer();
// shutdown is called only here. Call it at the top level and the container exits right after boot.
process.on('SIGTERM', () => { void shutdown(server); });
```

```ts
// ❌ top-level call — the server closes itself the moment it comes up. The container fails to boot
const booted = startServer();
await shutdown(booted);
```

<!-- verified: brought each of the two shapes up as its own process and instrumented stdout and port reachability -->
Both shapes were brought up and instrumented side by side.

| where it is called | what was observed |
| --- | --- |
| top level | `drain start` printed at **2ms** and `listening` **never printed once.** Three seconds later the process was gone and the port refused connections |
| inside the `SIGTERM` handler | sending the signal while a 1.5-second request was in flight ended that request with **200 · a complete body**, and the drain completed 1.1 seconds after that. The process exited on its own |

**Why there is a deadline**: wait on the drain indefinitely and Cloud Run kills the process outright after 10 seconds,
at which point `firestore.terminate()` never runs. 8 seconds is the value that gives up before that.

<!-- verified: left one idle keep-alive socket (response header `connection: keep-alive`, 1 open socket) and instrumented the close() callback delay — 0ms both with and without. Note the measured runtime was Node 24.7.0 while this axis targets Node 22 -->
`closeIdleConnections()` was **defense in depth** on the runtime measured — remove it and measure again and the `close()`
callback still came immediately (Node closes idle keep-alive connections by itself). It stays anyway: that behavior is
a property internal to Node and not our contract, and **it could not be measured directly on the target runtime (22).**

## 5. The lifetime of a single container — cold start · concurrency

**Cloud Run is a resident process.** All four decisions of this pack (Firestore client reuse · the JWKS cache ·
SIGTERM drain · module-top-level `settings`) stand on that premise.

| point in time | what runs | and so |
| --- | --- | --- |
| cold start | module top level runs **once per instance** | a `settings` parse failure is **a boot failure** — no half-alive container comes into being |
| request handling | many requests use the same module instance **at the same time** <!-- unverified: no real Cloud Run — the default concurrency value was not observed --> | do not put **per-request mutable state** at module top level. Put only what is shared read-only, such as the client·caches |
| after the response | CPU is not guaranteed outside a request <!-- unverified: no real Cloud Run --> | a "clean it up later" promise run after the response was sent can stay frozen until the next request |
| SIGTERM | drain time is **10 seconds** (frozen by L0) | the deadline in section 4 finishes before that |

Build `new Firestore()` or `createRemoteJWKSet()` inside a request and the first row of this table becomes meaningless —
the cache is thrown away per request, gRPC channels pile up, and every request round-trips to Google.

## 6. `log` (`src/obs/log.ts`) — the key is `severity`, not `level`

<!-- unverified: with no real GCP project, whether Cloud Logging actually reads this key as the severity was not observed. The value set follows the documentation -->
The key Cloud Logging reads as the severity is **`severity`**, and the values are a fixed set too — it is `WARNING`,
not `warn`. Emit `level: 'warn'` and every log clumps into a single severity, leaving the filter powerless.

<!-- file: src/obs/log.ts -->
```ts
// src/obs/log.ts
import { settings } from '../settings.js';

type Level = 'info' | 'warn' | 'error';

// The key Cloud Logging reads as the severity is `severity`, not `level`, and the values are this set too.
const SEVERITY: Record<Level, string> = { info: 'INFO', warn: 'WARNING', error: 'ERROR' };
const RANK: Record<Level, number> = { info: 10, warn: 20, error: 30 };

export function log(level: Level, message: string, fields?: Record<string, unknown>): void {
  if (RANK[level] < RANK[settings.LOG_LEVEL]) return;
  let line: string;
  try {
    line = JSON.stringify({ severity: SEVERITY[level], message, ...fields });
  } catch {
    // A circular reference·BigInt makes stringify throw. A logging failure must not kill the request.
    line = JSON.stringify({ severity: SEVERITY[level], message, logError: 'unserializable fields' });
  }
  process.stdout.write(line + '\n');
}
```

<!-- verified: ran the file above as-is and captured stdout -->
The instrumented output, and two traps.

| what was called | the line that came out |
| --- | --- |
| `log('warn', 'id token rejected', { reason: 'ERR_JWT_EXPIRED' })` | `{"severity":"WARNING","message":"id token rejected","reason":"ERR_JWT_EXPIRED"}` |
| `log('error', 'unhandled', { err: new Error('boom') })` | `{"severity":"ERROR","message":"unhandled","err":{}}` — **an `Error` becomes `{}`** |
| a circular reference as a field | `logError: "unserializable fields"` — it does not throw |

**Do not load an `Error` into a field as it is.** `JSON.stringify` throws away `name`·`message`·`stack`,
all of them — where you believe "the cause was recorded", only `{}` is left. Pull out what you need as a string and load that.
And **do not load tokens·whole documents·email addresses.** A log is a leak path too.

## 7. The repository knows nothing about HTTP

The place layering collapses is almost always **convenience** — you start wanting to answer 404 straight from the repository.
Below is the shape in which `src/services/tasks.ts` calls the repository.

```ts
// ❌ the repository takes a Context — the test for this function now has to stand up an HTTP app
export async function findTask(c: Context, taskId: string) { /* … */ }
// ❌ the repository knows a status — the same decision also grows in the router and the two diverge
if (!doc.exists) return { status: 404 };
// ✅ the data layer gives back values only. Missing or someone else's is null
const task = await getTask(ownerId, taskId);
// ✅ the service makes the decision that turns it into a status — absence and someone else's are not distinguished
if (task === null) throw new AppError('NOT_FOUND', 'task not found');
```

Whether you stand up a class like `TaskService` or export functions is free. **What is fixed is the one direction** —
no file under `src/firestore/` imports `hono`·`src/http/`. It is the same reason the `isNotFound` family, which detects
gRPC codes, lives in `src/firestore/errors.ts` and not in `src/http/errors.ts`.

## Misuse list ① — resident-server·serverless idioms → the shape on this axis

| old habit | the current shape (Cloud Run + Hono) |
| --- | --- |
| hard-coding the port in the code, as in `app.listen(3000)` | `settings.PORT` — Cloud Run injects it |
| omitting the host, as in `hostname: 'localhost'` · `serve({ fetch })` | **state** `hostname: '0.0.0.0'` |
| `process.on('SIGTERM', () => process.exit(0))` | `shutdown(server)` — in-flight requests are not lost |
| the functional-serverless "build a client per handler" | a single instance at module top level. The cache only lives in a resident process |
| `console.log('user %s logged in', id)` | `log('info', 'login', { userId: id })` — one JSON line |
| configuring `winston`·`pino` transports | one line to stdout and you are done. Collection is the platform's job |
| building the response with a `try/catch` in every router | throw, and one `installErrorHandlers` receives it |

## Misuse list ② — confusion pairs

| what gets picked wrong often | the exact condition for applying it |
| --- | --- |
| `createApp()` vs a module-global `app` | assembly has to be a function for the tests to stand one up fresh each time |
| the **definition** of `shutdown` vs **where it is called** | the definition is `src/main.ts`, the call is inside the `SIGTERM` handler |
| `server.close()` vs `process.exit()` | the first waits for in-flight requests. The second cuts them off |
| `app.onError` — parent vs child router | the child's wins. This axis attaches only the parent's |
| putting a dependency check in `/healthz` vs leaving it out | put one in and a data-layer outage becomes a failed deploy |
| `severity` vs `level` | the key Cloud Logging reads is the first, and the value is `WARNING` |
| module-top-level state — a shared cache vs a per-request value | the first is right, the second gets mixed up between concurrent requests |
