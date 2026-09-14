<!-- orangekit-rule-version: 3.25.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Data deletion strategy — Status vs Soft Delete vs Hard Delete

> **"Deletion is a policy, not a technique."** Core domains (orders · payments · settlement) are usually managed by **status**, not deletion.

| strategy                         | when to apply                                 | examples                                                  |
| -------------------------------- | --------------------------------------------- | --------------------------------------------------------- |
| **status-based** (no concept of deletion) | a complex business lifecycle · multi-stage state transitions | products (on sale/out of stock/discontinued), orders (awaiting payment/complete/cancelled/refunded) |
| **Soft Delete** (`deleted_at`)   | simple existence · recoverability · keeping FK references | comments, posts, likes, member withdrawal            |
| **Hard Delete**                  | no retention value · GDPR deletion duty · temporary data | carts, logs, sessions, test data                       |

**Soft Delete basics**: `deleted_at TIMESTAMPTZ` (NULL = active). `is_deleted BOOLEAN` is forbidden (it loses the deletion time).

**Mandatory implementation** (when adopting Soft Delete):

- Partial index: `CREATE INDEX idx_{table}_active ON {table}(...) WHERE deleted_at IS NULL`
- UNIQUE constraint: `CREATE UNIQUE INDEX uq_{table}_{column} ON {table}({column}) WHERE deleted_at IS NULL` (unique among active rows only)
- RLS policy: add `AND deleted_at IS NULL` to the `USING` clause of every SELECT/UPDATE policy (only on stacks that use row-level security — details live in that stack's backend-guide auth/authorization boundary resource)
- Read layer: do not repeat the soft-delete filter (`deleted_at IS NULL`) in every query; enforce it through a DB view or a shared query helper

**Relationship with the history table** (→ [`change-history.md`](./change-history.md)): Soft Delete and the `_history` table are **complements, not substitutes**. A core table with FK references → Soft Delete + `_history` together (referential integrity kept + change history preserved). A table with no FK references → Hard Delete + `_history` is enough (keeps the main table light).

**Anti-patterns**: ①using `is_deleted BOOLEAN` (loses the deletion time, forensics impossible) ②a full table scan for lack of a partial index ③not reflecting soft delete in the RLS policy (exposing deleted data) ④mixing soft delete and hard delete (loss of consistency) ⑤applying `deleted_at` to a core domain (orders · products) — consider status-based management first
