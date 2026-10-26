<!-- orangekit-rule-version: 3.38.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Statistics table design

> Scope: the principles are common to relational DBs, and the syntax is given for both PostgreSQL and MySQL 8.
> **Do not aggregate the source tables directly in production.** A GROUP BY over millions of rows on every call turns that load into a service outage.
> Summarize ahead of time, and have reads read the summary.

## Decision criteria

| Approach | When | Note |
| --- | --- | --- |
| **Daily summary table + nightly batch** (default) | dashboards and reports, where a one-day lag is acceptable | common to both DBs |
| Materialized View | on PG, when storing one aggregate query as-is is enough | **PG only.** On MySQL, use a summary table |
| Hybrid (past summary `UNION ALL` today's source) | today's numbers are needed in real time too | an index on the source's date column is mandatory |
| Micro-batch (an `intraday` table) | traffic is high enough that aggregating even today's source is a burden | every 1–5 minutes |
| Real-time aggregation of the source | little data, and an index is enough | move up when it grows |

Order of evolution: GROUP BY → a daily table → derive weekly/monthly/yearly from the daily one → hybrid → an idempotent batch → micro-batch → UPSERT.
Climb one step at a time, as the need arises.

**One daily table is enough.** Weekly, monthly, and yearly statistics are built by `GROUP BY` over the daily table. Even ten years is 3,650 rows.
Separate monthly and yearly tables only add places to maintain. The exception is global scale, where daily rows number in the hundreds of millions.

## Standard design

```sql
-- common (on PG use NUMERIC or BIGINT)
CREATE TABLE stat_sales_daily (
  stat_date          DATE   NOT NULL,
  total_order_count  INT    NOT NULL DEFAULT 0,
  total_sales_amount BIGINT NOT NULL DEFAULT 0,   -- sales grow large
  PRIMARY KEY (stat_date)                         -- with a dimension: (stat_date, store_id …)
);

-- for the micro-batch (today only)
CREATE TABLE stat_sales_intraday (
  stat_date          DATE     NOT NULL PRIMARY KEY,
  total_order_count  INT      NOT NULL DEFAULT 0,
  total_sales_amount BIGINT   NOT NULL DEFAULT 0,
  updated_at         DATETIME NOT NULL             -- shown on screen as "as of 14:05" (PG: TIMESTAMPTZ)
);
```

- Name it `stat_{subject}_{unit}`. For an MV, name it `mv_{subject}_{unit}`.
- Write the refresh interval, the source query, and the acceptable lag in the table definition document.
- **The aggregation range is a half-open interval**: `order_date >= 'D 00:00:00' AND order_date < 'D+1 00:00:00'`.
  Wrapping the column in a function, as in `DATE(order_date) = D`, cannot use the index.
- Run the nightly batch in the small hours, 3–5 a.m., when there are hardly any users.

## Refresh procedure — idempotency is required

**A statistics aggregation must be idempotent.** Re-running the same batch any number of times must give the same result.
That way an outage, a duplicate run, and a change to past data are all solved by one method: "re-run that date".

| Batch | Strategy |
| --- | --- |
| **Daily batch** | **DELETE + INSERT in one transaction** — delete that date and re-aggregate from the source |
| **Real-time / micro-batch** | **UPSERT overwriting with the full value** — in a batch that runs often, DELETE+INSERT causes Undo/Redo log volume, index rebuilds, page fragmentation, and lock waits |

```sql
-- daily batch (common to both; on MySQL use START TRANSACTION)
BEGIN;
DELETE FROM stat_sales_daily WHERE stat_date = :d;
INSERT INTO stat_sales_daily (stat_date, total_order_count, total_sales_amount)
SELECT :d, COUNT(*), COALESCE(SUM(total_amount), 0)
  FROM orders
 WHERE order_date >= :d AND order_date < :d + INTERVAL '1 day'   -- MySQL: :d + INTERVAL 1 DAY
   AND order_status = 'COMPLETED';
COMMIT;
```

```sql
-- UPSERT — PostgreSQL
INSERT INTO stat_sales_intraday (stat_date, total_order_count, total_sales_amount, updated_at)
SELECT CURRENT_DATE, COUNT(*), COALESCE(SUM(total_amount), 0), now()
  FROM orders
 WHERE order_date >= CURRENT_DATE AND order_status = 'COMPLETED'
ON CONFLICT (stat_date) DO UPDATE
   SET total_order_count  = EXCLUDED.total_order_count,
       total_sales_amount = EXCLUDED.total_sales_amount,
       updated_at         = EXCLUDED.updated_at;
```

```sql
-- UPSERT — MySQL 8 (VALUES() is deprecated from 8.0.20 → reference it through a derived-table alias)
INSERT INTO stat_sales_intraday (stat_date, total_order_count, total_sales_amount, updated_at)
SELECT * FROM (
  SELECT CURDATE() AS stat_date, COUNT(*) AS total_order_count,
         COALESCE(SUM(total_amount), 0) AS total_sales_amount, NOW() AS updated_at
    FROM orders
   WHERE order_date >= CURDATE() AND order_status = 'COMPLETED'
) AS new_stats
ON DUPLICATE KEY UPDATE
  total_order_count  = new_stats.total_order_count,
  total_sales_amount = new_stats.total_sales_amount,
  updated_at         = new_stats.updated_at;
```

- **When past data changes, re-run that date's batch.** For example, if a January 1 order is refunded on January 4, re-aggregate January 1.
  An accumulate-style update cannot fix this situation.
- If you do the micro-batch as DELETE + INSERT, always do it inside a transaction. Otherwise there are moments when a reader sees an empty row.
- Storing a `last_order_id` and adding only the increment after it breaks idempotency easily.
  Unless the situation is extreme, use "re-aggregate all of today + UPSERT".
- **PG MV**: `REFRESH MATERIALIZED VIEW CONCURRENTLY` requires a `UNIQUE` index on the MV. Refresh it from a scheduler such as `pg_cron`.

## Reading — hybrid

```sql
SELECT stat_date, total_order_count, total_sales_amount
  FROM stat_sales_daily
 WHERE stat_date >= :from AND stat_date < :today
UNION ALL
SELECT stat_date, total_order_count, total_sales_amount     -- with a micro-batch, read intraday;
  FROM stat_sales_intraday WHERE stat_date = :today;        -- without one, aggregate only today's range from orders
```

- For a hybrid that aggregates today's source directly, **an index on the source's date column is mandatory**.
- A monthly total wraps the result above in a subquery and does a `GROUP BY` by month.

## Anti-patterns

1. Aggregating a large source table directly on every request in production.
2. **An accumulating incremental update `SET total = total + :delta`.** A re-run inflates the numbers, and a past change (a refund) cannot be reflected either.
3. Running DELETE + INSERT without a transaction.
4. Building separate monthly and yearly tables when a daily table exists.
5. Bounding the aggregation range with `DATE(col) = :d` or `BETWEEN … '23:59:59'`. It cannot use the index, or milliseconds at the boundary leak through.
6. Running a high-frequency micro-batch as DELETE + INSERT.
7. Newly writing `ON DUPLICATE KEY UPDATE x = VALUES(x)` on MySQL 8.0.20 or later (deprecated).
8. Running `REFRESH … CONCURRENTLY` on PG with no UNIQUE index (an error).
9. Not documenting the refresh interval and acceptable lag. If the screen does not show the as-of time either, the lag goes unnoticed.
10. A hybrid read with no index on the source's date column.
