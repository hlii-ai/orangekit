<!-- orangekit-pack: backend/node-nest v3.16.0 verified 2026-08-24 @nestjs/common@11 @nestjs/core@11 @nestjs/platform-express@11 @nestjs/config@4 @nestjs/typeorm@11 @nestjs/mapped-types@2 typeorm@1 pg@8 class-validator@0.15 class-transformer@0.5 reflect-metadata@0.2 rxjs@7 typescript@5 @nestjs/testing@11 jest@30 ts-jest@29 supertest@7 @types/jest@30 @types/supertest@6 @types/node@22 -->

# node-nest axis pack — hub fragments

These are the **axis-local fragments to insert verbatim** when building the combination hub (`SKILL.md`). A combination that has a
pre-built seam does not use this file — there the seam's `HUB.md` holds the whole hub.

Each fragment sits between `<!-- pack-slot: name -->` and `<!-- /pack-slot -->`, closes inside the axis,
and holds whatever the frontend axis turns out to be. Nothing here is a function of the combination —
the table at the end of the file spells out the seam's share.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── main.ts                       # Boot only — global pipes, logger, shutdown wiring, then listen
├── app.module.ts                 # Root module: ConfigModule · TypeOrmModule · feature modules
├── config/
│   └── env.ts                    # EnvVars (the class is the schema) + validateEnv
├── common/
│   ├── validation.ts             # buildValidationPipe — assembles the global pipe
│   ├── error-status.ts           # ERROR_STATUS table · driver code detection · field errors
│   ├── app-error.ts              # AppError — **owned by the seam**
│   └── all-exceptions.filter.ts  # Envelope emission — **owned by the seam**
├── database/
│   ├── data-source.ts            # buildDataSourceOptions + dataSource for the CLI
│   └── migrations/               # Applied with migration:run (a step separate from the deploy)
├── tasks/
│   ├── task.entity.ts            # @Entity — table mapping
│   ├── task.view.ts              # TaskView type + TASK_VIEW select constant (same file)
│   ├── cursor.ts                 # Cursor encoding and decoding
│   ├── dto/                      # class-validator DTOs — the class is the schema
│   ├── tasks.service.ts          # Owns the queries. Knows nothing about HTTP
│   ├── tasks.module.ts           # forFeature([Task]) + exports the service
│   └── tasks.controller.ts       # **Owned by the seam** (paths, envelope)
├── auth/                         # AuthGuard · CurrentUser — **owned by the seam**
└── ops/
    ├── readiness.service.ts      # Sole owner of the drain flag
    ├── health.controller.ts      # /healthz(liveness) · /readyz(readiness)
    ├── ops.module.ts             # Bundles the two above and puts them on AppModule
    ├── shutdown.ts               # Drain → grace → close → force
    └── logging.ts                # buildLogger(JSON) + SlowQueryLogger

test/
└── db.ts                         # Per-worker schema isolation · app boot · seeding · cleanup

jest.config.ts                    # ts-jest. Runs e2e and unit from one config
tsconfig.json                     # experimentalDecorators and emitDecoratorMetadata required
```

**Dependencies flow one way only**: `controller → service → repository`. A service that takes
`Request` or `Response` collapses the layering and makes a query test need an HTTP server.
<!-- /pack-slot -->

<!-- pack-slot: architecture-overview -->
## Architecture Overview

**The module is the boundary.** In Nest, "what can be used where" is decided by the **module
graph**, not by import statements. Without `exports: [TasksService]` on `TasksModule`, no other module
can have that service injected — importing the file still fails boot with `Nest can't resolve dependencies`.
So this pack controls access **through module boundaries, not file layout**.

**A Repository is obtained only through DI.** `@InjectRepository(Task)` is the sole procurement path.
Building `dataSource.getRepository(Task)` straight into a service field removes the place a test
would slot a double (there is nothing left for `getRepositoryToken(Task)` to override).
The exception is **inside a transaction** — there `manager.getRepository(Task)` hands you the
instance bound to that transaction.

**`reflect-metadata` comes on the entry point's first line.** Without it the first call that reads
decorator metadata dies with `Reflect.getMetadata is not a function` (verified by running it). `main.ts` and the
`database/data-source.ts` the CLI reads each carry it on their own first line — because there are two entry points.

**Order of the global wiring**: create with `bufferLogs: true` → `useLogger` → `useGlobalPipes` →
(the seam's `useGlobalFilters`) → `installShutdown` → `listen`. Attaching the logger late is
deliberate — using the `logger` option of `NestFactory.create` would mean reading environment values
before the app, and then `main.ts` reads `process.env` directly.
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
## Core Principles (7 Key Rules)

This axis has **no row-level policy engine.** The application attaches to PostgreSQL over a trusted connection,
so rules 1-3 are the only boundary — "the data layer backs us up, so this is defense in depth" does not hold here.
`user` is the `AuthUser` the seam's `AuthGuard` puts there.

### 1. Ownership lives in the `where` — not in a comparison after the fetch

```ts
// src/tasks/tasks.service.ts
// ❌ Compare the owner after fetching — no layer will catch a missing comparison
const found = await this.tasks.findOne({ where: { id } });
if (found && found.ownerId !== user.id) throw new AppError('FORBIDDEN');
// ✅ Ownership is a fetch condition
const task = await this.tasks.findOne({ where: { id, ownerId }, select: TASK_VIEW });
```

### 2. An array `where` is an OR — repeat ownership on every branch

<!-- verified: typeorm@1.1.0 + PostgreSQL 18.4, run — removing ownerId from one branch mixed another owner's rows into the result (8 rows total) -->
Drop `ownerId` from one branch and that branch passes another user's rows through wholesale. The policy regex
only looks at "is `ownerId` in the `where`", so **no machine catches this defect.**

### 3. A mutation checks the affected row count

<!-- verified: typeorm@1.1.0 + PostgreSQL 18.4, run — an update against a row owned by someone else came back with affected = 0 -->
An `update` or `delete` carrying an ownership filter **silently succeeds with 0 rows changed** against another user's row.
Without looking at `res.affected === 0`, a 200 goes out.

### 4. `select` narrows the value only — the type stays

<!-- verified: typeorm@1.1.0, run — after select, the object had the ownerId key with an undefined value -->
Without declaring the return type as `TaskView` **explicitly**, `task.ownerId` compiles and is
`undefined` at runtime. Once that value rides in the envelope, a wrong response goes out silently.

### 5. Schema changes go through migrations only — `synchronize` stays off

Tests are not exempt. This pack's test harness **actually runs the migrations** against an isolated
schema, and so verifies the migrations too.

### 6. The DTO class validates and the global pipe enforces

`whitelist` + `forbidNonWhitelisted` + `transform` are pinned in one place (`buildValidationPipe`).
Building a fresh `new ValidationPipe(...)` per controller lets the options diverge.

### 7. Shutdown drains first — and then severs keep-alive

<!-- verified: @nestjs/core@11.2.1, run — with a keep-alive connection outstanding, app.close() did not return before the 5.8s deadline, and calling closeAllConnections() completed it immediately -->
`app.close()` **never returns as long as even one keep-alive connection is open.**
Setting a deadline and severing them with `server.closeAllConnections()` is the only device that ends shutdown.
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
## Common Imports

```ts
// Framework
import { Injectable, Module, Logger, ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { InjectRepository, InjectDataSource, TypeOrmModule } from '@nestjs/typeorm';
import { DataSource, Repository, LessThan, In, QueryFailedError } from 'typeorm';
import { IsIn, IsInt, IsOptional, IsString, validateSync } from 'class-validator';
import { plainToInstance, Type } from 'class-transformer';

// Modules the pack owns — paths are relative to src/<layer>/ (ledger.md is canonical for the assignment)
import { EnvVars, validateEnv } from './config/env';
import { buildValidationPipe } from './common/validation';
import { ERROR_STATUS, toAppError, isUniqueViolation, fieldErrors } from './common/error-status';
import { buildDataSourceOptions } from './database/data-source';
import { Task, TaskStatus } from './tasks/task.entity';
import { TASK_VIEW, TaskView } from './tasks/task.view';
import { encodeCursor, decodeCursor } from './tasks/cursor';
import { TasksService } from './tasks/tasks.service';
import { ReadinessService } from './ops/readiness.service';
import { installShutdown } from './ops/shutdown';
import { buildLogger, SlowQueryLogger } from './ops/logging';

// Seam-owned — the axis fixes the paths
import { AppError } from './common/app-error';
import { AllExceptionsFilter } from './common/all-exceptions.filter';
import { AuthGuard, AuthUser } from './auth/auth.guard';
import { CurrentUser } from './auth/current-user.decorator';
```

`AppError` is **thrown from any layer** — a pure error class that knows nothing about HTTP, with the status mapping
done separately by `ERROR_STATUS`. `AuthGuard`, `CurrentUser` and `TasksController` are defined by the seam,
so they never appear in pack code.
<!-- /pack-slot -->

<!-- pack-slot: http-status-and-antipatterns -->
## HTTP Status Codes & Anti-Patterns

**The canonical source for status codes is the `ERROR_STATUS` owned by `error-handling.md`.** The table below summarizes it,
and where they disagree `ERROR_STATUS` wins.

| code | domain code | when it goes out |
| --- | --- | --- |
| 200 | — | Read or update succeeded (with a body) |
| 201 | — | Create succeeded — Nest gives this by default on `@Post` |
| 204 | — | Delete succeeded — you have to state `@HttpCode(204)` |
| 400 | `VALIDATION_FAILED` | DTO validation failed. Field errors go in `details` |
| 401 | `UNAUTHENTICATED` | No credential or an expired one — thrown by the seam's `AuthGuard` |
| 403 | `FORBIDDEN` | Only for refusing an action (insufficient role) on a resource whose existence **is already known** |
| 404 | `NOT_FOUND` | Absent **and** owned by someone else. Splitting the two lets an id sweep reveal existence |
| 409 | `CONFLICT` | Unique constraint collision — driver code `23505` |
| 503 | — | Draining, or the DB is unreachable — emitted by `/readyz` only |
| 500 | `INTERNAL` | Everything else. The cause goes to the logs, never the response |

### Anti-patterns — what is actually observed on NestJS 11 + TypeORM 1

| ❌ shape | why it is wrong / instead |
| --- | --- |
| `createConnection()` · `getManager()` | **Those exports do not exist** in TypeORM 1.x. Receive a `DataSource` through DI <!-- verified: typeorm@1.1.0 runtime export list has no Connection, createConnection, getRepository or getManager --> |
| `repo.update({}, patch)` · `updateAll` | A mutation with no WHERE hits other users' rows too. That 1.x split it out as `updateAll` is **a warning, not a recommendation** |
| `@Column() createdAt: Date` (no precision) | The resolution gap between `timestamptz` (µs) and JS `Date` (ms) skips rows in cursor pagination <!-- verified: PostgreSQL 18.4, run — with no precision, 1 of 5 rows was lost; with precision: 3, all 5 came through --> |
| A service taking `@Res() res` | HTTP leaks outside the controller and Nest's interceptors and serialization are bypassed wholesale |
| `new ValidationPipe()` per controller | The options diverge. Keep exactly one global (`buildValidationPipe`) |
| Zero-downtime deploys from `enableShutdownHooks()` alone | That hook **refuses new connections immediately** and creates no drain window <!-- verified: @nestjs/core@11.2.1, run — right after SIGTERM new connections got ECONNREFUSED and only in-flight requests completed --> |
| Closing resources in `onModuleDestroy` | It fires while in-flight requests are still outstanding <!-- verified: @nestjs/core@11.2.1, run — fired 1ms after SIGTERM, with the request finishing 1.2s later --> |
| Request logs via `console.log` | No level, no context, no serialization. Use `Logger` + the JSON output of `buildLogger` |
<!-- /pack-slot -->

## For the seam to fill

| slot | why it is a function of the combination |
| --- | --- |
| `api-endpoints` | The controller's paths and decorators, and the response envelope. The wire contract decides the envelope |
| `auth-boundaries` | How the token is verified depends on whether the frontend axis has a server runtime |
| `complete-example` | Migration → entity → DTO → service → controller → e2e, end to end |
