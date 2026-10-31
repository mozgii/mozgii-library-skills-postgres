---
name: postgres-timeseries
description: 'Stores and queries time-series data on PostgreSQL 18: plain Postgres with daily range partitions, BRIN indexes, rollup tables for downsampling, gap filling, late data and retention by dropping partitions, and TimescaleDB 2.31 with hypertables, chunk intervals, the columnstore, continuous aggregates, retention policies and the features that need its Community licence. Use when storing metrics, IoT or sensor readings, events or logs by time, when "the readings table is huge", dashboards over time ranges are slow, old data must be deleted cheaply, or when choosing between plain Postgres and TimescaleDB.'
metadata:
  tags:
  - postgres
  - timeseries
  - timescaledb
  - hypertables
  - continuous-aggregates
  - brin
  - partitioning
  - retention
  - downsampling
---

# PostgreSQL time-series data

Time-series rows arrive in time order, are rarely updated, are read by time range and expire by age. Design for
that: a narrow raw table partitioned by time, an index that serves ranges, rollup tables for dashboards, and
retention that drops whole partitions instead of deleting rows. Use plain PostgreSQL when you can run a partition
job and a rollup job yourself; use TimescaleDB when you want compression, continuous aggregates and retention as
policies and its licence fits. Partitioning in depth: `postgres-partitioning`. A runnable partition and retention
job: [scripts/partition-maintenance.sql](scripts/partition-maintenance.sql).

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: read the server version, the extensions and the table's shape

The choice below depends on what the server can load, how big the table is and whether it is already partitioned.
`SHOW timescaledb.license;` works only once TimescaleDB is loaded.

```sql
SELECT current_setting('server_version') AS version;
SELECT name, default_version, installed_version FROM pg_available_extensions
WHERE name IN ('timescaledb', 'pg_partman', 'pg_cron');
SELECT c.relkind, c.reltuples::bigint AS est_rows, pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
       (SELECT count(*) FROM pg_inherits i WHERE i.inhparent = c.oid) AS partitions
FROM pg_class c WHERE c.oid = 'metrics.readings'::regclass;       -- relkind p: already partitioned
```

## Choose plain partitions or TimescaleDB

Plain partitions and TimescaleDB both split a table by time; they differ in what you must build and run yourself.

| Need | Plain PostgreSQL 18 | TimescaleDB 2.31 (Community edition) |
|---|---|---|
| Split by time | `PARTITION BY RANGE`, partitions created by your job (or pg_partman) | hypertable, chunks created on insert |
| Compression | none built in (TOAST only compresses large values) | columnstore (Tiger Data cites up to 98% smaller) |
| Pre-computed rollups | rollup table filled by your job, or a materialized view | continuous aggregates with a refresh policy |
| Retention | `DETACH PARTITION ... CONCURRENTLY` + `DROP TABLE` | `add_retention_policy` |
| Managed services | every provider | only where the provider ships it; check which edition |

Pick plain PostgreSQL for modest volumes, managed services without TimescaleDB, or an open-source-only rule. Pick
TimescaleDB when raw data runs to hundreds of gigabytes and you self-host or use Tiger Cloud.

## Raw table layout for time-series rows

A raw time-series table stores one narrow row per reading: `timestamptz`, a series key and the values. Every extra
byte is multiplied by billions of rows, so keep text labels in a lookup table and store their integer id.

```sql
CREATE SCHEMA metrics;
CREATE TABLE metrics.readings (
  ts        timestamptz      NOT NULL,
  device_id int              NOT NULL,
  value     double precision NOT NULL
) PARTITION BY RANGE (ts);
```

- Use `timestamptz`, never `timestamp`, so readings from different zones compare correctly.
- A unique constraint on a partitioned table must include the partition key: `(device_id, ts)`, not an `id`. Add
  one only if duplicates must be rejected; each unique index costs insert speed.
- PostgreSQL 18 refuses `CREATE UNLOGGED TABLE ... PARTITION BY`; a single partition may still be `UNLOGGED`.

## Daily range partitions created ahead of time

Range partitions must exist before rows for their range arrive, or the insert fails with `no partition of relation
... found for row`. Create them several days ahead from a scheduled job, with bounds written in UTC so the session's
`TimeZone` cannot shift them.

```sql
CREATE OR REPLACE FUNCTION metrics.ensure_daily_partitions(p_from date, p_days int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE d date;
BEGIN
  FOR d IN SELECT generate_series(p_from, p_from + p_days - 1, interval '1 day')::date LOOP
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS metrics.%I PARTITION OF metrics.readings FOR VALUES FROM (%L) TO (%L)',
      'readings_' || to_char(d, 'YYYYMMDD'),
      d::timestamp AT TIME ZONE 'UTC',
      (d + 1)::timestamp AT TIME ZONE 'UTC');
  END LOOP;
END $$;

SELECT metrics.ensure_daily_partitions(current_date - 14, 21);   -- 14 days back, 7 ahead
```

- Run it daily from `pg_cron` (`postgres-queues-jobs`) or your scheduler.
- Avoid a `DEFAULT` partition for time series. Rows that land in it block the creation of the matching partition
  (`updated partition constraint for default partition ... would be violated`) and forbid `DETACH ... CONCURRENTLY`.
- pg_partman 5.5 automates the same job. Call `partman.create_partition(p_parent_table => 'metrics.readings',
  p_control => 'ts', p_interval => '1 day', p_premake => 4, p_default_table => false)`, which replaced `create_parent`
  in 5.4, and set `retention` in `partman.part_config`. It adds a default partition unless told not to, hence
  `p_default_table => false`. `postgres-partitioning` covers it.

## BRIN and B-tree indexes for time ranges

A BRIN index stores the minimum and maximum time per block range, so on append-only data it is tiny and still skips
most of a partition for a range query. A B-tree on `(device_id, ts DESC)` serves "this device over this period" and
"latest reading per device".

```sql
CREATE INDEX readings_ts_brin   ON metrics.readings USING brin (ts) WITH (pages_per_range = 32);
CREATE INDEX readings_device_ts ON metrics.readings (device_id, ts DESC);
```

- Indexes created on the parent are created on every existing and future partition.
- `pages_per_range` defaults to 128; smaller is larger and more precise. New ranges are summarized by vacuum, or at
  once with `autosummarize = on` or `brin_summarize_new_values()`.
- BRIN only works while physical order follows time; backfills into a current partition spread the ranges.

## Rollup tables for downsampling

A rollup table keeps one row per series per bucket (minute, hour, day), so a dashboard reads thousands of rows
instead of millions. Store sums and counts, not averages, so buckets can be combined into larger ones later.

```sql
CREATE TABLE metrics.readings_1h (
  bucket    timestamptz      NOT NULL,
  device_id int              NOT NULL,
  n         bigint           NOT NULL,
  sum_value double precision NOT NULL,
  min_value double precision NOT NULL,
  max_value double precision NOT NULL,
  PRIMARY KEY (device_id, bucket)
);

CREATE OR REPLACE PROCEDURE metrics.rollup_1h(p_from timestamptz, p_to timestamptz)
LANGUAGE sql AS $$
  INSERT INTO metrics.readings_1h AS r (bucket, device_id, n, sum_value, min_value, max_value)
  SELECT date_bin('1 hour', ts, timestamptz '2000-01-01 00:00+00'), device_id,
         count(*), sum(value), min(value), max(value)
  FROM metrics.readings
  WHERE ts >= date_bin('1 hour', p_from, timestamptz '2000-01-01 00:00+00') AND ts < p_to
  GROUP BY 1, 2
  ON CONFLICT (device_id, bucket) DO UPDATE
    SET n = EXCLUDED.n, sum_value = EXCLUDED.sum_value,
        min_value = EXCLUDED.min_value, max_value = EXCLUDED.max_value
    WHERE (r.n, r.sum_value) IS DISTINCT FROM (EXCLUDED.n, EXCLUDED.sum_value);
$$;

CALL metrics.rollup_1h(now() - interval '14 days', date_trunc('hour', now()));
```

- `date_bin` takes any fixed stride and an origin, but no strides of a month or more: use `date_trunc` for months.
- The `WHERE ... IS DISTINCT FROM` clause skips unchanged buckets, so a rerun writes no dead rows.
- Averages come back as `sum_value / n`; a day is the sum of its 24 hourly rows.

## Late and out-of-order data

Late data is a reading that arrives after its bucket was rolled up. Handle it by recomputing a sliding window on
every run rather than only the newest bucket: the upsert in the rollup procedure makes recomputation safe.

```sql
CALL metrics.rollup_1h(now() - interval '6 hours', date_trunc('hour', now()));   -- every 10 minutes
```

- Size the window to the lateness you accept (devices offline for a day need 24 hours); run a wider pass nightly.
- Data older than the oldest partition fails with `no partition ... found for row`: reject and log it on purpose,
  or create the old partition first.

## Gap filling and carrying the last value forward

Gap filling produces a row for every bucket even when no data arrived, which charts need. Generate the buckets and
`LEFT JOIN` the data; to carry the last known value forward (LOCF), count non-null values in a running window.

```sql
SELECT g.bucket,
       r.sum_value / r.n AS avg_value,
       (array_agg(r.sum_value / r.n) FILTER (WHERE r.n IS NOT NULL) OVER w)[count(r.n) OVER w] AS avg_locf
FROM generate_series(date_trunc('hour', now()) - interval '6 hours',
                     date_trunc('hour', now()) - interval '1 hour', interval '1 hour') AS g(bucket)
LEFT JOIN metrics.readings_1h r ON r.bucket = g.bucket AND r.device_id = 3
WINDOW w AS (ORDER BY g.bucket)
ORDER BY g.bucket;
```

PostgreSQL 18 has no `IGNORE NULLS` for window functions, hence the array trick. Latest value per series, rollups
of rollups and percentiles: [references/time-series-queries.md](references/time-series-queries.md).

## Retention by detaching and dropping partitions

Retention removes whole partitions: `DROP TABLE` frees the space at once and leaves no dead rows, where a
`DELETE` of the same rows takes hours, bloats the table and needs vacuum. Detach first with `CONCURRENTLY` so
readers and writers of the parent are not blocked.

```sql
SELECT c.oid::regclass AS expired_partition
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'metrics.readings'::regclass
  AND (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz
      <= now() - interval '12 days';

ALTER TABLE metrics.readings DETACH PARTITION metrics.readings_20261014 CONCURRENTLY;
DROP TABLE metrics.readings_20261014;
```

- `DETACH ... CONCURRENTLY` cannot run in a transaction block (so not in a `DO` block or function) and is refused
  while a `DEFAULT` partition exists. Send one statement per partition from the job, after `SET lock_timeout`.
- An interrupted concurrent detach leaves the partition pending; finish it with `DETACH PARTITION ... FINALIZE`.
- Roll up before you drop: the rollup table keeps history after the raw rows are gone.

## TimescaleDB hypertables, columnstore and policies

A hypertable is a table TimescaleDB splits into chunks by time on insert, so there is no partition job; policies
then compress, aggregate and expire chunks on a schedule. In 2.31, `CREATE TABLE ... WITH (tsdb.hypertable)`
creates one directly. The extension must be in `shared_preload_libraries` before `CREATE EXTENSION timescaledb`.

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE TABLE sensor_data (
  ts        timestamptz NOT NULL,
  device_id int         NOT NULL,
  temp      double precision
) WITH (
  tsdb.hypertable,
  tsdb.partition_column = 'ts',
  tsdb.chunk_interval   = '1 day',
  tsdb.segmentby        = 'device_id',
  tsdb.orderby          = 'ts DESC'
);
CALL remove_columnstore_policy('sensor_data');                         -- replace the default one
CALL add_columnstore_policy('sensor_data', after => INTERVAL '7 days');
SELECT add_retention_policy('sensor_data', drop_after => INTERVAL '90 days');
```

- `tsdb.chunk_interval` defaults to 7 days. Size it so the indexes of the chunks being written fit in about 25% of
  `shared_buffers` (Tiger Data's guideline); high-volume tables want 1 day or less.
- The columnstore is on by default and creates a policy at once (seen on 2.31: `after` equal to the chunk
  interval). Its calls are procedures (`CALL`); retention and aggregate policies are functions.
- A continuous aggregate (`CREATE MATERIALIZED VIEW ... WITH (timescaledb.continuous)`) refreshes only changed
  buckets. Its refresh policy's `start_offset` is the late-data window; keep raw `drop_after` longer than it, or a
  refresh over dropped chunks deletes those buckets. Raw for 90 days and hourly for years is downsampling.
- Since 2.13 continuous aggregates default to `materialized_only = true`: queries see refreshed buckets only.

Continuous aggregates, gap filling with `time_bucket_gapfill`, install per OS, chunk sizing, job monitoring and
upgrades: [references/timescaledb.md](references/timescaledb.md).

## TimescaleDB licensing: Apache 2 and Community editions

TimescaleDB ships as two editions; the features above are not all in both.

| Edition | Licence | Includes | Where you get it |
|---|---|---|---|
| Apache 2 | Apache 2.0 | hypertables, `time_bucket`, `drop_chunks`, `first`/`last` | PGDG `postgresql-18-timescaledb`, `-oss` Docker tags |
| Community | Tiger Data License (TSL) | adds columnstore, continuous aggregates, all policies, `add_job`, `time_bucket_gapfill`, `locf`, `interpolate`, SkipScan | Tiger Data's packages, `timescale/timescaledb` images, Tiger Cloud |

The TSL lets you run the Community edition free on your own servers and modify it, but not offer it as a database
service to others. Check the running edition with `SHOW timescaledb.license;` (`timescale` or `apache`).

## Worked example: "the readings table is 400 GB and the dashboard times out"

Two years of 10-second readings from 5,000 devices sit in one table; the 7-day dashboard takes 40 seconds and a
`DELETE` of old rows never finishes. Build a partitioned `readings_new` with daily partitions and both indexes,
copy history day by day (skipping what retention would drop), swap names in one short transaction under
`lock_timeout`, and copy the last gap. Point the dashboard at a backfilled `readings_1h`: 5,000 devices times 168
hours is 840,000 rows instead of 300 million. Schedule the partition job, the 10-minute rollup and the daily drop.

## Gotchas

These are the failures seen most often with time-series tables, each with its cause and fix.

1. **`no partition of relation "readings" found for row`.** The partition job did not run or fell behind. Create
   partitions several days ahead and alert when the newest partition is less than two days ahead.
2. **Partition bounds are off by hours.** Bounds were computed from `date::timestamptz` in a session with a non-UTC
   `TimeZone`. Write bounds with `AT TIME ZONE 'UTC'` or as literals with `+00`.
3. **`DETACH PARTITION ... CONCURRENTLY` fails.** It ran inside a transaction or function, or a `DEFAULT` partition
   exists. Run it as a top-level statement and drop the default partition.
4. **A continuous aggregate lost old buckets.** Raw retention was shorter than the refresh window, so a refresh saw
   deleted data. Keep `drop_after` on raw data larger than `start_offset`.
5. **The dashboard shows nothing for the last hour.** `materialized_only` is `true` (the default since 2.13) and the
   newest buckets are not refreshed yet. Set it to `false` or shorten `end_offset`.
6. **`function "add_columnstore_policy" is not supported under the current "apache" license`.** The Apache
   edition is installed (PGDG package, `-oss` image). Install the Community edition, or stay on plain partitions.
   A separate error, `is a procedure`, means the call needs `CALL` instead of `SELECT`.

## Anti-patterns in time-series tables

These feel fine in the first month and hurt at a billion rows.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| `DELETE` for retention | it takes hours, bloats the table and needs vacuum | drop whole partitions or chunks |
| Storing averages in rollups | averages cannot be combined into larger buckets | sums and counts |
| Repeating text labels in each row | bytes multiply by billions of rows | a lookup table and an integer id |
| Dashboards over raw rows | each load reads millions of rows | a rollup table or continuous aggregate |
| A `DEFAULT` partition "just in case" | its rows block new partitions, and it forbids concurrent detach | create partitions ahead and alert when the job falls behind |
| Partition bounds from local time | bounds shift by hours between sessions | bounds written in UTC |
| Partitioning modest tables by the hour | planning and locking grow with the partition count | an interval that fits the volume and the retention |

## Verify partitions, pruning and retention

Run these after the first maintenance run and from monitoring. They ran on 18.6 after
[scripts/partition-maintenance.sql](scripts/partition-maintenance.sql) with `ahead=7`.

```sql
SELECT count(*) AS partitions,                               -- 8: today and 7 ahead
       count(*) FILTER (WHERE pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT') AS default_parts   -- 0
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'metrics.readings'::regclass;
EXPLAIN (COSTS OFF) SELECT avg(value) FROM metrics.readings
WHERE ts >= date_trunc('day', now() + interval '1 day')
  AND ts <  date_trunc('day', now() + interval '1 day') + interval '1 hour';   -- Subplans Removed: 7
```

`Subplans Removed` is pruning at run time, because `now()` is not a constant; constant bounds list only the matching
partition instead. Alert when the newest partition is less than two days ahead, because a failed job then has time to
be noticed before inserts fail with `no partition of relation "readings" found for row`.

## Checklist

Check these points before you call a time-series design done.

- [ ] Partitions (or chunks) exist ahead of time, with UTC bounds and no `DEFAULT` partition.
- [ ] A BRIN or B-tree index serves the time-range queries; `EXPLAIN` shows partition pruning.
- [ ] Dashboards read a rollup table or continuous aggregate, not raw rows.
- [ ] The rollup recomputes a window as wide as the lateness you accept.
- [ ] Retention drops partitions or chunks; nothing deletes raw rows in bulk.
- [ ] Raw retention is longer than the aggregate refresh window.
- [ ] The TimescaleDB edition and its licence match how you run it.

## See also

Related skills in this library:

- `postgres-partitioning`: partitioning and pg_partman in depth
- `postgres-sql-dates-times`: zones, `date_bin` and buckets
- `postgres-queues-jobs`: scheduling the jobs with pg_cron
- `postgres-indexing`: BRIN and B-tree choices
- `postgres-extensions-install`: installing TimescaleDB

## Sources

- https://www.postgresql.org/docs/18/ddl-partitioning.html
- https://www.postgresql.org/docs/18/sql-altertable.html
- https://www.postgresql.org/docs/18/brin.html
- https://www.postgresql.org/docs/18/functions-datetime.html
- https://www.postgresql.org/docs/18/functions-window.html
- https://github.com/pgpartman/pg_partman/blob/master/doc/pg_partman.md
- https://www.tigerdata.com/docs/reference/timescaledb/hypertables/create_table
- https://www.tigerdata.com/docs/reference/timescaledb/hypercore/add_columnstore_policy
- https://www.tigerdata.com/docs/learn/data-lifecycle/data-retention/data-retention-with-continuous-aggregates
- https://www.tigerdata.com/docs/learn/hypertables/sizing-hypertable-chunks
- https://www.tigerdata.com/docs/get-started/choose-your-path/timescaledb-editions
