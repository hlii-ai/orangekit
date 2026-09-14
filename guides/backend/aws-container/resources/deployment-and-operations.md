<!-- orangekit-pack: backend/aws-container v3.12.0 -->
# Deployment and operations — the image, the deploy order, health checks, performance

It covers building the container image, shipping the migration and the app **separately**, and observing them once
they are up. Everything here is infrastructure-layer work, so `src/` knows nothing of this file's contents.

## The multi-stage Dockerfile

```dockerfile
# syntax=docker/dockerfile:1
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci                                  # devDependencies included — the build needs them
COPY . .
RUN npm run build                           # tsc → dist/

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
RUN apk add --no-cache curl                 # for the health check. Without it, use wget -q -O-
ADD https://truststore.pki.rds.amazonaws.com/global-bundle.pem /etc/ssl/rds/global-bundle.pem
ENV DB_CA_PATH=/etc/ssl/rds/global-bundle.pem
COPY package*.json ./
RUN npm ci --omit=dev                       # runtime dependencies only
COPY --from=build /app/dist ./dist
COPY --from=build /app/drizzle ./drizzle    # the migration task uses the same image
USER node                                   # run as non-root
EXPOSE 8080
CMD ["node", "dist/index.js"]               # exec form — the shell form never receives SIGTERM
```

- **`CMD` must be the exec form.** With the shell form (`CMD node dist/index.js`), PID 1 becomes `/bin/sh`
  so SIGTERM is never delivered to Node, and every deployment cuts the connections off by force
- Keep the base image vendor-neutral. Use an AWS-only base and an on-premises migration becomes an image
  rewrite (`resources/portability-boundaries.md`)
- `drizzle/` goes into the runtime image because of the deploy order below — **the same image runs as both the app
  and the migration task.** Build the two images separately and the versions drift apart

## Local parity (`docker-compose.yml`)

```yaml
services:
  db:
    image: postgres:16-alpine            # the same major as the production RDS
    environment: { POSTGRES_USER: app, POSTGRES_PASSWORD: local, POSTGRES_DB: app }
    ports: ['5432:5432']
    volumes: ['./docker/init-test-db.sql:/docker-entrypoint-initdb.d/10-test-db.sql:ro']
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U app -d app']
      interval: 2s
      timeout: 3s
      retries: 20
  app:
    build: .
    environment:                         # do not miss a single required key of the env schema
      DATABASE_URL: postgres://app:local@db:5432/app
      DB_SSL: 'false'                    # loopback plaintext — DB_CA_PATH is not needed
      CORS_ORIGINS: http://localhost:5173
      OIDC_ISSUER: ${OIDC_ISSUER}
      OIDC_JWKS_URL: ${OIDC_JWKS_URL}
      OIDC_AUDIENCE: ${OIDC_AUDIENCE}
      OIDC_AUTHORIZE_BASE: ${OIDC_AUTHORIZE_BASE}
      SPA_CALLBACK_URL: http://localhost:5173/auth/callback
      SPA_LOGOUT_URL: http://localhost:5173/
      AUTH_STATE_SECRET: local-only-secret-at-least-32-characters
      S3_BUCKET: local-bucket
    depends_on:
      db: { condition: service_healthy }
    ports: ['8080:8080']
```

**compose is the env schema's first test.** Miss even one required key and the app container dies immediately
with `process.exit(1)` — every time a key is added to the schema, fix this block along with it.
Without `depends_on.condition: service_healthy` the app comes up before the DB and the first query breaks.

```bash
docker compose up -d --wait && TOKEN=<Cognito access token>     # smoke check
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/healthz      # 200 (no auth)
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/api/tasks    # 401 (no token)
curl -s -X POST localhost:8080/api/tasks -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"title":"first task"}' | jq
```

## Deploy order — the migration is a separate one-off task

Call `migrate()` at app boot and the Fargate tasks that come up together contend over the same
migration. The pipeline enforces the order.

```
① build and push the image (tag = the commit SHA)
② run exactly one migration task:  RunTask(overrides: command = ["npx","drizzle-kit","migrate"])
   └ on a non-zero exit code, stop the deployment here (the service is still on the old version)
③ update the service (rolling): the old task leaves only once the new one passes the health check
④ on failure, roll back the service only — the schema is not reverted
```

- **For ④ to hold, a migration must always be backward compatible.** A rollback is possible only if old code
  runs against the new schema. So a destructive change is split: ① add the column → ② backfill + support old and
  new code at once → ③ promote to NOT NULL and drop the old column (`resources/data-access.md`)
- Run the migration task from **the same image and the same tag as the app**. Use a different image and a path opens
  where "the code is the new version and the schema is a different commit"
- The task has to be safe across repeated retries. `drizzle-kit migrate` reads the record of what was applied and skips,
  so re-running it is safe — slip a hand-written one-off SQL in and that property breaks

## Health checks and graceful shutdown

| path | what it checks | who | on failure |
| --- | --- | --- | --- |
| `/healthz` | is the process alive (no DB connection) | the ALB target group, ECS | task replacement |
| `/readyz` | does it reach the DB (`select 1`) | deployment verification and monitoring | an alarm (no replacement) |

**Do not put `/readyz` on the ALB health check.** A few seconds of RDS failover has every task judged unhealthy at
once and all of them replaced, and that restart pushes the DB load right back up.

```
SIGTERM received → stop accepting new connections → wait for in-flight requests to finish → pool.end() → exit(0)
```

- Set the ECS `stopTimeout` (30s by default) **longer** than the server's drain timeout (the 10s in
  `resources/portability-boundaries.md`). The other way round and SIGKILL arrives mid-cleanup
- Reduce the ALB's **deregistration delay** (300s by default) to the level of the longest request. Too long and
  every deployment waits on a task that already left; too short and an in-flight request is cut off
- Keep the container health check in the form `CMD-SHELL curl -fsS localhost:8080/healthz || exit 1`

## Connection pool sizing

```
concurrent connection ceiling = (max task count × DB_POOL_MAX) + the migration task + headroom for operator access
once that value passes the RDS max_connections, an autoscale is an outage
```

- Compute it from the autoscale **ceiling**. Compute it from the everyday task count and the moment traffic piles up
  the scale-out produces DB connection refusals — the outage comes from the deployment settings, not the load
- `DB_POOL_MAX` is not a value that gets better the larger it is. PostgreSQL uses a process per connection, so
  idle connections eat memory. Start at 5-10 per task and adjust by watching the wait time
- If the task count has to grow a lot, put **a connection pooler such as RDS Proxy in the infrastructure
  layer** instead of enlarging the pool. The app does not know whether the host is a proxy or an instance
- Leave `connectionTimeoutMillis` (5s) in place. When the pool dries up, **failing fast** beats waiting forever
  — let the waits pile up and every request dies together at the ALB timeout

## Actually seeing slow queries and N+1

Without instrumentation in the application, a report of "it is slow" ends as guesswork. Turn on two axes.

**On the DB side**: turn on `log_min_duration_statement` (say 500ms) in the RDS parameter group and the `auto_explain`
extension, and slow queries and their plans come out in the log. Use `pg_stat_statements` to find the queries whose call count ×
average time is largest — **the query with the big total is the culprit, and a one-off slow query usually is not.**

**On the app side**: carry the per-request query count in the request log to make N+1 visible.

```ts
// put a request-scoped counter on the requestContext (src/http/logger.ts)
log.info({ msg: 'request', method: c.req.method, path: c.req.path,
  status: c.res.status, ms, queries: c.get('queryCount'), requestId })
```

- If a list endpoint's `queries` **grows in proportion to the item count, that is N+1**. It has to be constant
  (the batch read in `resources/data-access.md`)
- Confirm with `EXPLAIN` that cursor pagination rides the index. If `Seq Scan on tasks` shows up,
  either the owner index is missing or it is out of line with the sort key
- Start with four metrics: request count, p95 latency, 5xx rate and pool wait time. Grow the dashboard first and
  you end up with graphs nobody looks at

## What changes on premises

| concern | AWS | on premises |
| --- | --- | --- |
| orchestration | an ECS service + task definition | a K8s Deployment (**the same image**) |
| running the migration | a one-off `RunTask` task | a K8s Job (the same image, the same command) |
| health checks | an ALB target group + the container health check | Service/Ingress + liveness and readiness probes |
| draining | the deregistration delay | `terminationGracePeriodSeconds` + preStop |
| DB TLS trust | the RDS bundle (`DB_CA_PATH`) | the in-house CA bundle (**the same key**) |
| logs | the awslogs driver → CloudWatch | Fluent Bit or Loki (the app knows only stdout) |
| secret injection | Secrets Manager → the task definition | a K8s Secret → env (the same key names) |

**Everything that changes lives in this file and in `infra/`.** If a file under `src/` turns out to need fixing, the boundary
is leaking, so run the CI check of `resources/portability-boundaries.md` before the migration.

## Misuse list (confusable pairs)

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| `migrate()` at boot vs a separate task | running it at boot has the simultaneously starting tasks contend → a one-off task in the deployment pipeline |
| `/readyz` as the ALB health check | a momentary DB break replaces every task → the ALB takes `/healthz`, `/readyz` is for alarms |
| `CMD node dist/index.js` (the shell form) | PID 1 becomes the shell and SIGTERM is never delivered → the exec form `["node","dist/index.js"]` |
| a single-stage image | devDependencies and the source stay in the production image → split build/runtime + `--omit=dev` |
| a different image for the app and the migration | the code and schema versions drift apart → the same tag, only the command differs |
| reverting the schema too when rolling back | a migration rollback is a data-loss path → backward-compatible migrations + roll back the service only |
| clearing the wait by raising `DB_POOL_MAX` | as connections grow RDS hits its limit first → compute the ceiling, then put a pooler in the infrastructure layer |
| computing connections from the everyday task count | compute from the autoscale ceiling. Otherwise a scale-out is an outage |
| "it feels slow" with no APM | `pg_stat_statements` + a per-request query count log. Start from the query with the biggest total |
