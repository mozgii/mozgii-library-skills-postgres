---
title: Time-series queries on plain PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Time-series queries on plain PostgreSQL

This reference collects the query shapes time-series dashboards need on plain PostgreSQL 18, using the
`metrics.readings` and `metrics.readings_1h` tables from the skill. Every query was run on PostgreSQL 18.6.

## Contents

The sections of this reference on time-series queries:

1. Latest value per series with LATERAL
2. Rolling hourly rollups up to days
3. First and last value in each bucket
4. Percentiles per bucket
5. Rate of change between buckets

## Latest value per series with LATERAL

The latest reading per series is fastest as one index lookup per series: a `LATERAL` subquery ordered by time with
`LIMIT 1`, driven by the table of series. It needs an index on `(device_id, ts DESC)`.

```sql
CREATE TABLE IF NOT EXISTS metrics.devices (device_id int PRIMARY KEY, name text NOT NULL);
INSERT INTO metrics.devices SELECT g, 'sensor-' || g FROM generate_series(1, 20) g ON CONFLICT DO NOTHING;

SELECT d.device_id, d.name, l.ts, l.value
FROM metrics.devices d
CROSS JOIN LATERAL (
  SELECT ts, value FROM metrics.readings r
  WHERE r.device_id = d.device_id AND r.ts >= now() - interval '1 day'
  ORDER BY ts DESC LIMIT 1
) l;
```

- The `ts >= now() - interval '1 day'` bound lets the planner prune partitions at run time; without it every
  partition's index is probed for silent devices.
- `SELECT DISTINCT ON (device_id) ... ORDER BY device_id, ts DESC` gives the same answer and suits a short time
  range; `postgres-sql-patterns` covers it.
- For thousands of series polled every few seconds, keep a `latest` table updated by the ingest path with
  `INSERT ... ON CONFLICT (device_id) DO UPDATE`.

## Rolling hourly rollups up to days

Daily figures come from hourly rollup rows, not raw rows, as long as the rollup stores sums and counts. Averages
are recomputed as total sum over total count.

```sql
SELECT date_trunc('day', bucket, 'UTC') AS day, device_id,
       sum(sum_value) / sum(n) AS avg_value,
       min(min_value) AS min_value, max(max_value) AS max_value, sum(n) AS n
FROM metrics.readings_1h
WHERE bucket >= now() - interval '7 days'
GROUP BY 1, 2
ORDER BY 1, 2
LIMIT 5;
```

`date_trunc` with a time zone argument (the third parameter) cuts days at that zone's midnight; use the zone the
report is read in, not the server's.

## First and last value in each bucket

The first and last value in a bucket (opening and closing reading) need ordered aggregation. `array_agg` with
`ORDER BY` and an index of `[1]` picks one row per bucket without a self join.

```sql
SELECT date_bin('1 hour', ts, timestamptz '2000-01-01 00:00+00') AS hour,
       (array_agg(value ORDER BY ts))[1]      AS first_value,
       (array_agg(value ORDER BY ts DESC))[1] AS last_value
FROM metrics.readings
WHERE device_id = 1 AND ts >= now() - interval '3 hours'
GROUP BY 1 ORDER BY 1;
```

Over long ranges this materializes large arrays; aggregate per bucket from a rollup that stores first and last
values instead, filled at rollup time.

## Percentiles per bucket

Percentiles cannot be combined from rollup rows: the median of hourly medians is not the daily median. Compute them
from raw rows over a bounded range with `percentile_cont`, or store a histogram per bucket.

```sql
SELECT date_bin('1 hour', ts, timestamptz '2000-01-01 00:00+00') AS hour,
       percentile_cont(0.5)  WITHIN GROUP (ORDER BY value) AS p50,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY value) AS p95
FROM metrics.readings
WHERE device_id = 1 AND ts >= now() - interval '3 hours'
GROUP BY 1 ORDER BY 1;
```

## Rate of change between buckets

The change from one bucket to the next is a window function over the rollup: `lag()` returns the previous bucket's
value for the same series.

```sql
SELECT bucket, device_id,
       sum_value / n AS avg_value,
       sum_value / n - lag(sum_value / n) OVER (PARTITION BY device_id ORDER BY bucket) AS change
FROM metrics.readings_1h
WHERE device_id = 1 AND bucket >= now() - interval '6 hours'
ORDER BY bucket;
```

Missing buckets make `lag()` compare against an older bucket; fill gaps first (the skill's gap-filling query) when
the change per hour must be exact.

## Sources

- https://www.postgresql.org/docs/18/functions-datetime.html
- https://www.postgresql.org/docs/18/functions-aggregate.html
- https://www.postgresql.org/docs/18/functions-window.html
- https://www.postgresql.org/docs/18/queries-table-expressions.html
