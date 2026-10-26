<!-- orangekit-rule-version: 3.38.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Idempotency design

**Payments · external APIs · state transitions**: idempotency is mandatory. Pure reads and operations inside a single transaction do not need it.

| mandatory                                 | not needed                               |
| ----------------------------------------- | ---------------------------------------- |
| payment processing (external payment webhook retries) | pure reads (SELECT)                          |
| state transitions (request→paid→completed)        | operations inside a single transaction       |
| external API calls (push notifications / OCR / payments) | a natural UNIQUE already exists at creation (email, etc.) |
| message handling between distributed systems | delete operations (a no-op if already gone = naturally idempotent) |

**Pattern**: add an `idempotency_key VARCHAR(64) UNIQUE` column. `INSERT ... ON CONFLICT (idempotency_key) DO UPDATE SET updated_at = now() RETURNING *` — a duplicate request returns the existing result. MySQL 8: `INSERT … ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id)`, then read the existing row's ID back with `LAST_INSERT_ID()` and fetch the row.

**Key generation strategy**: client-generated `{user_id}:{action}:{target_id}:{timestamp_bucket}`, or server-generated `{webhook_event_id}` (using the PG webhook ID).

**TTL**: clean up with a `pg_cron` batch after `created_at + INTERVAL '24h'` (prevents unbounded accumulation). Index: `idx_{table}_idempotency_key`.

**Anti-patterns**: ①handling webhooks with no idempotency key (risk of duplicate payments and duplicate credits) ②idempotency records with no TTL (unbounded table growth) ③app-level duplicate checks only (a DB UNIQUE constraint is mandatory — it defends against concurrent requests) ④using the idempotency key as the PK (violates the surrogate-key principle → card §3)
