<!-- orangekit-pack-policies: backend/gcp-serverless v3.14.0 -->

# gcp-serverless pack — cross-file invariants (L0 draft)

The gate checks **whether the pack itself and the seams keep the policies this pack declares**. When the place that declares a policy
and the place that enforces it differ and nothing obliges anyone to reconcile the two, the policy survives only as documentation — this file is that obligation.

## Machine checks (gate `check_policies` · `check_pack_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad block.
Counting prose and anti-pattern examples turns every hit into a false positive.

**The `proof example` column is mandatory** (missing it is a gate FAIL). The gate asserts ① that the example matches its own regex
② and, for `forbid`, that the example does not actually occur in the target file.

**Narrow the scope of a `require` down to the owning file.** `scope` takes **`file:<filename>`**, not just
`guide`·`seam`. Left as `guide` it degrades into "passes if it appears anywhere in the pack at least once", and it grows **more
toothless the more files there are** — measured in fastapi, audit C showed by execution that the policy still passed after the
owning file's check was deleted outright, because a sibling file carried the same string.

**Do not use markdown emphasis in a `scope` value.** `**seam**` is not recognized as a scope, so the policy
silently targets every file — that is exactly what happened in the vue pack.

**Do not use optional groups in a regex.** Patterns like `verify(IdToken)?\(` are satisfied by the broad side alone and
measure nothing of the narrow path they were meant to verify. Check the regex against a string it **must not let through**
as well — if that passes, the policy is dead.

| id | verdict | scope | regex | exempt files | proof example | counter-example | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-entry` | forbid | guide | `process\.env` | `input-validation.md` | `const projectId = process.env.GCP_PROJECT_ID` | `process.env["GCP_PROJECT_ID"]` | Environment values are read in one place only, `settings`. When another file reads them directly, typing, validation, and boot-time failure are all bypassed. There are **only two** exceptions: where the schema is defined, and where the test setup injects the emulator host. **The injection is done through the `env` field of `vitest.config.ts`** — `settings` parses at module top level, so assigning to `process.env` in a `beforeAll` is **already too late** (measured by C4) |
| `no-firebase-admin` | forbid | guide | `firebase-admin` | — | `import { getFirestore } from 'firebase-admin/firestore'` | `const { getApps } = require('firebase-admin/app')` | This axis connects with `@google-cloud/firestore`. Pull `firebase-admin` in and **the code overlaps the `firebase` axis pack**, mixing the security boundaries of two axes — that one rests on the premise that the rules block the client, while this one denies in the rules entirely |
| `converter-required` | require | file:data-access.md | `withConverter\(` | — | `firestore.collection('tasks').withConverter(taskConverter)` | `firestore.collection("tasks").doc(id)` | A collection reference without a converter gives you raw documents — the types pass while a field is missing or a value is not a `Timestamp`. Documents change outside the code, so the converter is **the place that re-parses on read** |
| `ownership-in-query` | require | file:data-access.md | `where\('ownerId'` | — | `tasksRef.where('ownerId', '==', ownerId)` | `tasksRef.where('status', '==', 'open')` | This axis has **no working policy engine** (the rules deny everything and the server bypasses them). Ownership has to be in the query, and the shape that filters in JavaScript after the read has already read someone else's document |
| `cursor-tiebreak` | require | file:data-access.md | `__name__` | — | `.orderBy('__name__', 'desc')` | `.orderBy('createdAt', 'desc')` | **With a single sort key, documents with identical timestamps vanish at the page boundary.** Measured by C2: paging 7 documents with the same `createdAt` at `limit: 2`, `('createdAt','desc')` alone **lost 5 of the 7**, and adding `('__name__','desc')` gave 7/7. The loss is not an exception but **a silent loss of correct answers**, so without a test it is never seen |
| `mutation-in-transaction` | require | file:data-access.md | `runTransaction\(` | — | `await firestore.runTransaction(async (tx) => { … })` | `const fn = firestore.runTransaction` | Update and delete **read, confirm ownership, and then write.** Split the confirmation from the write and you overwrite a document that changed in between, and since `delete()` succeeds even on a missing document, without the confirmation a request to delete someone else's is answered as success |
| `strict-schema` | require | file:input-validation.md | `\.strict\(\)` | — | `const TaskQuery = z.object({ … }).strict()` | `z.object({ title: z.string() })` | Allow unknown keys and a typo'd filter is silently ignored while the list is returned as a normal response. Apply it to both the query and the body |
| `rules-deny-all` | forbid | guide | `allow[^:]*:[[:space:]]*if[[:space:]]+request\.auth` | — | `allow read, write: if request.auth != null;` | `allow update: if request.auth.uid == resource.data.ownerId;` | The `firestore.rules` of this axis is **a blanket deny**. Write an auth condition into the rules and you create the premise that "the rules protect us", while the server connects with a service account and bypasses the rules entirely — that premise is false and it loosens the application's own checks |
| `seam-no-direct-token-parse` | forbid | seam | `jwtVerify\(` | — | `const { payload } = await jwtVerify(token, jwks)` | `await jose.jwtVerify(token, jwks)` | If the seam verifies the token itself, the issuer and audience checks split in two, and those two will always diverge. The seam only extracts the credential and hands verification to `verifyIdToken` (provided by the pack) |
| `seam-status-lookup` | forbid | seam | `ERROR_STATUS\[` | — | `const status = ERROR_STATUS[err.code]` | `ERROR_STATUS[appErr.code] ?? 500` | Subscript access gives `undefined` for a code absent from the table, and once that lands where the status code goes, the runtime error folds into a 500 and the cause disappears. **The seam uses `statusFor(code)` (provided by the pack).** This cell previously read "use `ERROR_STATUS[code] ?? 500`", and **that very prescription tripped this forbidding regex**, leaving the seam no way to pass (measured in the pilot) — when a regex cannot tell the safe shape from the dangerous one, **giving an accessor and forbidding the subscript outright** is the only enforceable shape |
| `vocab-task` | forbid | guide | `\bnotes?\b` | — | `const notes = []` | `creates a note` | The vocabulary is Task/task (issued by L0). Splitting authorship across clusters splits the vocabulary — measured, it drifted to `task` 217 times against `note` 166 times, and the complete examples could not run against each other |

## What humans keep (machines cannot decide it)

- **Answer absence and lack of permission the same way.** Give a `403` on someone else's document and a `404` on a missing one
  and that difference is itself proof of existence. This pack folds **both into `NOT_FOUND`**
- **`sub` is the subject.** `email` can be changed by the user and can be reused, so do not use it as
  `ownerId`. Which claim of the token becomes the ownership key is an irreversible decision
- **Do not fold `FAILED_PRECONDITION` (code 9) into a 4xx.** Most of the time it is a missing index, and that is
  a missing deployment rather than a user input problem — fold it into a 4xx and the cause disappears from the logs
- **Do not build module-top-level instances per request.** Cloud Run is a resident process, so the caches of
  `firestore` and `jwks` really do live. Build them inside the handler and all of that benefit is gone, and the
  gRPC channel and the JWKS round trip grow with the request count
- **Call `shutdown(server)` inside the signal handler.** Called at the top level, the container exits right after
  boot. What Cloud Run gives you is 10 seconds after SIGTERM
