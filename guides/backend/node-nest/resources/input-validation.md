<!-- orangekit-pack: backend/node-nest v3.16.0 -->
# Input validation — the DTO class is the schema

This file owns **the shape of requests and environment variables**. Which status code a validation failure goes out as is owned by
`error-handling.md`, and how the controller receives the DTO by the seam.

## 1. What is validated where

| input | validated by | fails at |
| --- | --- | --- |
| Request body, query, params | DTO class + the global `ValidationPipe` | Before request handling (400) |
| Environment variables | `EnvVars` + `validateEnv` | **At boot** (the process exits) |
| DB constraints | CHECK and UNIQUE in the migration | At query execution (409 and the like) |

**Attach all three layers.** The DTO gives the user a friendly 400, and the DB constraints block the paths
that bypass the DTO (migrations, manual SQL, another service). The temptation to cut it to one is real,
but they block different things.

## 2. Global pipe (`src/common/validation.ts`)

<!-- file: src/common/validation.ts -->
```ts
import { BadRequestException, ValidationPipe } from '@nestjs/common';
import { fieldErrors } from './error-status';

export function buildValidationPipe(): ValidationPipe {
  return new ValidationPipe({
    whitelist: true,
    forbidNonWhitelisted: true,
    transform: true,
    transformOptions: { enableImplicitConversion: false },
    exceptionFactory: (errors) =>
      new BadRequestException({
        code: 'VALIDATION_FAILED',
        details: fieldErrors(errors),
      }),
  });
}
```

<!-- verified: @nestjs/common@11.2.1 + class-validator@0.15.1, run — sending the unknown key admin produced a 400 and {"code":"VALIDATION_FAILED","details":{"admin":["property admin should not exist"]}} -->

| option | why it is on |
| --- | --- |
| `whitelist` | **Strips** keys not declared on the DTO. The first line of defense against mass assignment |
| `forbidNonWhitelisted` | **Rejects** instead of stripping. Without it a misspelled field quietly vanishes, a 200 goes out, and the cause is unfindable |
| `transform` | Turns the plain object into a DTO **instance**. Without it neither `@Type` nor defaults apply |
| `transformOptions.enableImplicitConversion: false` | Does not change types by guesswork. Put `@Type` **explicitly** only on the fields that need conversion (§4) |
| `exceptionFactory` | The default envelope is `{ message: string[] }`, which **flattens the field information away**. This is the only place to turn it into a per-field map |

The difference between the default envelope and the `exceptionFactory` envelope, as actual responses:

| form | response body |
| --- | --- |
| Default | `{"message":["title must be a string"],"error":"Bad Request","statusCode":400}` |
| This pack | `{"code":"VALIDATION_FAILED","details":{"title":["title must be a string"]}}` |

**Do not build a `new ValidationPipe(...)` per controller.** The moment the options diverge, some
endpoints reject unknown keys and others let them through — and that difference is invisible until you
have read all of the code.

## 3. Request DTOs (`src/tasks/dto/`)

<!-- file: src/tasks/dto/create-task.dto.ts -->
```ts
import { IsIn, IsOptional, IsString, MaxLength, MinLength } from 'class-validator';

export class CreateTaskDto {
  @IsString() @MinLength(1) @MaxLength(200)
  title!: string;

  @IsOptional() @IsIn(['open', 'done'])
  status?: 'open' | 'done';
}
```

Derive a partial update with `PartialType` — write the fields twice and they diverge.

<!-- file: src/tasks/dto/update-task.dto.ts -->
```ts
import { PartialType } from '@nestjs/mapped-types';
import { CreateTaskDto } from './create-task.dto';

export class UpdateTaskDto extends PartialType(CreateTaskDto) {}
```

<!-- verified: @nestjs/mapped-types@2.1.1 + @nestjs/common@11.2.1, run — an empty body {} passed, and sending {status:'done'} left the DTO with the single key ['status'] -->
`PartialType` **only makes the fields optional**; it creates no defaults. So a field that was not sent is
absent from the DTO entirely, and `update(where, patch)` never touches that column.

**Do not carry default values into a partial-update DTO.** Put an initializer like `= 'open'` on
`CreateTaskDto`'s `status` and `PartialType` inherits it too, so a request meant to change only the status
overwrites the title, or the reverse. The syntax is perfect and only running it reveals the problem.

## 4. A query string is always a string

<!-- file: src/tasks/dto/list-tasks.query.dto.ts -->
```ts
import { Type } from 'class-transformer';
import { IsIn, IsInt, IsOptional, IsString, Max, Min } from 'class-validator';

export class ListTasksQueryDto {
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(100)
  limit: number = 20;

  @IsOptional() @IsString()
  cursor?: string;

  @IsOptional() @IsIn(['open', 'done'])
  status?: 'open' | 'done';
}
```

<!-- verified: class-transformer@0.5.1, run — ?limit=5 arrived as the number 5, no query arrived as the default 20, and ?limit=999 was a 400 -->
Without `@Type(() => Number)`, `@IsInt()` rejects `'5'` (a string) and **a legitimate request becomes a
400.** Turning on `enableImplicitConversion` globally converts without the decorator, but then unintended
fields get converted by guesswork too, producing surprises like `'true'` becoming a boolean.
Stating it only where conversion is needed is the narrower option.

A default (`limit: number = 20`) applies only when `transform: true` is on — the DTO **instance** has to
be built for the class field initializer to live.

## 5. Environment variables (`src/config/env.ts`)

<!-- file: src/config/env.ts -->
```ts
import { plainToInstance } from 'class-transformer';
import { IsIn, IsInt, IsString, Matches, Max, Min, validateSync } from 'class-validator';

export class EnvVars {
  @IsIn(['development', 'test', 'production'])
  NODE_ENV: 'development' | 'test' | 'production' = 'development';

  @IsInt() @Min(1) @Max(65535)
  PORT: number = 3000;

  @IsString()
  DATABASE_URL!: string;

  @Matches(/^[a-z_][a-z0-9_]*$/)
  DB_SCHEMA: string = 'public';

  @IsIn(['error', 'warn', 'log', 'debug', 'verbose'])
  LOG_LEVEL: 'error' | 'warn' | 'log' | 'debug' | 'verbose' = 'log';

  @IsInt() @Min(1) @Max(100)
  DB_POOL_MAX: number = 10;

  @IsInt() @Min(0)
  DB_SLOW_QUERY_MS: number = 300;

  @IsInt() @Min(0)
  DRAIN_DELAY_MS: number = 5000;

  @IsInt() @Min(1000)
  SHUTDOWN_TIMEOUT_MS: number = 10000;
}

export function validateEnv(raw: Record<string, unknown>): EnvVars {
  const parsed = plainToInstance(EnvVars, raw, {
    enableImplicitConversion: true,
    exposeDefaultValues: true,
  });
  const errors = validateSync(parsed, { whitelist: false, forbidUnknownValues: false });
  if (errors.length > 0) {
    const lines = errors.map((e) => `  ${e.property}: ${Object.values(e.constraints ?? {}).join(' · ')}`);
    throw new Error(`Environment validation failed — aborting boot\n${lines.join('\n')}`);
  }
  return parsed;
}
```

<!-- verified: class-validator@0.15.1 + class-transformer@0.5.1, run — with DATABASE_URL unset and PORT='abc', boot failed immediately carrying the constraint messages of both fields -->
**`AppModule` passes this function to `ConfigModule.forRoot({ validate: validateEnv })`**
(`project-structure.md` §2). Without that wiring this file is dead code.

| choice | reason |
| --- | --- |
| `enableImplicitConversion: true` | Environment variables are **all strings**. Here alone, conversion by guesswork is right |
| `exposeDefaultValues: true` | Without it the class field defaults are ignored and `PORT` comes out `undefined` |
| `forbidUnknownValues: false` | The process environment is full of keys we do not know. Make those an error and it boots nowhere |
| `throw` (rather than returning) | The point is to **abort** boot. A process that came up on a bad configuration blows up on one particular request hours later |

**This file is not where `process.env` is read.** `ConfigModule` passes the process environment into this
function, and application code obtains values only through `ConfigService`. The only two places that read it
directly are the CLI DataSource, which runs outside DI, and the test harness — and that is the entire
exemption list for `env-single-entry` in `policies.md`.

`DB_SCHEMA` carries `@Matches(/^[a-z_][a-z0-9_]*$/)` because **that value is used as an identifier** —
an identifier cannot be parameterized, so its shape is narrowed up front.

## Misuse list ① — Zod/Joi idiom → class-validator form

| old habit (schema object) | current form (DTO class) |
| --- | --- |
| Declaring `z.object({...})` separately | The class is the schema. Type and validation live in one declaration |
| Calling `schema.parse(body)` in the handler | The global `ValidationPipe` does it before the controller is entered |
| Rejecting unknown keys with `.strict()` | `whitelist` + `forbidNonWhitelisted` (pipe options) |
| `z.coerce.number()` | `@Type(() => Number)` — stated per field |
| `.partial()` | `PartialType(Dto)` (`@nestjs/mapped-types`) |
| `z.infer<typeof Schema>` | The class name is the type |
| `.optional()` | `@IsOptional()` — **without it `undefined` is validated too** and fails |
| Branching on a `safeParse` result | `exceptionFactory` is that place. The handler sees only the success path |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `@IsOptional()` vs `?:` | The first skips validation, the second is a type annotation. **Both** are needed |
| `whitelist` alone vs also `forbidNonWhitelisted` | The first deletes silently. To surface a client typo, the second |
| `@Type(() => Number)` vs `enableImplicitConversion` | The first names a field, the second guesses globally. Request DTOs take the first, environment variables the second |
| `@IsIn([...])` vs a TypeScript union | A union disappears at runtime. A value set always needs `@IsIn` |
| Missing `@ValidateNested()` | The nested object passes **unchecked**. Use it paired with `@Type` |
| Adding methods or default logic to a DTO | A DTO is a shape declaration. Conversion logic goes to the service — that is what lets you slot a double |
