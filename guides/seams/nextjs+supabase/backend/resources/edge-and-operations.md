<!-- orangekit-seam: nextjs+supabase/backend v3.12.0 -->
# Edge Runtime, Response Headers & Operations

Middleware does not run where your handlers run, and the cross-cutting concerns
(CORS, security headers, rate limits, logs) live on that boundary. This file covers both.

## Middleware runs on the Edge Runtime

`middleware.ts` executes on the **Edge Runtime** — a Web-API subset, not Node.js — and it
runs on *every* matched request, ahead of the handler. That constrains what may go in it.

Not available there:

- **Node built-ins**: `fs`, `net`, `dns`, `child_process`, `node:crypto`. (Web Crypto —
  `crypto.subtle`, `crypto.randomUUID()` — *is* available.)
- **TCP database drivers**: `pg`, `mysql2`, Prisma's native engine, anything that opens a
  socket. Supabase works in middleware only because `@supabase/ssr` speaks HTTPS/REST.
- **Heavy CPU work**: image processing, big JSON transforms, `bcrypt`/`argon2` hashing.
  Middleware sits on the latency path of every request; a slow middleware is a slow site.

What follows from that:

- Keep middleware to **session refresh (`updateSession`) + coarse path gating + headers**.
- Per-resource authorization (a `profiles.role` read, an ownership check) belongs in the
  handler/action. In middleware it becomes a DB round trip on every matched path.
- Need a Node API? Move the work into a Route Handler — Route Handlers run on the **Node
  runtime by default**. Opt a route into `export const runtime = 'edge'` only when it is
  pure fetch/Web-API work; the Supabase server client works under both.
- Middleware cannot import `lib/supabase/admin.ts` usefully anyway: service-role work is
  handler/webhook territory, and it must never sit in front of every request.

## Rate limiting

**The trap:** a module-scope `Map` (or plain object) counting requests per IP looks like a
rate limiter and enforces nothing.

- Edge middleware runs in **many isolates across many regions**; each has its own memory.
  A "5 requests per minute" counter becomes "5 per isolate per minute" — unbounded in
  practice.
- Serverless Node handlers have the same problem: instances scale out and are recycled,
  so counters reset at random and are never shared.
- It is also an unbounded memory leak — nothing evicts the keys.

**The rule:** rate limiting requires **state shared across all instances**. Use a managed
service backed by an external store (`@upstash/ratelimit` on Upstash Redis, Vercel's
firewall/rate-limit rules, an API gateway, or a Postgres/Redis counter you own). Pick one
and configure it — do not hand-roll an in-memory counter.

What to rate-limit first: auth endpoints (sign-in, sign-up, password reset), anything that
sends email/SMS, expensive search or export endpoints, and unauthenticated POSTs.
Return **429** with the standard envelope (`{ error: { code: 'rate_limited', ... } }`) and a
`Retry-After` header.

## Security headers

Set them once for the whole app rather than per route:

```ts
// next.config.ts
import type { NextConfig } from 'next'

const securityHeaders = [
  { key: 'X-Frame-Options', value: 'DENY' },                 // clickjacking: no framing
  { key: 'X-Content-Type-Options', value: 'nosniff' },       // no MIME sniffing
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
  // HSTS: only once the site is fully HTTPS, including subdomains
  { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains' },
]

const nextConfig: NextConfig = {
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }]
  },
}
export default nextConfig
```

- `X-Frame-Options: DENY` (or `SAMEORIGIN` if you embed your own pages) — the CSP
  equivalent is `frame-ancestors`, which supersedes it where CSP is in play.
- A Content-Security-Policy is worth adding, but it needs a nonce per request and breaks
  loudly when wrong — introduce it deliberately, report-only first.

### Request ID — attach one in middleware

```ts
// inside updateSession, before returning the response
const requestId = request.headers.get('x-request-id') ?? crypto.randomUUID()
supabaseResponse.headers.set('x-request-id', requestId)
```

Log that id in every handler log line and return it in error responses' `details` when you
want support to be able to correlate a user report with a server log.

## CORS — only when external origins call the API

Same-origin apps (your own React tree calling your own `/api`) need none of this. For a
route consumed from another origin:

```ts
const CORS = {
  'Access-Control-Allow-Origin': 'https://app.example.com', // never '*' on authenticated endpoints
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
}

// Preflight — browsers send OPTIONS before non-simple requests; without this they never
// reach your GET/POST
export async function OPTIONS() {
  return new Response(null, { status: 204, headers: CORS })
}
```

Spread the same headers into every real response of that route:
`NextResponse.json({ data }, { headers: CORS })`. With cookies involved you also need
`Access-Control-Allow-Credentials: 'true'` — and then `Allow-Origin` **must** be an exact
origin, never `*`.

## Structured logging & observability

Logs are read by machines first. One JSON object per line, one level, one timestamp, one
context object:

```ts
// lib/logger.ts
type Level = 'debug' | 'info' | 'warn' | 'error'

function log(level: Level, message: string, context: Record<string, unknown> = {}) {
  const line = JSON.stringify({
    level,
    message,
    timestamp: new Date().toISOString(),
    ...context,
  })
  if (level === 'error' || level === 'warn') console.error(line)
  else console.log(line)
}

export const logger = {
  debug: (m: string, c?: Record<string, unknown>) => log('debug', m, c),
  info:  (m: string, c?: Record<string, unknown>) => log('info', m, c),
  warn:  (m: string, c?: Record<string, unknown>) => log('warn', m, c),
  error: (m: string, c?: Record<string, unknown>) => log('error', m, c),
}
```

```ts
// in a handler — identifiers and outcomes, not payloads
logger.error('tasks.create failed', {
  handler: 'POST /api/tasks',
  requestId,
  userId: user.id,          // an opaque uuid, not an email
  dbCode: error.code,       // '23505' — the code, not the message
})
```

**Never put in a log line:**

- **Secrets**: service-role keys, JWTs, cookie values, API keys, passwords (including
  whole `request.headers` or `process.env` dumps).
- **PII**: emails, phone numbers, names, addresses, full request bodies. Log the row id.
- **Raw driver errors** as the user-facing story: keep `error.message`/SQL/constraint names
  on the server side only — they never reach a response body
  (`resources/validation-and-errors.md`).

Levels: `error` = a request failed and someone must look; `warn` = degraded but handled
(retry succeeded, fallback used); `info` = business events worth counting (created,
deleted, signed in); `debug` = local only. Keep the level out of the message string — it is
a field.

**What to watch in production:** 5xx rate per route, p95 latency per route, auth failure
rate (`401`/`403` spikes = credential stuffing), 429 rate, and slow Postgres queries via
the Supabase dashboard. A `500` that nobody is alerted on is an outage you learn about from
users.
