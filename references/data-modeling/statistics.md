<!-- orangekit-rule-version: 3.25.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Statistics table design

**Default: a Materialized View** + periodic `pg_cron` refresh. Whenever real time is not required, prefer an MV.

| approach               | when to apply                                                        | when not to apply                                 |
| ---------------------- | -------------------------------------------------------------------- | ------------------------------------------------- |
| Materialized View (MV) | repeated aggregate queries · stale data acceptable · simple to medium aggregation | second-level real time needed · MV refresh costs more than the direct query |
| Summary Table          | incremental refresh needed · custom aggregation logic · full recomputation on MV refresh too expensive | simple COUNT/SUM (an MV is enough) |
| real-time query        | small data volume · an index suffices · always needs the latest      | repeated aggregation over large tables (response time exceeded) |

**Hybrid read strategy** (when real-time statistics are needed but aggregating the whole source is too costly): historical data (the statistics/MV table) `UNION ALL` today's data (the source table, a date index mandatory). Only today's data is aggregated in real time, so DB load is minimal. This only works if the source table's date column **definitely has an index**.

**Time-granularity principle**: one daily statistics table is enough. Weekly, monthly, and annual statistics are re-aggregated from the daily table with `GROUP BY` (10 years = 3,650 rows, nothing to a DB). Creating separate monthly/annual tables only adds maintenance surface — unnecessary below global scale.

**MV naming**: `mv_{subject}_{granularity}` (e.g. `mv_order_daily_stats`, `mv_user_monthly_summary`)

**MV requirements**: ①a `CREATE UNIQUE INDEX` is mandatory — it is the precondition for `REFRESH MATERIALIZED VIEW CONCURRENTLY` ②refresh via `pg_cron` or a Supabase Edge Function schedule ③record the refresh interval, the source query, and the acceptable staleness in the table definition document

**Summary Table**: naming `stat_{subject}_{granularity}`. `period_start TIMESTAMPTZ` + `period_end TIMESTAMPTZ` + aggregate columns + `updated_at TIMESTAMPTZ`. A BRIN index (optimal for sequential time-series inserts).

**Batch refresh strategy** (idempotency mandatory):

| batch type                   | strategy                                                                                   | reason                                                         |
| ---------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------- |
| nightly batch (once a day)   | **DELETE & INSERT** — delete that period, then re-aggregate from the source                | idempotency is obvious · retroactive changes such as refunds are picked up automatically · easy to debug |
| micro-batch (minutes to hours) | **UPSERT overwriting the whole value** — `INSERT ... ON CONFLICT DO UPDATE SET count = EXCLUDED.count` | avoids the undo/redo log cost of DELETE & INSERT · prevents index fragmentation |

**Anti-patterns**: ①attempting a `CONCURRENTLY` refresh with no UNIQUE index (error) ②an undocumented refresh interval (staleness cannot be reasoned about) ③introducing a Summary Table where an MV suffices (→ violates the denormalization premise in card §7) ④**incremental accumulation with `count = count + :delta` — re-running the batch inflates the data** (always overwrite the whole value or use DELETE & INSERT)
