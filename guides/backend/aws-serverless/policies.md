<!-- orangekit-pack-policies: backend/aws-serverless v3.13.0 -->

# aws-serverless pack — cross-file invariants (L0 draft)

## Machine checks (gate `check_policies` · `check_pack_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad span.

**The `proof example` column is mandatory** (FAIL without it). The gate asserts ① does the example match its own regex
② for `forbid`, is that example absent from the target files.
**Do not use markdown emphasis in a `scope` value** — `**seam**` is not recognized as a scope.

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-entry` | forbid | guide | `process\.env` | `input-validation.md, deploy-and-iam.md` | `const t = process.env.TABLE_NAME` | `process.env["TABLE_NAME"]` | Environment values are read in exactly one place, `env`. Two exceptions: where the schema is applied, and where CDK passes deploy-time values |
| `boot-time-env-validation` | require | guide | `safeParse\([^)]*process\.env` | — | `EnvSchema.safeParse(process.env)` | `EnvSchema.parse(process.env)` | **Fail at the cold start.** Validate inside the handler and a bad deploy stays alive until the first request |
| `no-scan` | forbid | guide | `ScanCommand\|new Scan\(` | `data-modeling.md` | `new ScanCommand({ TableName: TABLE })` | `await ddb.send(new ScanCommand({}))` | Scan reads the whole table — cost and latency scale with the data volume and **the ownership filter becomes a post-filter instead of a key condition.** The only exception is the modeling document that explains the anti-pattern |
| `ownership-in-key` | require | guide | `(KeyConditionExpression\|ConditionExpression)` | — | `KeyConditionExpression: 'pk = :pk'` | `FilterExpression: 'ownerId = :o'` | **The biggest risk on this axis.** There is no policy engine, so ownership has to go into **the key condition or the condition expression**. Comparing after the read is pierced by a race, and a post-filter comes after the read already happened |
| `no-table-wide-grant` | forbid | guide | `grantReadWriteData\|grantFullAccess` | — | `table.grantReadWriteData(fn)` | `table.grantFullAccess(fn)` | Grant least privilege per function. With table-wide permissions, one pierced function opens every domain |
| `client-outside-handler` | require | guide | `DynamoDBDocumentClient\.from` | — | `const ddb = DynamoDBDocumentClient.from(base)` | `const ddb = new DynamoDBClient({})` | Build the client at **module top level**. Build it inside the handler and every call stands a new connection up, and the cold-start gain is gone |
| `no-console` | forbid | guide | `console\.(log\|error\|warn)\(` | — | `console.log(user)` | `console.error(err)` | Use the powertools logger only. It has to be structurally queryable in CloudWatch |
| `error-status-single-table` | require | guide | `ERROR_STATUS\[[^]]*\][[:space:]]*\?\?` | — | `ERROR_STATUS[e.code] ?? 500` | `export const ERROR_STATUS = {` | Decide status codes file by file and the same failure goes out under a different code depending on where it happens |
| `no-relational-idiom` | forbid | guide | `\bJOIN\b\|foreign key` | `data-modeling.md` | `SELECT * FROM tasks JOIN users` | `creates a foreign key` | DynamoDB has no joins. Carry relational habits straight over and the whole access-pattern design goes wrong. The only exception is the modeling document that carries the contrast table |
| `vocab-task` | forbid | guide | `\bnotes?\b` | — | `const notes = []` | `creates a note` | Fix the domain vocabulary at `Task`/`tasks`/`task` (issued by L0). Measured, the frontend used `/tasks` while the backend used `/notes` and the complete examples could not run against each other |
| `auth-in-handler` | require | seam | `=[[:space:]]*requireAuth\(` | — | `const user = requireAuth(event)` | `export function requireAuth(event)` | **Why the scope is `seam`**: `requireAuth` is defined by the seam, so aiming it at `guide` can never fail as long as the seam ships — and the handler wiring, the one thing that actually needs verifying, goes unchecked |
| `envelope-from-respond` | require | seam | `respond\.fail\(` | — | `return respond.fail(e)` | `return respond.ok(data)` | Envelope emission happens in exactly one place. Let the handler build `{ statusCode, body }` itself and the envelope forks. **Why the regex carries no optional group**: write it `respond(\.fail)?\(` and the success path's `respond(...)` alone satisfies it, so **the failure path is never measured at all** — audit A found this by measurement. It is the same class as `ownership-in-query` being satisfied by a parameter comment |

A `scope` of `guide` looks at the whole assembled guide, `pack` at pack files only, `seam` at seam files only,
and `file:<name>` at that one file. Before assembly (`--pack`) a `seam` scope is undecidable, so
**what was skipped is reported explicitly**.

## For humans to keep (machine-undecidable)

- **Do not answer absence and unauthorized differently.** Someone else's item is a 404, not a 403
- **Do not apply ownership with a `FilterExpression`.** The filter runs **after** the read, so you are billed
  for it and the page size comes out wrong — the owner has to go into the **partition key**.
  `KeyConditionExpression` and `FilterExpression` are distinguishable line by line, but **which of the two
  holds the owner** only a human knows
- **Do not stack `.default()` onto a partial-update schema.** A field that was not sent gets overwritten
  by the default — the syntax is perfect and only running it reveals the problem
- **Do not build an `UpdateExpression` by string concatenation.** Pass attribute names as `#n` placeholders
  and values as `:v`
- **Do not let one handler serve several routes.** Least-privilege IAM per function stops
  holding — split a function per route
- **Distinguish retryable failures from the rest.** Throttles and timeouts are retry targets and
  a validation failure is not. Write on the premise that API Gateway does not retry
