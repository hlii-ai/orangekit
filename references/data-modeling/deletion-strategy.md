<!-- orangekit-rule-version: 3.41.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Data deletion strategy — logical deletion by default, physical deletion only for exempt tables

> Scope: the principles are common to relational DBs, and the syntax is given for both PostgreSQL and MySQL 8.
> **Deletion is a policy, not a technique.** Decide it **per table**, looking at recovery, legal retention, audit, analytics, and referential integrity.

## Decision criteria — logical deletion by default, physical deletion only for exempt tables

In operation, development changes and errors **will put wrong data into tables that then has to be removed.** Physical deletion erases
that the data ever existed and why it was removed. So business data is **removed by logical deletion.**

| Approach | Applies to | Examples |
| --- | --- | --- |
| **Logical deletion — Soft Delete** (`deleted_at`·`deleted_by`) | the default | members, posts · comments, operator-managed data such as products · banners · challenges, measurement and activity records, notifications |
| **Logical deletion — void state** (`VOIDED` + `voided_at`·`voided_by`) | core domains whose lifecycle is managed by status | orders, payments, settlements, exchanges · refunds |
| **Physical deletion** (Hard Delete) | **exempt tables only** — their history survives another way or they have nothing to lose | the table below |

| Exempt table | Why physical deletion is fine |
| --- | --- |
| Ledgers (point · amount events) | rows are not deleted but **fixed by adding correcting entries** — the correction stays in the ledger |
| Archive tables | they are where rows filtered out of the source are kept |
| History tables (`_history` · `audit_log`) | they are the change record itself |
| Derived caches (balances · aggregates) | recomputed from the source |
| Expiring data (tokens · verification links · sessions · idempotency keys) | cleaned up by expiry — no history worth keeping |
| Single-row settings | never deleted, only changed |

- **Core domains (orders · payments · settlements) are managed by status.** A Status table has no `deleted_at`. A wrongly created row moves to `VOIDED` with `voided_at`·`voided_by` filled.
- The cost of Soft Delete (missed filters, indexes) is handled by the active views · shared helpers in "Query procedure" below. Do not hard-delete a non-exempt table to avoid that cost.
- Write the chosen approach in the table definition document or the migration comment (the "three per-table decisions" in card §8).
- A request for complete erasure of personal data is a separate procedure ("Permanent deletion and personal data" below).

## Operational corrections must be traceable under any strategy

In operation, wrongly entered data will certainly need correcting. Whichever strategy you chose,
a record must remain of **who, when, why, and what (before/after values)** changed. Handle the correction and its record in **one transaction**.

| Strategy | How to correct wrongly entered data | Traceability |
| --- | --- | --- |
| Void state | Fix the value (UPDATE). If the row itself is wrong, transition to `VOIDED` and fill `voided_at`·`voided_by`. Do not express it with `deleted_at` | the dedicated `_history` with `change_type = 'CORRECTION'` and a `change_reason` |
| Soft Delete | Fix the value, or fill in `deleted_at` · `deleted_by` | the same history row. For a table with no history, `audit_log`'s `old_data`/`new_data` |
| Physical deletion (exempt tables only) | ledgers: INSERT a correcting entry; expiring data · caches: DELETE | for a ledger the correcting entry is the record. Otherwise record in `audit_log` only when it matters to the business |

- Business-critical tables (price · status · balance · contract · permission) get a dedicated history, and the rest go to `audit_log` (→ the history strategy table in [`change-history.md`](./change-history.md)).
  **There must be no correction path that is recorded in neither.**
- A correction done as a direct UPDATE/DELETE in the DB console follows the same rule. Perform operational corrections only through an admin function or script that writes the history as well.

## Standard design — Soft Delete

```sql
deleted_at  TIMESTAMPTZ NULL,       -- MySQL: DATETIME NULL · NULL = active
deleted_by  BIGINT      NULL        -- on tables that need audit (who deleted it)
```

- Do not use `is_deleted BOOLEAN`. It does not tell you when it was deleted, you cannot permanently delete rows past their retention period, and you cannot trace withdrawal and recovery history.
- Recovery is just setting `deleted_at = NULL` again.

### Dialect differences — indexing and UNIQUE on active rows only

| Goal | PostgreSQL | MySQL 8 |
| --- | --- | --- |
| Index for reading active rows | a partial index `CREATE INDEX idx_members_name_active ON members (name) WHERE deleted_at IS NULL` | There is no partial index. Keep just the business-column index, or if you need covering, order it **`(business column, deleted_at)`** |
| UNIQUE on active rows only | a partial UNIQUE `CREATE UNIQUE INDEX uq_members_login_id ON members (login_id) WHERE deleted_at IS NULL` | **Change the value on withdrawal** (below). Do not use `UNIQUE (login_id, deleted_at)` — NULLs do not count as duplicates, so even active rows may duplicate each other |

```sql
-- MySQL: change the UNIQUE value on withdrawal to avoid a re-signup collision
UPDATE members
   SET deleted_at = NOW(),
       login_id   = CONCAT(login_id, '_deleted_', UNIX_TIMESTAMP())
 WHERE member_id = :id;
```

- Do **not put `deleted_at` as the leading column** of an index. Over 90% of rows are NULL, so it has no selectivity.
  Leave it out of the index, or if you include it, put it last.
- Leave room in the UNIQUE column's length for the suffix (`_deleted_` + a 10-digit timestamp).

## Read procedure

- 99% of queries read only active data. Apply `deleted_at IS NULL` **on every table you join**. Applying it on one side lets deleted orders slip through.
- Do not repeat the filter by hand in every query — **enforce it with an active view or a shared query helper**.
  For example `CREATE VIEW active_members AS SELECT … FROM members WHERE deleted_at IS NULL`. Joining active views leaves no room for the mistake.
- On a stack that uses row-level security (RLS), put `deleted_at IS NULL` in the `USING` clause of every SELECT and UPDATE policy.
  The policy details live in that stack's backend-guide auth/permission boundary resource.
- Deleted data can still be analyzed. For example, withdrawals per month come from a `GROUP BY` on the withdrawal month.

## Permanent deletion and personal data

- **Permanently delete with a batch once the retention period has passed.** Run it daily.

  ```sql
  DELETE FROM members WHERE deleted_at IS NOT NULL AND deleted_at < :now - INTERVAL '1 year';   -- PG
  DELETE FROM members WHERE deleted_at IS NOT NULL AND deleted_at < DATE_SUB(NOW(), INTERVAL 1 YEAR);  -- MySQL
  ```

- **A request for complete deletion of personal data may not be satisfied by Soft Delete.** Handle it in this order:
  1. **Anonymize** the data that references it (orders and so on). For example `member_id = NULL`, or a pseudonymous ID.
  2. **Hard delete** the subject row.
  For transaction records you must retain, strip only the identifying information and keep the rest.
- Risks of the FK options when you Hard Delete:
  - `ON DELETE CASCADE` makes a large amount of related data vanish from a single mistake.
  - `ON DELETE SET NULL` loses "who placed the order".
  Choose either on purpose; never use them as a default.
- If child rows must be deleted along with a Soft-Deleted parent, do it in **the same transaction**.

## Relationship with the history table — a complement, not a substitute

The history table is covered in [`change-history.md`](./change-history.md).

- Logical deletion keeps the fact that something was removed; a history table keeps what changed and how. Put a history table **only on tables that truly need it** (→ `change-history.md`).
- A referenced parent cannot be physically deleted — delete it logically or move it to the void state.

## Anti-patterns

1. Using `is_deleted BOOLEAN`. You lose the deletion time, which blocks forensics, retention management, and recovery-history tracing.
2. Physically deleting a table that is not exempt. Removing wrongly entered data then erases both the data and why it was removed.
3. Mixing strategies within one table. For example `status = 'CANCELLED'` with `deleted_at` also filled — two columns saying different things about the same fact.
4. Putting `deleted_at` on a core domain (orders · payments · settlements). Consider Status first.
5. Applying `deleted_at IS NULL` to only one side of a join.
6. Putting `deleted_at` as the leading column of an index.
7. On PG, scanning everything with no partial index. On MySQL, trying to keep active rows unique with `UNIQUE (business_key, deleted_at)` (NULLs allow duplicates).
8. Not considering re-signup after withdrawal, so a UNIQUE collision occurs.
9. Not reflecting the Soft Delete condition in the RLS policy (deleted data exposed).
10. Handling a personal-data deletion request with Soft Delete and stopping there.
11. No retention cleanup batch. Soft-Deleted rows pile up indefinitely.
12. Putting `ON DELETE CASCADE` on a referenced parent as the default.
13. An operational correction (fixing a bad entry · voiding · deleting) that leaves no history or audit log. This includes a direct UPDATE/DELETE in the console.
14. Putting `deleted_at` on an exempt table (ledger · expiring data · derived cache). A ledger is fixed with correcting entries; the rest are cleaned up by expiry or recomputation.
