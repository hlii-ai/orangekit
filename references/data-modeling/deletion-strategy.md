<!-- orangekit-rule-version: 3.38.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Data deletion strategy — Status vs Soft Delete vs Hard Delete

> Scope: the principles are common to relational DBs, and the syntax is given for both PostgreSQL and MySQL 8.
> **Deletion is a policy, not a technique.** Decide it **per table**, looking at recovery, legal retention, audit, analytics, and referential integrity.

## Decision criteria — pick one per table

| Strategy | When | Examples |
| --- | --- | --- |
| **Status-based** (no concept of deletion) | a complex lifecycle with multi-stage state transitions | products (on sale · out of stock · discontinued), orders (awaiting payment · complete · cancelled · refunded), shipments. Members too, if they have many states |
| **Soft Delete** (`deleted_at`) | only existence matters, and you want to keep recovery open | member withdrawal, posts, comments, reviews, likes |
| **Hard Delete** | no value in keeping it | carts, notifications, API logs, temporary data |

Signals that point to Soft Delete:
- Recovery requests are frequent.
- There is a legal retention duty (e.g. e-commerce transaction records for 5 years).
- It is a core entity that many tables reference.
- You must audit who deleted it and when.

- **Core domains (orders · payments · settlements) are usually managed by status, not deletion.** Order data is never deleted because of accounting and settlement.
  A Status table has no `deleted_at`. A single `status = 'CANCELLED'` explains every situation.
- **Do not apply Soft Delete to every table mechanically.** Soft Delete costs you in queries, indexes, human error, and storage.
  Missing a single filter exposes deleted data.
- Write the chosen strategy in the table definition document or the migration comment (the "three per-table decisions" in card §8).

## Operational corrections must be traceable under any strategy

In operation, wrongly entered data will certainly need correcting. Whichever strategy you chose,
a record must remain of **who, when, why, and what (before/after values)** changed. Handle the correction and its record in **one transaction**.

| Strategy | How to correct wrongly entered data | Traceability |
| --- | --- | --- |
| Status | Fix the value (UPDATE). If the business must void it entirely, transition to a void status value (e.g. `VOIDED`). Do not express it with `deleted_at` | the dedicated `_history` with `change_type = 'CORRECTION'` and a `change_reason` |
| Soft Delete | Fix the value, or fill in `deleted_at` · `deleted_by` | the same history row. For a table with no history, `audit_log`'s `old_data`/`new_data` |
| Hard Delete | DELETE | record the last state **before** deleting — in the history as `change_type = 'DELETE'`, or in `audit_log` |

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

- **Tables nobody references** (log-like settings and so on): use Hard Delete together with history. In one transaction, INSERT the `change_type = 'DELETE'` history row first, then DELETE the original.
  The main table stays light.
- **Core tables that are referenced** (members · products · orders): add history to Soft Delete or Status. A referenced parent cannot be Hard Deleted.

## Anti-patterns

1. Using `is_deleted BOOLEAN`. You lose the deletion time, which blocks forensics, retention management, and recovery-history tracing.
2. Applying Soft Delete to every table mechanically. The strategy must be decided per table.
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
