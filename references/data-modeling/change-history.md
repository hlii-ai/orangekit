<!-- orangekit-rule-version: 3.25.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Data change-history design

> **Core principle: "disk capacity < development productivity + operational stability"**. A simple full-row snapshot beats a complex per-column log.

### 11.1 Change-tracking column levels

Apply the appropriate level of tracking columns to every table.

| level                   | columns                                                | applies to                                 |
| ----------------------- | ------------------------------------------------------ | ------------------------------------------ |
| **Level 1** (basic)     | `created_at`, `created_by`, `updated_at`, `updated_by` | **almost every table** (card §8 checklist)      |
| **Level 2** (change reason) | `change_type TEXT`, `change_reason TEXT`           | business-critical tables (price · status · tier changes) |
| **Level 3** (audit)     | `source_system TEXT`, `client_ip INET`                 | regulatory/security mandated · tables changed by multiple systems |
| **Level 4** (distributed tracing) | `request_id UUID`                            | microservice environments (tracing the whole flow)       |

Example standard `change_type` values: `CREATE`, `PRICE_CHANGE`, `STATUS_CHANGE`, `STOCK_ADJUST`, `CORRECTION`. Example standard `source_system` values: `WEB_ADMIN`, `WEB_USER`, `API`, `BATCH`, `MOBILE_APP`.

### 11.2 Choosing a history strategy

| approach                                  | when to apply                                                          | when not to apply                                |
| ----------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------ |
| **full-row snapshot `_history` (default strategy)** | business history is required (status · tier · price changes — most cases) | high-frequency updates · log-like data      |
| event ledger (Event Sourcing)             | **ledger-like data** such as amounts and points (current value = SUM(delta), `point_events`) | simple CRUD, no history needed |
| Generic Audit (shared history table)      | compliance · **supplementary** full change tracking for debugging       | as the sole history strategy (run it alongside a dedicated `_history`) |
| SCD Type 1 (overwrite)                    | error correction · only the latest value is needed                      | previous values must be tracked                  |

### 11.3 The full-row snapshot `_history` table (recommended default strategy)

**Structure**: `{source}_history` — `history_id` (PK BIGINT), a copy of every source column, `history_created_at TIMESTAMPTZ DEFAULT now()`, `history_created_by UUID`, `change_type TEXT CHECK (change_type IN ('INSERT','UPDATE','DELETE'))`, `change_reason TEXT`.

**Core rules**:

- **History must be stored from the first INSERT**: store into `_history` with `change_type = 'INSERT'` at initial registration too. The history table alone then guarantees a complete timeline. Storing only on change produces UNION hell at read time
- **Two distinct times**: the source's `created_at` (data creation date, immutable) + `history_created_at` (history record date, refreshed on every change)
- Current data reads → the source table. History reads → the `_history` table. Splitting the tables optimizes current-data read performance

**Validity period (applied selectively)**:

| data type                        | validity columns                                      | reason                                                               |
| -------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------- |
| master data (products · members · organizations) | `valid_from`/`valid_to DEFAULT '9999-12-31'` **recommended** | optimizes point-in-time reads (`WHERE :time >= valid_from AND :time < valid_to`)  |
| transactional data (orders · payments · logs) | **not recommended**                      | the occurrence time is what matters, and the volume makes UPDATE expensive |

When a validity period is applied: every data change UPDATEs the previous row's `valid_to` and INSERTs a new row → **a transaction is mandatory**. Keeping both `is_current BOOLEAN` and `valid_to` is deliberate denormalization (readability · index efficiency → card §7 principle).

### 11.4 The Generic Audit pattern (supplementary)

`audit_logs` — `log_id` (PK), `table_name TEXT`, `row_id BIGINT`, `action TEXT`, `old_values JSONB`, `new_values JSONB`, `actor_id UUID`, `created_at TIMESTAMPTZ`. Use `row_to_json(OLD)` / `row_to_json(NEW)` in the trigger.

**Important**: a shared history table **requires periodic archiving** (monthly/quarterly partitioning + a move to cold storage after the retention period). Operating without archiving risks exhausting DB capacity.

### 11.5 Tracking exclusions · anti-patterns · principles

**Excluded from tracking**: session/token tables · cache/temporary tables · high-volume log tables (a separate log pipeline) · `audit_logs` itself

**Business history vs system logs**: store **only business history** in the DB (price changes, status changes, audit records, and so on). System logs (HTTP requests, debug information, access records) belong in a **file-based log pipeline**. Piling every log into the DB risks degrading business transaction performance.

**Anti-patterns**: ①adding history columns to the operational table (table bloat) ②applying Generic Audit to every table (performance loss) ③UPDATE/DELETE of records in an event ledger (violates ledger immutability) ④not storing the INSERT-time history in the `_history` table (broken timeline · UNION hell) ⑤using a per-column change log (`column_name`, `old_value`, `new_value` TEXT) as the primary history strategy (point-in-time restoration becomes extremely hard — allowed only as an audit display for specific fields)
