<!-- orangekit-pack: backend/aws-serverless v3.13.0 verified 2026-08-23 @aws-sdk/client-dynamodb@3 @aws-sdk/lib-dynamodb@3 @aws-lambda-powertools/logger@2 aws-cdk-lib@2 constructs@10 zod@4 typescript@5 vitest@2 esbuild@0.28 @types/aws-lambda@8 @types/node@22 aws-jwt-verify@5 -->

# aws-serverless axis pack — hub fragments

These are the axis-local fragments to insert verbatim when building the combination hub (`SKILL.md`). Each fragment
sits between `<!-- pack-slot: name -->` markers and is closed within the axis.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── env.ts                   # the only file under `src/` that reads the process environment (validates and fails at the cold start)
├── keys.ts                  # single-table key assembly — the only place pk/sk are built
├── db/
│   ├── client.ts            # the DocumentClient singleton — built at **module top level**
│   └── tasks.ts             # Query / conditional writes. It knows neither the event nor the response
├── schemas/
│   └── task.ts              # Zod schemas — body and query
├── http/
│   ├── parse.ts             # parseBody/parseQuery/pathParam — pulls the values out of the event
│   ├── errors.ts            # the ERROR_STATUS table · DynamoDB error detection · ZodError normalization
│   ├── app-error.ts         # AppError — **owned by the seam**
│   ├── respond.ts           # envelope emission — **owned by the seam**
│   └── require-auth.ts      # requireAuth · AuthUser — **owned by the seam**
├── obs/
│   └── logger.ts            # the powertools logger · the withContext wrapper · the cold-start flag
├── handlers/                # one function per route. export const handler = withContext(...)
└── services/                # domain logic that ties several queries together
infra/
├── app.ts                   # the CDK entry point
├── table.ts                 # the TaskTable construct (single table + GSI1)
└── routes.ts                # route↔function mapping — **owned by the seam**
test/
└── invoke.ts                # the harness that runs a handler directly
```

**Layers flow in one direction only**: `handlers → services → db`. There are **two** exceptions —
`http/app-error.ts` (the common type for domain failures) and `http/errors.ts` (the SDK exception detectors).
Both are pure modules that know nothing about HTTP, so `db/` importing them does not invert the direction.
<!-- /pack-slot -->

<!-- pack-slot: architecture-overview -->
## Architecture Overview

**Module resolution is `bundler`** — do not put an extension on a relative import. esbuild does the bundling and
what goes up to Lambda is the bundle output.

**The event is an `APIGatewayProxyEventV2`.** `body` · `queryStringParameters` ·
`pathParameters` are **optional fields**, not `| null` (`| null` is the V1 shape —
checked against `@types/aws-lambda@8.10.162`). Pull them out with the `?? {}` · `?.` forms that are safe either way.

**Three things serverless changes.** ① There is no resident connection — build the client at module top level
so it sits outside the cold start, and switching to a relational DB makes connection pooling a mandatory topic. ② There is no
middleware chain — `requireAuth` is not middleware but **a function called on the handler's first line**.
③ The function is the unit of permission — least privilege only holds once a function is split per route.

**There is no data-layer policy engine.** DynamoDB has no enforcement like RLS and IAM condition keys are not a general
substitute — **the application layer is the only real boundary** and the owner goes into the partition key.
Move the BaaS axis's "double defense" statement here and it becomes exactly the opposite guidance.

**The T1 data-modeling card lies dormant.** That card presumes a relational model and its `paths:` does not
match either — single-table design and access-patterns-first are owned by `resources/data-modeling.md`.
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
## Core Principles

1. **Ownership lives in the partition key.** There is no policy engine, so put the owner in `pk` and confirm it
   with a condition expression. Reading first and sifting with `.filter()` happens after someone else's item was already read,
   and **a `DeleteCommand` with no condition expression succeeds even on an item that does not exist** — success means not "it was
   deleted" but "it is absent now that this finished" (`data-access.md` §4 · `data-modeling.md` §5).
2. **Fill in the access-pattern table first.** In single-table design the key is a function of the query. Draw the entities
   first and you end up patching it with `Scan` later, and by then the key cannot be changed (`data-modeling.md` §1).
3. **Build the client at module top level.** Build it inside the handler and every call stands a new connection up,
   and the cost you could have moved outside the cold start attaches to every request. Conversely, **a value that differs
   per request does not go at top level** — that value leaks into the next invocation (`data-access.md` §2 · `handler-patterns.md` §1).
4. **There is no middleware chain.** `requireAuth` is not middleware but **a function called on the handler's
   first line**, and the wrapping stops at the single `withContext`. Stack wrappers and the trail of which layer built the
   response is cut (`handler-patterns.md` §4).
5. **The function is the unit of permission.** Least privilege only holds once a function is split per route. Attach
   every route to one function and that function's IAM policy becomes the union of every action (`deploy-and-iam.md` §3).
6. **The environment fails at the cold start.** `src/env.ts` runs `safeParse` at module top level, so a bad
   environment is a boot failure. Let it blow up at request time instead and you get a function that is half alive
   (`input-validation.md` §2).
7. **Status mapping is the one `ERROR_STATUS` table.** Pick a status per handler and the same failure
   goes out under a different code per path (`error-handling.md` §2).
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
## Common Imports

```ts
// event and context types — these are V2. body, queryStringParameters and pathParameters are optional fields
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2, Context } from 'aws-lambda';

// DynamoDB — wrap the low-level client in a Document client and build it exactly once
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { GetCommand, QueryCommand, PutCommand, UpdateCommand, DeleteCommand } from '@aws-sdk/lib-dynamodb';

// validation — a schema at every boundary. Environment variables go through the same tool
import { z } from 'zod';

// observability — powertools redacts nothing. What gets logged is the caller's decision
import { Logger } from '@aws-lambda-powertools/logger';

// infrastructure (infra/) — the same repository as the runtime code, a different bundle
import { App, Duration, RemovalPolicy, Stack } from 'aws-cdk-lib';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import { Architecture, Runtime } from 'aws-cdk-lib/aws-lambda';
import { PolicyStatement } from 'aws-cdk-lib/aws-iam';
import { LogGroup, RetentionDays } from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';

// standard library — cursor encoding and ID generation
import { Buffer } from 'node:buffer';
import { randomUUID } from 'node:crypto';
```

**Do not put an extension on a relative import** — module resolution is `bundler` and esbuild does the bundling.
It is `import { ddb } from './client'`, not `'./client.js'`.

**`routes`, `AppError`, `respond` and `requireAuth` are owned by the seam.** The pack only calls them, and
having no definition before assembly is normal.
<!-- /pack-slot -->

<!-- pack-slot: http-status-and-antipatterns -->
## HTTP status mapping and the recurring anti-patterns

`ERROR_STATUS` is **the only mapping table**. Read it in the form `ERROR_STATUS[code] ?? 500` —
let `undefined` land in the status slot for an unknown code and the response itself breaks.

| domain code | status | when |
| --- | --- | --- |
| `VALIDATION_FAILED` | 400 | a schema or format violation · `ValidationException` · a cursor that failed to decode |
| `UNAUTHENTICATED` | 401 | the token is missing or failed verification |
| `FORBIDDEN` | 403 | the subject is confirmed but **the role is insufficient** |
| `NOT_FOUND` | 404 | not in my partition — **someone else's item lands here too** |
| `CONFLICT` | 409 | an attempt to create something that already exists (`putTask`'s `attribute_not_exists`) |
| `INTERNAL` | 500 | everything else `toAppError` folded up |

- ❌ **Giving a 403 for someone else's item** — a 403 leaks existence. Use `FORBIDDEN` **only for an insufficient
  role**, and treat an item that failed the owner condition as **not existing**.
- ❌ **Folding `ConditionalCheckFailedException` into one code** — the same exception is a 409 in `putTask`
  and a 404 in `updateTask` and `deleteTask`. **Which condition expression failed decides the code**
  (`error-handling.md` §4).
- ❌ **Telling SDK exceptions apart with `instanceof`** — v3 tells them apart by `name`.
  `isConditionalCheckFailed` is the one place for that.
- ❌ **The handler picking the status code itself** — bypass `respond` (the seam) and `ERROR_STATUS`
  and there are two envelopes.
- ❌ **Putting the exception straight into the response** — the SDK message carries the table name and key structure.
  Normalize with `toAppError` first, and leave diagnostics only in `logger`. **powertools redacts
  nothing**, so do not put tokens or a full request body in the log (`handler-patterns.md` §7).
<!-- /pack-slot -->

## For the seam to fill

| slot | why it is a function of the combination |
| --- | --- |
| `api-endpoints` | Route↔function mapping and the response envelope. The wire contract decides the envelope |
| `auth-boundaries` | Cognito token verification and claim extraction. The auth method depends on the frontend axis |
| `complete-example` | IaC → table → access pattern → query → handler → test, end to end |
