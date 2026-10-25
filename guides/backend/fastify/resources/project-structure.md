<!-- orangekit-pack: backend/fastify v3.36.0 -->
# Project structure — the encapsulation context is the boundary

This file owns the assembly order of `buildApp` (`src/app.ts`) and **what plugin encapsulation lets reach where**.
The route plugin bodies (`src/http/routes/`) are owned by `resources/api-endpoints.md`, the auth plugin
(`src/http/auth-plugin.ts`) by `resources/auth-boundaries.md`, and the boot and signal wiring (`src/index.ts`) by
`resources/operations.md`.

## 1. Decision tree — which context does this code go in

In Fastify, "where do I register it" is the same question as "how far does it apply". Pick first, then write.

| this | where it goes | why |
| --- | --- | --- |
| validation and serialization compilers | root (`buildApp`) | child contexts inherit them — set them once |
| `setErrorHandler` · `setNotFoundHandler` | root | there must be one envelope. If a child overrides it, that child alone emits a different envelope |
| auth hook (`requireAuth`) | **inside the route plugin** | on a sibling it does not reach; at the root it blocks even the health checks |
| CORS · auth endpoints (`authPlugin`) | root (a plugin wrapped in `fp`) | preflight requests (OPTIONS) have to reach every path. **It does not carry the `requireAuth` hook** |
| request ID header (`x-request-id`) | root `onRequest` | it has to be on every response, including 404 · parser failures · 204 |
| ops endpoints (`/healthz` · `/readyz`) | root, **outside** the auth plugin | the load balancer has no token |
| DB client | module (`src/db/client.ts`) | carry it as a decorator and the query functions have to take the app |
| a decorator several plugins share | a plugin wrapped in `fastify-plugin` | the only legitimate place to break encapsulation on purpose (§4) |

## 2. App assembly (`src/app.ts`)

`buildApp` **only assembles and does not `listen`.** Tests build the app with the same function and call it
through `app.inject()`, so opening a port would make the tests contend for ports.

<!-- file: src/app.ts -->
```ts
// src/app.ts
import { randomUUID } from 'node:crypto'
import Fastify, { type RouteOptions } from 'fastify'
import { serializerCompiler, validatorCompiler, type ZodTypeProvider } from 'fastify-type-provider-zod'
import { env } from './env'
import { AppError } from './http/app-error'
import { authPlugin } from './http/auth-plugin'
import { errorHandler } from './http/error-handler'
import { tasksRoutes } from './http/routes/tasks'
import { healthz, readyz } from './ops/health'
import { loggerOptions } from './ops/logger'

// Only assembles the app — does not listen. Tests call this through inject
export async function buildApp(opts: { logger?: boolean; onRoute?: (route: RouteOptions) => void } = {}) {
  const app = Fastify({
    logger: opts.logger === false ? false : loggerOptions,
    bodyLimit: env.BODY_LIMIT_BYTES,
    // The default is an in-process sequence (req-1), so instances collide. Incoming headers are not trusted
    genReqId: () => randomUUID(),
  }).withTypeProvider<ZodTypeProvider>()

  // Tests enumerate the registered routes — the hook must come before registration to see them all
  if (opts.onRoute) app.addHook('onRoute', opts.onRoute)

  // Compilers and error/404 handling live at the root — child contexts inherit them
  app.setValidatorCompiler(validatorCompiler)
  app.setSerializerCompiler(serializerCompiler)
  app.setErrorHandler(errorHandler)
  app.setNotFoundHandler(() => {
    throw new AppError('NOT_FOUND', 'Route not found')
  })

  // The request ID goes into a response header — set at the root so it can be traced even on a bodiless 204 or 404
  app.addHook('onRequest', async (req, reply) => {
    reply.header('x-request-id', req.id)
  })

  // Ops endpoints live at the root, outside the auth context
  app.get('/healthz', healthz)
  app.get('/readyz', readyz)

  // CORS + auth endpoints (differ per variant). The requireAuth hook is not here — it is inside the route plugin
  await app.register(authPlugin)
  // Each domain's routes are their own encapsulated plugin — the auth hook is set inside it
  await app.register(tasksRoutes, { prefix: '/api/tasks' })
  return app
}

export type App = Awaited<ReturnType<typeof buildApp>>
```

An `AppError` thrown inside `setNotFoundHandler` goes to the root `errorHandler` — so a missing route also becomes
a 404 in the same envelope (the "missing route" test in `testing.md`). Leave the default 404 handler in place and
**a different envelope** goes out: `{"message":"Route GET:/nope not found","error":"Not Found","statusCode":404}`
<!-- verified: ran fastify@5.12.7 — the body from inject without setNotFoundHandler (2026-10-15) -->.

## 3. Encapsulation — how far hooks, error handlers, and decorators reach

<!-- verified: ran fastify@5.12.7 in scratch, each row observed through inject (2026-10-15) -->

| arrangement | observed | meaning |
| --- | --- | --- |
| `onRequest` hook on sibling plugin A, route on sibling B | B's route returns **200** | the hook does not reach — the same as having no auth |
| hook on a plugin wrapped in `fp()` | every route 401 | it climbs to the parent (root) and becomes global |
| same plugin, `addHook` **after** the route declaration | 401 | inside a context, membership decides, not declaration order |
| hook at the root + `/healthz` | `/healthz` is 401 too | it blocks even the ops endpoints |
| a child overrides with `setErrorHandler` | only the child's routes use the child's handler | the envelope splits |
| `decorate('thing')` in sibling A, `hasDecorator` in B | `false` | decorators are invisible to siblings too |

The first row is the most expensive failure on this axis. Read the code and `addHook('onRequest', requireAuth)` is
plainly there, and it passes the type checker and the gate. **Only the registration structure decides whether it
reaches** — which is why `testing.md` actually sends an unauthenticated request to every route under `/api`.

## 4. Where `fastify-plugin` belongs — only when breaking encapsulation on purpose

`fp` declares "show what this plugin registered to the parent as well". Its only legitimate use is
**a decorator several siblings have to share** (for example, a request-scoped utility).

```ts
// ❌ Wrapping the route plugin in fp — its auth hook climbs to the root and blocks even /healthz
app.register(fp(tasksRoutes), { prefix: '/api/tasks' })
// ✅ Do not wrap the route plugin — the hook stays confined to its context
await app.register(tasksRoutes, { prefix: '/api/tasks' })
```

`prefix` does not apply to a plugin wrapped in `fp` either — with no encapsulation, there is no context to attach
the prefix to. A route registered with `{ prefix: '/api' }` was 404 at `/api/x` and 200 at `/x`
<!-- verified: ran fastify@5.12.7 + fastify-plugin@5.1.0 through inject (2026-10-15) -->.

## 5. Layer boundaries — `routes → services → db`

| layer | takes | knows nothing about |
| --- | --- | --- |
| `src/http/routes/*` | `req.user` · the parsed `req.body`/`req.query`/`req.params` | SQL · tables |
| `src/services/*` | `ownerId` + domain values | `FastifyRequest` · status codes |
| `src/db/*` | `ownerId` + parsed values | anything HTTP (policy `db-layer-knows-no-http` in `data-access.md`) |

Create a service layer only when several queries have to be bound into one transaction (`importTasks` in
`data-access.md` §6). Do not create a service that merely wraps one query — it adds a layer without adding a
boundary.

## 6. Adding another domain

A new domain is **a new route plugin**. Do not mix its routes into an existing plugin — once a domain with a
different auth policy (public reads and the like) appears, the context has to be split.

```ts
// src/app.ts — inside buildApp, next to the tasksRoutes registration
await app.register(tasksRoutes, { prefix: '/api/tasks' })
await app.register(usersRoutes, { prefix: '/api/users' })
```

`usersRoutes` also sets `requireAuth` on the first line of its own body. If you need public routes, make them a
**separate plugin** and set no hook there — turning auth on and off per route inside one plugin leaves any route
you forget wide open.

## Misuse list ① — Express · Fastify 4 → Fastify 5 idioms

| old habit | current form (Fastify 5) |
| --- | --- |
| a global middleware with `app.use(authMiddleware)` | `app.addHook('onRequest', requireAuth)` inside the route plugin — it is a hook, not middleware |
| `app.listen(3000)` | `app.listen({ host, port })` — a positional argument fails the boot <!-- verified: fastify@5.12.7 — listen(0) threw a TypeError --> |
| `Fastify({ logger: pinoInstance })` | an options object or `loggerInstance` <!-- verified: fastify@5.12.7 — FST_ERR_LOG_INVALID_LOGGER_CONFIG --> |
| a router object with `app.use('/api', router)` | `app.register(plugin, { prefix: '/api/…' })` |
| `res.status(404).json(...)` | `throw new AppError('NOT_FOUND', …)` — the envelope is the root `errorHandler`'s job |
| `app.decorate('db', db)` then `fastify.db` | `import { db } from '../db/client'` — so query functions do not take the app |

## Misuse list ② — confusable pairs

| often picked wrong | exact condition |
| --- | --- |
| `register(plugin)` vs `register(fp(plugin))` | routes and auth use the former (confined). Only shared decorators use the latter (leaks out) |
| root hook vs route plugin hook | only what every request needs (request IDs and the like) goes at the root. Auth goes in the plugin |
| `setErrorHandler` at the root vs in a child | one, at the root. Overriding it in a child splits the envelope |
| auth in `onRequest` vs `preHandler` | `onRequest` — it rejects **before** the body is parsed. With `preHandler` an unauthenticated request first gets a 400 for broken JSON or a 413 for a large body — the parser runs before auth <!-- verified: fastify@5.12.7 inject — onRequest 401/401, preHandler 400/413 --> |
