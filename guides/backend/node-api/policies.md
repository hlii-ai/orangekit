<!-- orangekit-pack-policies: backend/node-api v3.13.0 -->

# node-api pack — cross-file invariants (L0 draft)

The gate checks **whether the pack itself and the seams keep the policies this pack declares**. When the place that declares a policy
and the place that enforces it differ and nothing obliges anyone to reconcile the two, the policy survives only as documentation — this file is that obligation.

## Machine checks (gate `check_policies` · `check_pack_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad block.
Counting prose and anti-pattern examples turns every hit into a false positive.

**The `proof example` column is mandatory** (missing it is a gate FAIL). The gate asserts ① that the example matches its own regex
② and, for `forbid`, that the example does not actually occur in the target file. Measured (2026-08-23), building and running a
defect fixture per policy dominated the wall clock of the vue authoring, and this column replaces that round trip.

**Do not use markdown emphasis in a `scope` value.** `**seam**` is not recognized as a scope, so the policy
silently targets every file — that is exactly what happened in the vue pack.

| id | verdict | scope | regex | exempt files | proof example | counter-example | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-entry` | forbid | guide | `process\.env` | `input-validation.md, testing.md` | `const url = process.env.DATABASE_URL` | `process.env["DATABASE_URL"]` | Environment values are read in one place only, `env`. When another file reads them directly, typing, validation, and boot-time failure are all bypassed. Two exceptions: where the schema is applied, and where a test injects an isolated DB |
| `boot-time-env-validation` | require | guide | `safeParse\([^)]*process\.env` | — | `EnvSchema.safeParse({ ...process.env })` | `EnvSchema.parse(process.env)` | A missing or malformed value has to fail **at boot**, not at first use. A first-use failure blows up on one particular request hours after the deploy |
| `prisma-single-client` | forbid | guide | `new[[:space:]]+PrismaClient\(` | `data-access.md` | `const db = new PrismaClient()` | `const db = new  PrismaClient()` | Two clients means two connection pools. The only exception is the place that defines the singleton. **That tests are not an exception is deliberate** — isolation comes from injecting a URL, not from a new client (confirmed by C3) |
| `no-raw-sql-interpolation` | forbid | guide | `\$(queryRawUnsafe\|executeRawUnsafe)` | — | `prisma.$queryRawUnsafe(sql)` | `prisma.$executeRawUnsafe(sql)` | The `Unsafe` variants send the string through as-is. The tagged template (`$queryRaw`) is parameterized and therefore allowed. **A table name cannot be parameterized, so `TRUNCATE`-based test cleanup is sealed off on this axis — deliberately**: `deleteMany()` is slower but the FK order is enforced by types (raised by C3) |
| `ownership-in-query` | require | guide | `where:[[:space:]]*\{[^}]*ownerId` | — | `where: { id, ownerId }` | `where: { id: taskId }` | **The biggest risk on this axis.** There is no data-layer policy engine, so ownership has to go into the query condition. Comparing after the read is open to a race, and omitting it is a data leak outright. **Why the regex demands it be inside the `where` object**: a bare `ownerId:` is satisfied by a single TypeScript parameter annotation (`ownerId: string`) and sees nothing of whether it made it into the `where` — C2 found this by measurement |
| `mutation-affected-rows` | require | guide | `\.count[[:space:]]*===[[:space:]]*0` | — | `if (res.count === 0) throw new AppError('NOT_FOUND')` | `const count = 0` | A mutation with an ownership filter silently succeeds against someone else's row with **0 rows changed**. Without looking at the affected row count it returns a 200 |
| `db-layer-knows-no-http` | forbid | file:data-access.md | `\b(Request\|Response\|NextFunction)\b\|\bres\.(status\|json\|send\|sendStatus\|set\|cookie\|redirect\|end)\b` | — | `export function listTasks(req: Request) {` | `res.status(404).json({})` | Once the data layer knows about HTTP, tests need a server and the layering collapses. A query function takes plain arguments only. **Why a bare `res.` is not forbidden**: the idiomatic name for a mutation result is exactly `res`, which would collide with `res.count === 0` in `mutation-affected-rows` — so it targets response-object methods only (measured by C2) |
| `no-console` | forbid | guide | `console\.(log\|error\|warn)\(` | — | `console.log(user)` | `console.warn(x)` | Use the structured logger only. `console` has no request correlation, no level, and no serialization, so it is not searchable in production |
| `graceful-shutdown` | require | guide | `on\('SIGTERM'` | — | `process.on('SIGTERM', shutdown)` | `const SIGTERM_GRACE = 10000` | Fail to drain in-flight requests on container shutdown and every deploy produces 5xx |
| `error-status-single-table` | require | guide | `ERROR_STATUS\[[^]]*\][[:space:]]*\?\?` | — | `ERROR_STATUS[err.code] ?? 500` | `export const ERROR_STATUS = {` | Decide status codes per file and the same failure goes out with a different code depending on where it happened |
| `vocab-task` | forbid | guide | `\bnotes?\b` | — | `const notes = []` | `creates a note` | Fix the domain vocabulary at `Task`/`tasks`/`task` (issued by L0). Measured, the frontend used `/tasks` while the backend used `/notes` and the complete examples could not run against each other — splitting authorship across clusters widens that surface |
| `requireauth-on-router` | require | seam | `,[[:space:]]*requireAuth[,)]` | — | `router.post('/', requireAuth, createTask)` | `export function requireAuth(req, res, next)` | **Why the scope is `seam`**: `requireAuth` is defined by the seam, so scoping it to `guide` means it can never fail as long as the seam ships — and the router wiring, the thing that actually needs verifying, goes unchecked (raised by the vue pack measurement) |
| `envelope-from-error-handler` | require | seam | `app\.use\(errorHandler` | — | `app.use(errorHandler)` | `export function errorHandler(err, req, res, next)` | The envelope is emitted in one place only. If a router does `res.status(400).json(...)` itself, the envelope splits. It targets the seam for the same reason as above |

A `scope` of `guide` looks at the whole assembled guide (pack + seam), `pack` at pack files only, `seam` at seam
files only, and `file:<name>` at that file alone. A `require` is satisfied by at least one occurrence.
Before assembly (`--pack`), `seam`-scoped policies are undecidable, so **what was skipped is reported explicitly**.

## What humans keep (undecidable by machine)

- **Do not answer differently for absence and lack of permission.** Reading someone else's row is a 404, not a 403 —
  split them and an unauthorized user can enumerate which resources exist. A regex cannot see the meaning of a
  response branch
- **Do not read with `findUnique({ where: { id } })` and then compare the owner.** Ownership goes into the read
  condition. The two shapes are not distinguishable line by line — all a machine sees is whether `ownerId:` is there
- **Do not stack a `.default()` onto a partial-update schema.** Fields that were not sent get overwritten with the
  default. The syntax is perfect and only running it reveals the problem (the worst measured defect)
- **Do not make an external call (HTTP, a queue) inside a transaction.** It is not rolled back and it only lengthens the lock
- **Fetch only the columns you need with `select`.** Especially on a model with secret or hash columns, selecting
  everything becomes a leak path into logs and responses
- **Run migrations as a step separate from the deploy.** Doing `migrate deploy` at application boot makes
  instances race when they come up together
