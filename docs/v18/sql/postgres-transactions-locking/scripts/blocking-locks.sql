-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Blocking report for PostgreSQL 14 and later. Read-only.
-- Run: psql -X -d app -f blocking-locks.sql
-- Shows each waiting session with the session blocking it, then long transactions and idle-in-transaction sessions.

\echo '== Waiting sessions and their blockers'
SELECT w.pid                         AS waiting_pid,
       w.usename                     AS waiting_user,
       now() - w.query_start         AS waiting_for,
       left(w.query, 70)             AS waiting_query,
       b.pid                         AS blocking_pid,
       b.usename                     AS blocking_user,
       b.state                       AS blocking_state,
       now() - b.xact_start          AS blocking_xact_age,
       left(b.query, 70)             AS blocking_query
FROM pg_stat_activity w
CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS bp(pid)
JOIN pg_stat_activity b ON b.pid = bp.pid
ORDER BY w.query_start;

\echo '== Transactions open longer than 5 minutes'
SELECT pid, usename, application_name, state,
       now() - xact_start AS xact_age, left(query, 70) AS last_query
FROM pg_stat_activity
WHERE xact_start < now() - interval '5 minutes'
ORDER BY xact_start;

\echo '== Idle in transaction'
SELECT pid, usename, application_name,
       now() - state_change AS idle_for, left(query, 70) AS last_query
FROM pg_stat_activity
WHERE state LIKE 'idle in transaction%'
ORDER BY state_change;

\echo '== Prepared transactions (hold locks until committed or rolled back)'
SELECT gid, prepared, owner, database FROM pg_prepared_xacts;

\echo 'To stop a blocker: SELECT pg_cancel_backend(<pid>);  or  SELECT pg_terminate_backend(<pid>);'
