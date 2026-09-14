<!-- orangekit-pack-policies: backend/aws-container v3.12.0 -->

# aws-container pack — cross-file invariants

The gate checks **whether the seam keeps the policies this pack declares**. Measured: the
largest class of audit findings (26 of 57) was "the place that declares a policy and the place that
enforces it differ, and nothing obliges anyone to reconcile them" — this file is that obligation.

> **Premise of this axis**: the data layer has no row-level policy engine. The ownership policies below are
> not a convenience but **the only line of defense**. Copy this section over from a pack on an axis that has a
> policy engine (BaaS) and the strength is inverted.

## Machine checks (gate `check_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad
span. Every item below was **tested against the pre-built seams at extraction time and confirmed to have 0 violations**.

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-entry` | forbid | seam | `process\.env` | `SKILL.md` | `const url = process.env.DATABASE_URL` | `process.env['DATABASE_URL']` | App code does not read `process.env` directly. It imports only the validated `env` module — a missing value must die at boot, not on the first request. **The hub (`SKILL.md`) is exempt** — it carries the env module's own definition as a ✅ example, and that is not a counterexample to the policy but the very point the policy names (confirmed as a false positive on the gate's first run) |
| `boot-time-env-validation` | require | guide | `safeParse\(process\.env\)` | — | `const parsed = EnvSchema.safeParse(process.env)` | `EnvSchema.parse(process.env)` | Boot validation takes exactly one form: `safeParse` + `process.exit(1)`. The exception from `parse` loses which key was missing from the logs |
| `no-vendor-sdk-in-app` | forbid | guide | `aws-jwt-verify\|CognitoJwtVerifier` | `portability-boundaries.md`, `deployment-and-operations.md` | `import { CognitoJwtVerifier } from 'aws-jwt-verify'` | `import { CognitoJwtVerifier } from "aws-jwt-verify/cognito-verifier"` | A vendor-only verification library turns a migration into a rewrite. Use standard OIDC/JWKS (`jose`) |
| `db-layer-knows-no-http` | forbid | file:`data-access.md` | `\bContext\b\|\bc\.req\b` | — | `export function listTasks(c: Context) {` | `const body = await c.req.json()` | `db/queries/` knows nothing about the Hono `Context`. A reverse import collapses the layering |
| `ownership-in-query` | require | guide | `eq\([a-z]+\.ownerId` | — | `eq(tasks.ownerId, userId)` | `where(eq(tasks.id, taskId))` | Put the owner condition in every query, read and mutation alike. The data layer does not back you up |
| `mutation-returning` | require | guide | `\.returning\(\)` | — | `const [row] = await db.update(tasks).set(patch).returning()` | `const returning = true` | Do not answer a 0-row mutation as success — the source of the "it says deleted but it is still there" bug |

A `scope` of `guide` looks at the whole assembled guide (pack + seam), `seam` at seam files only, and
`file:<name>` at that one file. `require` is satisfied by at least one occurrence after assembly.

**The `proof example` column is mandatory** (the gate FAILs without it). Write one string the regex actually
catches. The gate asserts two things: ① does the example match its own regex — if not, it is a dead regex
that catches nothing ② for `forbid`, is that example absent from the target files —
if present, the pack broke its own policy. Measured (2026-08-23): while authoring the vue pack, building a defective
fixture per policy and running it dominated the wall clock, and this column replaces that round trip with milliseconds.

**Do not use markdown emphasis in a `scope` value.** The gate does not recognize `**seam**` as a scope,
so the policy silently aims at every file — that actually happened in the vue pack, and the audit repair
"aim at the seam" shipped void. The gate now strips emphasis, but write the bare value in the table.

## For humans to keep (machine-undecidable — confirmed as false positives in testing)

- **Isolate queries with no owner condition into a separate file.** `src/db/queries/admin-*.ts` is
  the only exception, and that whole sub-app has to sit behind a role guard. Do not put an `isAdmin`
  flag on the same function — one flag arriving wrong opens every table.
  *(Catch it with a regex and this legitimately isolated file is flagged as a violation — confirmed at extraction time)*
- **Register the public routes before the auth middleware.** They execute in registration order, so with
  `/healthz` coming later the health check dies with a 401. Order cannot be decided by a regex
- **Absent and unauthorized get the same response.** Distinguish 403 from 404 and an unauthorized user can enumerate
  which resources exist. Use 403 only on the non-ownership axis (insufficient role)
- **Do not put DB constraint names, SQL or stacks in an error message** — the schema leaks out
- **Do not run migrations at server boot** — several tasks contend at once
