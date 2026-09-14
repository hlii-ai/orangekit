<!-- orangekit-pack: backend/node-api v3.13.0 -->
# Operations — shutdown · health checks · the connection pool · structured logging

This file owns **the lifetime and observation of the process**: SIGTERM handling, the liveness/readiness probes,
connection pool sizing, the pino logger, and migration deploy order. App assembly and middleware order are owned by
`project-structure.md`, the Prisma singleton by `data-access.md`, and test DB isolation by `testing.md`
(pool sizing contends for the same resource as that file).

The environment keys this file reads are `NODE_ENV` · `PORT` · `LOG_LEVEL` · `DRAIN_DELAY_MS` ·
`SHUTDOWN_TIMEOUT_MS`.
Anything not in `EnvSchema` is added there — the schema body lives in `src/env.ts` (owned by
`input-validation.md`), and operations code imports `env` rather than reading environment values directly.

## 1. Judgment — do not mix the four signals

| question | where it is answered | what the orchestrator does on failure |
| --- | --- | --- |
| is the process alive | `healthz` (it does not look at dependencies) | **kills the container** |
| may it take traffic right now | `readyz` (it checks the DB) | removes it from the load balancer (does not kill it) |
| may it shut down | `shutdown` (is the drain done) | — |
| what happened | `logger` (request correlation) | — |

**The two must not be made the same.** If `healthz` checks the DB, then when the DB is briefly slow for 5 seconds the
orchestrator **restarts** a perfectly healthy process — and the restarted instance reconnects to the DB and
makes the load worse. Liveness answers only "does this process have to be killed to recover".

Conversely, if `readyz` does not look at the DB, traffic goes into an instance whose pool is not yet filled right after a deploy.

## 2. Structured logging (`src/ops/logger.ts`)

<!-- file: src/ops/logger.ts -->
```ts
// src/ops/logger.ts
import { pino } from 'pino';
import { env } from '../env';

// `*` is exactly one level. Write it out per depth by hand and you will miss one — build and expand it.
const SECRET_KEYS = ['password', 'token', 'accessToken', 'refreshToken',
  'apiKey', 'api_key', 'secret', 'clientSecret', 'DATABASE_URL'];
const atAnyDepth = (k: string) => [k, `*.${k}`, `*.*.${k}`, `*.*.*.${k}`];

export const logger = pino({
  level: env.LOG_LEVEL,
  redact: {
    paths: ['res.headers["set-cookie"]', ...SECRET_KEYS.flatMap(atAnyDepth)],
    censor: '[redacted]',
  },
  base: { service: 'tasks-api', env: env.NODE_ENV },
});
```

Request correlation is attached by `pino-http`. App assembly is owned by `project-structure.md`, so only the
wiring is shown here — it has to be **the very first middleware** for errors thrown after it to be tied to the same `reqId`.

```ts
// src/app.ts — inside makeApp(), before the routers
import { randomUUID } from 'node:crypto';
import { pinoHttp } from 'pino-http';
import { logger } from './ops/logger';

// Credential headers cannot be blocked by enumeration — pick them with an allowlist.
const SAFE_HEADERS = ['host', 'user-agent', 'content-type', 'content-length', 'x-request-id'];

app.use(pinoHttp({
  logger,
  genReqId: (req) => req.headers['x-request-id'] ?? randomUUID(),
  serializers: {
    req(req) {   // ✅ the default serializer carries **every** header — swap in an allowlist
      const headers: Record<string, unknown> = {};
      for (const h of SAFE_HEADERS) if (req.headers[h] !== undefined) headers[h] = req.headers[h];
      return { id: req.id, method: req.method, url: req.url, headers };
    },
  },
}));
```

From then on, handlers and services use `req.log.info({ taskId }, 'task updated')`. Call `logger` directly and
`reqId` is missing, so the logs of one request cannot be stitched together in production.

## 3. What `redact` hides and what it cannot (measured)

`redact` is **path-based**, and so it fails to block three things. We logged for real with pino 9.14.0 ·
pino-http 10.5.0 and checked the output.

| shape | result |
| --- | --- |
| `{ token }` · `{ user: { password } }` · `{ items: [{ password }] }` | ✅ `[redacted]` |
| `{ a: { b: { c: { password } } } }` — declared only up to `*.*.password` | ❌ **printed as-is** |
| `{ refreshToken }` · `{ api_key }` · `{ secret }` — names not on the list | ❌ **printed as-is** |
| `x-api-key` · `proxy-authorization` · `x-auth-token` through pino-http's default serializer | ❌ **in plain text on every request** |
| `{ err: new Error('connect failed: postgresql://u:PW@h/db') }` | ❌ **message and stack printed in full** |

**① An approach that enumerates names will always leak.** It blocks `accessToken` and misses `refreshToken` —
and the one it missed has the longer lifetime. For headers, enumeration is worse still:
blocking only `authorization`·`cookie` still leaked `x-api-key`·`proxy-authorization` (an RFC 7235 standard)·
`x-auth-token` **on every request, on the default path of the wiring the pack prescribed**. So §2 swaps
headers over to an **allowlist** and gathers the key names in `SECRET_KEYS` so they grow in one place.

**② `*` is exactly one level.** You have to write it out per depth, and **`**.password` throws no exception
and hides nothing** — it silently becomes a powerless setting. The `atAnyDepth` in §2 **cuts off at depth 4**
(confirmed by running it: depth 4 ✅ · depth 5 ❌). Not putting secrets deeper than that is the contract.

**③ A secret embedded inside a string cannot be hidden in principle.** Do not log the exception object whole; log only the
fields needed to identify it — a Prisma connection error carries the connection string in its message.

```ts
// handling inside src/ops/health.ts — do not log the exception whole
logger.warn({ name: (err as Error).name }, 'readiness probe failed');   // ✅
```

## 4. Health checks (`src/ops/health.ts`)

<!-- file: src/ops/health.ts -->
```ts
// src/ops/health.ts
import type { RequestHandler } from 'express';
import { prisma } from '../db/client';
import { logger } from './logger';

let draining = false;
export function beginDrain(): void { draining = true; }

export const healthz: RequestHandler = (_req, res) => {
  res.status(200).json({ status: 'ok' });   // it does not look at dependencies
};

export const readyz: RequestHandler = async (_req, res) => {
  if (draining) { res.status(503).json({ status: 'draining' }); return; }
  try {
    await prisma.$queryRaw`SELECT 1`;       // tagged template — parameterized
    res.status(200).json({ status: 'ready' });
  } catch (err) {
    logger.warn({ name: (err as Error).name }, 'readiness probe failed');
    res.status(503).json({ status: 'degraded' });
  }
};
```

Mount both probes **before authentication** — the orchestrator does not carry a token. In exchange, do not put internal
information such as the version, the host, or the schema into the response. Exclude the probe paths from the request log or lower them
to `trace` level (they arrive several times a second and swallow the log budget).

`beginDrain` is the one entry point §5 calls. Without this flag, `readyz` returns 200 even while draining
and the load balancer keeps sending new requests to an instance that is about to die.

## 5. Graceful shutdown (`src/ops/shutdown.ts`)

**Get the order wrong and every deploy produces 5xx.** ① unset readiness → ② time for the load balancer to notice → ③ refuse new
connections and drain in-flight requests → ④ disconnect the DB → ⑤ exit. Drop ② and a request that was still being
routed right after `close()` meets a connection refusal.

<!-- file: src/ops/shutdown.ts -->
```ts
// src/ops/shutdown.ts
import type { Server } from 'node:http';
import { prisma } from '../db/client';
import { env } from '../env';
import { beginDrain } from './health';
import { logger } from './logger';

let running: Promise<void> | null = null;

export function shutdown(server: Server): Promise<void> {
  running ??= drainAndExit(server);   // runs once even if the signal arrives twice
  return running;
}

async function drainAndExit(server: Server): Promise<void> {
  beginDrain();                                              // ① readyz starts returning 503
  logger.info({ drainDelayMs: env.DRAIN_DELAY_MS }, 'shutdown: draining');
  const kill = setTimeout(() => {
    logger.error('shutdown: timed out, forcing exit');
    process.exit(1);                                         // the last safety net
  }, env.SHUTDOWN_TIMEOUT_MS);
  kill.unref();
  await new Promise((r) => setTimeout(r, env.DRAIN_DELAY_MS)); // ② time for the LB to notice
  const closed = new Promise<void>((resolve, reject) =>
    server.close((err) => (err ? reject(err) : resolve())),    // ③ drain
  );
  server.closeIdleConnections();
  await closed;
  await prisma.$disconnect();                                  // ④
  clearTimeout(kill);
  logger.info('shutdown: complete');                           // ⑤ it exits once the event loop empties
}
```

```ts
// src/index.ts — hang the signals at boot
const server = makeApp().listen(env.PORT, () => logger.info({ port: env.PORT }, 'listening'));
process.on('SIGTERM', () => { void shutdown(server); });
process.on('SIGINT', () => { void shutdown(server); });
```

What was confirmed by running it (Node 24.7.0 · Express 5.2.1, `DRAIN_DELAY_MS=800`):

- `readyz` was 200 before SIGTERM and **the same process returned 503 300ms after SIGTERM** —
  the server still accepts connections while draining. That is the purpose of ②
- A 1.5-second request that started before the drain **completed with a 200**. `close()` waited for it
- The process **exited 1.22 seconds** after SIGTERM and `$disconnect()` was called.
  New connections after exit were refused
- `server.closeIdleConnections()` is **redundant for idle keep-alive connections on Node 24.7.0**
  — `close()` alone closed them in 2ms <!-- verified: held a keep-alive connection open with a net socket and timed close() -->.
  More importantly, **a request whose headers are not complete is not closed by `closeIdleConnections()` either**
  (still BLOCKED after waiting 3 seconds). That is why the forced-exit timer is the real safety net

Set `SHUTDOWN_TIMEOUT_MS` **shorter** than the orchestrator's grace period — longer, and SIGKILL arrives before
our timer does, and the drain means nothing.

## 6. Connection pool sizing

Prisma builds its own pool per instance. PostgreSQL's `max_connections` is a limit for **the whole cluster**.
The two have to be joined by multiplication.

```
instance count × connection_limit
  + migration job  + operations tools (psql, dashboards)  + test workers
  ≤ max_connections − superuser_reserved_connections
```

`connection_limit` goes on the connection string: `postgresql://…/app?connection_limit=10`.
Leave it unspecified and Prisma derives it from the host CPU count, so **running several instances on a big machine
quietly pushes the total past the limit** <!-- unverified -->.

Look at three observation points before settling on a number — nothing here can be stated as a fixed value.

| what | how to look at it |
| --- | --- |
| connections actually in use | `SELECT count(*), state FROM pg_stat_activity WHERE datname = current_database() GROUP BY state` |
| the server limit | `SHOW max_connections` · `SHOW superuser_reserved_connections` |
| pool exhaustion | the rate of pool timeout errors (`P2024`) <!-- unverified --> |

If `state = 'idle in transaction'` piles up, look for **an external call inside a transaction** before growing the pool.
Growing the pool hides that symptom briefly and it resurfaces on the DB side.

The same formula is why `testing.md` puts `connection_limit=2` on the per-worker URL — 4 workers each opening
the default pool would use up the whole limit of a local development DB on their own.

## 7. Migration is a step separate from the deploy

The reason `migrate deploy` must not run at boot is in `data-access.md`. Here we cover only **how the deploy order is
arranged as a result**.

```bash
# deploy pipeline — once before the app runs, and from one process only
npx prisma migrate deploy      # ① move the schema forward (no rollback — it only goes forward)
# ② roll out the new image (wait until readyz turns green)
```

Because of the order, **the old code and the new schema coexist for one deploy.** So split a destructive change across
two deploys: first add the column and write to both, then drop the old column in the next deploy. Add a `NOT NULL` column or
rename a column all at once and every old instance still rolling out produces 5xx.

`migrate dev` is for a development machine only — it can reset the schema, so do not call it in CI or production.

## Misuse list ① — single-process habits → orchestration idioms

| old habit | current shape |
| --- | --- |
| logging with `console.*` | `logger`/`req.log` — level, correlation, and JSON serialization come with it |
| one `/health` for everything | split into `healthz` (liveness) and `readyz` (readiness) |
| exiting immediately with `process.exit(0)` | drain with `shutdown()` and exit naturally once the event loop empties |
| `migrate deploy` at boot | a separate step in the deploy pipeline |
| assuming only `SIGKILL` | handle `SIGTERM` + a forced-exit timer shorter than its grace period |
| leaving the pool size at the per-app default | multiply `connection_limit` by the instance count and match it to the limit |
| logging the error object whole | only the identifying fields — `redact` cannot see inside a string |
| logging request headers at the default | leave only an allowlist with `serializers.req` |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| checking the DB in `healthz` vs in `readyz` | in `readyz` only. Let `healthz` look at the DB and DB latency becomes a restart storm |
| `*.token` vs `*.*.token` | `*` is exactly one level. Write it per depth (`**` is powerless) and it cuts off at depth 4 |
| a header denylist vs an allowlist | the **allowlist**. Names like `x-api-key`·`proxy-authorization` grow without end |
| `server.close()` vs `closeIdleConnections()` | `close()` does the draining. The latter is for idle sockets and cannot close an incomplete request |
| the forced-exit timer vs the drain delay | the delay is time for the LB to notice (②), the timer is the safety net for a drain that does not finish (⑤) |
| `logger` vs `req.log` | `req.log` whenever there is a request context — otherwise `reqId` is missing |
| `migrate dev` vs `migrate deploy` | `dev` is for a development machine only (it can reset); deployment uses `deploy` |
| `max_connections` vs `connection_limit` | the former is the whole-server limit, the latter the pool size of **one instance** |
