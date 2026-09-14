<!-- orangekit-pack: backend/node-api v3.13.0 -->
# File layout and app assembly — layer boundaries · Express 5 wiring

What this file owns: the layer boundaries (`routers → services → db`) and the means of enforcing them · `makeApp` ·
`notFound` · middleware order · the router mount points · the async handler convention. What it does not own:
**router bodies, the response envelope, `errorHandler`, and `AppError` are owned by the seam** (`src/http/routers/` ·
`src/http/error-handler.ts` · `src/http/app-error.ts`). Queries are in `resources/data-access.md`, environment variables in
`resources/input-validation.md`, and the process lifetime (boot logs, shutdown, health check bodies) in `resources/operations.md`.

## 1. Judgment — which layer does new code go in

| what that code does | where it goes | what it may take |
| --- | --- | --- |
| reads the request and builds the response envelope | `src/http/routers/` (seam) | `Request` · `Response` · `NextFunction` |
| ties several queries together and sets the transaction boundary | `src/services/` | plain arguments (`ownerId` · a DTO) |
| one block of queries against one table | `src/db/` | plain arguments only |
| request shape validation | `src/schemas/` + `src/http/parse.ts` | Zod schemas |
| process concerns (logger, health, shutdown) | `src/ops/` | — |
| assembles the app (mounting, order) | `src/app.ts` | — |
| starts the process (`listen`, signals) | `src/index.ts` | — |

When the judgment is unclear, ask **"does testing this code require an HTTP server"**. If not, it belongs in the
service or db layer. It is also why `src/app.ts` does not call `listen` — a test can hand `makeApp()` straight to supertest
without taking a port (`resources/testing.md`).

## 2. Layering flows in one direction only

`routers → services → db`. A reverse import (`db/` calling `http/`) makes a query test require a server,
and it ends with the data layer taking the request object as an argument.

**There is one exception**: `src/db/` may import `src/http/app-error`. `AppError` is not an HTTP
adapter but a domain error type that knows no status code (the mapping is done by `ERROR_STATUS`), and
its living under `src/http/` is the result of L0 nailing down the layout of the files the seam owns.

Discipline alone does not hold, so a check is attached.

```json
// package.json — scripts excerpt
"scripts": {
  "lint:layers": "! grep -rn \"from '[.][.]/http/\" src/db | grep -v http/app-error"
}
```

**Block confirmation**: planting `import { errorHandler } from '../http/error-handler'` in
`src/db/tasks.ts` and running it printed that line and exited 1; removing it gave 0. Running the file and catching something are
different, so plant a defect and confirm before putting it in CI.

## 3. App assembly (`src/app.ts`)

`makeApp()` **only assembles** the app. It takes no requests and grabs no port.

<!-- file: src/app.ts -->
```ts
// src/app.ts
import express, { type Express, type RequestHandler } from 'express';
import { AppError } from './http/app-error';
import { errorHandler } from './http/error-handler';
import { healthz, readyz } from './ops/health';
import { tasksRouter } from './http/routers/tasks';

export const notFound: RequestHandler = (_req, _res, next) => {
  next(new AppError('NOT_FOUND', 'Route not found'));
};

export function makeApp(): Express {
  const app = express();
  app.disable('x-powered-by');

  app.get('/healthz', healthz);          // before the parser and auth — it has to answer even when dependencies are down
  app.get('/readyz', readyz);

  app.use(express.json({ limit: '1mb' }));
  app.use('/api/tasks', tasksRouter);    // the router applies requireAuth

  app.use(notFound);                     // no match → AppError
  app.use(errorHandler);                 // envelope emission — must be last
  return app;
}
```

**Confirmed by running it** (Express 5.2.1): `/healthz` 200 · `/api/tasks/…` 200 · both unmatched
`/api/tasks/no-such` and `/nope` gave a 404 through the error envelope. The place for the request logger (`resources/operations.md`) is
**after** the health endpoints and **before** the routers — so health polling does not fill the log.

Without `app.use(express.json())` ahead of the routers, `req.body` is `undefined` in the handler.
Put it globally instead and even a file upload route passes through the JSON parser, so once such a route appears,
narrow it to the mount point, as in `app.use('/api/tasks', express.json(), tasksRouter)`.

## 4. Middleware order — get it wrong and the envelope disappears

Express walks in registration order. **`notFound` goes after every router and before `errorHandler`.**

Measured on the same app with only the order changed:

| arrangement | response for `/nope` |
| --- | --- |
| `…routers → notFound → errorHandler` | `404` + the JSON envelope |
| `…routers → errorHandler → notFound` | `500` + Express's default **HTML error page** |
| the error handler declared with 3 arguments `(err, req, res)` | `500` + HTML — it is registered as ordinary middleware |

The third is the quiet trap. Express identifies error middleware by **an argument count of 4** and nothing else.
Delete `next` because you do not use it and that function never sees an error again — keep it, renamed to `_next`.

There is one place that emits the envelope: `errorHandler`. If a router does `res.status(400).json(...)`
itself, the same failure goes out in a different shape depending on where it happened.

## 5. Router mounting and Express 5 path syntax

The router files are owned by the seam. What `makeApp` decides is **the mount point** and nothing else.

```ts
// src/app.ts — as domains grow, only the mount lines grow
app.use('/api/tasks', tasksRouter);
app.use('/api/users', usersRouter);
```

Express 5's path matcher changed, and the wildcard and optional-parameter notations used in 4 now **throw at boot**.
They blow up at route registration time, so everything dies right after a deploy.

<!-- verified: ran express@5.2.1 — app.get('*')·app.get('/:id?') threw a PathError -->

| notation | on Express 5.2.1 |
| --- | --- |
| `'*'` | `PathError: Missing parameter name at index 1` |
| `'/*splat'` | fine — use a named wildcard |
| `'/:id?'` | `PathError: Unexpected ? at index 4` |
| `'/tasks{/:id}'` | fine — braces mark an optional segment |

With `notFound` there is no need for a catch-all route in the first place. The table above is for porting existing code over.

## 6. Async handlers — do not build a wrapper

<!-- verified: ran express@5.2.1 — a throw from an async handler reached errorHandler and the 404 envelope went out -->
Express 5 forwards a rejected promise returned by a handler to `next(err)` **automatically**. The
`asyncHandler`·`express-async-errors` style wrappers used in Express 4 are unnecessary on this axis.

```ts
// src/http/routers/tasks.ts — a file the seam owns (shape only)
// ✅ just throw and it reaches errorHandler
router.get('/:id', requireAuth, async (req, res) => {
  const task = await getTask(req.user.id, req.params.id);
  if (!task) throw new AppError('NOT_FOUND', 'Task not found');
  res.json({ data: task });
});
```

But **a throw inside a callback is not forwarded.** An exception inside `setTimeout(() => { throw … })` or inside an
event listener kills the process. Always return asynchronous work as a promise and `await` it.

## 7. Boot (`src/index.ts`)

`index.ts` does three things — assemble · `listen` · **wire the signals**. Put logic here and a test cannot call it
without taking a port. This section is canonical for `src/index.ts` —
`resources/operations.md` owns the body of `shutdown` and does not redraw this file.

<!-- file: src/index.ts -->
```ts
// src/index.ts
import { makeApp } from './app';
import { env } from './env';
import { logger } from './ops/logger';
import { shutdown } from './ops/shutdown';

const server = makeApp().listen(env.PORT, () => logger.info({ port: env.PORT }, 'listening'));

process.on('SIGTERM', () => { void shutdown(server); });
process.on('SIGINT', () => { void shutdown(server); });
```

**Do not call `shutdown(server)` at the top level.** `shutdown` is not a function that hangs the signals but the function that
**performs the drain** (`(server: Server) => Promise<void>`). Called at the top level, the drain runs at the same moment as boot,
the process does not live a single second, and **because the exit code is 0 a crash loop looks like repeated clean
shutdowns.** Confirmed by running it: that shape printed `draining`·`complete` before it even printed `listening` and
died with exit 0. Called inside the handler, it stays alive after `listening` and drains only on SIGTERM.

The port comes from `env` — the only file that reads `process.env` is `src/env.ts`. Boot logs go through the
structured logger, not `console`. `console` has neither a level nor request correlation, so it is not
searchable in production. `shutdown` takes the server handle because it needs something to drain — the body (SIGTERM
handling, connection draining) and the signature are canonical in `resources/operations.md`.

## 8. Errors thrown by the body parser

`express.json()` throws on a malformed body before it reaches the router. **The measured error shapes**:

| input | `err.name` | `err.status` | `err.type` |
| --- | --- | --- | --- |
| `{bad` | `SyntaxError` | `400` | `entity.parse.failed` |
| a body over the `limit` | `PayloadTooLargeError` | `413` | `entity.too.large` |

These errors are not `AppError`, so without normalization they all drop to 500 — a client's mistake is
reported as a server error and the alerts fire wrongly. `toAppError` does the normalization and
`ERROR_STATUS` holds the mapping table (`resources/error-handling.md`). `makeApp` decides only **where** the parser goes.

## Misuse list ① — Express 4 → Express 5 idioms

| old habit (Express 4) | current shape (Express 5.2.1) |
| --- | --- |
| `app.get('*', notFound)` <!-- verified: ran it — PathError --> | `app.use(notFound)` (as middleware, not a route) |
| `router.get('/:id?')` <!-- verified: ran it — PathError --> | `router.get('/tasks{/:id}')` |
| wrapping with `asyncHandler(fn)` <!-- verified: ran it — the 404 envelope arrived with no wrapper --> | just an `async` handler. A rejected promise is forwarded automatically |
| the 2-argument call `res.json(201, body)` <!-- verified: ran express@5.2.1 — status 200, body `201` --> | `res.status(201).json(body)`. The 2-argument call sends **status 200 + the body `201`** with no exception — it is silently wrong |
| `app.del('/x', h)` <!-- verified: ran it — typeof app.del === 'undefined' --> | `app.delete('/x', h)` |
| `req.param('id')` <!-- verified: ran it — express.request.param is undefined --> | `req.params.id` · `req.query.id` |
| `res.redirect('back')` <!-- verified: ran express@5.2.1 — 302 Location: back --> | the special handling is gone, so it navigates to the literal string `back`. When you need a return path, send it to **a fixed path the server decides** |
| `app.use(bodyParser.json())` | `app.use(express.json())` — no separate package needed |

**Do not put a value that came from the request into `Location`.** Headers, the query, and the body are chosen by the attacker, so an absolute URL,
a protocol-relative one (`//host`), or `javascript:` passes straight through — that is an open redirect. This axis is a JSON API, so
a redirect is rare to begin with, and for a combination that needs a post-login return path that validation is owned by the seam's
`auth-boundaries` slot. If you must handle it here, a string prefix or an origin comparison is not enough:
you have to validate **the output path after normalization** for `/..//host` to be blocked.

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `app.use(fn)` vs `app.use(path, fn)` | with one argument **every** request passes through it. To narrow the mount point, give the path first |
| `notFound` vs `errorHandler` | the former is the 3-argument middleware that **turns** "no route matched" into an error, the latter the 4-argument middleware that **turns** that error into an envelope. The order is always this one |
| `next(err)` vs `throw err` | inside a synchronous or `async` handler the two are the same. Inside a callback a `throw` is not forwarded, so only `next(err)` works |
| `makeApp()` vs `app.listen()` | separate assembly from boot. A test hands `makeApp()` to supertest and takes no port |
| `src/services/` vs `src/db/` | `db/` when one query is the whole of it. `services/` (e.g. `TaskService`) once a transaction boundary or a combination of several queries appears |
| `req.query.limit` vs the validated value | the default query parser of Express 5 is `simple`, so values are `string` or `string[]`. Code expecting a number uses only a value that passed `TaskQuerySchema` |
| `res.status(400).json(...)` in a router vs `throw new AppError(...)` | do not build the envelope in two places. The router only throws and `errorHandler` emits |
