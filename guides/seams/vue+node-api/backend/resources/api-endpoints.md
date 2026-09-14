<!-- orangekit-seam: vue+node-api v3.13.0 -->
# API endpoints — the shape of a router and the response envelope

This file owns three code files: `src/http/app-error.ts` · `src/http/error-handler.ts` ·
`src/http/routers/tasks.ts`. These three live in the seam because **the envelope is a function of the combination**. The status mapping table
(`ERROR_STATUS`) and the normalization (`toAppError`) are owned by `resources/error-handling.md`, the parsing helpers by
`resources/input-validation.md`, and the mount order by `resources/project-structure.md`.
Token verification and `requireAuth` are in `resources/auth-boundaries.md`.

## 1. The decision — what response answers this request

The frontend is a Vue SPA and the server is a separate origin, so there is only one boundary, HTTP. The table below is therefore
everything the frontend parses — one cell out of line and the screen splits.

| What you want to do | Method · path | Success | Body |
| --- | --- | --- | --- |
| list | `GET /api/tasks` | 200 | `{ data: Task[], nextCursor }` |
| single | `GET /api/tasks/:id` | 200 | `{ data: Task }` |
| create | `POST /api/tasks` | 201 + `Location` | `{ data: Task }` |
| update | `PATCH /api/tasks/:id` | 200 | `{ data: Task }` |
| delete | `DELETE /api/tasks/:id` | 204 | none |
| everything else (failure) | — | 4xx · 5xx | `{ error: { code, message, details? }, requestId }` |

**The router builds the success envelope and `errorHandler` builds the failure envelope.** That is two places — but the point is that the
failure side is one place. Once routers start writing the failure envelope themselves, the same failure goes out in a different
shape from each site and the frontend grows more branches.

## 2. The success envelope — never return the value bare

Do not put an array or a primitive at the top level. One layer of `data` keeps the frontend parsing from breaking
when `nextCursor` · `meta` are added later.

```ts
// src/http/routers/tasks.ts — the four shapes of the success envelope
// ❌ an array at the top level — there is nowhere to carry page information
res.json(rows);
// ✅ the four shapes of the contract
res.json({ data: task });                                   // single, 200
res.json({ data, nextCursor });                             // list, 200
res.status(201).location(`/api/tasks/${task.id}`).json({ data: task });  // create
res.sendStatus(204);                                        // delete — no body
```

<!-- verified: express@5.2.1 + supertest@7.2.2 run — the four shapes were observed with real requests. The Location of the create response was `/api/tasks/<created id>`, and the delete response was status 204 with res.text an empty string -->
Use `res.status(201).json(body)`. In Express 5, `res.json(201, body)` raises no exception and sends
**status 200 with the body `201`** — a shape that is wrong silently.

## 3. The error envelope and `AppError` (`src/http/app-error.ts`)

The failure envelope of the contract is `code` · `message` · `details` (optional) inside `error`, with `requestId` at the top level.
`AppError` is the domain type that carries the first three of those and **knows nothing of the HTTP status** — the status is decided by
the single `ERROR_STATUS` table.

<!-- file: src/http/app-error.ts -->
```ts
export class AppError extends Error {
  readonly code: string;
  readonly details?: Record<string, string[]>;

  constructor(code: string, message: string, details?: Record<string, string[]>) {
    super(message);
    this.name = 'AppError';
    this.code = code;
    this.details = details;
  }
}
```

The constructor argument order is `(code, message, details?)`. `parseBody` throws in this order
(`resources/input-validation.md`), and so does `toAppError` — change it and the whole pack goes out of line.

`details` is a `Record<string, string[]>` and is carried **only on a validation failure**. The frontend attaches it beside the field,
so the keys must equal the form field names, and an error over the whole schema arrives under the key `_`.
`code` is looked up as the key of a `Record<string, number>`, so always use the seven codes of the contract:
`VALIDATION_FAILED` · `UNAUTHENTICATED` · `FORBIDDEN` · `NOT_FOUND` · `CONFLICT` ·
`PAYLOAD_TOO_LARGE` · `INTERNAL`. A code not in the table is not a type error; it quietly becomes a 500.

## 4. Emission happens in one place (`src/http/error-handler.ts`)

<!-- file: src/http/error-handler.ts -->
```ts
import { randomUUID } from 'node:crypto';
import 'pino-http';   // declaration merging for req.log · req.id (http.IncomingMessage)
import type { ErrorRequestHandler, Request } from 'express';
import { ERROR_STATUS, toAppError } from './errors';

// pino-http attaches req.id to every request. Even without it, the contract says requestId must always be carried,
// so it is created here — if the value a user quotes in a support request is missing from the response, the trail breaks.
function requestIdOf(req: Request): string {
  return req.id === undefined ? randomUUID() : String(req.id);
}

export const errorHandler: ErrorRequestHandler = (err, req, res, next) => {
  if (res.headersSent) { next(err); return; }
  const e = toAppError(err);
  const status = ERROR_STATUS[e.code] ?? 500;
  req.log?.[status >= 500 ? 'error' : 'warn']({ err, code: e.code }, 'request failed');
  res.status(status).json({
    error: { code: e.code, message: e.message, ...(e.details ? { details: e.details } : {}) },
    requestId: requestIdOf(req),
  });
};
```

**There are exactly four arguments.** Express identifies an error middleware by arity alone — cut it to three and it
registers but is never called in the error flow.
<!-- verified: express@5.2.1 run — sending a throw to an app carrying a 3-argument use skipped that middleware and the default Express handler returned 500 + text/html -->
The single line `import 'pino-http'` brings in the types of `req.log` and `req.id` — it is an import whose value is unused, so it is
easy to delete, and deleting it removes both properties from `Request` and breaks compilation.
<!-- verified: pino-http@10.5.0 + typescript@5.9.3 — without this import, tsc --strict failed with TS2339 "Property 'log' does not exist on type 'Request'", and with it the check passed -->

**Do not skip `toAppError`.** Most of what arrives at this middleware is not an `AppError`.
**The same input** (`{bad`) was sent to a form that reads `err.code` directly without normalization and to the normalized form:

<!-- verified: express@5.2.1 run — the malformed JSON was sent to an app with each middleware mounted and the responses observed as they were -->
| Form | Status | Body |
| --- | --- | --- |
| reading `err.code` directly | 500 | `{"error":{"code":"INTERNAL","message":"Expected property name or '}' in JSON at position 1 …"}}` |
| `toAppError(err)` first | 400 | `{"error":{"code":"VALIDATION_FAILED","message":"The request body is not valid JSON"}}` |

The first row is wrong twice. A client mistake is counted as a 5xx, and **the internal message of the parser went straight out
in the response.** Normalization is not only a status code matter; it blocks leakage.

## 5. `tasksRouter` (`src/http/routers/tasks.ts`)

<!-- file: src/http/routers/tasks.ts -->
```ts
import { Router, type Request } from 'express';
import { AppError } from '../app-error';
import { parseBody, parseQuery } from '../parse';
import { requireAuth, type AuthUser } from '../require-auth';
import { TaskCreateSchema, TaskQuerySchema, TaskUpdateSchema } from '../../schemas/task';
import { deleteTask, getTask, insertTask, listTasks, updateTask } from '../../db/tasks';

// mounted only behind requireAuth, so req.user exists. Even so, no `!` assertion is used —
// if the mount is forgotten, the assertion leaks as a TypeError (500) while this function closes with a 401 (measured: below §5).
function actor(req: Request): AuthUser {
  if (!req.user) throw new AppError('UNAUTHENTICATED', 'Authentication failed');
  return req.user;
}

export const tasksRouter = Router();
tasksRouter.use(requireAuth);

tasksRouter.get('/', async (req, res) => {
  const q = parseQuery(TaskQuerySchema, req);
  const page = await listTasks(actor(req).id, q);
  const hasMore = page.length > q.limit;
  const data = hasMore ? page.slice(0, q.limit) : page;
  res.json({ data, nextCursor: hasMore ? data[data.length - 1].id : null });
});

tasksRouter.post('/', async (req, res) => {
  const input = parseBody(TaskCreateSchema, req);
  const task = await insertTask(actor(req).id, input);
  res.status(201).location(`/api/tasks/${task.id}`).json({ data: task });
});

tasksRouter.get('/:id', async (req, res) => {
  const task = await getTask(actor(req).id, req.params.id);
  if (!task) throw new AppError('NOT_FOUND', 'Task not found');
  res.json({ data: task });
});

tasksRouter.patch('/:id', async (req, res) => {
  const patch = parseBody(TaskUpdateSchema, req);
  const task = await updateTask(actor(req).id, req.params.id, patch);
  res.json({ data: task });
});

tasksRouter.delete('/:id', async (req, res) => {
  await deleteTask(actor(req).id, req.params.id);
  res.sendStatus(204);
});
```

Attach `tasksRouter.use(requireAuth)` **on the first line of the router**. Inserting it as an argument on each route can be
forgotten when a new route is added, and a forgotten route is quietly public — the failure direction is open.

There is no `try/catch` and no `next(err)`. Express 5 forwards the rejection of an async handler to the error middleware
automatically. `parseBody`/`parseQuery` use the **return value** — assigning to `req.query` has no effect.

<!-- verified: express@5.2.1 run — two copies of the router without requireAuth were called without authentication. `actor(req)` gave 401 UNAUTHENTICATED and `req.user!.id` gave 500 INTERNAL -->
The version with `actor()` and the version with `req.user!` were both hit without authentication, with `requireAuth` removed.
The former gives 401, the latter **500**. The latter did not hand over anyone else's row, but the failure is counted as a server error.

## 6. The cursor pagination response

The pagination of the contract is a cursor — the request parameters are `limit` and `cursor`, and the response field is `nextCursor`.
Offsets (`page` · `skip`) are not used: when a list changes often, rows are duplicated or dropped at the page
boundary. The query function fetches one extra row with `take: limit + 1`, so all the router has to do is
**trim it and carry the last id**.

```ts
// src/http/routers/tasks.ts — excerpt from the list handler
// ❌ counting the total with a separate count query to build totalPages — one more scan on every request
const total = await countTasks(owner);
// ✅ take one extra row to decide whether a next page exists. On the last page nextCursor is null
const hasMore = page.length > q.limit;
const data = hasMore ? page.slice(0, q.limit) : page;
res.json({ data, nextCursor: hasMore ? data[data.length - 1].id : null });
```

<!-- verified: express@5.2.1 + supertest@7.2.2 run — 5 rows walked over 3 pages with limit=2. 2 · 2 · 1 items arrived, the 5 ids gathered without duplication, and the nextCursor of the last page was null -->
`limit=0` is blocked with a 400 by the `.min(1)` of `TaskQuerySchema`, and an unknown query key such as `?utm_source=x` is
**stripped** by `z.object` (not rejected). The body is the opposite: `z.strictObject` rejects it.

## 7. CORS — the premise of a separate origin (`src/http/cors.ts`)

The Vue SPA is served from its own origin and this server is on another. So CORS is not optional; it is
the boundary itself. **The allowed origins come from `env`, not from code** — staging and production differ.

<!-- file: src/http/cors.ts -->
```ts
import type { RequestHandler } from 'express';
import { AppError } from './app-error';
import { env } from '../env';

const ALLOWED = new Set(env.WEB_ORIGINS);

export const cors: RequestHandler = (req, res, next) => {
  const origin = req.get('origin');
  if (origin && ALLOWED.has(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader('Vary', 'Origin');
  }
  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PATCH,DELETE');
    res.setHeader('Access-Control-Allow-Headers', 'authorization,content-type');
    res.setHeader('Access-Control-Max-Age', '600');
    res.sendStatus(204);
    return;
  }
  next();
};

// a route that authenticates with a cookie, such as the reissue, calls this directly. CORS headers only block reading
// the response; they cannot block the request from executing (auth-boundaries §5).
export function requireAllowedOrigin(req: Parameters<RequestHandler>[0]): void {
  const origin = req.get('origin');
  if (origin !== undefined && !ALLOWED.has(origin)) {
    throw new AppError('FORBIDDEN', 'Origin not allowed');
  }
}
```

Mount it **before** `express.json()` in `makeApp()`. A preflight has no body, and if a parser error
blocks the preflight the browser reports the cause only as a CORS failure.

<!-- verified: express@5.2.1 + supertest@7.2.2 run — an OPTIONS from an allowed origin gave 204 + ACAO/ACAC + Vary: Origin, while a disallowed origin had no ACAO header at all -->
Without `Vary: Origin` a cache (proxy · CDN) hands one origin's response to another origin.
`Access-Control-Allow-Origin: *` and `credentials: true` **cannot be used together** — the browser
refuses, so the form has to echo the origin back, and that is why the allowlist is mandatory.

## Misuse list ① — Express 4 → Express 5 idiom table (from the envelope angle)

| Old habit (Express 4) | The current form (Express 5.2.1) |
| --- | --- |
| `res.json(201, body)` | `res.status(201).json(body)` — the 2-argument form sends status 200 with the body `201` |
| Wrapping in `asyncHandler(fn)` to keep the envelope | Just throw. The rejected promise reaches `errorHandler` |
| `app.use('*', notFound)` | `app.use(notFound)` — `'*'` is a boot failure under path-to-regexp 8 |
| `router.get('/:id?', h)` | `router.get('/tasks{/:id}', h)` — there is no `?` optional-parameter syntax |
| Declaring the error middleware with three arguments | Four. Three is never called in the error flow |
| `req.query = TaskQuerySchema.parse(req.query)` | `const q = parseQuery(TaskQuerySchema, req)` — the assignment has no effect |
| A failure response through `res.send(err.message)` | Throw the code only and let `errorHandler` build the envelope |

## Misuse list ② — confused pairs

| Frequently chosen wrongly | The exact condition for each |
| --- | --- |
| `res.json({ data })` vs `res.json(rows)` | Always one layer of `data`. An array at the top level leaves nowhere to carry `nextCursor` |
| `res.sendStatus(204)` vs `res.status(204).json({})` | A delete uses `sendStatus`. Carry a body on a 204 and the JSON parsing on the frontend breaks |
| `next(err)` vs `throw err` | Inside a handler they are the same. `next(err)` is used only for the `res.headersSent` handover |
| `toAppError(err)` vs `err instanceof AppError` | In the middleware, always `toAppError`. Counting the branches by hand misses a new kind of exception |
| `details` vs `message` in `errorHandler` | Only per-field errors go in `details`. The one line a person reads is `message` |
| `router.use(requireAuth)` vs an argument per route | Attach it per router. Per route, a new route is quietly published |
| `Access-Control-Allow-Origin: *` vs echoing it back | With credentials, `*` is impossible. Pick from the allowlist and echo it back |
| No upper bound on `limit` vs `.max(100)` | Without an upper bound there is a path that reads the whole table in one request |
