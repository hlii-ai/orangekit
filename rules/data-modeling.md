---
paths:
  - "supabase/**"
  - "**/migrations/**"
  - "db/**"
  - "prisma/**"
  - "drizzle/**"
  - "dev/docs/database/**"
---
<!-- orangekit-rule-version: 3.25.0 -->

# Data Modeling Card

> Based on Kim Young-han's modern data modeling philosophy. Apply it when designing a new table·migration·schema change.
> If the project has a canonical schema document (`dev/docs/database/`), stay consistent with it.
>
> **Scope**: §1~4·6~8 are common to relational DBs, §5 is specific to PostgreSQL (Supabase included) —
> on another RDB take the principles only and substitute that DB's syntax. Each file under "Pattern References" below
> also states its scope at the top. In a NoSQL project this card's paths barely match, so it stays dormant.

**Three core principles**: surrogate keys first · 3NF by default · non-identifying relationships by default

---

## 1. Requirements Analysis — extracting entities

**Extraction rule**: in the business description, **nouns → entity candidates**, **verbs → relationship/action entity candidates**.

**Six entity validity criteria** (an entity only when all are met): ① the business needs it ② a unique identifier exists ③ 2+ instances ④ 2+ attributes ⑤ used in a business process ⑥ has a relationship with another entity

**Entity classification**: fundamental (exists on its own: customer, product) → central (derived from relationships: order, contract) → action (records an event: order line, payment history)

**Design patterns**: master-transaction separation (users vs transactions) · extracting code tables (TEXT+CHECK or a reference table → details in `common-code.md`) · history management (a separate `_history` table → details in `change-history.md`)

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
| Ordinary PK  | `BIGINT GENERATED ALWAYS AS IDENTITY` | 8B, sequential insert, best for joins |
| URL/API exposed | `UUID DEFAULT gen_random_uuid()`   | blocks enumeration attacks. 16B, random insert |
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

**Common mistakes**: bypassing 1NF with JSONB (dumping structured data into JSON), abusing the EAV pattern (→ details in `eav-vs-jsonb.md`), over-normalizing (splitting a code table ten levels deep).

---

## 5. Physical Modeling — data types

On PostgreSQL/Supabase:

| Category       | Rule                | Type                                            |
| -------------- | ------------------- | ----------------------------------------------- |
| PK             | surrogate key       | `BIGINT GENERATED ALWAYS AS IDENTITY`           |
| Public ID      | UUID                | `UUID DEFAULT gen_random_uuid()`                |
| Money          | **never FLOAT**     | `NUMERIC(12,0)` (KRW) / `NUMERIC(15,2)` (foreign currency) |
| String (bounded) | length from a business rule | `VARCHAR(n)` (email 320, nickname 30, etc.) |
| String (unbounded) | length undetermined | `TEXT`                                      |
| Time           | **always time zone aware** | `TIMESTAMPTZ DEFAULT now()`              |
| Date only      | no time needed      | `DATE` (date of birth, expiry date)             |
| Status/type    | enumerated value    | `TEXT` + a `CHECK` constraint                   |
| Fluid schema   | JSONB               | `JSONB` + a CHECK constraint or app-side Zod validation |
| Boolean        | only when truly binary | `BOOLEAN` (any chance of 3+ states → a TEXT enum) |
| Quantity/count | integer             | `INTEGER` (at large scale: `BIGINT`)            |

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
- [ ] `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + at least one policy (only on stacks that use row level security — policy details live in that stack's backend-guide auth/permission boundary resource. On a stack without RLS, the application-layer ownership check is the only boundary)
- [ ] Create an index on FK columns (`idx_{table}_{fk_column}`)
- [ ] Add an index on frequently used WHERE/ORDER BY columns
- [ ] A GIN index on JSONB columns (when searching inside them is needed)
- [ ] TypeScript type definitions → the project's type directory (in a monorepo, the shared package's `types/`) + update the barrel export
- [ ] Table definition document → `dev/docs/database/` (optional, from medium scale up)
- [ ] `created_at TIMESTAMPTZ DEFAULT now()` + `updated_at TIMESTAMPTZ DEFAULT now()` common columns
- [ ] `created_by UUID` + `updated_by UUID` common columns (applied by default to nearly every table → `change-history.md` Level 1)
- [ ] Tables that require business history → create the `_{table}_history` history table at the same time (→ `change-history.md`)
- [ ] When applying Soft Delete: a `deleted_at` column + a partial index + the RLS condition updated (→ `deletion-strategy.md`)
- [ ] When idempotency is needed: an `idempotency_key` UNIQUE column + TTL cleanup (→ `idempotency.md`)

---

---

## Pattern References — read only what you need

This card carries only **what you always need when building a schema** (§1~8). The ten patterns below are
needed **only when you actually design that pattern**, so they were moved down to `.claude/references/data-modeling/`.
Read **only the one** file on the matching row — reading them all makes the split meaningless.

| What you are designing now | File to read |
| --- | --- |
| A column with a **fixed set of values**, like status·category·type | [`common-code.md`](../references/data-modeling/common-code.md) — designing a common-code table |
| A **self-referencing hierarchy**, like a category tree·org chart | [`hierarchy.md`](../references/data-modeling/hierarchy.md) — designing a hierarchy |
| You **must keep a history** of who changed what and when | [`change-history.md`](../references/data-modeling/change-history.md) — designing data change history |
| You only need to hold the single previous value in a column | [`scd-type3.md`](../references/data-modeling/scd-type3.md) — keeping the previous value in a column — SCD Type 3 |
| Deciding how deletion works (status value · Soft · Hard) | [`deletion-strategy.md`](../references/data-modeling/deletion-strategy.md) — data deletion strategy — Status vs Soft Delete vs Hard Delete |
| A **statistics table** for aggregation·dashboards | [`statistics.md`](../references/data-modeling/statistics.md) — designing a statistics table |
| It must stay safe **when the same request arrives twice**, as with payments·webhooks | [`idempotency.md`](../references/data-modeling/idempotency.md) — designing idempotency |
| The attributes vary, so the columns cannot be fixed | [`eav-vs-jsonb.md`](../references/data-modeling/eav-vs-jsonb.md) — EAV vs JSONB design |
| An **inheritance relationship** built from common attributes + per-type attributes | [`supertype-subtype.md`](../references/data-modeling/supertype-subtype.md) — designing supertype/subtype (inheritance) |
| A **DB function** that runs with elevated privileges | [`security-definer.md`](../references/data-modeling/security-definer.md) — conventions for writing SECURITY DEFINER functions |
