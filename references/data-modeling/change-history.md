<!-- orangekit-rule-version: 3.41.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Data change-history design

> Scope: the principles are common to relational DBs, and the syntax is given for both PostgreSQL and MySQL 8.
> **The core principle is "disk capacity < development productivity + operational stability".** A simple full-row snapshot beats a complex per-column log.

## Decision criteria

### Change-tracking columns — levels

| Level | Columns | Applies to |
| --- | --- | --- |
| **Level 1** (basic) | `created_at`, `created_by`, `updated_at`, `updated_by` — all NOT NULL | **every table** (the card's "Default columns for every new table"). Only an append-only table that must never change carries just `created_*` — there is no other omission |
| **Level 2** (change reason) | `change_type` (a classification code for the system), `change_reason` (a description for people) | business-critical tables such as price, status, tier |
| **Level 3** (audit) | `source_system`, `client_ip` | tables under regulatory or security requirements, or changed by several systems |
| **Level 4** (distributed tracing) | `request_id` | microservices — trace the whole flow of one request |

- Fill `updated_at` and `updated_by` **on INSERT too.** Treat creation as the first modification.
  Leaving them NULL forces a `COALESCE(updated_at, created_at)` into every query.
- Use `change_type` with a fixed value set. For example: `CREATE`, `PRICE_CHANGE`, `STATUS_CHANGE`, `STOCK_ADJUST`, `INFO_UPDATE`, `CORRECTION`, `DELETE`.
  The owning department manages the value set. Aggregate by code instead of searching free text like `change_reason LIKE '%discount%'`.
- Example `source_system` values: `WEB_ADMIN`, `WEB_USER`, `MOBILE_APP`, `API`, `BATCH`, `MIGRATION`, `MANUAL`.
- These columns alone cannot tell you **the previous value, or the value at a given point in time.** Preserving the past needs the history strategy below.

### History strategy — choose by table importance

| Importance | Examples | Approach |
| --- | --- | --- |
| Critical | price, orders, balance/quantity, contracts/terms, permissions, settings | **a dedicated `_history` table (full-row snapshot) — the default strategy** |
| Important | member information | dedicated, or the shared `audit_log` |
| Ordinary | configuration-type data, logs | the shared `audit_log`, or a log file |
| Low | temporary data | no history |

- If any of these is "yes", consider a dedicated history table: is it a business-critical change · are past values read · are point-in-time reads needed · is there an audit requirement.
- Things that **do not need** a dedicated history: logs, temporary data, code tables that almost never change, and large content such as a body text.
- **Put a history table only on tables that truly need it.** If none of the questions above is "yes", do not create one — a `_history` on every table only adds write cost and things to manage.
  Logical deletion (`deleted_at` · `voided_at`) already keeps the trace of a removal, so do not create a history table just for deletion (→ [`deletion-strategy.md`](./deletion-strategy.md)).
- **Ledger-like data** such as amounts and points is managed as an event ledger whose rows are never updated (current value = `SUM(delta)`).
  Never UPDATE or DELETE a ledger row.
- For a linear state where only the single previous value is needed, use [`scd-type3.md`](./scd-type3.md).

## Standard design — full-row snapshot `_history`

**Separate** the current table from the history table. 99% of ordinary reads read current data.
Mixing history into the current table slows those 99% of reads.

```sql
-- PostgreSQL
CREATE TABLE product_history (
  history_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id         BIGINT       NOT NULL,
  name               VARCHAR(200) NOT NULL,          -- ↓ a copy of every business column of the source
  price              NUMERIC(12,0) NOT NULL,
  stock_quantity     INTEGER      NOT NULL,
  status             VARCHAR(20)  NOT NULL,
  created_at         TIMESTAMPTZ  NOT NULL,          -- the source's creation time (immutable per product)
  created_by         VARCHAR(100) NOT NULL,
  history_created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),  -- when this snapshot was recorded
  history_created_by VARCHAR(100) NOT NULL,
  change_type        VARCHAR(50)  NOT NULL,          -- CREATE, PRICE_CHANGE, … DELETE
  change_reason      VARCHAR(500)
);
CREATE INDEX idx_product_history_product_id ON product_history (product_id);
CREATE INDEX idx_product_history_history_created_at ON product_history (history_created_at);
```

```sql
-- MySQL 8
CREATE TABLE product_history (
  history_id         BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  product_id         BIGINT       NOT NULL,
  name               VARCHAR(200) NOT NULL,
  price              DECIMAL(12,0) NOT NULL,
  stock_quantity     INT          NOT NULL,
  status             VARCHAR(20)  NOT NULL,
  created_at         DATETIME     NOT NULL,
  created_by         VARCHAR(100) NOT NULL,
  history_created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  history_created_by VARCHAR(100) NOT NULL,
  change_type        VARCHAR(50)  NOT NULL,
  change_reason      VARCHAR(500),
  INDEX idx_product_history_product_id (product_id),
  INDEX idx_product_history_history_created_at (history_created_at)
);
```

- **There are two time columns.** `created_at` is when the data first came into being, copied unchanged from the source.
  `history_created_at` is when this snapshot was recorded, and it is what orders the timeline.
- A history row stores the **state after the change**. So one row means "from this moment, this state".
- Do not put an FK to the source. The history must survive after the source row is hard deleted.

### Validity period — only when point-in-time reads are frequent

With `valid_from` and `valid_to`, a point-in-time read such as "total stock as of March 10" ends with one plain WHERE.

```sql
valid_from DATETIME NOT NULL,                                  -- PG: TIMESTAMPTZ
valid_to   DATETIME NOT NULL DEFAULT '9999-12-31 23:59:59',    -- the current row = a far-future sentinel
-- indexes: (product_id, valid_from, valid_to), (valid_from, valid_to)

-- point-in-time read: the half-open interval [valid_from, valid_to)
WHERE :t >= valid_from AND :t < valid_to
```

- The sentinel is `'9999-12-31 23:59:59'`, NOT NULL, rather than NULL. A single comparison catches the current row too.
- If you separated the current table from the history table, **you do not need `is_current`.** The current value lives in the source table.
- Deciding whether to add a validity period:

  | Situation | Validity period |
  | --- | --- |
  | Master data (products · member tiers · categories · departments) | **recommended** |
  | Transaction and log data (orders · payments · point records · access records) | **not recommended**. Append-only INSERT is the right fit |
  | Point-in-time reads or point-in-time statistics batches are frequent | add it |
  | **History rows must be immutable** (audit) | **do not add it**, because the previous row's `valid_to` would have to be UPDATEd |

- Without a validity period, a point-in-time read is `MAX(history_id) … WHERE history_created_at <= :t GROUP BY product_id`. Slower, but possible.

### Compromise for large columns

If a large field such as `description` bloats the history, leave that column out of the snapshot or split it into a separate table.
Do not switch to a per-column log.

## Write procedure — the data change and the history record share one transaction

The data change and the history write **must succeed together or fail together.** The default is for the app to write them directly inside a transaction.
A trigger has a hard time knowing who changed it and why (`history_created_by`, `change_reason`).

```sql
-- create (MySQL): source INSERT → a CREATE row in history (stored from the very first data)
START TRANSACTION;
INSERT INTO product (name, price, stock_quantity, status, created_by, updated_by) VALUES (...);
INSERT INTO product_history (product_id, name, price, stock_quantity, status,
       created_at, created_by, history_created_by, change_type, change_reason)
SELECT product_id, name, price, stock_quantity, status,
       created_at, created_by, :actor, 'CREATE', 'New registration'
FROM product WHERE product_id = LAST_INSERT_ID();
COMMIT;

-- create (PostgreSQL): feed the RETURNING result straight into history.
-- Re-SELECTing the source inside a CTE of the same statement cannot see the row just inserted, giving 0 rows.
BEGIN;
WITH n AS (
  INSERT INTO product (name, price, stock_quantity, status, created_by, updated_by) VALUES (...)
  RETURNING product_id, name, price, stock_quantity, status, created_at, created_by
)
INSERT INTO product_history (product_id, name, price, stock_quantity, status,
       created_at, created_by, history_created_by, change_type, change_reason)
SELECT product_id, name, price, stock_quantity, status, created_at, created_by, :actor, 'CREATE', 'New registration'
FROM n;
COMMIT;

-- change (with a validity period): close the previous row → INSERT the new state → UPDATE the source
BEGIN;
UPDATE product_history SET valid_to = :now
 WHERE product_id = :id AND valid_to = '9999-12-31 23:59:59';
INSERT INTO product_history (..., valid_from, change_type, change_reason) VALUES (..., :now, 'PRICE_CHANGE', :reason);
UPDATE product SET price = :price, updated_by = :actor WHERE product_id = :id;
COMMIT;
```

- The previous row's `valid_to` and the new row's `valid_from` must be **the same instant**. Only then is the interval free of gaps and overlaps.
- When you hard delete from a table nobody references, write the `change_type = 'DELETE'` history row first, in the same transaction
  (→ [`deletion-strategy.md`](./deletion-strategy.md)).
- **Operational corrections take the same path.** When you fix wrongly entered data, record `change_type = 'CORRECTION'` and the reason.
  A table with no dedicated history is covered by `audit_log`. Keep no path that fixes things directly in the console without a record.

## The shared history table `audit_log` — supplementary

It handles system-wide change tracking, incident root-cause tracing, and acts as a backup store. **It does not replace a dedicated history.**

```sql
CREATE TABLE audit_log (
  audit_id      BIGINT       NOT NULL,  -- PG: GENERATED ALWAYS AS IDENTITY · MySQL: AUTO_INCREMENT
  table_name    VARCHAR(100) NOT NULL,
  record_id     VARCHAR(100) NOT NULL,  -- a string so it can hold composite and non-numeric keys
  action        VARCHAR(20)  NOT NULL,  -- INSERT | UPDATE | DELETE
  old_data      JSON,                   -- PG: JSONB · NULL on INSERT
  new_data      JSON,                   -- PG: JSONB · the whole row after the change
  changed_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,   -- PG: TIMESTAMPTZ DEFAULT now()
  changed_by    VARCHAR(100) NOT NULL,
  source_system VARCHAR(50),
  client_ip     VARCHAR(50),            -- PG: INET works
  request_id    VARCHAR(100),
  PRIMARY KEY (audit_id)
);
-- indexes: (table_name, record_id), (changed_at), (changed_by)
```

- To see the history of one field you must parse the JSON, point-in-time restoration is hard, and the data piles up very fast.
  **For business-critical data, always keep a separate dedicated history table.**
- **Archiving is mandatory.** Move rows older than 3–6 months to files or an archive DB and delete them from the operational DB (easy with monthly partitioning).
  Left to pile up, it will eventually blow the DB up.
- If you fill it from a PG trigger, use `to_jsonb(OLD)`/`to_jsonb(NEW)` and pass the actor through a session variable (`set_config`).

## Business history vs system logs

Keep only **business history** in the DB: price changes, status changes, audit records. System logs such as HTTP requests, debug information, and access records
go to a file-based log pipeline (e.g. ELK). A database is not a trash can.
For an admin app with very little traffic, keeping DB logs for convenience is acceptable.

**Excluded from tracking**: session and token tables, cache and temporary tables, high-volume log tables, and `audit_log` itself.

## Anti-patterns

1. Bolting previous-value columns onto a business table to stand in for history. Only the single previous value survives, and every tracked column adds three columns (→ the Limit in `scd-type3.md`).
2. Stacking `is_current` rows in the current table to manage history. Point-in-time reads and statistics queries get complicated, and the current reads that make up 99% scan a bloated table.
3. **Not writing the creation (CREATE) row to the history table.** If only pre-change values are stored, reading the full history means a UNION with the source (UNION hell),
   and nothing can be restored once the source is deleted.
4. Making the data change and the history write in different transactions. A failure in between leaves the history out of step.
5. Using a per-column change log (`column_name`, `old_value`, `new_value` strings) as the main history strategy.
   Point-in-time restoration needs a query per column and the type information is lost. Allowed only as an audit display for specific fields.
6. Using the shared `audit_log` as the only history mechanism, or applying it to every table.
7. Letting `audit_log` pile up with no archiving.
8. Adding a validity period to a high-volume transaction or log table. Every change pays for an UPDATE.
9. Reading a validity interval as a closed interval (`BETWEEN`), or recording the previous row's `valid_to` and the new row's `valid_from` at different instants.
   At the boundary instant, two rows match or none does.
10. UPDATEing or DELETEing rows of an event ledger. A ledger must be immutable.
11. Piling system logs (HTTP requests, debug information) into the business DB.
12. Leaving `updated_at` and `updated_by` NULL on INSERT.
13. Dropping `created_by` · `updated_by` because "the actor is only the owning user" or "only the admin token". Put that ID in —
    a system job uses a fixed system actor ID. If it is missing, the "who" of an operational correction is not recorded.
14. Creating a `_history` for every table without deciding whether it is needed. Only tables that need past values, point-in-time reads or audit get one.
