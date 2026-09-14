<!-- orangekit-pack: backend/aws-serverless v3.13.0 -->
# The Lambda handler shape — a world where one request wakes one function

This file owns **the handler's lifetime and wiring**: what goes at module top level, what the wrapper
does, and what does and does not go into the log. Input validation is owned by
`resources/input-validation.md`, status code mapping by `resources/error-handling.md`,
and queries by `resources/data-access.md`. `requireAuth`, `respond` and `AppError` are
defined by **the seam** (`src/http/require-auth.ts` · `src/http/respond.ts` ·
`src/http/app-error.ts`) — here they are only called.

## 1. The decision — does this value go at module top level or inside the handler

The execution environment **freezes and thaws** between requests. Module top-level code runs once at the cold
start and **every later request that environment handles shares** the result. So there is one criterion —
**is it safe for the next request to read this value.**

| value | where it goes | why |
| --- | --- | --- |
| `ddb` (DocumentClient) | module top level | it finishes credential resolution and connection setup during the cold start. The `client-outside-handler` policy demands it |
| `logger` | module top level | the instance is reused. Request-scoped values are attached and removed with `appendKeys` |
| `env` (validated environment values) | module top level | it kills a bad deploy **at initialization**, not on the first request |
| Zod schema objects | module top level | the schema assembly cost becomes per environment rather than per request |
| the authenticated subject · the request body · the request ID | **inside the handler** | at top level the next request reads the previous user's value — the silent data-leak path of this axis |
| a cache of query results | inside the handler (or at top level with an explicit TTL) | an environment lives for tens of minutes to several hours. A cache with no invalidation keeps handing out stale data |

**Top-level initialization is not lazy.** Once the module is loaded it runs unconditionally. So only things that
need no `await` go at top level — a top-level `await` lengthens the cold start, and on failure
the function dies before the handler is ever called. <!-- unverified: the initialization-failure behavior of the Lambda runtime. Not reproduced locally -->

## 2. The standard handler (`src/handlers/tasks-get-one.ts`)

One file per route. The order is fixed: **auth → input → data → response**, with
a `try/catch` around the outside that turns a failure into an envelope.

```ts
// src/handlers/tasks-get-one.ts
import type { APIGatewayProxyEventV2 } from 'aws-lambda';
import { withContext, logger } from '../obs/logger';
import { requireAuth } from '../http/require-auth';
import { respond } from '../http/respond';
import { AppError } from '../http/app-error';
import { getTask } from '../db/tasks';
import { pathParam } from '../http/parse';

export const handler = withContext(async (event: APIGatewayProxyEventV2) => {
  try {
    const user = requireAuth(event);              // not middleware — a function call on the first line
    const id = pathParam(event, 'id');
    const task = await getTask(user.id, id);      // the owner comes first
    if (!task) throw new AppError('NOT_FOUND', 'task not found');
    logger.info('task read', { ownerId: user.id, taskId: id });
    return respond(task);
  } catch (e) {
    return respond.fail(e);                       // envelope emission in one place only
  }
});
```

`event` is an `APIGatewayProxyEventV2`. `body` · `pathParameters` · `queryStringParameters` are
**optional fields**, not `| null`, so pull them out with `?.` · `?? {}`. The handler does not settle the
status code — `respond.fail` normalizes through `toAppError` and then reads it from `ERROR_STATUS`.

**Do not distinguish absence from unauthorized.** Asking for someone else's task is a 404 too. `getTask(user.id, id)`
puts the owner in the key condition, so someone else's item is never read in the first place and both cases
end up with the same response — hand out a separate 403 and an unauthorized user can enumerate what exists.

## 3. Observability wiring (`src/obs/logger.ts`)

The logger, the wrapper and the cold-start flag live in one file. All three depend on **module top-level state**, so
splitting them gives you two copies of the flag.

<!-- file: src/obs/logger.ts -->
```ts
// src/obs/logger.ts
import { Logger } from '@aws-lambda-powertools/logger';
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2, Context } from 'aws-lambda';
import { env } from '../env';

type ApiHandler = (e: APIGatewayProxyEventV2, c: Context) => Promise<APIGatewayProxyResultV2>;

export const logger = new Logger({ serviceName: 'tasks', logLevel: env.LOG_LEVEL });

let cold = true;

export function isColdStart(): boolean {
  return cold;
}

export function withContext(h: ApiHandler): ApiHandler {
  return async (event, context) => {
    logger.addContext(context);
    logger.appendKeys({ coldStart: cold, routeKey: event.routeKey });
    try {
      return await h(event, context);
    } catch (e) {
      logger.error('unhandled handler error', e as Error);
      throw e;
    } finally {
      cold = false;
      logger.removeKeys(['coldStart', 'routeKey']);
    }
  };
}
```

Putting `removeKeys` in `finally` is the whole point. `appendKeys` **stays on the instance** —
leave it on and the next request's log goes out carrying the previous request's `routeKey`. For the same reason, request-
scoped values (the user ID, the body) are passed as arguments of the individual log call rather than through `appendKeys`.

There is a reason `withContext` is typed as the narrowed `ApiHandler` rather than `Handler`.
`Handler` in `@types/aws-lambda@8.10.162` supports the callback style as well, so its return is
`void | Promise<TResult>`; the result of `await h(...)` then includes `void` and the wrapper as written
does not type-check as a `Handler`. The narrowed shape is **assignable** to `Handler`, so the Lambda-side
contract is unchanged. <!-- verified: tsc 5.9.3 strict — TS2322 reproduced before the narrowing, `const asLambda: Handler = handler` passed after it -->

## 4. There is no middleware chain — the wrapping stops at one

`withContext` is **the only wrapper**. The reason nothing more is stacked is not taste.

- **A wrapper erases types.** Lift auth into a wrapper and the only channel for handing `AuthUser` to the handler
  is a field secretly attached to `event`, and that field lives outside the type system. A function call
  **returns** the value as `const user = requireAuth(event)`, so the type stays alive
- **A wrapper hides the order.** Once the chain passes three, the call site no longer shows which runs first.
  With three function calls on the handler's first three lines, the order is the code
- **A wrapper makes early return hard.** For middleware to emit a 401 it has to know the envelope, and then
  `respond` is called from two places — the shape the `envelope-from-respond` policy blocks

What `withContext` does is **observability only**: attaching the context, marking the cold start, and the last
net. It **logs an unhandled exception and rethrows it** — swallow it and the return value becomes `undefined`, so
API Gateway emits a causeless 502/500 and nothing is left in CloudWatch. In a local run
`throw new Error('kaboom')` was printed as `{"level":"ERROR","message":"unhandled handler error",
"error":{"name":"Error","message":"kaboom","stack":...}}` and then rethrown to the caller
unchanged. <!-- verified: tsx run — after the log was emitted, 'kaboom' arrived in the catch block -->

## 5. The cold-start flag — do not take powertools' `cold_start` at face value

Our `isColdStart()` reads the module top-level `cold` flag, and `withContext` lowers it to
`false` in its `finally`. So it is **`true` while the first invocation runs** and `false` after that
(local run: `true` before the call → `true` inside call 1 → `false` after call 1 → `false` on call 2).
<!-- verified: tsx run — isColdStart() instrumented before and after two invokeHandler calls -->

The `cold_start` key powertools attaches to the log is **a different thing**, and it carries two traps.

| trap | what actually happens |
| --- | --- |
| always `false` outside Lambda | the `Utility` constructor lowers `coldStart` to `false` immediately whenever `AWS_LAMBDA_INITIALIZATION_TYPE` is not `on-demand`. That is why a test or a local run only ever shows `cold_start:false` <!-- verified: @aws-lambda-powertools/commons 2.35.0 Utility.js getColdStart + output compared with and without the environment variable --> |
| reading it consumes it | `getColdStart()` returns `true` while flipping the internal flag to `false`. Call it once in the handler and the value `addContext` attaches becomes `false` <!-- verified: the same source as above, `if (this.coldStart) { this.coldStart = false; return true }` --> |

Under provisioned concurrency it is not `on-demand` either, so powertools' `cold_start` stays
`false`. **Use `isColdStart()` for branching, measurement and tests.** The log's `coldStart` key is
attached by `withContext` from our own flag, so the two values never diverge.

## 6. Timeouts and retries — 29 seconds is the real ceiling

Lambda's own ceiling is 15 minutes, but behind an API Gateway HTTP API you never reach it.
The integration timeout of `HttpLambdaIntegration` is **50ms to 29s**, and the default is 29s.
<!-- verified: aws-cdk-lib 2.266.0 aws-apigatewayv2-integrations/lib/http/lambda.d.ts:22-27 -->
If the integration cuts first the client gets a 504 and **the Lambda keeps running** — for a write,
a request the client saw as a failure may in fact have succeeded.

| failure | is it a retry target | basis |
| --- | --- | --- |
| a DynamoDB throttle (`isThroughputExceeded`) | **yes** — the SDK already retries. Once exhausted it comes down as a 429 | it is transient and the same request succeeds on the next attempt |
| an integration timeout (504) | conditionally — **a write is dangerous** | the server-side outcome is unknown. A conditional write is what makes a re-run safe |
| `AppError('VALIDATION_FAILED')` | no | the same input always fails the same way |
| `AppError('CONFLICT')` | no | a retry does not resolve the conflict |

**API Gateway does not retry a proxy integration** — the retry is the client's share.
So a create request needs an idempotency key held by a conditional write, or a client retry produces
a duplicate (`resources/data-access.md`). <!-- unverified: based on the AWS documentation. Not instrumented against a real API Gateway deployment -->

Set the function timeout **shorter** than the integration. With the integration cutting at 29s and the function at 60s, you are
billed for 31 seconds after the cut while building a response nobody will read.

## 7. Keeping secrets out of the log — powertools redacts nothing

powertools logger 2.35.0 has **no automatic masking.** A local run fed it six depths and read the
output, and **every one printed in plaintext**: a top-level `token`, `user.accessToken` (depth 2),
`a.b.password` and `a.b.connectionString` (depth 3), the `Bearer …` of `headers.authorization`,
an `apiKey` inside an array element, and **even a connection string embedded as a literal in an `Error`'s
`message` and `stack`**. <!-- verified: @aws-lambda-powertools/logger 2.35.0 — tsx run, all 6 probe outputs confirmed by running them, every one in plaintext -->

That last one is the most dangerous. `logger.error('failed', e)` carries `error.stack` wholesale, so once
a secret is in the exception message **it leaks however carefully the log keys were chosen.**

```ts
// src/handlers/tasks-get-one.ts
// ❌ carrying the event and the headers wholesale — nothing redacts them for you
logger.info('incoming', { event });
logger.debug('auth', { headers: event.headers });
// ✅ carry only identifiers and shape. Log presence, not the value
logger.info('list tasks', {
  ownerId: user.id,
  limit: q.limit,
  hasCursor: Boolean(q.cursor),
});
```

Three rules: ① do not hand `event` · `event.headers` · `requestContext.authorizer` over
wholesale ② leave a token or a secret as **a length or a presence flag** only ③ do not put a secret in an exception message —
`AppError`'s `message` goes to the client and to the log alike.

**Looking at `message` and `stack` alone is not enough.** An error object carries more than those two:

| what rides along | why it is a problem |
| --- | --- |
| **custom enumerable properties** attached to the `Error` | an AWS SDK exception **always** arrives carrying `$metadata` and `$fault`, and a transaction failure `CancellationReasons`. Request fragments and internal identifiers sit inside them |
| `Error.cause` | **the lower layer's exception comes up whole** along the cause chain. If a connection string is in there it leaks however carefully the upper message was polished |
| **this pack's own `respond.fail`** | on a 500 the adapter in `resources/error-handling.md` §6 **carries the error whole** as `{ code, err: e }`. The two rows above go straight into CloudWatch |

That last row is not an exception to the rule but **the place the rule applies**. A 500 is exactly where the cause has
to be kept, so deleting `err: e` is not the answer — pick what to carry (like `err: { name: e?.name,
message: e?.message }`) or narrow the access to the log group. Either way, **make the decision and
move on.** The seam owns `respond`, so that decision is the seam's share too.

## 8. Misuse list ① — Express/Fastify idiom → Lambda shape contrast table

| old habit (Express/Fastify) | current shape (Lambda + API Gateway HTTP API v2) |
| --- | --- |
| `app.use(authMiddleware)` | `const user = requireAuth(event)` on the handler's first line — there is no chain |
| `req.body` (a parser middleware fills it) | `parseBody(TaskCreateSchema, event)` — `event.body` is a string or absent entirely |
| `res.status(404).json(...)` | `return respond.fail(new AppError('NOT_FOUND', '...'))` |
| propagating an error with `next(err)` | `try/catch` + `respond.fail(e)` — there is no upper layer to propagate to |
| one process serving every route | one function per route — the unit of least-privilege IAM is the function |
| creating a connection pool at boot | one client at module top level. There is no pool and no resident connection |
| `process.on('uncaughtException')` | the `catch` in `withContext` — it logs and rethrows |
| debugging with `console.log` | the powertools `logger` — it has to be structurally queryable in CloudWatch |
| health-check initialization before `app.listen` | top-level initialization. A failure shows up as a function initialization failure |

## 9. Misuse list ② — confusable pairs

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| `logger.getColdStart()` vs `isColdStart()` | the former **is consumed when read** and is always `false` unless initialization is `on-demand`. Use the latter for branching and tests |
| `appendKeys` vs `appendPersistentKeys` | request scope takes the former (always remove it with `removeKeys`), environment-global the latter. Leave the former on and the next request's log is contaminated |
| `logger.addContext` vs `logger.appendKeys` | the former is only for the Lambda `Context` (function name · request ID · memory), the latter for arbitrary keys. Do not pass the event to `addContext` |
| `event.requestContext.requestId` vs `context.awsRequestId` | the former is the API Gateway request ID, the latter the Lambda invocation ID. Correlation tracing takes the former, execution tracing the latter |
| `throw` vs `return respond.fail(e)` | a failure meant for the client takes the latter. A `throw` is logged by `withContext`, rethrown, and becomes a gateway 5xx |
| `JSON.parse` on `event.body` directly vs `parseBody` | the former breaks when `isBase64Encoded` is `true`. Parsing happens in one place, `src/http/parse.ts` |
| `withContext` vs adding a wrapper | a second concern goes in as a **function call** on the handler's first line, not as a wrapper |
| a top-level constant vs a top-level cache | the former is safe (immutable), the latter is shared across requests — put a per-user value in it and that is cross-exposure |
