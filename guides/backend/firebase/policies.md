<!-- orangekit-pack-policies: backend/firebase v3.14.0 -->

# firebase pack — cross-file invariants (L0 draft)

The gate checks **whether the pack itself and the seam keep the policies this pack declares**.

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad span.

**The `proof example` column is mandatory** (the gate FAILs without it). **Do not use markdown emphasis in a `scope` value.**
**Do not use an optional group in a regex** — it is satisfied by the success path alone and never measures the failure path.

## Machine checks (gate `check_policies` · `check_pack_policies`)

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `no-console-log` | forbid | guide | `console\.log\(` | — | `console.log('created', id)` | `console.log(`created ${id}`)` | The structured fields disappear and it cannot be queried in Cloud Logging. Use `logger` |
| `single-app-init` | forbid | guide | `initializeApp\(` | `data-access.md` | `initializeApp()` | `initializeApp(config)` | Calling it twice throws. Only the place that builds the client is exempt |
| `owner-in-query` | require | guide | `where\(\s*'ownerId'\s*,\s*'=='` | — | `.where('ownerId', '==', ownerId)` | `where('id', '==', taskId)` | A document ID alone reads other people's documents too. **Ownership has to be in the query** — the admin SDK bypasses the rules, so this is the only boundary on the function path |
| `tx-for-check-then-write` | require | guide | `runTransaction\(` | — | `await db.runTransaction(async (tx) => {` | `const fn = db.runTransaction` | Split the existence-and-ownership check from the write and the owner can change in between |
| `no-client-timestamp` | forbid | guide | `createdAt:\s*new Date\(` | — | `createdAt: new Date()` | `createdAt:  new Date()` | Do not trust the clock of a client or a function instance. Use `FieldValue.serverTimestamp()` |
| `rules-split-write` | forbid | guide | `allow[^:]*\bwrite\b[^:]*:` | — | `allow write: if isOwner(resource);` | `allow write, delete: if isOwner(resource);` | Bundling everything under one `write` means the invariants of create and update differ and one of the two is necessarily loose. Write `create`, `update` and `delete` separately |
| `params-value-in-handler` | forbid | guide | `^[[:space:]]*const \w+ = \w+\.value\(\)` | — | `const key = apiKey.value()` | `  const key = apiKey.value()` | Calling `.value()` at module top level blows up during the deploy analysis phase. Call it inside the handler |
| `vocab-task` | forbid | guide | `\bnote(s)?\b` | — | `const notes = []` | `creates a note` | The vocabulary is Task/task (issued by L0). Split the clusters and the vocabulary diverges |

## For humans to keep (the machine cannot decide these)

- **Rules and queries change together.** Firestore answers a query that cannot satisfy the rules with a
  **rejection, not 0 results** — if the rules have an `ownerId` condition, the query needs that `where` too
- **A composite index is a function of the query.** Change the `where` + `orderBy` combination and
  `firestore.indexes.json` changes too; deploy without the index and that one query fails at runtime
- **Do not leave the rules loose just because `clientAccessPolicy` is `functions-only`.** Even when only functions are planned,
  keep the rules locked — the moment someone attaches an SDK later, the door is already open
- **Do not verify rules by "reading" them without the emulator.** The rules language's evaluation order and the
  `resource` / `request.resource` distinction are the classic places to get wrong by reading
