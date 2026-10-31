---
name: postgres-internals-architecture
description: 'Explains how a PostgreSQL 18 server works underneath, shown with SQL on a running server: the process model (postmaster, client backends, background writer, checkpointer, walwriter, autovacuum launcher, io workers, logical replication launcher), shared memory (shared_buffers, the buffer manager and its clock sweep, ring buffers, WAL buffers, the lock table), per-backend memory (work_mem, hash_mem_multiplier, maintenance_work_mem, temp_buffers), the write-ahead log (records, LSN, full-page writes, checkpoints, crash recovery), the data directory and relation files, how a query flows through parse, analyze, rewrite, plan and execute, and why connections are expensive. Use when learning Postgres internals, sizing memory, reading pg_buffercache, pg_walinspect or pg_stat_io, or explaining checkpoints, WAL growth or connection cost.'
metadata:
  tags:
  - postgres
  - internals
  - architecture
  - shared-buffers
  - wal
  - checkpoints
  - processes
  - memory
---

# PostgreSQL internals: processes, memory, WAL and files

A PostgreSQL server (an instance) is one postmaster process that starts a set of background processes and one
backend process per client connection; they share one memory area holding the page cache (shared buffers), WAL
buffers and lock tables. Every change is written to the write-ahead log (WAL) before the data page, so a crash is
repaired by replaying WAL from the last checkpoint. Three rules follow: connections are processes, so pool them;
memory is `shared_buffers` once plus `work_mem` per sort or hash node per backend; and WAL volume, not table size,
drives checkpoints, replication and disk growth. Tuning and operations are in `postgres-operations`, vacuum in
`postgres-vacuum-bloat`, row storage in `postgres-internals-mvcc-storage`. WAL and recovery detail:
[references/wal-checkpoints-recovery.md](references/wal-checkpoints-recovery.md).

## Step 0: read the server version and the settings that shape it

Defaults such as `io_method` depend on the version and platform, so read them on your own server first.

```sql
SELECT version();
SELECT name, setting, unit, source FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem', 'max_connections', 'wal_buffers',
               'max_wal_size', 'checkpoint_timeout', 'io_method', 'io_workers', 'huge_pages');
```

## Setup for the examples

The examples were run on PostgreSQL 18.6 as a superuser on a scratch cluster with default settings. The inspection
extensions ship in contrib; `pg_buffercache` needs `pg_monitor`, `pg_walinspect` needs `pg_read_server_files`, and
`pg_ls_dir` and the eviction functions need a superuser.

```sql
CREATE EXTENSION IF NOT EXISTS pg_buffercache;
CREATE EXTENSION IF NOT EXISTS pg_walinspect;
CREATE SCHEMA ia;
CREATE TABLE ia.big AS SELECT g AS id, repeat('x', 200) AS pad FROM generate_series(1, 300000) g;
VACUUM (ANALYZE) ia.big;
```

## The process model: postmaster, backends and background processes

The postmaster is the first process of an instance: it owns the listening sockets, creates shared memory, starts
the background processes and starts a new backend for every connection. On Linux and macOS a child is made with
`fork()` and inherits the postmaster's state; on Windows (`EXEC_BACKEND`) each child is a new `postgres.exe`
started with `CreateProcess()` that re-attaches to shared memory and reloads its state, which makes connecting
slower there. The postmaster itself is not in `pg_stat_activity`.

| `backend_type` | Job |
|---|---|
| `client backend` | runs one session's queries |
| `checkpointer` | writes all dirty buffers at each checkpoint |
| `background writer` | writes some dirty buffers ahead of need, so backends rarely have to |
| `walwriter` | flushes WAL buffers for asynchronous commits (every `wal_writer_delay`, 200 ms) |
| `autovacuum launcher` / `autovacuum worker` | schedules / runs vacuum and analyze |
| `io worker` (18) | performs asynchronous reads when `io_method = worker` (default, `io_workers = 3`) |
| `logical replication launcher` | starts logical replication workers |
| `startup` | replays WAL in crash recovery and on standbys |
| `archiver`, `walsender`, `walreceiver`, `walsummarizer` | only when archiving, replication or `summarize_wal` are on |
| `parallel worker`, `background worker` | parallel query helpers, extension workers |

```sql
SELECT backend_type, count(*) FROM pg_stat_activity GROUP BY 1 ORDER BY 1;
SELECT pg_postmaster_start_time() AS started, current_setting('data_directory') AS pgdata;
```

The OS process list shows the same processes by title (`postgres: checkpointer`); `update_process_title` is on by
default except on Windows, where it defaults to off.

## Connections and why they are expensive

A connection is a process, so each one costs a process start, authentication, and a private cache of catalog
entries and plans that warms up from cold. `log_connections` in 18 accepts a list, and `setup_durations` logs the
total setup time, the fork time and the authentication time of every connection. The memory a backend holds is
visible in its memory contexts.

```sql
SELECT pg_size_pretty(sum(total_bytes)) AS this_backend_total,
       (SELECT pg_size_pretty(total_bytes) FROM pg_backend_memory_contexts
        WHERE name = 'CacheMemoryContext') AS catalog_cache
FROM pg_backend_memory_contexts;
SELECT name, setting FROM pg_settings WHERE name IN ('max_connections', 'log_connections');
```

`max_connections` (default 100) also sizes shared structures such as the lock table, which is why it needs a
restart. Hundreds of mostly idle connections waste memory and CPU; put a pooler in front (`postgres-connection-pooling`).

## Shared memory: shared buffers, WAL buffers and the lock table

Shared memory is allocated once at start and holds everything the processes share. `pg_shmem_allocations` lists the
parts; on this cluster the 128 MB of shared buffers dominate and `XLOG Ctl` holds the 4 MB of WAL buffers
(`wal_buffers = -1` means 1/32 of `shared_buffers`, between 64 kB and one 16 MB WAL segment).

```sql
SELECT name, pg_size_pretty(allocated_size) AS size
FROM pg_shmem_allocations ORDER BY allocated_size DESC LIMIT 6;
SELECT name, setting, unit, context FROM pg_settings
WHERE name IN ('shared_buffers', 'wal_buffers', 'max_locks_per_transaction', 'shared_memory_type',
               'dynamic_shared_memory_type', 'huge_pages', 'huge_pages_status');
```

The main segment uses `mmap` on Linux and macOS and Windows shared memory on Windows (`shared_memory_type`); parallel
query uses dynamic shared memory (`posix` on Linux and macOS, `windows` on Windows). `huge_pages = try` works only
on Linux and Windows; `huge_pages_status` says whether it took. The lock table holds
`max_locks_per_transaction` (64) object locks per process on average, not row locks, which live in the rows.

## The buffer manager: shared buffers and clock sweep

Every table or index page is read through shared buffers, 8 kB slots each with a header holding a pin count, a dirty
flag and a usage count. A backend that needs a free slot runs the clock sweep: a hand moves around the slots, skips
pinned ones, decrements each usage count it passes, and takes the first unpinned slot whose count is 0, writing it
first if dirty. Each access raises the count, up to 5, so hot pages survive several sweeps.

```sql
SELECT * FROM pg_buffercache_summary();
SELECT * FROM pg_buffercache_usage_counts();         -- usage_count 0..5
SELECT c.relname, count(*) AS buffers, sum(b.isdirty::int) AS dirty
FROM pg_buffercache b
JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
 AND b.reldatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
GROUP BY c.relname ORDER BY buffers DESC LIMIT 5;
```

A sequential scan of a table larger than a quarter of `shared_buffers` uses a small ring of buffers instead of the
whole cache, so one report cannot evict everything (`VACUUM` has its own ring, `vacuum_buffer_usage_limit`, 2 MB).
Proof: after evicting it, a full scan of the 69 MB demo table reads all 8,832 pages but leaves under a hundred of
them cached.

```sql
SELECT pg_size_pretty(pg_relation_size('ia.big')) AS size, buffers_evicted
FROM pg_buffercache_evict_relation('ia.big');
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM ia.big;   -- shared read=8832
SELECT count(*) AS pages_still_cached FROM pg_buffercache
WHERE relfilenode = pg_relation_filenode('ia.big') AND relforknumber = 0;            -- 94 on this run
```

## Per-backend memory: work_mem, hash_mem_multiplier, maintenance_work_mem and temp_buffers

Per-backend memory is taken on demand and freed after the operation, outside shared memory.

| Setting | Default on 18.6 | Limit applies to |
|---|---|---|
| `work_mem` | 4 MB | each sort, and each hash table divided by `hash_mem_multiplier`, per plan node, per process |
| `hash_mem_multiplier` | 2.0 | hash tables may use `work_mem` x this |
| `maintenance_work_mem` | 64 MB | `CREATE INDEX`, `VACUUM`, `ALTER TABLE ADD FOREIGN KEY` |
| `autovacuum_work_mem` | -1 (use `maintenance_work_mem`) | each autovacuum worker |
| `temp_buffers` | 8 MB | temporary tables of one session; fixed after first use |
| `logical_decoding_work_mem` | 64 MB | each logical decoding connection |

A sort that does not fit spills to temporary files; the plan says which happened.

```sql
SET max_parallel_workers_per_gather = 0;
SET work_mem = '64kB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT id FROM ia.big ORDER BY pad DESC, id LIMIT 100000 OFFSET 1;     -- Sort Method: external merge  Disk: 64072kB
SET work_mem = '256MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT id FROM ia.big ORDER BY pad DESC, id LIMIT 100000 OFFSET 1;     -- Sort Method: top-N heapsort  Memory: 31926kB
```

The `LIMIT` lets the sort keep only the top rows, which is why the second plan says `top-N heapsort`; the same `ORDER BY`
with no `LIMIT` says `quicksort  Memory: 77914kB`.

The worst case for one query is `work_mem` times its sort and hash nodes, times parallel workers plus one, times
concurrent sessions; size `work_mem` from that product, and raise it per role or per transaction.

## The write-ahead log in brief

The WAL is a sequence of records, each describing one change to one or more pages, addressed by a byte position
called the LSN (log sequence number). A change is logged before its page may be written, and a commit returns only
after its commit record is flushed (with `synchronous_commit = on`). After each checkpoint, the first change to a
page logs a full-page image, so a page torn by a crash can be restored whole. `pg_walinspect` reads the records.

```sql
CREATE TABLE ia.w (id int PRIMARY KEY, v text);
SELECT pg_current_wal_insert_lsn() AS before \gset
INSERT INTO ia.w VALUES (1, 'hello');
SELECT pg_current_wal_insert_lsn() AS after \gset
SELECT resource_manager, record_type, record_length, fpi_length, description
FROM pg_get_wal_records_info(:'before', :'after');     -- Heap INSERT+INIT, Btree NEWROOT, Btree INSERT_LEAF, Transaction COMMIT
```

Checkpoints, the redo point, full-page writes after a checkpoint, and a real crash recovery log are in
[references/wal-checkpoints-recovery.md](references/wal-checkpoints-recovery.md).

## Crash recovery after a power loss: replaying WAL from the last checkpoint

After a crash or a power loss, Postgres gets committed data back on its next start by replaying WAL from the last
checkpoint. The `startup` process reads `pg_control`, starts at the last checkpoint's redo point and re-applies every
WAL record until the end of valid WAL; the log says `database system was not properly shut down; automatic recovery
in progress`. A commit returned only after its commit record was flushed, so committed transactions whose data pages
were never written are restored; uncommitted ones stay invisible because their commit record is missing. Full-page
images repair pages torn by the crash. Recovery time grows with the WAL since the last checkpoint, which
`max_wal_size` and `checkpoint_timeout` bound.

## The data directory and relation files

The data directory (`PGDATA`) holds one subdirectory per database under `base/` (named by database OID), cluster-wide
catalogs in `global/`, WAL in `pg_wal/`, commit status in `pg_xact/`, and the control file `global/pg_control`.
Each table or index is a file named by its relfilenode, split into 1 GB segments (`16397`, `16397.1`, ...), with
the free space map in `<relfilenode>_fsm` and the visibility map in `<relfilenode>_vm`.

```sql
SELECT pg_ls_dir AS entry FROM pg_ls_dir('.') ORDER BY 1;          -- superuser only
SELECT pg_relation_filepath('ia.big') AS heap_file, pg_relation_filepath('pg_database') AS shared_catalog;
SELECT pg_relation_filenode('ia.w') AS before_truncate;
TRUNCATE ia.w;
SELECT pg_relation_filenode('ia.w') AS after_truncate;             -- a new file: the old one is dropped at commit
```

| Directory | Holds |
|---|---|
| `base/<db oid>/` | tables, indexes, their `_fsm` and `_vm` forks |
| `global/` | shared catalogs (`pg_database`, roles), `pg_control`, `pg_filenode.map` |
| `pg_wal/` | 16 MB WAL segment files, named by timeline and position |
| `pg_xact/`, `pg_subtrans/`, `pg_multixact/` | commit status, subtransaction parents, shared row locks |
| `pg_stat/` | statistics saved at clean shutdown |
| `pg_tblspc/` | links to tablespaces |
| `postmaster.pid` | lock file with PID, port and socket; absent after shutdown |

Never edit or delete files there by hand; a removed WAL segment or `pg_xact` file loses data.

## How a query flows: parse, analyze, rewrite, plan and execute

A query passes five stages in its backend. The parser checks syntax and builds a raw tree; analysis looks up names
in the catalogs and resolves types and operators; the rewriter expands views and rules; the planner picks the
cheapest plan; the executor runs it, pulling rows from the plan's top node. Each stage has its own errors.

| Stage | Error that proves it | Visible with |
|---|---|---|
| parse | `syntax error at or near` | `log_parser_stats` |
| analyze | `relation "x" does not exist`, `operator does not exist` | `debug_print_parse` |
| rewrite | view replaced by its query | `debug_print_rewritten`, `EXPLAIN` shows base tables |
| plan | | `EXPLAIN`, `log_planner_stats`, `Planning Time` |
| execute | `division by zero`, constraint violations | `EXPLAIN ANALYZE`, `log_executor_stats` |

```sql
CREATE VIEW ia.small_ids AS SELECT id FROM ia.big WHERE id < 10;
EXPLAIN (COSTS OFF) SELECT * FROM ia.small_ids;             -- no view in the plan: the rewriter put big there
PREPARE q(int) AS SELECT pad FROM ia.big WHERE id = $1;     -- parsed and analyzed once
EXECUTE q(5);                                               -- planned and executed
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;   -- custom_plans = 1
```

How the planner chooses is in `postgres-internals-planner`.

## Verify a memory and WAL picture of a server

Check a sizing or an explanation against the running server, not against the formula.

```sql
SELECT * FROM pg_buffercache_summary();                 -- are shared buffers used, and how many are dirty
SELECT num_timed, num_requested, write_time, sync_time FROM pg_stat_checkpointer;    -- mostly timed
SELECT backend_type, context, sum(reads) AS reads, sum(writes) AS writes
FROM pg_stat_io GROUP BY 1, 2 ORDER BY writes DESC NULLS LAST LIMIT 10;
SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal FROM pg_stat_wal;
SELECT pg_size_pretty(sum(temp_bytes)) AS temp_files FROM pg_stat_database;          -- work_mem too small when it grows
```

Run them again after a busy hour and compare: the differences are the load.

## Gotchas

These are the internals surprises seen most often, each with its cause and fix.

1. **A setting change does nothing.** Its `context` is `postmaster` (`shared_buffers`, `max_connections`,
   `io_method`, `wal_level`): it needs a restart. Check `pending_restart` in `pg_settings`.
2. **The server runs out of memory under load.** `work_mem` multiplied by nodes, workers and sessions exceeded RAM.
   Lower the global value and raise it per query.
3. **Connecting is slow on Windows.** Each backend is a fresh process that rebuilds its state. Pool connections.
4. **`pg_wal` keeps growing.** WAL is kept for an inactive replication slot, failed archiving, or `max_wal_size`.
   Never delete segments; fix the cause (`postgres-operations`).
5. **`permission denied for function pg_ls_dir`.** It is superuser-only by default; grant `EXECUTE` or use
   `pg_ls_waldir()` with `pg_monitor`.

## Checklist

Check these points when you size or explain a server.

- [ ] `shared_buffers` is sized for the machine (about 25% of RAM on a dedicated server) and restart-only.
- [ ] Peak per-query memory (`work_mem` x nodes x processes) fits beside shared buffers.
- [ ] Connections go through a pool; `max_connections` stays in the low hundreds.
- [ ] Checkpoints are mostly timed, not requested (`pg_stat_checkpointer`).
- [ ] Nobody touches `PGDATA` files by hand.

## Anti-patterns when reasoning about internals

| Do not | Do this instead |
|---|---|
| set `work_mem` globally for one big query | set it per role or per transaction |
| hold hundreds of idle connections | a pooler in front |
| size `shared_buffers` to most of RAM | about 25% on a dedicated server, then measure |
| edit or delete files in `PGDATA` | SQL and the server's own tools |
| turn off `full_page_writes` to cut WAL | keep it on, and tune checkpoints |
| judge a setting from a formula alone | read `pg_stat_io`, `pg_buffercache` and the plans |

## See also

- `postgres-operations`: tuning and configuration.
- `postgres-vacuum-bloat`: vacuum and freezing.
- `postgres-internals-mvcc-storage`: pages, tuples and visibility.
- `postgres-internals-planner`: statistics and plan choice.
- `postgres-connection-pooling`: why and how to pool.
- `postgres-os-kernel-tuning`: huge pages and disks.

## Sources

- https://www.postgresql.org/docs/18/connect-estab.html
- https://www.postgresql.org/docs/18/glossary.html
- https://www.postgresql.org/docs/18/monitoring-stats.html
- https://www.postgresql.org/docs/18/runtime-config-resource.html
- https://www.postgresql.org/docs/18/runtime-config-wal.html
- https://www.postgresql.org/docs/18/runtime-config-logging.html
- https://www.postgresql.org/docs/18/runtime-config-locks.html
- https://www.postgresql.org/docs/18/storage-file-layout.html
- https://www.postgresql.org/docs/18/pgbuffercache.html
- https://www.postgresql.org/docs/18/pgwalinspect.html
- https://www.postgresql.org/docs/18/query-path.html
- https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/storage/buffer/README
- https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/postmaster/launch_backend.c
