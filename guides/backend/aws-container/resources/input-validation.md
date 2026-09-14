<!-- orangekit-pack: backend/aws-container v3.12.0 -->
# Input validation (Zod 4) — request body, query, environment variables

Every value coming from the browser is hostile input. Even when the SPA validates with the same schema,
**client validation is UX and the server is the only trust boundary**.

## Schemas live in `src/schemas/`

The `src/schemas/tasks.ts` below is **canonical for the request schemas**. Every citation of
`CreateTaskInput` / `UpdateTaskInput` / `ListTasksQuery` in the other resource files points here.

```ts
// src/schemas/tasks.ts
import { z } from 'zod'

export const TaskIdParam = z.object({ id: z.uuid() })

// The field definition with no defaults is the source — defaults go only on the create schema
const TaskFields = z.strictObject({
  title: z.string().trim().min(1).max(120),
  body: z.string().max(20_000),
})

export const CreateTaskInput = TaskFields.extend({ body: TaskFields.shape.body.default('') })

export const UpdateTaskInput = TaskFields.partial().refine(
  (v) => Object.keys(v).length > 0,
  { error: 'at least one field to change is required' },
)

export const ListTasksQuery = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(20),
  cursor: z.string().max(200).optional(),       // base64url("<iso>|<uuid>")
  archived: z.stringbool().optional(),          // the "true"/"false" query string → boolean
})

export type CreateTaskInput = z.infer<typeof CreateTaskInput>
export type UpdateTaskInput = z.infer<typeof UpdateTaskInput>
export type ListTasksQuery = z.infer<typeof ListTasksQuery>
```

- **Do not pull the PATCH schema out of the create schema with `.partial()`.** `.partial()` cannot remove
  `.default()` — `CreateTaskInput.partial().parse({})` yields `{ body: '' }`. Then
  ① the "at least one field" `refine` passes forever, so an empty PATCH is not refused, and ② `set({ ...patch })`
  **overwrites a body you never touched with an empty string.** The default-free `TaskFields` has to be the source
- **Use `strictObject` by default**: when an unknown key passes silently, a value like `{ ownerId: "..." }`
  can ride straight into the `insert` (`.extend()` and `.partial()` preserve strict)
- Put a `max()` on every string. An unbounded string is a memory and storage attack surface
- Query parameters are always strings → numbers take `z.coerce.number()`, booleans `z.stringbool()`
- **Always wire a declared query parameter all the way to the query function.** `archived` is consumed by
  `listOwnedTasks(ownerId, limit, cursor, archived)` (`resources/data-access.md`) —
  a parameter that is parsed and never read promises the client a feature that does not exist

## Parsing helpers (`src/http/validate.ts`)

Build exactly three, so a handler never writes a `safeParse` branch itself.

```ts
import type { Context } from 'hono'
import { z, type ZodType } from 'zod'
import { AppError } from '@/http/errors'

function fail(err: z.ZodError): never {
  throw new AppError(422, 'VALIDATION_FAILED', 'the request values are not valid',
    z.flattenError(err).fieldErrors)
}

export async function jsonBody<T extends ZodType>(c: Context, schema: T): Promise<z.infer<T>> {
  let raw: unknown
  try {
    raw = await c.req.json()
  } catch {
    throw new AppError(400, 'BAD_REQUEST', 'the JSON body could not be read')
  }
  const r = schema.safeParse(raw)
  return r.success ? r.data : fail(r.error)
}

export function queryParams<T extends ZodType>(c: Context, schema: T): z.infer<T> {
  const r = schema.safeParse(c.req.query())
  return r.success ? r.data : fail(r.error)
}

export function pathParam<T extends ZodType>(c: Context, schema: T): z.infer<T> {
  const r = schema.safeParse(c.req.param())
  return r.success ? r.data : fail(r.error)
}
```

- **A parse failure is a 422, not a 400.** 400 means "not even JSON", 422 means "JSON but it breaks the rules"
- `z.flattenError(err).fieldErrors` has the shape `{ title: ["..."] }`, so it maps straight onto an SPA form
- Do not echo the original input back in the error `details` — secret values get copied into the response and the logs

## Attach it once more with DB constraints

Zod sees only **this request**. Concurrent requests, other entry points and manual SQL never pass through Zod.
So the same rule is expressed as a schema constraint too.

| rule | Zod (request boundary) | DB (last defense) |
| --- | --- | --- |
| Required value | `z.string().min(1)` | `.notNull()` |
| No duplicate title per user | A pre-read loses to a race | `uniqueIndex('tasks_owner_title_key')` |
| Length ceiling | `.max(120)` | `varchar(120)` or a check constraint |
| Enumerated value | `z.enum([...])` | A check constraint or a reference table |

Implement the duplicate check as `select` → `insert` if absent and two concurrent requests both pass.
**Just insert and convert `23505` into a 409** (`isUniqueViolation` in `resources/api-endpoints.md`).

## Environment variables are input too (`src/config/env.ts`)

When app code reads `process.env` directly, a typo or omission blows up **only on one path after deploy**.
Keep one validated module and fail at boot.

```ts
import { z } from 'zod'

const PublicEnv = z.object({                       // values that may be printed to the logs
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().default(8080),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
  CORS_ORIGINS: z.string().transform((s) => s.split(',').map((v) => v.trim())),
  DB_POOL_MAX: z.coerce.number().int().min(1).max(50).default(10),
  DB_SSL: z.stringbool().default(true),
  DB_CA_PATH: z.string().min(1).optional(),        // path to the CA bundle for server certificate verification
  OIDC_ISSUER: z.url(),                            // e.g. https://cognito-idp.<region>...
  OIDC_JWKS_URL: z.url(),
  OIDC_AUDIENCE: z.string().min(1),                // the app client id (= the client_id claim)
  OIDC_GROUPS_CLAIM: z.string().min(1).default('cognito:groups'),
  OIDC_AUTHORIZE_BASE: z.url(),                    // the Hosted UI domain (origin of authorize and logout)
  SPA_CALLBACK_URL: z.url(),                       // the callback URL registered on the app client
  SPA_LOGOUT_URL: z.url(),                         // the registered sign-out URL (used verbatim as logout_uri)
  S3_BUCKET: z.string().min(1),
  S3_ENDPOINT: z.url().optional(),                 // set only for on-premises MinIO
  AWS_REGION: z.string().min(1).optional(),        // a setting for the S3 adapter — leave it empty on-premises
})

const SecretEnv = z.object({                       // values that never go into logs or responses
  DATABASE_URL: z.string().startsWith('postgres'),
  AUTH_STATE_SECRET: z.string().min(32),           // the OAuth state signing key (HMAC)
})

const EnvSchema = z.object({ ...PublicEnv.shape, ...SecretEnv.shape })
const parsed = EnvSchema.safeParse(process.env)
if (!parsed.success) {
  console.error(JSON.stringify({
    level: 'error', msg: 'invalid environment',
    issues: z.flattenError(parsed.error).fieldErrors,   // key names only, never the values
  }))
  process.exit(1)                                   // boot failure = deploy failure (the health check catches it)
}

export const env = parsed.data
export const publicEnvKeys = Object.keys(PublicEnv.shape)   // the basis for log masking
```

Rules:

- `env` is imported anywhere in `src/`. **`process.env` appears only in this file**
  (in CI, `grep -rn "process\.env" src/ --include=*.ts | grep -v config/env.ts` must come back empty)
- **Reading a key that is not in `env` must break compilation.** Add a new setting to this schema before
  using it — reading a key absent from the schema as `env.X` is a type error, so an omission is caught before boot
- **Do not put a server secret behind the `VITE_*` prefix.** Vite inlines that prefix into the browser
  bundle — do not mix the SPA-side `.env` and the backend `.env` in a shared repository
- The criterion for classifying a secret is "is a leak an incident". `DB_POOL_MAX` and `DB_SSL` are tuning values, so they are public —
  inflate the secret list and you lose the values you could have used in logs and boot diagnostics
- `publicEnvKeys` is used by the logger as **the allowlist when it prints the boot configuration**. A key not on the list
  structurally cannot reach the logs → `logBootConfig` in `resources/portability-boundaries.md`
- A boot failure is `process.exit(1)`, not a `throw` — the container dies immediately and the deploy rolls back.
  **The `safeParse` + `exit(1)` in this file is the only form of boot validation** (do not use `parse`)
- Locally, the entry point is `environment:` in `docker compose`. Do not commit `.env`; keep
  **the key names only** in `.env.example`

## File upload input

When the SPA uploads a file directly, **the server validates the metadata** even if it goes through a presigned URL:
restrict `contentType` to an allowlist and put a `contentLength` ceiling in the signing conditions.
Do not use the filename the client sent as the storage key — the server generates the key.

## Misuse list (Zod 3 → Zod 4 idiom)

| old habit (Zod 3) | Zod 4 form |
| --- | --- |
| `z.string().email()` | `z.email()` |
| `z.string().uuid()` | `z.uuid()` |
| `z.string().url()` | `z.url()` |
| `z.object({...}).strict()` | `z.strictObject({...})` |
| `z.object({...}).passthrough()` | `z.looseObject({...})` |
| `{ message: '...' }` | `{ error: '...' }` |
| `{ required_error, invalid_type_error }` | A single `error` callback or string |
| `err.format()` | `z.treeifyError(err)` |
| `err.flatten()` | `z.flattenError(err)` |
| `z.preprocess((v) => v === 'true', z.boolean())` | `z.stringbool()` |
| `z.record(z.string())` (one argument) | `z.record(z.string(), z.string())` (key and value both stated) |

## Misuse list (confusable pairs)

| often chosen wrong | exactly when it applies |
| --- | --- |
| `parse()` vs `safeParse()` | **Both are `safeParse`.** Boundary parsing goes into the 422 envelope; boot configuration prints key names only and calls `process.exit(1)` — the exception from `parse` leaves only a stack and loses which key was missing from the logs |
| Making the PATCH schema with `Create.partial()` | `.default()` survives, so an empty PATCH passes and an unspecified field is overwritten → keep the default-free base as the source and put `.default()` only on Create |
| `z.object()` vs `z.strictObject()` | A request body takes `strictObject` — it refuses unknown keys. An external webhook payload is better off with `object` |
| `.optional()` vs `.nullish()` vs `.default()` | Absent key takes `optional`, also allowing `null` takes `nullish`, and always having a value takes `default` |
| `z.coerce.number()` vs `z.number()` | Query parameters are strings, so `coerce`. A number in a JSON body takes `z.number()` |
| `z.infer` vs `z.input` | A service signature takes `z.infer`, the type **after** conversion. `z.input` is the pre-parse shape |
| Parsing responses with a schema too | The response is a value we made — contract it with a return type rather than parsing. Parsing belongs at the trust boundary only |
| Sharing the schema file with the SPA | Sharing is fine but **it is not a reason to skip server validation**. A client can send any request at all |
