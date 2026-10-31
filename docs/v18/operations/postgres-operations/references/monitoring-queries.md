---
title: PostgreSQL monitoring queries
author: MOZGII, Inc.
lang: en
---

# PostgreSQL monitoring queries

This reference collects read-only queries for the numbers worth graphing and alerting on. All work on PostgreSQL 16
and later; most on older versions too. The `pg_monitor` role can run them without superuser.

## Contents

The sections of this reference on postgreSQL monitoring queries:

1. Connections by state
2. Cache hit ratio and I/O
3. Table sizes and growth
4. Autovacuum progress and dead tuples
5. What holds back vacuum: find the session, slot or prepared transaction (the xmin horizon)
6. Wraparound age per table
7. Checkpoints and background writes
8. WAL archiving and replication
9. Alert thresholds to start from

## Connections by state

Connection counts by state show pool sizing and stuck sessions.

```sql
SELECT state, count(*) FROM pg_stat_activity
WHERE backend_type = 'client backend' GROUP BY state;
SELECT current_setting('max_connections')::int AS max_connections;
```

Alert when client connections pass 80% of `max_connections`, or `idle in transaction` sessions last minutes.

## Cache hit ratio and I/O

The share of reads served from `shared_buffers`; below about 99% on an OLTP database suggests too little memory or
a missing index that forces large scans.

```sql
SELECT datname, round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS hit_pct,
       xact_commit, xact_rollback, deadlocks, temp_files, pg_size_pretty(temp_bytes) AS temp
FROM pg_stat_database WHERE datname = current_database();

SELECT backend_type, object, context, reads, read_bytes, writes, write_bytes, extends
FROM pg_stat_io WHERE reads > 0 OR writes > 0 ORDER BY reads DESC LIMIT 10;   -- read_bytes etc. PG 18
```

## Table sizes and growth

Sizes per table, with indexes and TOAST, to graph growth over time.

```sql
SELECT relid::regclass AS table_name,
       pg_size_pretty(pg_total_relation_size(relid)) AS total,
       pg_size_pretty(pg_relation_size(relid)) AS heap,
       pg_size_pretty(pg_indexes_size(relid)) AS indexes,
       n_live_tup, n_dead_tup
FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 20;
```

## Autovacuum progress and dead tuples

Tables with many dead rows and no recent vacuum show autovacuum falling behind.

```sql
SELECT relid::regclass AS table_name, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum, last_autoanalyze, autovacuum_count
FROM pg_stat_user_tables WHERE n_dead_tup > 10000 ORDER BY n_dead_tup DESC LIMIT 20;

SELECT p.pid, p.relid::regclass AS table_name, p.phase, p.heap_blks_scanned, p.heap_blks_total,
       now() - a.xact_start AS running
FROM pg_stat_progress_vacuum p JOIN pg_stat_activity a USING (pid);
```

## What holds back vacuum: find the session, slot or prepared transaction (the xmin horizon)

When something is holding back vacuum, dead rows stay after every vacuum run and tables keep growing. Vacuum cannot
remove rows newer than the oldest snapshot any session, slot or prepared transaction still needs; this query finds
the oldest holders.

```sql
SELECT 'session' AS holder, pid::text AS id, age(backend_xmin) AS xmin_age FROM pg_stat_activity WHERE backend_xmin IS NOT NULL
UNION ALL
SELECT 'slot', slot_name, age(xmin) FROM pg_replication_slots WHERE xmin IS NOT NULL
UNION ALL
SELECT 'slot catalog', slot_name, age(catalog_xmin) FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL
UNION ALL
SELECT 'prepared xact', gid, age(transaction) FROM pg_prepared_xacts
ORDER BY xmin_age DESC NULLS LAST LIMIT 10;
```

Release the oldest holder: end the session (`pg_terminate_backend(pid)`), drop a slot nobody reads
(`pg_drop_replication_slot`), or finish the prepared transaction (`COMMIT PREPARED` / `ROLLBACK PREPARED`).

## Wraparound age per table

The tables closest to forced anti-wraparound vacuum.

```sql
SELECT c.oid::regclass AS table_name, age(c.relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c
WHERE c.relkind IN ('r', 'm', 't')
ORDER BY age(c.relfrozenxid) DESC LIMIT 10;
```

## Checkpoints and background writes

Requested checkpoints that outnumber timed ones mean WAL fills faster than `max_wal_size` allows.

```sql
SELECT num_timed, num_requested, num_done, write_time, sync_time, buffers_written, stats_reset
FROM pg_stat_checkpointer;                 -- PG 17+; earlier versions: pg_stat_bgwriter
```

## WAL archiving and replication

A failing archive or a lagging replica both make `pg_wal` grow.

```sql
SELECT archived_count, failed_count, last_archived_wal, last_archived_time, last_failed_time
FROM pg_stat_archiver;
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
```

## Alert thresholds to start from

These starting thresholds catch most incidents early; tune them to your workload.

| Signal | Warn | Page |
|---|---|---|
| Client connections / `max_connections` | 70% | 90% |
| Oldest transaction | 5 min | 30 min |
| Database `age(datfrozenxid)` | 500 million | 1 billion |
| Replication byte lag | 1 GB | 10 GB |
| Slot retained WAL | 10 GB | 50% of free disk |
| `pg_stat_archiver.failed_count` increase | any | sustained 15 min |
| Disk used | 75% | 90% |
| Newest successful backup | older than schedule + 50% | older than 2 schedules |
