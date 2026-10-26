---
paths:
  - "supabase/**"
  - "**/migrations/**"
  - "db/**"
  - "prisma/**"
  - "drizzle/**"
  - "dev/docs/database/**"
  - "**/db/**"
  - "**/migration/**"
  - "alembic/**"
  - "**/*.sql"
---
<!-- orangekit-rule-version: 3.38.0 -->

# Data Modeling Card

> Based on Kim Young-han's modern data modeling philosophy. Apply it when designing a new table·migration·schema change.
> If the project has a canonical schema document (`dev/docs/database/`), stay consistent with it.
>
> **Scope**: the principles are common to relational DBs, and the syntax is given for both PostgreSQL (Supabase included) and MySQL 8 (§5 and the dialect tables in the pattern files).
> On any other RDB take the principles only and substitute that DB's syntax. In a NoSQL project this card's paths barely match, so it stays dormant.

**Three core principles**: surrogate keys first · 3NF by default · non-identifying relationships by default

## Default columns for every new table — apply these first, every time you create a table

The columns below are **mandatory — there is no exit by writing a reason and leaving one out.** To trace why production data changed,
who created and who changed it has to exist first, and the history (`_history` · `audit_log`) inherits these values.
The only thing that may be absent is `updated_*` on the append-only tables below.

| Column | PostgreSQL | MySQL 8 | Applies to |
| --- | --- | --- | --- |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | `DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP` | every table |
| `updated_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` **+ an update trigger** (or the app sets it every time) — `DEFAULT` alone does not change on UPDATE | `DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP` | tables that can be modified |
| `created_by` · `updated_by` | actor ID, NOT NULL — fill **both** on INSERT (creation = the first modification) | same | **every table** (append-only tables carry `created_by` only, → `change-history.md` Level 1) |

Append-only tables (ledger entries · events · idempotency keys · audit logs) carry `created_at` · `created_by` only and are never modified or deleted.

**Include them even when the actor is simple** — "the actor is only the owning user" or "only the admin token" is not a reason to omit them;
it is the case where **that user's or admin's ID goes in**. Batches · webhooks · system jobs use a fixed system actor ID (for example a seeded `system` user).

**Decide three things per table** and write them in the migration comment (or the table definition document) — these are per-table decisions, not a blanket default:

1. **Deletion strategy** — Status · Soft (`deleted_at`·`deleted_by`) · Hard. Core-domain tables (orders · payments · settlements) are managed by status rather than deleted,
   and Soft Delete is not bolted onto every table mechanically (→ `deletion-strategy.md`)
2. **History level** — a dedicated `_history` table (full-row snapshot, starting from the row's creation) · the shared `audit_log` · none (→ `change-history.md`)
3. **Code-column approach** — app ENUM + `CHECK` · a common-code table · hybrid (→ `common-code.md`)

**Operational corrections must be traceable under any strategy** — fixing, voiding, or deleting wrongly entered data leaves who · when · why · before/after values
in the history (`change_type = 'CORRECTION'`/`'DELETE'`) or `audit_log`, **in the same transaction**. Do not keep a correction path that leaves no record (editing directly in a console).

---

## 1. Requirements Analysis — extracting entities

**Extraction rule**: in the business description, **nouns → entity candidates**, **verbs → relationship/action entity candidates**.

**Six entity validity criteria** (an entity only when all are met): ① the business needs it ② a unique identifier exists ③ 2+ instances ④ 2+ attributes ⑤ used in a business process ⑥ has a relationship with another entity

**Entity classification**: fundamental (exists on its own: customer, product) → central (derived from relationships: order, contract) → action (records an event: order line, payment history)

**Design patterns**: master-transaction separation (users vs transactions) · separating code values (store the code value, not a display string — ENUM + `CHECK` when logic uses it, a common-code group/detail table when it is display only, hybrid when both → details in `common-code.md`) · history management (a separate `_history` table → details in `change-history.md`)

---

## 2. Conceptual Modeling — ERD design

**Choosing the primary identifier**: ① used often by the business ② exclude names (labels·descriptions) ③ minimize composites (prefer a single column) ④ immutable ⑤ NOT NULL ⑥ unique

**Cardinality**: 1:1 (merge by default, split only for security/optional relationships) · 1:N (most common, the FK goes on the N side) · N:M (**always decompose into a junction table**, give it a surrogate key)

**Participation**: mandatory (NOT NULL FK) vs optional (NULLABLE FK). ERD notation: **IE (Crow's Foot)** by default.

**Glossary**: when designing a new domain, define it in `dev/docs/database/` — standard term name, English physical name, definition, domain (type), allowed values

---

## 3. Logical Modeling — keys and relationships

### Key strategy

**Default: a surrogate key (BIGINT)**. Manage natural keys with a UNIQUE constraint only. "Use a surrogate key unrelated to the business" — Kim Young-han (case: a national ID number as PK → a change in privacy law made collecting it impossible)

| Situation    | Type                                  | Note                          |
| ------------ | ------------------------------------- | ----------------------------- |
| Ordinary PK  | `BIGINT GENERATED ALWAYS AS IDENTITY` (MySQL: `BIGINT AUTO_INCREMENT`) | 8B, sequential insert, best for joins |
| URL/API exposed | `UUID DEFAULT gen_random_uuid()` (MySQL: `BINARY(16)` + `UUID_TO_BIN(UUID(), 1)`) | blocks enumeration attacks. 16B, random insert |
| Distributed system | UUID v7 / ULID                  | time-ordered, nearly sequential insert |

### Relationship rules

- **FK placement**: always on the **Many (N) side**. For 1:1, place it on the primary table (the side queried more often)
- **N:M**: a junction table + a surrogate PK. No direct N:M mapping (it cannot grow extra attributes)
- **Composite keys**: 3+ columns → switch to a surrogate key
- **Identifying vs non-identifying**: **non-identifying by default**. Identifying only for a pure junction table or full lifecycle dependency

---

## 4. Normalization

**3NF by default, BCNF applied selectively**.

| Normal form | Core rule                                 | Problem when violated    |
| ------ | ------------------------------------------ | ------------------------ |
| 1NF    | every column atomic (remove repeating groups·multi-values) | cannot search/update |
| 2NF    | remove partial functional dependency (depends on only part of a composite PK) | update anomaly |
| 3NF    | remove transitive functional dependency (A→C within A→B→C) | insert/delete anomaly |
| BCNF   | **every determinant must be a candidate key** | update anomaly (stricter than 3NF) |

**Deciding BCNF**: check that the left side (determinant) of every FD is a candidate key. If not, decompose.

**When not to normalize**:

- History/snapshot tables: data frozen at a point in time (the product name then, the price then)
- Log/event tables: write optimization first (e.g. `events.data` JSONB)
- Read-heavy aggregation: OLAP, summary tables for dashboards

**Common mistakes**: bypassing 1NF with JSON (dumping structured data into JSON → `json-columns.md`), abusing the EAV pattern (→ details in `eav-vs-jsonb.md`), over-normalizing (splitting a code table ten levels deep).

---

## 5. Physical Modeling — data types

| Category       | Rule                | PostgreSQL                                      | MySQL 8 |
| -------------- | ------------------- | ----------------------------------------------- | ------- |
| PK             | surrogate key       | `BIGINT GENERATED ALWAYS AS IDENTITY`           | `BIGINT AUTO_INCREMENT` |
| Public ID      | UUID                | `UUID DEFAULT gen_random_uuid()`                | `BINARY(16)` (`UUID_TO_BIN(UUID(), 1)` — time-ordered) |
| Money          | **never FLOAT**     | `NUMERIC(12,0)` (KRW) / `NUMERIC(15,2)` (foreign currency) | `DECIMAL(12,0)` / `DECIMAL(15,2)` |
| String (bounded) | length from a business rule | `VARCHAR(n)` (email 320, nickname 30, etc.) | `VARCHAR(n)` — character set `utf8mb4` |
| String (unbounded) | length undetermined | `TEXT`                                      | `TEXT` (`VARCHAR(n)` if it is searched or indexed) |
| Time           | **the instant must be unambiguous** | `TIMESTAMPTZ DEFAULT now()`  | `DATETIME` + **a store-in-UTC convention** (pin the session `time_zone`). `TIMESTAMP` is discouraged because of the year-2038 limit. If you need fractional seconds use `DATETIME(3)` — `DATETIME` **rounds** fractional seconds |
| Date only      | no time needed      | `DATE` (date of birth, expiry date)             | `DATE` |
| Status/type    | enumerated value    | `TEXT`/`VARCHAR(n)` + a `CHECK` constraint      | `VARCHAR(n)` + `CHECK` (enforced from 8.0.16). Do not use the DB `ENUM` type — every new value needs an ALTER |
| Fluid schema   | JSON                | `JSONB` + a CHECK constraint or app-side Zod validation | `JSON` + CHECK (→ `json-columns.md`) |
| Boolean        | only when truly binary | `BOOLEAN` (any chance of 3+ states → a TEXT enum) | `BOOLEAN` (= `TINYINT(1)`) |
| Quantity/count | integer             | `INTEGER` (at large scale: `BIGINT`)            | `INT` (at large scale: `BIGINT`) |

---

## 6. Naming Conventions

Stay consistent with the existing schema:

| Target              | Rule                                    | Example                                           |
| ------------------- | --------------------------------------- | ------------------------------------------------- |
| Table               | snake_case, **plural**                  | `orders`, `point_events`                          |
| Column              | snake_case                              | `product_name`, `unit_price`                      |
| PK                  | `{table_singular}_id`                   | `user_id`, `order_id`                             |
| FK                  | `{referenced_table_singular}_id`        | `host_id`, `order_id`                             |
| Boolean             | `is_` / `has_`                          | `is_public`, `has_receipt`                        |
| Timestamp           | `_at` suffix                            | `created_at`, `cancelled_at`                      |
| Index/unique/CHECK  | `idx_`/`uq_`/`chk_` + `{table}_{column}` | `idx_orders_status`, `chk_orders_total_positive`  |

---

## 7. Denormalization

**Precondition**: only after the normalized design is finished and **a performance problem is proven with EXPLAIN ANALYZE**.

| Pattern           | When to apply       | Required condition                         |
| ----------------- | ------------------- | ------------------------------------------ |
| Merging tables (1:1) | always queried together | no separate permission management needed |
| Duplicating a column | a join must be removed | document the sync strategy (trigger/app logic) |
| Derived column    | frequent aggregate queries | refreshed automatically by a DB trigger |
| Summary table     | a bulk aggregate scanned every time | a Materialized View or a periodic refresh (→ `statistics.md`) |

**Mandatory**: when denormalizing, record the reason·sync mechanism·consistency risk in the table definition document.

---

## 8. Migration & RLS Checklist

Mandatory checks when creating a new table:

- [ ] `CREATE TABLE` + inline constraints (PK, FK, CHECK, NOT NULL, DEFAULT)
- [ ] `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + at least one policy (only on stacks that use row level security — policy details live in that stack's backend-guide auth/permission boundary resource (if the detailed guide is installed). On a stack without RLS, the application-layer ownership check is the only boundary)
- [ ] Create an index on FK columns (`idx_{table}_{fk_column}`) — PG does not create one automatically; MySQL InnoDB does create an index on every FK
- [ ] Add an index on frequently used WHERE/ORDER BY columns
- [ ] An index strategy when you search inside a JSON column — PG GIN / expression index; MySQL generated-column / functional / multi-valued index (→ `json-columns.md`)
- [ ] TypeScript type definitions → the project's type directory (in a monorepo, the shared package's `types/`) + update the barrel export
- [ ] Table definition document → `dev/docs/database/` (optional, from medium scale up)
- [ ] The "Default columns for every new table" section above — the default columns are on every table (only append-only tables lack `updated_*`), and the three per-table decisions (deletion strategy · history level · code-column approach) are written in the migration comment
- [ ] Soft Delete tables: the active-row index and UNIQUE in the dialect's form (PG partial index / MySQL `(business_key, deleted_at)` + change the value on withdrawal) + the RLS condition updated (→ `deletion-strategy.md`)
- [ ] Tables that require business history → create the `_{table}_history` history table at the same time (→ `change-history.md`)
- [ ] When idempotency is needed: an `idempotency_key` UNIQUE column + TTL cleanup (→ `idempotency.md`)
- [ ] Personal or sensitive columns: a retention period and what enforces it (job · TTL) + a per-subject erasure path (anonymize the references then hard delete the subject, or an intended subject FK `ON DELETE CASCADE`). If undecided, record the reason for indefinite retention in the table definition (→ `deletion-strategy.md`)

---

## Pattern References — read only what you need

This card carries only **what you always need when building a schema** (§1~8). The eleven patterns below are
needed **only when you actually design that pattern**, so they were moved down to `.claude/references/data-modeling/`.
Read **only the one** file on the matching row — reading them all makes the split meaningless.

| What you are designing now | File to read |
| --- | --- |
| A column with a **fixed set of values**, like status·category·type (ENUM+CHECK · common-code · hybrid) | [`common-code.md`](../references/data-modeling/common-code.md) — designing common codes |
| A **self-referencing hierarchy**, like a category tree·org chart | [`hierarchy.md`](../references/data-modeling/hierarchy.md) — designing a hierarchy |
| You **must keep a history** of who changed what and when | [`change-history.md`](../references/data-modeling/change-history.md) — designing data change history |
| You only need to hold the single previous value in a column | [`scd-type3.md`](../references/data-modeling/scd-type3.md) — keeping the previous value in a column — SCD Type 3 |
| Deciding a table's **deletion strategy** (status value · Soft · Hard), or implementing Soft Delete or operational corrections | [`deletion-strategy.md`](../references/data-modeling/deletion-strategy.md) — data deletion strategy — Status vs Soft Delete vs Hard Delete |
| A **statistics table** for aggregation·dashboards | [`statistics.md`](../references/data-modeling/statistics.md) — designing a statistics table |
| It must stay safe **when the same request arrives twice**, as with payments·webhooks | [`idempotency.md`](../references/data-modeling/idempotency.md) — designing idempotency |
| The attributes vary, so the columns cannot be fixed (regular columns vs JSON vs EAV) | [`eav-vs-jsonb.md`](../references/data-modeling/eav-vs-jsonb.md) — designing dynamic attributes |
| Creating a **JSON column**, or searching or validating inside one | [`json-columns.md`](../references/data-modeling/json-columns.md) — designing JSON columns |
| An **inheritance relationship** built from common attributes + per-type attributes | [`supertype-subtype.md`](../references/data-modeling/supertype-subtype.md) — designing supertype/subtype (inheritance) |
| A **DB function** that runs with elevated privileges | [`security-definer.md`](../references/data-modeling/security-definer.md) — conventions for writing SECURITY DEFINER functions |
