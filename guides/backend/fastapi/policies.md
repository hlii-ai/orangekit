<!-- orangekit-pack-policies: backend/fastapi v3.14.0 -->

# fastapi pack — cross-file invariants (L0 draft)

The gate checks **whether the pack itself and the seams keep the policies this pack declares**. When the place that declares a policy
and the place that enforces it differ and nothing obliges anyone to reconcile the two, the policy survives only as documentation — this file is that obligation.

## Machine checks (gate `check_policies` · `check_pack_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad block.
Counting prose and anti-pattern examples turns every hit into a false positive.

**The `proof example` column is mandatory** (missing it is a gate FAIL). The gate asserts ① that the example matches its own regex
② and, for `forbid`, that the example does not actually occur in the target file.

**Narrow the scope of a `require` down to the owning file.** `scope` takes **`file:<filename>`**, not just
`guide`·`seam`. Left as `guide` it degrades into "passes if it appears anywhere in the pack at least once", and it grows **more
toothless the more files there are** — audit C showed by execution that the policy still passed after the `rowcount` check in
`data-access.md` was deleted outright (another file was carrying the same string).

**Do not use markdown emphasis in a `scope` value.** `**seam**` is not recognized as a scope, so the policy
silently targets every file — that is exactly what happened in the vue pack.

**Do not use optional groups in a regex.** Patterns like `respond(\.fail)?\(` are satisfied by the success path alone and
measure nothing of the failure path they were meant to verify (measured in audit A). Check the regex against a string it **must not
let through** as well — if that passes, the policy is dead.

| id | verdict | scope | regex | exempt files | proof example | counter-example | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-entry` | forbid | guide | `os\.environ` | `testing.md` | `url = os.environ["DATABASE_URL"]` | `os.environ.get("DATABASE_URL")` | Environment values are read in one place only, `settings`. When another file reads them directly, typing, validation, and boot-time failure are all bypassed. There is **exactly one** exception: where a test injects an isolated DB. Where the schema is applied, pydantic-settings does the reading, so `os.environ` is not needed |
| `no-sync-session` | forbid | guide | `\bsessionmaker\(` | — | `SessionLocal = sessionmaker(engine)` | `SessionLocal = orm.sessionmaker(engine)` | A synchronous `sessionmaker` blocks the event loop inside an async router. This axis uses `async_sessionmaker` only — the two names are one prefix apart, so copying silently mixes them |
| `no-orm-in-response` | forbid | guide | `response_model\s*=\s*Task\b` | — | `@router.get("/{id}", response_model=Task)` | `response_model = Task` | Using an ORM model as the response schema silently leaks columns added later. Only `TaskOut` goes into a response |
| `ownership-in-where` | require | guide | `Task\.owner_id\s*==` | — | `select(Task).where(Task.owner_id == owner_id)` | `select(Task).where(Task.id == task_id)` | This axis has no row-level policy engine. **Ownership must be in the `WHERE`**; filtering in Python happens after someone else's rows have already been read |
| `rowcount-checked` | require | file:data-access.md | `\.rowcount\b` | — | `if result.rowcount == 0: raise AppError("NOT_FOUND", ...)` | `count = res.rowcount_total` | `UPDATE`·`DELETE` succeed even when they mutate 0 rows. Without the check, a request to delete someone else's row also returns 204 |
| `partial-update-exclude-unset` | require | guide | `exclude_unset\s*=\s*True` | — | `patch = body.model_dump(exclude_unset=True)` | `patch = body.model_dump(exclude_none=True)` | Without it, fields that were never sent overwrite stored values with their defaults. **The worst measured defect was of this class, and its syntax was perfect** — the schema run in `pack-smoke.sh` blocks the same class with a FAIL |
| `no-string-sqlstate` | forbid | guide | `(duplicate key\|unique constraint\|violates)` | — | `if "unique constraint" in str(exc):` | `if "duplicate key" in str(exc):` | Driver messages change with locale and version. Decide on SQLSTATE (`23505`). **Leaving the regex as the single string `"duplicate key"` fails to catch even the `"unique constraint"` the pack itself demonstrates as a ❌ example** (measured in audit C) |
| `seam-no-http-exception` | forbid | seam | `raise [A-Za-z_.]*HTTPException\(` | — | `raise HTTPException(status_code=404)` | `raise fastapi.HTTPException(status_code=404)` | A seam that raises `HTTPException` directly bypasses the `ERROR_STATUS` mapping table — a status absent from the code table leaks out and the envelope takes two shapes. Raise `AppError` and let `install_error_handlers` translate it |
| `seam-status-lookup` | forbid | seam | `ERROR_STATUS\[` | — | `status = ERROR_STATUS[app.code]` | `s = ERROR_STATUS[app_err.code]` | Subscript access raises `KeyError` on a code absent from the table, and that `KeyError` folds back into a 500 — the cause disappears. Use `ERROR_STATUS.get(code, 500)` |
| `seam-depends-current-user` | require | seam | `Depends\(current_user\)` | — | `user: AuthUser = Depends(current_user)` | `Depends(get_current_user)` | If a router parses the token itself there are two boundaries, and those two will always diverge. The subject is obtained through this one dependency alone |
| `vocab-task` | forbid | guide | `\bnotes?\b` | — | `notes = []` | `creates a note` | The vocabulary is Task/task (issued by L0). Splitting authorship across clusters splits the vocabulary — measured, it drifted to `task` 217 times against `note` 166 times, and the complete examples could not run against each other |

## What humans keep (machines cannot decide it)

- **`get_session` is the transaction boundary.** Committing inside every repository function lets one router leave
  a half-applied state behind. The commit happens once, when the request succeeds
- **A human decides where `selectinload` belongs and where it does not.** If a list does not use the relation,
  do not attach it — attaching it reads extra rows nobody will use on every page
- **Read and fix an Alembic autogenerated revision before committing it.** Index names, type changes, and data
  migration are not things autogeneration handles on its own. In particular, if the `(owner_id, created_at, id)` composite index
  (`ix_tasks_owner_created_id`) is missing, the list becomes a full scan — `data-access.md` owns the declaration,
  `migrations.md` owns the application
- **Do not build a router that bypasses `current_user`.** If even one parses the token itself,
  there are two boundaries, and those two will always diverge
