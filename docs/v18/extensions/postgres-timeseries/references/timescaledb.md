---
title: TimescaleDB on PostgreSQL 18
author: MOZGII, Inc.
lang: en
---

# TimescaleDB on PostgreSQL 18

This reference covers TimescaleDB 2.31 (released 20 October 2026, supports PostgreSQL 16, 17 and 18) beyond the
summary in the skill: installing it on each OS, chunk sizing, the columnstore, continuous aggregates, gap filling,
background jobs, upgrades and licensing. Every SQL example was run on the `timescale/timescaledb:2.31.0-pg18` image
(PostgreSQL 18.6).

## Contents

The sections of this reference on TimescaleDB:

1. Installing TimescaleDB on Linux, macOS, Windows and Docker
2. Checking the edition and turning off telemetry
3. Chunk intervals and changing them
4. Columnstore settings, manual conversion and backfills
5. Continuous aggregates: refresh windows, real-time mode and hierarchies
6. Gap filling with time_bucket_gapfill, locf and interpolate
7. Background jobs: listing, running and failures
8. Upgrading the TimescaleDB extension
9. Converting an existing table to a hypertable
10. Toolkit analytics: percentiles, time-weighted averages, uptime and state time

## Installing TimescaleDB on Linux, macOS, Windows and Docker

TimescaleDB is a shared library that must be preloaded, so every install ends with `shared_preload_libraries =
'timescaledb'`, a server restart and `CREATE EXTENSION timescaledb` in each database that uses it.

| OS | Community edition (TSL) | Apache 2 edition |
|---|---|---|
| Debian, Ubuntu | Tiger Data's packagecloud repository, then `sudo apt install timescaledb-2-postgresql-18` | PGDG `postgresql-18-timescaledb` (its description says "Apache-licensed version") |
| RHEL family | Tiger Data's packagecloud repository (`timescaledb-2-postgresql-18`) | built from source with `-DAPACHE_ONLY=1` |
| macOS | `brew tap timescale/tap` then `brew install timescaledb` (Homebrew PostgreSQL) | from source |
| Windows | the release zip from Tiger Data; run `setup.exe` as Administrator | from source |
| Docker | `timescale/timescaledb:2.31.0-pg18` | `timescale/timescaledb:2.31.0-pg18-oss` |

- Postgres.app does not bundle TimescaleDB; on macOS use Homebrew PostgreSQL or Docker for it.
- `timescaledb-tune` (in the `timescaledb-tools` package and run by the Docker image at first start) rewrites
  memory, worker and parallelism settings in `postgresql.conf`. Review its changes; it raised
  `max_worker_processes` to 37 in the test container.
- Every database that uses TimescaleDB needs `CREATE EXTENSION timescaledb;` run by a role allowed to create it.

This shell command starts a throwaway TimescaleDB container for trying the examples; it listens on no host port.

```bash
docker run -d --name tsdb-try -e POSTGRES_PASSWORD=change-me timescale/timescaledb:2.31.0-pg18
docker exec -it tsdb-try psql -U postgres
```

## Checking the edition and turning off telemetry

The TimescaleDB edition decides which functions work. The Apache edition answers calls to Community features with
`function "add_columnstore_policy" is not supported under the current "apache" license`.

```sql
SHOW timescaledb.license;                  -- timescale (Community) or apache
SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
SHOW timescaledb.telemetry_level;          -- basic by default
```

Telemetry reports go to Tiger Data while `timescaledb.telemetry_level` is `basic`. Set
`timescaledb.telemetry_level = off` in `postgresql.conf` (or `ALTER SYSTEM SET timescaledb.telemetry_level = off`
and reload) where outbound reports are not allowed.

## Chunk intervals and changing them

A chunk interval is the time span of one chunk. Tiger Data's guideline: the indexes of the chunks currently being
written should fit within 25% of `shared_buffers`. Too small an interval makes thousands of chunks and slows
planning; too large makes recent chunks spill out of memory.

```sql
SELECT set_chunk_time_interval('metrics', INTERVAL '12 hours');
SELECT column_name, time_interval FROM timescaledb_information.dimensions WHERE hypertable_name = 'metrics';
SELECT chunk_name, range_start, is_compressed
FROM timescaledb_information.chunks WHERE hypertable_name = 'metrics'
ORDER BY range_start DESC LIMIT 3;
```

The new interval applies only to chunks created afterwards; existing chunks keep their size.

## Columnstore settings, manual conversion and backfills

The columnstore stores a chunk as compressed batches, one set per `segmentby` value, ordered by `orderby`. Choose
`segmentby` as the column queries filter and group by (a device or tenant id), and `orderby` as the time column
descending. Settings apply to chunks converted after the change.

```sql
SELECT * FROM timescaledb_information.hypertable_columnstore_settings;
DO $$ DECLARE c regclass; BEGIN
  FOR c IN SELECT show_chunks('metrics', older_than => INTERVAL '7 days') LOOP
    CALL convert_to_columnstore(c, if_not_columnstore => true);
  END LOOP;
END $$;
SELECT pg_size_pretty(before_compression_total_bytes) AS before,
       pg_size_pretty(after_compression_total_bytes)  AS after
FROM hypertable_columnstore_stats('metrics');
```

- On random test data (10 devices, one reading a minute) 23 MB became 7 MB. Real metrics with repeating values
  compress far better; measure your own.
- `INSERT`, `UPDATE` and `DELETE` into columnstore chunks work in 2.31; a late row inserted 10 days back into a
  converted chunk was accepted and showed up in the aggregate after a refresh.
- `tsdb.direct_compress` (compress during ingest) is a tech preview in 2.31 and not production-ready per its docs.

## Continuous aggregates: refresh windows, real-time mode and hierarchies

A continuous aggregate keeps a materialized `time_bucket` query up to date by refreshing only buckets whose raw
data changed. The refresh policy's `start_offset` and `end_offset` define the window refreshed on each run;
`schedule_interval` defaults to 24 hours.

```sql
CREATE MATERIALIZED VIEW metrics_hourly
WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '1 hour', ts) AS bucket, device_id,
       avg(temp) AS avg_temp, min(temp) AS min_temp, max(temp) AS max_temp, count(*) AS n
FROM metrics
GROUP BY bucket, device_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('metrics_hourly',
  start_offset      => INTERVAL '3 days',
  end_offset        => INTERVAL '1 hour',
  schedule_interval => INTERVAL '30 minutes');

CALL refresh_continuous_aggregate('metrics_hourly', now() - interval '30 days', now() - interval '1 hour');
ALTER MATERIALIZED VIEW metrics_hourly SET (timescaledb.materialized_only = false);
```

- Backfill once with `refresh_continuous_aggregate` over the history; the policy only covers its window.
- Late data older than `start_offset` is not picked up by the policy: run `refresh_continuous_aggregate` over its
  range after a backfill.
- `materialized_only = false` (real-time aggregation) unions refreshed buckets with raw rows newer than the last
  refresh. It has been off by default since 2.13.
- A continuous aggregate can be built on another one, for example daily from hourly. Combine averages as
  `sum(avg * n) / sum(n)`, never as an average of averages.

```sql
CREATE MATERIALIZED VIEW metrics_daily
WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '1 day', bucket) AS day, device_id,
       sum(avg_temp * n) / sum(n) AS avg_temp, max(max_temp) AS max_temp, sum(n) AS n
FROM metrics_hourly
GROUP BY day, device_id
WITH NO DATA;
CALL refresh_continuous_aggregate('metrics_daily', NULL, now() - interval '1 day');
```

## Gap filling with time_bucket_gapfill, locf and interpolate

`time_bucket_gapfill` returns a row for every bucket in the queried range, even buckets without data; `locf()`
carries the previous value forward and `interpolate()` fills linearly between neighbours. The `WHERE` clause must
bound the time column on both sides. These functions are Community-edition features.

```sql
SELECT time_bucket_gapfill(INTERVAL '1 hour', ts) AS hour,
       avg(temp)              AS avg_temp,
       locf(avg(temp))        AS carried,
       interpolate(avg(temp)) AS interpolated
FROM metrics
WHERE device_id = 2 AND ts >= now() - interval '6 hours' AND ts < now()
GROUP BY hour ORDER BY hour;
```

## Background jobs: listing, running and failures

Policies run as TimescaleDB background jobs, limited by `timescaledb.max_background_workers` (16 by default) and in
turn by PostgreSQL's `max_worker_processes`. A failing job retries, and its errors show in the job views.

```sql
SELECT j.job_id, j.proc_name, j.schedule_interval, s.last_run_status, s.total_failures
FROM timescaledb_information.jobs j
JOIN timescaledb_information.job_stats s USING (job_id)
ORDER BY j.job_id;
SELECT add_retention_policy('metrics', drop_after => INTERVAL '90 days');
```

Run one job immediately with `CALL run_job(<job_id>);`, and pause one with `SELECT alter_job(<job_id>, scheduled
=> false);`. Alert when `total_failures` grows or `last_run_status` is not `Success`.

## Upgrading the TimescaleDB extension

A TimescaleDB upgrade installs the new package, then runs `ALTER EXTENSION` in every database that has the
extension. Tiger Data's procedure runs it with `psql -X` so no `.psqlrc` statement loads the old version first.

```bash
psql -X -d "$DB_URL" -c "ALTER EXTENSION timescaledb UPDATE;"
psql -X -d "$DB_URL" -c "\dx timescaledb"
```

Read the release notes for backward-incompatible changes before upgrading: 2.31 renamed
`timescaledb.enable_columnarscan` to `timescaledb.debug_enable_columnarscan`, and 2.29 dropped PostgreSQL 15.

## Converting an existing table to a hypertable

Moving a live table is worth it when it is written mostly by `INSERT`, is read by time ranges, and old rows can be
compressed or dropped. Check the mix first: large `n_tup_ins` next to small `n_tup_upd` and `n_tup_del`, and a
timestamp the queries filter on.

```sql
SELECT relname, n_tup_ins, n_tup_upd, n_tup_del, pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables ORDER BY n_tup_ins DESC LIMIT 20;
```

`create_hypertable` refuses a table that has rows unless told to move them, and every primary key and unique
constraint must include the time column.

```sql
ALTER TABLE readings DROP CONSTRAINT readings_pkey;          -- ERROR before this: cannot create a unique index
ALTER TABLE readings ADD PRIMARY KEY (id, ts);               -- without the column "ts" (used in partitioning)
SELECT create_hypertable('readings', by_range('ts', INTERVAL '1 day'), migrate_data => true);
```

| Table | Way | Trade-off |
|---|---|---|
| Small enough to lock for the copy | `migrate_data => true` in place | blocks the table while rows move into chunks |
| Large or busy | new hypertable beside it, dual writes, batched backfill, rename at cutover | no long lock; needs application work and a validation pass |

- Changing the key is a schema change the application sees: `id` alone is no longer unique, so agree it with the
  owners first and keep `id` indexed if lookups use it.
- Foreign keys measured on 2.31: hypertable to plain table and plain table to hypertable both work; hypertable to
  hypertable fails with `hypertables cannot be used as foreign key references of hypertables`. Enforce those in the
  application or drop them.
- Pick the time column that says when the event happened. `updated_at` changes after the insert, so rows leave time
  order.
- Afterwards, `EXPLAIN` a time-range query and confirm it scans only recent chunks.

## Toolkit analytics: percentiles, time-weighted averages, uptime and state time

The separate `timescaledb_toolkit` extension adds aggregates that plain SQL does badly over time. It ships in the
`timescale/timescaledb-ha` image, not in `timescale/timescaledb`; these were run on `timescale/timescaledb-ha:pg18`.

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit;
SELECT approx_percentile(0.95, percentile_agg(temp)) FROM readings;              -- p95 from a mergeable sketch
SELECT time_bucket('1 hour', ts) AS hour,
       average(time_weight('LOCF', ts, temp)) AS weighted_avg                    -- for irregular sampling
FROM readings GROUP BY hour ORDER BY hour;
SELECT average(stats_agg(temp)), stddev(stats_agg(temp)) FROM readings;
SELECT uptime(heartbeat_agg(ts, now() - interval '1 hour', interval '1 hour', interval '5 minutes'))
FROM readings WHERE ts >= now() - interval '1 hour';                             -- a gap over 5 minutes counts as down
SELECT duration_in(state_agg(ts, CASE WHEN temp > 20.5 THEN 'hot' ELSE 'ok' END), 'hot') FROM readings;
```

The sketches are what make these useful in a continuous aggregate: store `percentile_agg(temp)` per hour, then
combine hours with `rollup()` and read `approx_percentile` from the result. A plain `percentile_cont` cannot be
combined that way. An unweighted `avg` over irregular samples favours the periods that were sampled most.

## Sources

- https://www.tigerdata.com/docs/reference/timescaledb/hypertables/create_hypertable
- https://www.tigerdata.com/docs/get-started/choose-your-path/install-timescaledb
- https://www.tigerdata.com/docs/get-started/choose-your-path/timescaledb-editions
- https://www.tigerdata.com/docs/deploy/self-hosted/configuration/telemetry
- https://www.tigerdata.com/docs/deploy/self-hosted/upgrades/minor-upgrade
- https://www.tigerdata.com/docs/learn/hypertables/sizing-hypertable-chunks
- https://www.tigerdata.com/docs/reference/timescaledb/hypertables/create_table
- https://www.tigerdata.com/docs/reference/timescaledb/hypertables/set_chunk_time_interval
- https://www.tigerdata.com/docs/reference/timescaledb/hypercore/add_columnstore_policy
- https://www.tigerdata.com/docs/reference/timescaledb/continuous-aggregates/create_materialized_view
- https://www.tigerdata.com/docs/reference/timescaledb/continuous-aggregates/add_continuous_aggregate_policy
- https://www.tigerdata.com/docs/learn/continuous-aggregates/real-time-aggregates
- https://www.tigerdata.com/docs/reference/timescaledb/data-retention/add_retention_policy
- https://www.tigerdata.com/docs/reference/timescaledb/hyperfunctions/time_bucket_gapfill/time_bucket_gapfill
- https://github.com/timescale/timescaledb/releases/tag/2.31.0
- https://apt.postgresql.org (package list for `postgresql-18-timescaledb`)
