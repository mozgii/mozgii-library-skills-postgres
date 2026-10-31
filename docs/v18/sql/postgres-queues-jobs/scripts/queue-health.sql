-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Health report for a SKIP LOCKED queue table shaped like jobs.job in the skill.
-- Usage: psql -X -v ON_ERROR_STOP=1 -v queue_table=jobs.job -f queue-health.sql
-- Read-only. Tested on PostgreSQL 18.6.

\if :{?queue_table}
\else
  \set queue_table jobs.job
\endif

\echo '== jobs per queue and state, oldest ready job'
SELECT queue, state, count(*) AS jobs,
       max(now() - run_at) FILTER (WHERE state = 'ready' AND run_at <= now()) AS oldest_ready_wait,
       count(*) FILTER (WHERE state = 'running' AND lease_until < now()) AS expired_leases
FROM :queue_table
GROUP BY queue, state
ORDER BY queue, state;

\echo '== dead jobs by kind and last error'
SELECT kind, count(*) AS dead, left(max(last_error), 120) AS sample_error
FROM :queue_table WHERE state = 'dead'
GROUP BY kind ORDER BY dead DESC LIMIT 20;

\echo '== table size, dead rows and vacuum'
SELECT relid::regclass AS queue_table, n_live_tup, n_dead_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       last_autovacuum, autovacuum_count
FROM pg_stat_user_tables WHERE relid = :'queue_table'::regclass;

\echo '== oldest open transactions (they stop vacuum on every table)'
SELECT pid, usename, state, now() - xact_start AS xact_age, left(query, 80) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL AND pid <> pg_backend_pid()
ORDER BY xact_start LIMIT 5;

\echo '== LISTEN/NOTIFY queue usage (fraction of max_notify_queue_pages)'
SELECT pg_notification_queue_usage() AS notify_queue_usage;
