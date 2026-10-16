<!-- orangekit-pack-policies: backend/fastify v3.33.0 -->

# fastify pack — cross-file invariants

The gate checks **whether the pack itself and the seams keep the policies this pack declares**. When the place that declares a policy
and the place that enforces it differ and nothing obliges anyone to reconcile the two, the policy survives only as documentation — this file is that obligation.

## Machine checks (gate `check_policies` · `check_pack_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad block.
Counting prose and anti-pattern examples turns every hit into a false positive.

**The `proof example` column is mandatory** (missing it is a gate FAIL). The gate asserts ① that the example matches its own regex
② and, for `forbid`, that the example does not actually occur in the target file. **The `counter-example` means something different per verdict**:
for `forbid` it is **the same violation in a different shape** from the proof example (it checks that the regex targets the class), and for
`require` it is **a string that must not satisfy the policy** (if it matches, the policy is dead).

**Narrow a `require` policy down to the owning file** (`file:<name>`). Left as `guide`, it degenerates into "once anywhere in the
pack", and even if the owning file's check is deleted, a sibling file carrying the same string makes it pass.

| id | verdict | scope | regex | exempt files | proof example | counter-example | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-entry` | forbid | guide | `process\.env` | `input-validation.md, testing.md` | `const url = process.env.DATABASE_URL` | `const { PORT } = process.env` | Environment values are read in one place only, `env`. Two exceptions: where the schema is applied (`src/env.ts`) and where a test injects an isolated DB (`src/test/env.ts` · `global-setup.ts`). `drizzle.config.ts` imports `env` too — it is not an exception |
| `boot-time-env-validation` | require | file:input-validation.md | `safeParse\(\{[[:space:]]*\.\.\.process\.env` | — | `EnvSchema.safeParse({ ...process.env })` | `EnvSchema.parse(process.env)` | A missing or malformed value has to fail **at boot**, not at first use |
| `single-pool` | forbid | guide | `new[[:space:]]+Pool\(` | `data-access.md, testing.md` | `const p = new Pool({ connectionString })` | `const p = new  Pool()` | Two pools means two connection caps. Exceptions: the place that defines the singleton, and the `max: 1` pool `globalSetup` opens for migrations (the app modules are not loaded yet, so the singleton cannot be used) |
| `no-sql-raw` | forbid | guide | `sql\.raw\(` | — | `sql.raw(column)` | `db.execute(sql.raw(q))` | `sql.raw` does not escape. The tagged `sql` template is parameterized and therefore allowed |
| `ownership-in-query` | require | file:data-access.md | `eq\(tasks\.ownerId,[[:space:]]*ownerId\)` | — | `and(eq(tasks.id, id), eq(tasks.ownerId, ownerId))` | `ownerId: string` | **The biggest risk on this axis.** Why the regex demands an `eq(...)` call: a bare `ownerId` is satisfied by a single parameter annotation and sees nothing of whether it made it into the WHERE |
| `mutation-returning-checked` | require | file:data-access.md | `\.length[[:space:]]*===[[:space:]]*0` | — | `if (rows.length === 0) throw new AppError('NOT_FOUND', '…')` | `const length = 0` | An update under an ownership condition silently succeeds with 0 rows against someone else's row. The length of the `returning` result is the verdict |
| `delete-rowcount-checked` | require | file:data-access.md | `rowCount[[:space:]]*===[[:space:]]*0` | — | `if (res.rowCount === 0) throw new AppError('NOT_FOUND', '…')` | `res.rowCount` | A delete without `returning` is checked through `QueryResult.rowCount`. Why it is split from the policy above: bundle them as optional branches of one regex and the update check alone satisfies the delete check |
| `db-layer-knows-no-http` | forbid | file:data-access.md | `\bFastify(Request\|Reply\|Instance)\b\|\breply\.` | — | `export async function listTasks(req: FastifyRequest) {` | `reply.code(404).send()` | Once the data layer knows about HTTP, testing a single query needs the app |
| `no-console` | forbid | guide | `console\.(log\|error\|warn\|info)\(` | — | `console.log(user)` | `console.error(err)` | `req.log` carries `reqId`, a level, and redact. `console` has none of the three. An env failure before boot uses `process.stderr.write` |
| `listen-explicit-host` | require | file:operations.md | `listen\(\{[[:space:]]*host:` | — | `await app.listen({ host: env.HOST, port: env.PORT })` | `await app.listen({ port: env.PORT })` | host defaults to `127.0.0.1`, so it is unreachable from outside on EC2 or in a container (confirmed by running it) |
| `no-listen-positional` | forbid | guide | `\.listen\([^{)[:space:]]` | — | `app.listen(3000)` | `app.listen(env.PORT)` | v5 has no positional-argument signature — the boot fails. It catches not only literals but variables (`env.PORT`) too — real violations are usually the variable form |
| `no-logger-instance` | forbid | guide | `logger:[[:space:]]*pino\(` | — | `Fastify({ logger: pino() })` | `Fastify({ logger:pino({ level: 'info' }) })` | v5 rejects it with `FST_ERR_LOG_INVALID_LOGGER_CONFIG` |
| `graceful-shutdown` | require | file:operations.md | `process\.once\('SIGTERM'` | — | `process.once('SIGTERM', onSignal)` | `const SIGTERM_GRACE = 10000` | Die without draining and every deploy cuts off in-flight requests |
| `error-handler-at-root` | require | file:project-structure.md | `setErrorHandler\(errorHandler\)` | — | `app.setErrorHandler(errorHandler)` | `s.setErrorHandler((e, r, reply) => reply.send(e))` | The envelope is emitted in one place, the root. If a child context overrides `setErrorHandler`, only that child's routes emit a different envelope (confirmed by running it) |
| `vocab-task` | forbid | guide | `\bnotes?\b` | — | `const notes = []` | `creates a note` | Fix the domain vocabulary at `Task`/`tasks`/`task` (issued by L0) |
| `requireauth-in-route-plugin` | require | seam | `addHook\('onRequest',[[:space:]]*requireAuth\)` | — | `app.addHook('onRequest', requireAuth)` | `export async function requireAuth(req: FastifyRequest)` | **Why the scope is `seam`**: the place that sets the hook is the seam's route plugin. Scope it to `guide` and the definition alone passes, leaving the wiring itself unchecked |
| `status-from-table` | require | seam | `ERROR_STATUS\[` | — | `const status = ERROR_STATUS[app.code]` | `export const ERROR_STATUS = {` | The place that decides the status is the seam's `errorHandler`. Bypass the table and the same failure goes out with a different code in each place |

A `scope` of `guide` looks at the whole assembled guide (pack + seam), `pack` at pack files only, `seam` at seam
files only, and `file:<name>` at that file alone. A `require` is satisfied by at least one occurrence.
Before assembly (`--pack`), `seam`-scoped policies are undecidable, so **what was skipped is reported explicitly**.

## What humans keep (undecidable by machine)

- **Do not answer differently for absence and lack of permission.** Someone else's row is a 404, not a 403. A regex
  cannot see the meaning of a response branch — the tests check it through byte-for-byte identity of the two bodies
- **Do not set the auth hook on a sibling plugin.** A machine sees that `addHook` is there, but **whether it is in the
  same context as the routes** can only be known by reading the registration structure. The exhaustive auth boundary
  test in `testing.md` catches this by running
- **Do not use `db` inside a transaction callback.** `tx` and `db` cannot be told apart line by line — `db.insert` is
  fine outside the callback. The rollback test catches it (confirmed by running it: 1 row remained)
- **Do not stack a `.default()` onto a partial-update schema.** Fields that were not sent get overwritten with the
  default. The syntax is perfect and only running it reveals the problem
- **Do not put `err.message` in the response.** A `DrizzleQueryError`'s message is the full SQL. That is why
  `toAppError` discards the cause and uses a fixed phrase
- **The ownership and affected-row-count policies only check "once in the file".** `ownership-in-query` is satisfied
  even if only one of the five functions has it — per-function enforcement is done by the four ownership pairs and
  the mutation table in `testing.md`
- **Put a tiebreaker in the cursor.** Cut by `createdAt` alone and rows from the same ms drop out at the page
  boundary (confirmed by running it: some of 7 rows went missing)
- **Run migrations once, as a step separate from the deploy.** Call `migrate` at boot and instances contend when they
  come up together (the basis is principle — `knownGaps`)
