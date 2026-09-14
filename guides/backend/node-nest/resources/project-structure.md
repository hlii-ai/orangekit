<!-- orangekit-pack: backend/node-nest v3.16.0 -->
# Project structure — the module is the boundary

This file owns the **module graph and the boot path**. The controller's paths and envelope are the seam's share
(`api-endpoints` in `seamSlots`), queries are owned by `data-access.md`, and validation rules by
`input-validation.md`.

## 1. What goes where — decision tree

| what you are writing | where | why |
| --- | --- | --- |
| Domain logic and queries | `src/<feature>/<feature>.service.ts` | A layer that knows nothing about HTTP. Its tests need no server |
| A pure function several features use | `src/common/` | Not a module — do not make it a provider |
| An **injectable** several features use | Its own module + `exports` | A provider has to be exported to leave its module |
| Operational endpoints and lifetime wiring | `src/ops/` | Not domain. Owned by `operations.md` |
| Request shape definitions | `src/<feature>/dto/` | The class is the schema (`input-validation.md`) |
| Paths, status codes, envelope | `src/<feature>/<feature>.controller.ts` | **The seam's share** |

**Importing a file does not make it usable.** Having `TasksService` injected into another module requires
`TasksModule` to `exports` it. Omit that and boot dies with `Nest can't resolve dependencies of
the X (?)` — while compilation passes.

## 2. Root module (`src/app.module.ts`)

The root **only assembles**. It holds no controller and no provider of its own — that is what keeps this one file
the only place to look when a feature is added or removed.

<!-- file: src/app.module.ts -->
```ts
import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { EnvVars, validateEnv } from './config/env';
import { buildDataSourceOptions } from './database/data-source';
import { OpsModule } from './ops/ops.module';
import { TasksModule } from './tasks/tasks.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true, cache: true, validate: validateEnv }),
    TypeOrmModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService<EnvVars, true>) =>
        buildDataSourceOptions({
          DATABASE_URL: config.get('DATABASE_URL', { infer: true }),
          DB_SCHEMA: config.get('DB_SCHEMA', { infer: true }),
          DB_POOL_MAX: config.get('DB_POOL_MAX', { infer: true }),
          DB_SLOW_QUERY_MS: config.get('DB_SLOW_QUERY_MS', { infer: true }),
        }),
    }),
    OpsModule,
    TasksModule,
  ],
})
export class AppModule {}
```

`validate: validateEnv` is **the point that binds environment validation to boot**. `ConfigModule` takes its
return value as the configuration, so from then on `config.get('PORT', { infer: true })` hands back a value
that has been validated and converted. Without `isGlobal: true` every module has to import `ConfigModule`.

`forRootAsync` + `inject: [ConfigService]` are needed because of ordering — building the DataSource options
requires the environment values to be validated already. Writing the values directly into `forRoot` breaks that order.

## 3. Feature module (`src/tasks/tasks.module.ts`)

<!-- file: src/tasks/tasks.module.ts -->
```ts
import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { Task } from './task.entity';
import { TasksController } from './tasks.controller';
import { TasksService } from './tasks.service';

@Module({
  imports: [TypeOrmModule.forFeature([Task])],
  controllers: [TasksController],
  providers: [TasksService],
  exports: [TasksService],
})
export class TasksModule {}
```

`TypeOrmModule.forFeature([Task])` is where `@InjectRepository(Task)` is procured. Use
`@InjectRepository(Task)` in a service without it and boot fails with `Nest can't resolve dependencies of the
TasksService (?, DataSource)` — the question mark is the missing dependency.

The `controllers` array is **filled by the seam.** With only the pack assembled it is normal for this module
to have no controller (there are simply no endpoints; the service still works).

## 4. Boot (`src/main.ts`)

<!-- file: src/main.ts -->
```ts
import 'reflect-metadata';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { buildValidationPipe } from './common/validation';
import { EnvVars } from './config/env';
import { AppModule } from './app.module';
import { buildLogger } from './ops/logging';
import { installShutdown } from './ops/shutdown';

export async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  const config: ConfigService<EnvVars, true> = app.get(ConfigService);

  app.useLogger(buildLogger({ LOG_LEVEL: config.get('LOG_LEVEL', { infer: true }) }));
  app.useGlobalPipes(buildValidationPipe());
  installShutdown(app, {
    DRAIN_DELAY_MS: config.get('DRAIN_DELAY_MS', { infer: true }),
    SHUTDOWN_TIMEOUT_MS: config.get('SHUTDOWN_TIMEOUT_MS', { infer: true }),
  });

  await app.listen(config.get('PORT', { infer: true }));
}

void bootstrap();
```

**The order has reasons.**

| step | why it sits here |
| --- | --- |
| `bufferLogs: true` | Holds boot-time logs in a buffer. They flush at once after the custom logger is attached |
| `app.get(ConfigService)` | The values are already validated. **Do not read `process.env` here** |
| `useLogger` | Using the `logger` option of `NestFactory.create` would mean reading the environment before the app |
| `useGlobalPipes` | It has to be attached before a controller receives a request |
| `installShutdown` | **Before** `listen`. A SIGTERM arriving after the listener opens finds no wiring |
| `listen` | Last. Requests come in from this line on |

The seam slots `app.useGlobalFilters(new AllExceptionsFilter())` in right after `useGlobalPipes` —
because the envelope must be emitted from exactly one place.

## 5. What makes decorators work (`tsconfig.json`)

Nest finds injection targets through decorator metadata. Without the two options below **it compiles
and boot dies** — a common cause of `Nest can't resolve dependencies`.

<!-- file: tsconfig.json -->
```json
{
  "compilerOptions": {
    "module": "commonjs",
    "target": "ES2023",
    "moduleResolution": "node",
    "experimentalDecorators": true,
    "emitDecoratorMetadata": true,
    "strict": true,
    "strictPropertyInitialization": false,
    "esModuleInterop": true,
    "outDir": "dist",
    "skipLibCheck": true
  },
  "include": ["src/**/*", "test/**/*"]
}
```

Rather than turning `strictPropertyInitialization` off, **put `!` on entity and DTO fields**
(that is how this pack's code is written). Turn it off and a missing initialization passes silently in
ordinary classes outside entities too. It is left in the config above as a cushion for porting an existing project.

## 6. Circular dependencies and barrels

**Do not keep a barrel file (`index.ts`).** The `import { X } from '../tasks'` form makes the module
graph and the file graph diverge, and when a circular dependency appears in Nest the cause hides in
the barrel. Every import in this pack points at a file directly.

When a cycle really is needed there is `forwardRef(() => OtherModule)`, but first try **straightening
the dependency into one direction** — usually pushing the shared part down into a pure function in
`common/` resolves it. `forwardRef` turns boot order into something a human has to reason out.

## Misuse list ① — Express idiom → NestJS form

They sit on the same Node but are **different systems.** Carry an Express habit over unchanged and Nest's
guards, pipes and filters are bypassed wholesale.

| old habit (Express) | current form (NestJS 11) |
| --- | --- |
| `app.use(express.json())` | On by default. Adjust only the limits, through the `NestFactory.create(App, { bodyParser: true })` family |
| `app.use(authMiddleware)` | `AuthGuard` (`CanActivate`) — it sees the execution context and the metadata |
| `app.use(errorHandler)` (4 arguments) | A `@Catch()` exception filter + `useGlobalFilters` |
| `req`/`res` straight in the handler | The `@Body()`, `@Query()` and `@Param()` parameter decorators |
| `router.get('/x')` in a router file | `@Controller('x')` + `@Get()` — **the class is the routing declaration** |
| `next(err)` | Just `throw` — the pipeline sends it to the filter |
| Controlling execution order through middleware order | The guard → interceptor → pipe → handler order is **fixed** |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `providers` vs `exports` | `providers` is what is used inside this module, `exports` is what a module importing this one may use. Need both, write both |
| `imports` vs a file import | Using a module needs the `imports` array. Using only its types, a file import is enough |
| `forRoot` vs `forFeature` | Connection and global configuration go in `forRoot` (once, at the root); per-entity Repositories go in `forFeature` (in each feature module) |
| `useGlobalPipes` vs an `APP_PIPE` provider | The former is built outside DI. When the pipe needs a provider injected, use `APP_PIPE` — this pack's pipe needs no injection, so it takes the former |
| Missing `@Injectable()` | With nothing injected it looks like it works, then dies with `Cannot read properties of undefined` the moment one dependency is added. Always put it on a provider |
