---
title: Reporting and analytics queries in PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Reporting and analytics queries in PostgreSQL

Reports aggregate many rows into few, so the shape of the query matters more than in OLTP code. These patterns cover
conditional counts, subtotals, time series with gaps filled, percentiles and rollup tables.

## Contents

This reference covers the following report patterns.

- Conditional aggregates with FILTER
- Subtotals with GROUPING SETS, ROLLUP and CUBE
- Time buckets with date_trunc and date_bin
- Filling missing days with generate_series
- Percentiles and medians
- Rollup tables updated incrementally
- Running reports without hurting production

## Conditional aggregates with FILTER

`FILTER (WHERE ...)` counts or sums only the rows that match, so one pass over the table gives several numbers. It
replaces `sum(CASE WHEN ... THEN 1 ELSE 0 END)`.

```sql
SELECT customer_id,
       count(*)                                        AS orders,
       count(*) FILTER (WHERE status = 'cancelled')    AS cancelled,
       sum(total_cents) FILTER (WHERE status = 'paid') AS paid_cents
FROM app.orders
WHERE placed_at >= now() - interval '90 days'
GROUP BY customer_id;
```

## Subtotals with GROUPING SETS, ROLLUP and CUBE

Grouping sets compute several `GROUP BY` levels in one query: per region and product, per region, and a grand total.
`grouping()` tells a subtotal row from a real NULL.

```sql
SELECT region, product, sum(total_cents) AS cents,
       grouping(region, product) AS level        -- 0 detail, 1 region subtotal, 3 grand total
FROM app.sales
GROUP BY ROLLUP (region, product)
ORDER BY region NULLS LAST, product NULLS LAST;
```

`CUBE (a, b)` adds every combination, including per product across regions.

## Time buckets with date_trunc and date_bin

`date_trunc` buckets by calendar unit; `date_bin` buckets by any fixed interval, such as 15 minutes. Bucket in the
reporting time zone, or a day bucket follows the session's zone.

```sql
SELECT date_trunc('day', placed_at, 'Europe/Berlin') AS day, count(*)       -- third argument: the zone
FROM app.orders GROUP BY 1 ORDER BY 1;

SELECT date_bin('15 minutes', recorded_at, timestamptz '2026-01-01') AS slot, avg(value)
FROM app.readings WHERE recorded_at >= now() - interval '1 day'
GROUP BY 1 ORDER BY 1;
```

Index the time column (B-tree, or BRIN on append-only tables) and always bound the range in `WHERE`.

## Filling missing days with generate_series

A chart needs a row for every day, including days without data. Generate the days and left join the aggregate.

```sql
SELECT d::date AS day, coalesce(r.orders, 0) AS orders
FROM generate_series(date '2026-10-01', date '2026-10-31', interval '1 day') AS d
LEFT JOIN (
  SELECT (placed_at AT TIME ZONE 'UTC')::date AS day, count(*) AS orders
  FROM app.orders
  WHERE placed_at >= '2026-10-01 00:00+00' AND placed_at < '2026-11-01 00:00+00'
  GROUP BY 1
) r ON r.day = d::date
ORDER BY 1;
```

## Percentiles and medians

`percentile_cont` interpolates (the median of 10 and 20 is 15); `percentile_disc` returns an existing value. Both
sort their input, so filter first.

```sql
SELECT percentile_cont(0.5)  WITHIN GROUP (ORDER BY duration_ms) AS p50,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms) AS p95,
       percentile_cont(ARRAY[0.5, 0.9, 0.99]) WITHIN GROUP (ORDER BY duration_ms) AS ps
FROM app.requests WHERE at >= now() - interval '1 hour';
```

## Rollup tables updated incrementally

A rollup table keeps aggregates per bucket and is updated for recent buckets only, which scales where refreshing a
whole materialized view does not.

```sql
CREATE TABLE app.revenue_daily (day date PRIMARY KEY, cents bigint NOT NULL, orders int NOT NULL);

-- every few minutes: recompute the last two days only
INSERT INTO app.revenue_daily (day, cents, orders)
SELECT (placed_at AT TIME ZONE 'UTC')::date, sum(total_cents), count(*)
FROM app.orders
WHERE status = 'paid' AND placed_at >= ((now() AT TIME ZONE 'UTC')::date - 1)::timestamp AT TIME ZONE 'UTC'
GROUP BY 1
ON CONFLICT (day) DO UPDATE SET cents = EXCLUDED.cents, orders = EXCLUDED.orders;
```

The `::timestamp` cast matters. `AT TIME ZONE` on a bare `date` treats it as midnight in the session's zone and returns
a `timestamp`, so a New York session starts the window 8 hours late and overwrites that day with a partial total.

Rows that arrive later than the recompute window need a wider window or a nightly full pass.

## Running reports without hurting production

Heavy reports compete with the application for CPU, I/O and locks. Keep them apart.

- Run them on a read replica, or as a role with its own limits:
  `ALTER ROLE reporting SET statement_timeout = '5min'; ALTER ROLE reporting SET work_mem = '256MB';`
- Use one `REPEATABLE READ, READ ONLY` transaction when several queries must agree on one snapshot.
- Billions of rows across many dimensions fit a columnar engine better; measure plain Postgres with good indexes and
  rollup tables first.
