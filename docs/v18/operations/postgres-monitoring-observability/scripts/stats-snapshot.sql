-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- One-shot statistics snapshot for PostgreSQL 18: I/O, WAL, checkpoints, sessions, waits, statements. Read-only.
-- Run: psql -X -v ON_ERROR_STOP=1 -d <database> -f stats-snapshot.sql
-- Needs pg_monitor (or superuser). The statements part runs only when pg_stat_statements is installed here.
\pset pager off

\echo '== Settings that decide what is collected'
SELECT name, setting FROM pg_settings
WHERE name IN ('shared_preload_libraries', 'compute_query_id', 'track_io_timing', 'track_wal_io_timing',
               'log_destination', 'log_min_duration_statement', 'log_lock_waits', 'log_connections')
ORDER BY name;

\echo '== Database counters'
SELECT datname, numbackends, xact_commit, xact_rollback, deadlocks, conflicts, temp_files,
       pg_size_pretty(temp_bytes) AS temp, checksum_failures, sessions_abandoned, sessions_fatal, sessions_killed,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS hit_pct, stats_reset
FROM pg_stat_database WHERE datname IS NOT NULL ORDER BY numbackends DESC;

\echo '== I/O by backend type, object and context (bytes columns are new in 18)'
SELECT backend_type, object, context, reads, pg_size_pretty(read_bytes) AS read, read_time,
       writes, pg_size_pretty(write_bytes) AS written, write_time, extends, hits, evictions, fsyncs
FROM pg_stat_io
WHERE coalesce(reads, 0) + coalesce(writes, 0) + coalesce(extends, 0) > 0
ORDER BY coalesce(read_bytes, 0) + coalesce(write_bytes, 0) DESC LIMIT 15;

\echo '== WAL and checkpoints'
SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal, wal_buffers_full, stats_reset FROM pg_stat_wal;
SELECT num_timed, num_requested, num_done, round(write_time / 1000) AS write_s, round(sync_time / 1000) AS sync_s,
       buffers_written, slru_written, stats_reset FROM pg_stat_checkpointer;

\echo '== Sessions by state'
SELECT backend_type, state, count(*) AS sessions, max(now() - xact_start) AS oldest_xact
FROM pg_stat_activity GROUP BY 1, 2 ORDER BY 3 DESC;

\echo '== Wait events of non-idle sessions'
SELECT a.wait_event_type, a.wait_event, count(*) AS sessions, max(w.description) AS meaning
FROM pg_stat_activity a
LEFT JOIN pg_wait_events w ON w.type = a.wait_event_type AND w.name = a.wait_event
WHERE a.state <> 'idle' AND a.pid <> pg_backend_pid()
GROUP BY 1, 2 ORDER BY 3 DESC;

\echo '== WAL written per client session (18)'
SELECT a.pid, a.usename, a.application_name, w.wal_bytes, w.wal_fpi
FROM pg_stat_activity a CROSS JOIN LATERAL pg_stat_get_backend_wal(a.pid) w
WHERE a.backend_type = 'client backend' ORDER BY w.wal_bytes DESC NULLS LAST LIMIT 10;

\echo '== Archiver and replication slots'
SELECT archived_count, failed_count, last_archived_wal, last_failed_wal, last_failed_time FROM pg_stat_archiver;
SELECT slot_name, slot_type, active, wal_status, inactive_since,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;

SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS has_pgss \gset
\if :has_pgss
\echo '== Top statements by total time'
SELECT queryid, calls, round(total_exec_time::numeric, 1) AS total_ms, round(mean_exec_time::numeric, 2) AS mean_ms,
       rows, shared_blks_read, temp_blks_written, wal_bytes,
       round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 1) AS pct_time,
       left(query, 60) AS query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
SELECT dealloc, stats_reset FROM pg_stat_statements_info;
\else
\echo '== pg_stat_statements is not installed in this database'
\endif
