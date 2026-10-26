<!-- orangekit-rule-version: 3.38.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Keeping the previous value in a column — SCD Type 3

**Restricted use**: allowed only in a **linear state machine** where just one prior value is needed. Everything else → the `_history` table in [`change-history.md`](./change-history.md).

| conditions to apply                   | conditions not to apply         |
| ------------------------------------- | ------------------------------- |
| the state transitions linearly (A→B→C, no going back) | audit/regulatory requirements (full history needed) |
| the business needs only one prior value | multi-step undo/redo functionality |
| immediate comparison without a join is needed (performance first) | 3+ prior values may need tracking |
| low change frequency (1–2 times a day)  | high-frequency updates (prev\_ columns are waste) |

**Naming**: the `prev_{column_name}` prefix. Examples: `status` + `prev_status`, `tier` + `prev_tier`. When the change time must be tracked, optionally add a companion `{column}_changed_at TIMESTAMPTZ` column.

**Update logic**: `UPDATE SET prev_status = status, status = :new_status` — an atomic swap in a single statement. Do not read the old value in the app and then SET it (risk of a concurrency race).

**Limit**: only the single previous value survives, and every tracked column adds three columns (`prev_`, `_changed_at`, and the column itself) — once more than two columns are tracked, `_history` is cheaper.

**Anti-patterns**: ①the moment a `prev_prev_` column appears, switch to a `_history` table ②SELECT in the app → store in a variable → UPDATE (race condition) ③managing prev\_ columns by hand with no trigger (risk of omission)
