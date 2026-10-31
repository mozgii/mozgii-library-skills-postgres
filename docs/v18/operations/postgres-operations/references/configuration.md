---
title: PostgreSQL configuration baseline
author: MOZGII, Inc.
lang: en
---

# PostgreSQL configuration baseline

This reference gives starting values for `postgresql.conf` on a dedicated database server with SSD storage, with the
reason for each. Measure and adjust; never copy values across servers of different sizes without thinking.

## Contents

The sections of this reference on postgreSQL configuration baseline:

1. Memory settings
2. I/O and asynchronous I/O in PostgreSQL 18
3. WAL and checkpoints
4. Planner settings
5. Autovacuum settings
6. Logging settings
7. Connections and timeouts

## 1. Memory settings

Memory settings split RAM between PostgreSQL's own cache, the OS page cache and per-query work areas.

| Setting | Start at | Why |
|---|---|---|
| `shared_buffers` | 25% of RAM (8 GB on 32 GB) | Postgres cache; the OS cache holds the rest. Restart required |
| `effective_cache_size` | 50-75% of RAM | planner's estimate of total cache; allocates nothing |
| `work_mem` | 16-64 MB | per sort or hash node per connection; raise per query |
| `maintenance_work_mem` | 1-2 GB | `VACUUM`, `CREATE INDEX`, HNSW builds |
| `huge_pages` | `try` (Linux: configure `vm.nr_hugepages`) | fewer page table entries for large `shared_buffers` |

A rough ceiling for `work_mem`: (RAM - `shared_buffers`) / (`max_connections` × 3).

## 2. I/O and asynchronous I/O in PostgreSQL 18

PostgreSQL 18 adds an asynchronous I/O subsystem that reads ahead for sequential scans, bitmap heap scans and
vacuum.

| Setting | Value | Notes |
|---|---|---|
| `io_method` | `worker` (default) | `io_uring` on Linux builds compiled with liburing; `sync` for the old behaviour. Restart required |
| `io_workers` | 3 (default); raise on many-core servers with high I/O | used by `io_method = worker` |
| `effective_io_concurrency` | 16 (PG 18 default); 64-256 on fast NVMe | concurrent prefetch requests |
| `maintenance_io_concurrency` | 16 (PG 18 default) | for maintenance work |
| `random_page_cost` | 1.1 on SSD (default 4 assumes spinning disks) | lets the planner pick index scans |
| `track_io_timing` | `on` | I/O time in `EXPLAIN (BUFFERS)` and `pg_stat_io`; small overhead on modern systems |

## 3. WAL and checkpoints

WAL settings trade crash recovery time and disk use against write throughput.

| Setting | Start at | Why |
|---|---|---|
| `wal_level` | `replica` (default); `logical` for logical replication | restart required |
| `max_wal_size` | 4-16 GB | fewer forced checkpoints under write load |
| `min_wal_size` | 1-2 GB | keeps recycled WAL files ready |
| `checkpoint_timeout` | 15min | longer spacing, longer crash recovery |
| `checkpoint_completion_target` | 0.9 (default) | spreads checkpoint writes |
| `wal_compression` | `lz4` or `zstd` | less WAL for full-page images |
| `wal_buffers` | -1 (auto) | |
| `synchronous_commit` | `on`; `off` per transaction for disposable writes | `off` risks losing the last commits on a crash, never corruption |

## 4. Planner settings

Planner settings describe the hardware; they do not force plans.

| Setting | Value |
|---|---|
| `default_statistics_target` | 100 (default); raise per column instead of globally |
| `jit` | `off` for OLTP (JIT compile time often exceeds the gain on short queries); leave on for analytics |
| `max_parallel_workers_per_gather` | 2-4 |
| `max_parallel_workers` | number of cores |
| `max_worker_processes` | cores + extensions' needs (restart) |

## 5. Autovacuum settings

The autovacuum defaults are timid for large, busy databases.

| Setting | Start at |
|---|---|
| `autovacuum_max_workers` | 4-8 (PG 18: up to `autovacuum_worker_slots` without restart) |
| `autovacuum_vacuum_cost_limit` | 1000-2000 |
| `autovacuum_vacuum_cost_delay` | 2ms (default) |
| `autovacuum_naptime` | 30s |
| `autovacuum_vacuum_scale_factor` | 0.05 globally, lower per large table |
| `autovacuum_vacuum_insert_scale_factor` | 0.05 |
| `autovacuum_vacuum_max_threshold` (PG 18) | 100,000,000 (default) or lower |

## 6. Logging settings

Logs should name slow statements, lock waits and temp file use, in a format a log tool can parse.

```ini
logging_collector = on
log_destination = 'jsonlog'              # PG 15+; or 'stderr' / 'csvlog'
log_line_prefix = '%m [%p] %q%u@%d %a '  # used by stderr format
log_min_duration_statement = '1s'
log_lock_waits = on
log_temp_files = '100MB'
log_autovacuum_min_duration = '10s'
log_checkpoints = on                     # default on since PG 15
log_connections = 'authentication,authorization'   # PG 18 list form; earlier: on
log_statement = 'ddl'
```

## 7. Connections and timeouts

Connection limits protect memory; timeouts protect against stuck sessions.

| Setting | Value |
|---|---|
| `max_connections` | 100-300; pool in front for more clients (`postgres-connection-pooling`) |
| `superuser_reserved_connections` | 3 (default) |
| `idle_in_transaction_session_timeout` | 1-5 min (or per role) |
| `statement_timeout` | per role, not global (it also hits maintenance and migrations) |
| `tcp_keepalives_idle` | 60 |
| `password_encryption` | `scram-sha-256` (default) |
