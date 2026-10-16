<!-- orangekit-pack: backend/fastify v3.33.0 -->
# Operations — boot · health checks · draining · logging

This file owns `src/index.ts` (boot · signals) and `src/ops/` (health checks · logger options · shutdown). The
infrastructure definition of the deploy target (EC2 · ECS · a container orchestrator) is outside this pack — this file
covers only **the contract that infrastructure expects of the process** (binding · what the health checks mean · how
it reacts to SIGTERM).

## 1. Judgment — the two health checks and the shutdown steps

| question | endpoint / step | what it looks at |
| --- | --- | --- |
| does this process need restarting? | `/healthz` (liveness) | **only** whether the event loop responds. It does not look at the DB |
| can this instance receive traffic? | `/readyz` (readiness) | not draining + the DB is reachable |
| what comes first on the way down? | `shutdown` | mark draining → grace period → `app.close()` → `pool.end()` |

If liveness looks at the DB, **a DB outage turns into a restart storm across every instance** — restarting does not
bring the DB back.

## 2. Boot (`src/index.ts`)

<!-- file: src/index.ts -->
```ts
// src/index.ts
import { buildApp } from './app'
import { env } from './env'
import { shutdown } from './ops/shutdown'

const app = await buildApp()
// Omit host and it binds to 127.0.0.1 only — unreachable from outside in a container or on EC2
await app.listen({ host: env.HOST, port: env.PORT })

// In production, give the load balancer time to observe readyz 503 (at least the health check interval)
const drainDelayMs = env.NODE_ENV === 'production' ? 5_000 : 0
function onSignal(sig: NodeJS.Signals) {
  app.log.info({ sig }, 'shutting down')
  shutdown(app, drainDelayMs).then(() => process.exit(0), (err) => {
    app.log.error({ err }, 'shutdown failed')
    process.exit(1)
  })
}
process.once('SIGTERM', onSignal)
process.once('SIGINT', onSignal)
```

**It runs with `tsx`** — the same in development and production. The code uses top-level `await` and extensionless
relative imports (module resolution `bundler`), so running the `tsc` output directly with `node` fails to resolve.
Building to `dist/` needs a bundler, and this pack does not cover that path (`knownGaps`).

```json
{
  "type": "module",
  "scripts": { "start": "tsx src/index.ts", "typecheck": "tsc --noEmit", "test": "vitest run" }
}
```

<!-- verified: booted with npx tsx src/index.ts → healthz 200 · unauthenticated 401 · clean exit on SIGTERM (2026-10-15) -->

Leave `host` out of `listen` and it binds only to `127.0.0.1` and `::1` — on EC2 the load balancer cannot reach it,
and in a container the port mapping cannot. That is why `env.HOST` defaults to `0.0.0.0`
<!-- verified: fastify@5.12.7 — app.addresses() for listen({ port: 0 }) was 127.0.0.1 · ::1, while booting with host 0.0.0.0 showed *:port in lsof (2026-10-15) -->.

## 3. Health checks (`src/ops/health.ts`)

<!-- file: src/ops/health.ts -->
```ts
// src/ops/health.ts
import { sql } from 'drizzle-orm'
import type { FastifyReply, FastifyRequest } from 'fastify'
import { db } from '../db/client'

let draining = false

// Start draining — drop readyz to 503 so the load balancer stops sending new requests
export function beginDrain(): void {
  draining = true
}

// liveness — looks only at whether the process responds. Look at the DB and a DB outage becomes a restart storm
export async function healthz(): Promise<{ status: 'ok' }> {
  return { status: 'ok' }
}

// readiness — 503 while draining or when the DB is unreachable
export async function readyz(req: FastifyRequest, reply: FastifyReply) {
  if (draining) return reply.code(503).send({ status: 'draining' })
  try {
    await db.execute(sql`select 1`)
    return { status: 'ready' }
  } catch (err) {
    req.log.warn({ err }, 'readiness: database unreachable')
    return reply.code(503).send({ status: 'unavailable' })
  }
}
```

`readyz` writes `reply.code(503)` directly — an ops endpoint's 503 is not a domain failure but a protocol with the
load balancer, so it does not go through the `AppError` envelope (the only exception to `error-handling.md` §5).

`buildApp` registers both endpoints **at the root** (`project-structure.md` §2) — put them inside the route plugin
carrying the auth hook and the load balancer gets a 401 and takes the instance out.

## 4. Shutdown (`src/ops/shutdown.ts`)

<!-- file: src/ops/shutdown.ts -->
```ts
// src/ops/shutdown.ts
import type { FastifyInstance } from 'fastify'
import { pool } from '../db/client'
import { env } from '../env'
import { beginDrain } from './health'

// Performs the drain. It is not the signal wiring — the caller invokes it inside process.once('SIGTERM', ...)
export async function shutdown(app: FastifyInstance, drainDelayMs = 0): Promise<void> {
  beginDrain()
  // Give the load balancer time to observe readyz 503 (as long as the ALB health check interval)
  if (drainDelayMs > 0) await new Promise((r) => setTimeout(r, drainDelayMs))
  const deadline = setTimeout(() => {
    app.log.error('shutdown deadline exceeded — forcing exit')
    process.exit(1)
  }, env.SHUTDOWN_TIMEOUT_MS)
  deadline.unref()
  // close() stops accepting new connections, waits for in-flight requests, then runs the onClose hooks
  await app.close()
  // Close the pool after the app is closed — so in-flight requests do not lose their queries
  await pool.end()
  clearTimeout(deadline)
}
```

<!-- verified: fastify@5.12.7 — observed after calling close() while a request taking 1.2 s was in flight (2026-10-15) -->

| after `close()` is called | observed |
| --- | --- |
| a new connection | **`ECONNREFUSED` immediately** — the listener is closed |
| the next request on an idle keep-alive socket | `ECONNREFUSED` — idle connections are cut right away |
| a request that was in flight | processed to completion, 200 (`connection: close`) |
| when `close()` returns | **after** the in-flight requests finish |

The first row is why the grace period (`drainDelayMs`) exists. The load balancer finds out one health check interval
late — a request sent in between hits the closed listener and becomes a 502. So the order is **`readyz` 503 → wait at
least the health check interval → `close()`**. Set the grace period longer than the load balancer's health check
interval (times the threshold count) and shorter than the deregistration delay.

`pool.end()` comes **after** `close()` — so in-flight requests do not lose their last query. Past the deadline
(`SHUTDOWN_TIMEOUT_MS`) it forces an exit: one request that never finishes is not allowed to stall the whole deploy.

## 5. Logger options (`src/ops/logger.ts`)

<!-- file: src/ops/logger.ts -->
```ts
// src/ops/logger.ts
import type { FastifyServerOptions } from 'fastify'
import { env } from '../env'

// Fastify builds the pino instance itself — pass options only. Inside a request, use req.log
export const loggerOptions: FastifyServerOptions['logger'] = {
  level: env.LOG_LEVEL,
  // The default request log has no headers — this guards against someone logging { headers } or { req } directly
  redact: {
    paths: ['headers.authorization', 'headers.cookie', 'req.headers.authorization', 'req.headers.cookie'],
    censor: '[redacted]',
  },
}
```

Pass a pino **instance** to `logger` and Fastify 5 rejects it with `FST_ERR_LOG_INVALID_LOGGER_CONFIG` — pass an
options object or use `loggerInstance` <!-- verified: ran fastify@5.12.7 -->.

<!-- verified: fastify@5.12.7 — observed by intercepting the log stream. The req in the default request log held only method · url · host · remoteAddress; req.log.info({ headers }) was masked only by the headers.* paths, and with only the req.headers.* paths the token was printed as-is (2026-10-15) -->
**The default request log has no headers.** A token leaks when someone **logs it directly**, as in
`req.log.info({ headers: req.headers })`, and the path then is `headers.authorization`. Redact only
`req.headers.authorization` and the token goes out in that log untouched — keep both forms.

Inside a request, use `req.log` — it carries `reqId`, so one request's logs can be stitched together. `console.log`
has none of that, no level, and no redact (policy `no-console`).

## 6. The connection pool and deploy targets

Size it so that `DB_POOL_MAX × instance count` does not exceed PostgreSQL's `max_connections` minus the headroom kept
for administration. When you add instances, shrink the pool or put a connection pooler (RDS Proxy · PgBouncer) in
front — do not buy throughput by growing the pool. More often than not the queries are slow, not the connections
scarce.

| deploy target | contract with the process |
| --- | --- |
| EC2 + ALB | `HOST=0.0.0.0` · target group health check path `/readyz` · the process manager (systemd and the like) sends SIGTERM |
| container (ECS · Docker) | as above, and run `tsx` directly in exec form so PID 1 receives the signal — if a shell wrapper swallows SIGTERM there is no drain <!-- unverified: this pack did not run a container — signal delivery for a shell-form CMD is as described in the runtime docs --> |

## 7. Migration deploy order

1. Build the image or artifact
2. **Run `drizzle-kit migrate` once** — a separate step of the deploy pipeline (`data-access.md` §7)
3. Rolling deploy — drain the old instances after the new ones return `/readyz` 200

Do not call `migrate` from the boot code — when instances come up together they contend over the same migration (the
basis is principle, `knownGaps` in `pack.json`). Between steps 2 and 3 the old code runs on the new schema: split a
column drop or rename into **add → switch the code → drop in the next deploy**.

## Misuse list ① — Express · Fastify 4 ops habits → Fastify 5 idioms

| old habit | current form (Fastify 5) |
| --- | --- |
| `server.close()` then tracking keep-alive sockets by hand | `app.close()` — it cuts idle connections itself and waits for in-flight requests |
| `app.listen(PORT)` | `app.listen({ host, port })` |
| `Fastify({ logger: pino() })` | `Fastify({ logger: options })` or `loggerInstance` |
| `migrate && tsx src/index.ts` in the boot script | `drizzle-kit migrate` split out as a pipeline step |
| `process.on('SIGTERM', () => process.exit(0))` | `process.once('SIGTERM', onSignal)` → `shutdown` |

## Misuse list ② — confusable pairs

| often picked wrong | exact condition |
| --- | --- |
| a DB check in `/healthz` vs `/readyz` | only in the latter |
| `pool.end()` in an `onClose` hook vs in `shutdown` | the latter — tests build and close the app several times |
| `drainDelayMs` 0 vs at least the health check interval | the former locally and in tests, the latter in production behind a load balancer |
| `req.log` vs the module's `app.log` | the former inside a request (`reqId`), the latter only on the boot and shutdown paths |
