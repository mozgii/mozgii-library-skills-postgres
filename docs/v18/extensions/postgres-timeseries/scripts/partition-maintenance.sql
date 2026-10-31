-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Daily partition maintenance for a table partitioned BY RANGE on a timestamptz column.
-- Creates the partitions for today and the next :ahead days (UTC bounds, named <table>_YYYYMMDD),
-- then detaches and drops partitions whose upper bound is older than :keep_days days.
--
-- Run it once a day, outside a transaction (DETACH ... CONCURRENTLY refuses transaction blocks):
--   psql -X -v ON_ERROR_STOP=1 -v parent=metrics.readings -v ahead=7 -v keep_days=90 -f partition-maintenance.sql
-- The table must have no DEFAULT partition. Tested on PostgreSQL 18.6.

\if :{?parent}
\else
  \echo 'set -v parent=<schema.table>'
  \quit
\endif
\if :{?ahead}
\else
  \set ahead 7
\endif
\if :{?keep_days}
\else
  \set keep_days 90
\endif

SET lock_timeout = '5s';

-- 1. create missing partitions ahead of time
SELECT format(
         'CREATE TABLE IF NOT EXISTS %I.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
         n.nspname,
         c.relname || '_' || to_char(d, 'YYYYMMDD'),
         c.oid::regclass,
         d::timestamp AT TIME ZONE 'UTC',
         (d + 1)::timestamp AT TIME ZONE 'UTC')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL generate_series(
       (now() AT TIME ZONE 'UTC')::date,
       (now() AT TIME ZONE 'UTC')::date + :ahead,
       interval '1 day') AS g(day)
CROSS JOIN LATERAL (SELECT g.day::date AS d) AS x
WHERE c.oid = :'parent'::regclass
\gexec

-- 2. detach and drop expired partitions, one statement at a time
SELECT format('ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY', i.inhparent::regclass, c.oid::regclass),
       format('DROP TABLE %s', c.oid::regclass)
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = :'parent'::regclass
  AND (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz
      <= now() - make_interval(days => :keep_days)
ORDER BY c.relname
\gexec

-- 3. report what is left
SELECT count(*) AS partitions,
       min(c.relname) AS oldest,
       max(c.relname) AS newest
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = :'parent'::regclass;
