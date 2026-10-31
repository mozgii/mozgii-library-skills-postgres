-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Daily health check for PostgreSQL 17 and later. Read-only; run as a superuser or a member of pg_monitor.
-- Run: psql -X -d app -f health-check.sql
-- Each section prints rows only when something needs attention, except the summary at the top.

\echo '== Summary'
SELECT version() AS version,
       pg_size_pretty(pg_database_size(current_database())) AS db_size,
       (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend') AS client_connections,
       current_setting('max_connections') AS max_connections,
       pg_postmaster_start_time() AS started;

\echo '== Transactions open longer than 5 minutes'
SELECT pid, usename, application_name, state, now() - xact_start AS xact_age, left(query, 60) AS query
FROM pg_stat_activity
WHERE xact_start < now() - interval '5 minutes' AND backend_type = 'client backend'
ORDER BY xact_start;

\echo '== Databases above 500 million transaction ids old (wraparound)'
SELECT datname, age(datfrozenxid) AS xid_age
FROM pg_database WHERE age(datfrozenxid) > 500000000 ORDER BY 2 DESC;

\echo '== Tables with more than 20% dead rows (and over 10,000 dead)'
SELECT relid::regclass AS table_name, n_live_tup, n_dead_tup, last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000 AND n_dead_tup > 0.2 * (n_live_tup + n_dead_tup)
ORDER BY n_dead_tup DESC;

\echo '== Replication slots retaining more than 1 GB of WAL, or inactive'
SELECT slot_name, slot_type, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots
WHERE NOT active OR pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824;

\echo '== WAL archiving failures'
SELECT archived_count, failed_count, last_failed_wal, last_failed_time
FROM pg_stat_archiver WHERE failed_count > 0;

\echo '== Invalid indexes'
SELECT indexrelid::regclass AS index_name FROM pg_index WHERE NOT indisvalid;

\echo '== Checkpoints mostly requested (raise max_wal_size)'
SELECT num_timed, num_requested FROM pg_stat_checkpointer
WHERE num_requested > num_timed;

\echo '== Extensions with a newer version available'
SELECT name, installed_version, default_version
FROM pg_available_extensions
WHERE installed_version IS NOT NULL AND installed_version <> default_version;

\echo '== Settings waiting for a restart'
SELECT name, setting FROM pg_settings WHERE pending_restart;
