<!-- orangekit-pack: backend/aws-container v3.12.0 -->
# Portable boundaries — AWS stays in the infrastructure layer only

This backend may be moved on premises some day. So **AWS dependence is confined to the infrastructure layer and
the application code under `src/` is kept vendor-neutral.** Whether that migration turns out to be "a redeployment"
or "a rewrite" is decided by this one boundary.

## The decision table

| concern | what the app code (`src/`) knows | what the infrastructure layer (`infra/`, deployment) knows |
| --- | --- | --- |
| the runtime | listen for HTTP on `PORT`, shut down on SIGTERM | ECS/Fargate, the ALB, target groups, autoscaling |
| the database | one `DATABASE_URL`, standard PostgreSQL SQL | the RDS instance, parameter groups, backups, subnets |
| authentication | `OIDC_ISSUER` / `OIDC_JWKS_URL` / `OIDC_AUDIENCE` | the Cognito user pool, the app client, the domain |
| file storage | the `ObjectStorage` port + `S3_ENDPOINT` | the S3 bucket, policies, lifecycle rules |
| logging | one line of structured JSON on stdout | the CloudWatch Logs driver, retention, subscription filters |
| configuration and secrets | the single `env` module | Secrets Manager, task definition injection |
| queues and async work | (once introduced) a port interface | SQS, EventBridge |

**The rule in one line**: the only place an AWS product name appears inside `src/` is the `src/storage/` adapter.

## 1. The runtime — a standard HTTP server

<!-- file: src/index.ts -->
```ts
// src/index.ts
import { serve } from '@hono/node-server'
import { app } from '@/app'
import { env } from '@/config/env'
import { pool } from '@/db/client'
import { log } from '@/http/logger'

const server = serve({ fetch: app.fetch, port: env.PORT })
log.info({ msg: 'listening', port: env.PORT })

const shutdown = () => {
  server.close(async () => { await pool.end(); process.exit(0) })
  setTimeout(() => process.exit(1), 10_000).unref()   // force exit if the drain does not finish
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
```

- Do not use an adapter built only for a function runtime (handler signatures, cold-start assumptions). The same
  image runs as-is on ECS, on K8s and on on-premises Docker
- Write the Dockerfile's `CMD` in the **exec form** (`CMD ["node", "dist/index.js"]`). With the shell form,
  `node` never receives SIGTERM and every deployment cuts connections
- Separate `/healthz` (liveness, no DB needed) from `/readyz` (a DB `select 1`). The ALB watches `/healthz`
  — so a momentary DB break does not restart the tasks
- Run as a non-root user, and do not use an AWS-only base for the image

## 2. The database — avoid Aurora-only features

Keep **the same engine** as an on-premises PostgreSQL. What the app sees is one connection string.

Not used:

- **The Aurora Data API** (`@aws-sdk/client-rds-data`) — an AWS-only path that sends SQL over HTTP.
  Use nothing but a standard connection through Drizzle's `node-postgres` driver
- **IAM database authentication** (generating a temporary token with the RDS signer) — it brings AWS credential logic
  into the app code. Having the password injected from Secrets Manager into env is the portable way
- The `aurora_*` family of functions and views, Aurora-only extensions, Babelfish
- A branch where the app picks the reader endpoint itself — read splitting is served well enough by one more
  connection string, and the infrastructure settles that value

RDS Proxy is **an example of something that stays in the infrastructure layer**. The app does not know whether the host is a proxy or an instance.

## 3. Authentication — standard OIDC/JWKS

Verify with `jose`, and all the issuer information lives in env. What changes on a switch to Keycloak:

| value | Cognito | Keycloak |
| --- | --- | --- |
| `OIDC_ISSUER` | `https://cognito-idp.<region>.amazonaws.com/<poolId>` | `https://<host>/realms/<realm>` |
| `OIDC_JWKS_URL` | `<issuer>/.well-known/jwks.json` | `<issuer>/protocol/openid-connect/certs` |
| the audience claim | `client_id` (the access token) | `aud` |
| the group claim | `cognito:groups` | `realm_access.roles` |

**The only place the code changes is the one claim normalization function** (`resources/auth-boundaries.md`).
`aws-jwt-verify`, `amazon-cognito-identity-js` and the Cognito Admin SDK do not come into `src/`.
If administrative work such as creating a user or resetting a password is needed, split it into a separate operations script.

## 4. File storage — put the S3 API behind a port

MinIO implements the S3 **protocol** as it is. So using the SDK is not itself the problem; the contract is
**keeping the endpoint configurable and confining it to a single adapter file**.

The type the app code sees and the adapter implementing it are **different files**. Put them in one file and
`@aws-sdk` enters the app code's import graph, and having a port means nothing.

<!-- file: src/storage/index.ts -->
```ts
// src/storage/index.ts — the only type the app code sees
export interface ObjectStorage {
  put(key: string, body: Uint8Array, contentType: string): Promise<void>
  presignGet(key: string, expiresInSec: number): Promise<string>
}
```

<!-- file: src/storage/s3.ts -->
```ts
// src/storage/s3.ts — the only file that knows the AWS SDK
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3'
import { getSignedUrl } from '@aws-sdk/s3-request-presigner'
import { env } from '@/config/env'
import type { ObjectStorage } from '@/storage'

const client = new S3Client({
  region: env.AWS_REGION,                     // part of this adapter's config — the app logic knows no region
  endpoint: env.S3_ENDPOINT,                  // unset → the AWS default, set → MinIO and the like
  forcePathStyle: Boolean(env.S3_ENDPOINT),   // MinIO needs path-style
})

export const s3Storage: ObjectStorage = {
  async put(key, body, contentType) {
    await client.send(new PutObjectCommand({
      Bucket: env.S3_BUCKET, Key: key, Body: body, ContentType: contentType,
    }))
  },
  async presignGet(key, expiresInSec) {
    // the lifetime of a signed URL is in **seconds**. Mistake it for minutes and a URL 60× longer goes out
    return getSignedUrl(client, new GetObjectCommand({ Bucket: env.S3_BUCKET, Key: key }),
                        { expiresIn: expiresInSec })
  },
}
```

`AWS_REGION` is an **optional** value in the env schema (`resources/input-validation.md`). On an on-premises
MinIO, leave it empty and give only `S3_ENDPOINT` — make it required and a non-AWS deployment dies at boot.

- Do not put credentials in the code. On AWS the task role, and on premises the env credentials, are picked up
  by the default provider chain
- The server makes the storage key (`tasks/<ownerId>/<uuid>`). Use a filename the client sent as the key and
  path traversal and overwriting open up

## 5. Logging — structured JSON on stdout

Do not write through the CloudWatch SDK directly. The container spits one line at a time onto stdout, and **collection is the infrastructure's job**
(the awslogs driver on ECS, Fluent Bit or Loki on premises).

```ts
// src/http/logger.ts
import { createMiddleware } from 'hono/factory'
import { env, publicEnvKeys } from '@/config/env'
import type { AppEnv } from '@/http/types'

const ORDER = { debug: 10, info: 20, warn: 30, error: 40 } as const
type Level = keyof typeof ORDER

function emit(level: Level, fields: Record<string, unknown>) {
  if (ORDER[level] < ORDER[env.LOG_LEVEL as Level]) return
  process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), level, ...fields }) + '\n')
}

export const log = {
  debug: (f: Record<string, unknown>) => emit('debug', f),
  info: (f: Record<string, unknown>) => emit('info', f),
  warn: (f: Record<string, unknown>) => emit('warn', f),
  error: (f: Record<string, unknown>) => emit('error', f),
}

// once at boot — not a whitelist: a key outside the list structurally cannot ride along
// (called right after serve() in src/index.ts)
export function logBootConfig() {
  const cfg = Object.fromEntries(
    publicEnvKeys.map((k) => [k, (env as Record<string, unknown>)[k]]),
  )
  log.info({ msg: 'boot config', config: cfg })   // DATABASE_URL and AUTH_STATE_SECRET are not in the list
}
```

The point is the inversion from "erase what must not be printed" to **"pick only what may be printed"**.
A blacklist demands an update every time one env key is added, and forget it once and a secret goes out silently.

```ts
// assigning a requestId + the access log (src/http/logger.ts)
export const requestContext = createMiddleware<AppEnv>(async (c, next) => {
  const incoming = c.req.header('x-request-id')
  const requestId = incoming && /^[\w-]{1,64}$/.test(incoming) ? incoming : crypto.randomUUID()
  c.set('requestId', requestId)
  c.header('x-request-id', requestId)
  const started = performance.now()
  await next()
  log.info({ msg: 'request', method: c.req.method, path: c.req.path,
    status: c.res.status, ms: Math.round(performance.now() - started), requestId })
})
```

- An `x-request-id` that came from outside is used only after validation — it is a log injection path
- Do not put a token, a password, `DATABASE_URL`, `AUTH_STATE_SECRET` or the whole request body in the log
- **PII is on the same forbidden list**: email, phone number, name, address, IP. `AuthUser` carries
  `email`, so the single line `log.info({ user })` copies the email across the log collector and its whole retention.
  Print only `sub` to identify a user — `log.info({ msg: '...', sub: c.get('user').sub })`
- Do not spread a whole object (`{ ...user }`, `{ ...row }`). It is safe today, but **the moment one column
  is added** its value rides into the log. List the fields to print by name
- Put the message in the `msg` field and everything else in structured fields. A log built by string concatenation cannot be searched

## 6. Configuration and secrets — env as the single entry point

Secrets Manager is only **an injection mechanism**. The app does not query a secret store at runtime.

```ts
// infra/lib/service-stack.ts — this is not app code. Never imported from src/
taskDefinition.addContainer('api', {
  image: ecs.ContainerImage.fromAsset('.'),
  environment: { PORT: '8080', OIDC_ISSUER: issuerUrl, S3_BUCKET: bucket.bucketName },
  secrets: { DATABASE_URL: ecs.Secret.fromSecretsManager(dbSecret, 'url') },
  logging: ecs.LogDrivers.awsLogs({ streamPrefix: 'api' }),
  portMappings: [{ containerPort: 8080 }],
})
```

On premises, handing the same keys over through a K8s Secret or a `.env` file is all it takes. **The app does not know the difference.**

## Migration checklist (what actually changes when moving on premises)

- [ ] The container orchestrator: the ECS task definition → a K8s Deployment (the same image)
- [ ] The connection string: the RDS endpoint → an internal PostgreSQL host (`DATABASE_URL` only)
- [ ] The TLS trust anchor: the RDS bundle → the in-house CA bundle (the `DB_CA_PATH` value only, no code change)
- [ ] The IdP: swap the three `OIDC_*` values + edit the one group-claim normalization function
- [ ] Object storage: set `S3_ENDPOINT` + the credential env vars (no adapter code change)
- [ ] The log collector: the awslogs driver → Fluent Bit and the like (no app change)
- [ ] Secret injection: Secrets Manager → a K8s Secret (the same env key names)
- [ ] The migration: the same `drizzle-kit migrate` as a one-off Job

## Enforce the boundary in CI

Discipline alone does not hold it. These three lines have to come back empty.

```bash
grep -rn "@aws-sdk" src/ --include=*.ts | grep -v "^src/storage/"      # forbidden outside the storage adapter
grep -rn "aws-cdk-lib\|aws-jwt-verify\|amazon-cognito" src/            # infrastructure and vendor SDKs forbidden
grep -rn "process\.env" src/ --include=*.ts | grep -v "src/config/env.ts"   # env, the single entry point
```

## Misuse list (confusable pairs)

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| a runtime Secrets Manager SDK lookup vs env injection | injection is the default. A runtime lookup adds boot latency, IAM dependence and failure surface |
| the CloudWatch `PutLogEvents` SDK vs stdout | the container knows only stdout. Collection is the log driver's job |
| `aws-jwt-verify` vs `jose` | use standard OIDC verification only. The former pins the issuer into the code |
| the Aurora Data API vs `node-postgres` | standard protocol connections only. The Data API means rewriting the whole data access layer at migration time |
| IAM DB authentication vs password injection | take the password by injection. IAM authentication brings AWS credential logic into the app |
| calling the S3 SDK directly vs the `ObjectStorage` port | put it behind the port. With the adapter in one file, switching to MinIO ends at a configuration change |
| using `AWS_REGION` to branch app logic | the region is an infrastructure value. Let the app change behavior by region and there is nowhere to go on premises |
| delegating authentication to the ALB vs verifying in the app | the app verifies for itself. Do not build a setup where swapping the proxy makes authentication vanish entirely |
| importing a CDK constant from `src/` | the direction is always `infra/` → container environment variables. A reverse import becomes a circular dependency at migration time |
