<!-- orangekit-pack: backend/node-nest v3.16.0 -->
# Operations — shutdown, health checks, pool, observability

This file owns **the lifetime of the process and its connections**. How to write migrations belongs to
`data-modeling.md` §5; **when** they run in a deploy is owned by §7 here.

## 1. Why shutdown is hard — three measurements

| observation | result |
| --- | --- |
| A new connection right after SIGTERM | **Refused immediately** (ECONNREFUSED). There is no drain window |
| `onModuleDestroy` / `beforeApplicationShutdown` firing | **1ms** after SIGTERM. In-flight requests are still alive |
| `app.close()` with a keep-alive connection outstanding | **It does not return**. It hung until the 5.8s deadline |

<!-- verified: @nestjs/core@11.2.1, run — each of the three lines above was reproduced. The in-flight request completed with a 200 after 1.2s, and DataSource.isInitialized was still true at that point -->

The third is especially dangerous. Calling `closeAllConnections()` made `app.close()` return immediately and
`onApplicationShutdown` fire only then — that is, **shutdown never finishes unless you sever them.**

The implication of the second: **do not close a provider in `onModuleDestroy`.** Cut the DB connection at that
moment and the in-flight request fails with "Driver not Connected".

## 2. Shutdown wiring (`src/ops/shutdown.ts`)

<!-- file: src/ops/shutdown.ts -->
```ts
import { INestApplication, Logger } from '@nestjs/common';
import type { Server } from 'node:http';
import { EnvVars } from '../config/env';
import { ReadinessService } from './readiness.service';

type ShutdownEnv = Pick<EnvVars, 'DRAIN_DELAY_MS' | 'SHUTDOWN_TIMEOUT_MS'>;

export function installShutdown(app: INestApplication, env: ShutdownEnv): void {
  const log = new Logger('Shutdown');
  const readiness = app.get(ReadinessService);
  const server = app.getHttpServer() as Server;
  let started = false;

  const stop = async (signal: string): Promise<void> => {
    if (started) return;
    started = true;
    log.log({ event: 'shutdown.begin', signal });

    readiness.beginDrain();
    await new Promise((r) => setTimeout(r, env.DRAIN_DELAY_MS));

    const forced = setTimeout(() => {
      log.warn({ event: 'shutdown.force_close', afterMs: env.SHUTDOWN_TIMEOUT_MS });
      server.closeAllConnections();
    }, env.SHUTDOWN_TIMEOUT_MS);
    forced.unref();

    await app.close();
    clearTimeout(forced);
    log.log({ event: 'shutdown.done', signal });
  };

  for (const signal of ['SIGTERM', 'SIGINT'] as const) {
    process.once(signal, () => void stop(signal));
  }
}
```

Each step in the order has a reason.

| step | why |
| --- | --- |
| `beginDrain()` | `/readyz` starts answering 503. The load balancer stops sending new requests |
| Waiting `DRAIN_DELAY_MS` | This is **the time for the load balancer to notice** the state. At 0 it is the same as having no drain |
| The `SHUTDOWN_TIMEOUT_MS` timer | The safety device that severs hung connections. `unref()` it so the timer itself does not block exit |
| `app.close()` | Closes the listener, waits for in-flight requests, then runs the Nest hooks |
| `closeAllConnections()` | Severs keep-alive. **Without this the line above does not return** |

Using `process.once` and the `started` flag serve the same purpose — deploy tools commonly send SIGTERM
twice, and the second must not restart the drain from the beginning.

**Do not turn `app.enableShutdownHooks()` on alongside this.** With it on, Nest catches the same signal and
starts `app.close()` before the drain — and the grace period this function built disappears.

## 3. Health checks

<!-- file: src/ops/readiness.service.ts -->
```ts
import { Injectable } from '@nestjs/common';

@Injectable()
export class ReadinessService {
  private draining = false;

  isReady(): boolean {
    return !this.draining;
  }

  beginDrain(): void {
    this.draining = true;
  }
}
```

<!-- file: src/ops/health.controller.ts -->
```ts
import { Controller, Get, HttpCode, ServiceUnavailableException } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { ReadinessService } from './readiness.service';

@Controller()
export class HealthController {
  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly readiness: ReadinessService,
  ) {}

  @Get('healthz')
  @HttpCode(200)
  live(): { status: string } {
    return { status: 'ok' };
  }

  @Get('readyz')
  async ready(): Promise<{ status: string }> {
    if (!this.readiness.isReady()) throw new ServiceUnavailableException({ status: 'draining' });
    try {
      await this.dataSource.query('SELECT 1');
    } catch {
      throw new ServiceUnavailableException({ status: 'database_unreachable' });
    }
    return { status: 'ok' };
  }
}
```

<!-- file: src/ops/ops.module.ts -->
```ts
import { Module } from '@nestjs/common';
import { HealthController } from './health.controller';
import { ReadinessService } from './readiness.service';

@Module({
  controllers: [HealthController],
  providers: [ReadinessService],
  exports: [ReadinessService],
})
export class OpsModule {}
```

**Separating the two is the point.**

| endpoint | what it answers | on failure |
| --- | --- | --- |
| `/healthz` | Is the process alive | The orchestrator **restarts** it |
| `/readyz` | May it take requests right now | The load balancer **pulls it out** (not a restart) |

This is why `/healthz` must not check the DB — when the DB wobbles for a moment every instance restarts at
once, and restarting only raises the DB load further. Liveness looks at itself alone.

`/readyz` looks at the drain flag **first**. It has to come before the DB check so a shutting-down instance
gives an immediate 503 without a DB round trip.

## 4. Connection pool

<!-- verified: PostgreSQL 18.4 + pg@8.23.0, run — with extra.max: 3, issuing 6 concurrent requests stopped the pool's totalCount at 3 -->
`extra` is the option passed straight through to the driver (pg). `max` is the per-instance ceiling, so
**instance count × `DB_POOL_MAX` ≤ PostgreSQL's `max_connections`** must hold. Exceed it and
scaling out becomes an outage — the moment a new instance comes up the existing ones cannot get connections.

The default of 10 is deliberately small. Before raising it, **look at the slow queries first** — pool exhaustion
is usually a symptom of queries held too long, not of insufficient concurrency.

## 5. Logging and slow queries (`src/ops/logging.ts`)

<!-- file: src/ops/logging.ts -->
```ts
import { ConsoleLogger, Logger } from '@nestjs/common';
import { Logger as TypeOrmLogger } from 'typeorm';
import { EnvVars } from '../config/env';

const LEVELS = ['error', 'warn', 'log', 'debug', 'verbose'] as const;

type LogEnv = Pick<EnvVars, 'LOG_LEVEL'>;

export function buildLogger(env: LogEnv): ConsoleLogger {
  return new ConsoleLogger({
    json: true,
    colors: false,
    logLevels: LEVELS.slice(0, LEVELS.indexOf(env.LOG_LEVEL) + 1),
  });
}

export class SlowQueryLogger implements TypeOrmLogger {
  private readonly out = new Logger('Database');

  logQuerySlow(time: number, query: string): void {
    this.out.warn({ event: 'db.slow_query', durationMs: time, query: query.slice(0, 300) });
  }

  logQueryError(error: string | Error, query: string): void {
    this.out.error({ event: 'db.query_error', reason: String(error).slice(0, 300), query: query.slice(0, 300) });
  }

  logMigration(message: string): void {
    this.out.log({ event: 'db.migration', message });
  }

  logQuery(): void {}
  logSchemaBuild(): void {}
  log(): void {}
}
```

<!-- verified: @nestjs/common@11.2.1, run — ConsoleLogger({json:true}) emitted {"level":"log","pid":...,"timestamp":...,"message":...,"context":...}, and passing an object put it verbatim in the message slot -->
Nest 11's `ConsoleLogger` emits JSON, so **do not bring in another logging library.**
Pass an object instead of a string and that object rides in `message` as searchable fields.

<!-- verified: typeorm@1.1.0 + PostgreSQL 18.4, run — at maxQueryExecutionTime: 100, all 6 pg_sleep(0.15) queries arrived at logQuerySlow (153ms) -->
`SlowQueryLogger` is an implementation of TypeORM's `Logger` interface, and `buildDataSourceOptions`
attaches it paired with `maxQueryExecutionTime` (`data-modeling.md` §4). Only queries over the threshold
arrive, so ordinary output does not grow.

**The field being named `out` is no accident.** TypeORM's `Logger` interface has a `log`
method, so writing `private readonly log = new Logger(...)` makes the type check fail with
`Property 'log' is private in type 'SlowQueryLogger' but not in type 'Logger'`.

**Known gap**: there is no request correlation id. A field tying one request's logs together would have to
be carried through `AsyncLocalStorage`, and that shape was not verified in this pack —
`knownGaps` in `pack.json` is the canonical source.

## 6. Environment variables and defaults

| key | default | what to watch in production |
| --- | --- | --- |
| `DB_POOL_MAX` | 10 | Instance count × this value ≤ `max_connections` |
| `DB_SLOW_QUERY_MS` | 300 | Lowering the threshold grows the logs. Lower it only while tuning |
| `DRAIN_DELAY_MS` | 5000 | At least 2× the load balancer's health check interval |
| `SHUTDOWN_TIMEOUT_MS` | 10000 | **Shorter** than the orchestrator's force-kill (SIGKILL) grace period |

The last line matters most. Set it longer than Kubernetes' `terminationGracePeriodSeconds` (30s by default)
and the process dies before our timer is reached, making the drain pointless.

## 7. Migration deploy order

Leave `migrationsRun` off (`data-modeling.md` §4). Running it at boot has two processes grab the same
migration when instances come up together.

```
① Run the migration (an independent step of the deploy pipeline, 1 instance)
② Deploy the new version (rolling)
③ Shut the old instances down — drain → close
```

So **a migration must always be backward and forward compatible.** ① and ② are not atomic, so
old code runs on the new schema for a while (the order table in `data-modeling.md` §6 is the remedy).

## Misuse list ① — Express operations idiom → NestJS form

| old habit (Express) | current form (NestJS 11) |
| --- | --- |
| Zero downtime from `server.close(cb)` alone | With keep-alive outstanding it does not return. `closeAllConnections()` is needed |
| `app.enableShutdownHooks()` is enough | It creates no drain window — new connections are refused immediately |
| Request logs via `morgan` | Nest `Logger` + the JSON output of `buildLogger`. Attach request logging with an interceptor |
| Bringing in `pino`/`winston` | Nest 11's `ConsoleLogger({ json: true })` is enough |
| Keeping only one `/health` | Liveness and readiness are **different questions** (§3) |
| `process.on('SIGTERM', () => process.exit(0))` | It throws away in-flight requests. The order is drain → close → force |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `onModuleDestroy` vs `onApplicationShutdown` | The first is while requests are still running (1ms), the second after the listener has closed. Resource release takes the second |
| `closeIdleConnections()` vs `closeAllConnections()` | The first severs only idle ones — connections that were in flight remain. On timeout, the second |
| Checking the DB in liveness | Put it in and a DB wobble becomes a restart of every instance (§3) |
| `DRAIN_DELAY_MS = 0` | The same as having no drain. A load balancer does not notice immediately |
| A large `extra.max` | Look at it multiplied by the instance count. The cause of pool exhaustion is usually a slow query |
| Raw errors verbatim in the logs | Truncate queries and constraint names to 300 characters. It becomes a path for values to leak into the logs |
