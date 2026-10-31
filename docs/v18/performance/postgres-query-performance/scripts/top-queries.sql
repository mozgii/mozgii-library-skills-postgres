-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Top queries report from pg_stat_statements (PostgreSQL 14 and later). Read-only.
-- Needs: shared_preload_libraries = 'pg_stat_statements' and CREATE EXTENSION pg_stat_statements.
-- Run: psql -X -d app -f top-queries.sql

\echo '== Top 15 by total execution time'
SELECT round(total_exec_time::numeric) AS total_ms,
       calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       round((100 * total_exec_time / nullif(sum(total_exec_time) OVER (), 0))::numeric, 1) AS pct,
       rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 15;

\echo '== Top 10 by disk reads (shared blocks read from outside the buffer cache)'
SELECT shared_blks_read, shared_blks_hit,
       round((100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0))::numeric, 1) AS hit_pct,
       calls, left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS query
FROM pg_stat_statements
ORDER BY shared_blks_read DESC
LIMIT 10;

\echo '== Top 10 by temp files written (sorts and hashes spilling: consider work_mem or an index)'
SELECT temp_blks_written, calls, round(mean_exec_time::numeric, 2) AS mean_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS query
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 10;

\echo '== Top 10 by WAL generated (write-heavy statements)'
SELECT pg_size_pretty(wal_bytes::bigint) AS wal, calls,
       left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS query
FROM pg_stat_statements
ORDER BY wal_bytes DESC
LIMIT 10;

\echo '== Measurement window'
SELECT stats_reset FROM pg_stat_statements_info;
