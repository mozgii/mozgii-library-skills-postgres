---
title: PostgreSQL WAL records, LSNs, full-page writes, checkpoints and crash recovery
author: MOZGII, Inc.
lang: en
---

# PostgreSQL WAL records, LSNs, full-page writes, checkpoints and crash recovery

This reference shows how the write-ahead log works on a running PostgreSQL 18.6 server: what a WAL record and an LSN
are, how WAL files are named, why the first change after a checkpoint is large, what a checkpoint does, and how
crash recovery replays WAL. It continues the `postgres-internals-architecture` skill; run its setup block first.
WAL disk growth, archiving and replication slots are operations topics (`postgres-operations`,
`postgres-backup-restore`, `postgres-replication-ha`).

## WAL records and the LSN

A WAL record describes a change to one or more pages: a resource manager (`Heap`, `Btree`, `Transaction`, `XLOG`),
a record type, the data, and optionally a full-page image (FPI). Its address is the LSN, a 64-bit byte position in
the endless WAL stream written as two hexadecimal halves (`0/1E941530`). Subtracting two LSNs gives bytes;
`pg_current_wal_lsn()` is the position written out, `pg_current_wal_insert_lsn()` the position inserted in memory.

```sql
SELECT pg_current_wal_lsn() AS written, pg_current_wal_insert_lsn() AS inserted,
       '0/16B3748'::pg_lsn - '0/16B3700'::pg_lsn AS bytes_between;          -- 72
SELECT file_name, file_offset FROM pg_walfile_name_offset(pg_current_wal_lsn());
```

## WAL segment files and their names

WAL is stored in 16 MB segment files (`wal_segment_size`, fixed at initdb) in `pg_wal/`. A name such as
`00000001000000000000001E` is the timeline (first 8 hexadecimal digits) followed by the segment number;
`pg_split_walfile_name` takes it apart. Old segments are recycled or removed after a checkpoint once nothing needs them (no replication slot,
no pending archive, within `min_wal_size` / `max_wal_size`).

```sql
SELECT name, pg_size_pretty(size) AS size FROM pg_ls_waldir() ORDER BY name DESC LIMIT 3;   -- pg_monitor role
SELECT * FROM pg_split_walfile_name(pg_walfile_name(pg_current_wal_lsn()));                -- segment_number, timeline_id
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('wal_segment_size', 'min_wal_size', 'max_wal_size', 'wal_level', 'wal_compression');
```

## Full-page writes after a checkpoint

Full-page writes protect against torn pages: a crash in the middle of an 8 kB page write can leave half old and half
new data, which WAL deltas cannot repair. So with `full_page_writes = on` (the default) the first change to each page
after a checkpoint logs the whole page; later changes to that page until the next checkpoint log only the delta. The
proof: the first update after `CHECKPOINT` writes a 3,660-byte image, the second update to the same page none.

```sql
CREATE TABLE ia.fpw (id int PRIMARY KEY, v int) WITH (fillfactor = 50);
INSERT INTO ia.fpw SELECT g, 0 FROM generate_series(1, 100) g;
SELECT count(*) FROM ia.fpw;                        -- sets hint bits now, so they do not add records later
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS a \gset
UPDATE ia.fpw SET v = 1 WHERE id = 1;
SELECT pg_current_wal_insert_lsn() AS b \gset
UPDATE ia.fpw SET v = 2 WHERE id = 2;
SELECT pg_current_wal_insert_lsn() AS c \gset
SELECT record_type, record_length, fpi_length FROM pg_get_wal_records_info(:'a', :'b');   -- HOT_UPDATE, fpi 3660
SELECT record_type, record_length, fpi_length FROM pg_get_wal_records_info(:'b', :'c');   -- HOT_UPDATE, fpi 0
```

The image omits the free hole in the middle of the page, so half-empty pages log smaller images. With data checksums
on (the initdb default since PostgreSQL 18), even setting a hint bit on a page for the first time after a checkpoint
logs an image (`XLOG FPI_FOR_HINT`), so a read-only query can write WAL. More frequent checkpoints mean more images;
this is the main reason not to shorten `checkpoint_timeout` without cause. `wal_compression` (`off` by default;
`pglz`, `lz4` or `zstd` when built in) compresses the images.

`pg_get_wal_stats` sums the WAL since the last checkpoint by resource manager, with the share of full-page images.

```sql
SELECT "resource_manager/record_type" AS rmgr, count, round(record_size_percentage) AS rec_pct, round(fpi_size_percentage) AS fpi_pct
FROM pg_get_wal_stats((SELECT redo_lsn FROM pg_control_checkpoint()), pg_current_wal_lsn()) WHERE count > 0;
SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal_bytes, wal_buffers_full FROM pg_stat_wal;
```

## What a checkpoint does

A checkpoint is a point from which recovery can start. The checkpointer records the current WAL position as the redo
point, writes every dirty shared buffer to the data files (spread over `checkpoint_completion_target`, 0.9 of the
interval), fsyncs them, writes a checkpoint record and updates `pg_control`. A checkpoint starts every
`checkpoint_timeout` (5 min) or sooner when WAL since the last one approaches `max_wal_size` (1 GB); the second kind
is counted as requested.

```sql
SELECT checkpoint_lsn, redo_lsn, redo_wal_file, checkpoint_time FROM pg_control_checkpoint();
SELECT num_timed, num_requested, num_done, write_time, sync_time, buffers_written FROM pg_stat_checkpointer;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), redo_lsn)) AS wal_to_replay_after_a_crash
FROM pg_control_checkpoint();
```

`num_requested` far above `num_timed` means `max_wal_size` is too small for the write rate (`postgres-operations`).
The background writer writes some dirty buffers between checkpoints (`pg_stat_bgwriter.buffers_clean`), so backends
seldom write pages themselves.

## Crash recovery replays WAL from the redo point

Crash recovery is WAL replay: after a crash, the startup process reads `pg_control`, starts at the last checkpoint's
redo point and re-applies every record until the end of valid WAL, then the checkpointer writes an end-of-recovery
checkpoint. Committed transactions whose data pages were never written are restored; uncommitted ones stay invisible
because their commit record is missing. This scratch cluster was stopped with `pg_ctl stop -m immediate` after
inserting 50,000 rows, with 80 MB of WAL past the redo point `0/B1D65D8`; its log on the next start was:

```text
LOG:  database system was interrupted; last known up at 2026-10-28 09:56:30 EDT
LOG:  database system was not properly shut down; automatic recovery in progress
LOG:  redo starts at 0/B1D65D8
LOG:  invalid record length at 0/10187D58: expected at least 24, got 0
LOG:  redo done at 0/10187D30 system usage: CPU: user: 0.10 s, system: 0.02 s, elapsed: 0.16 s
LOG:  checkpoint starting: end-of-recovery immediate wait
LOG:  database system is ready to accept connections
```

The `invalid record length` line is the normal end of WAL, not an error. Recovery time grows with the WAL since the
last checkpoint, which `max_wal_size` and `checkpoint_timeout` bound. `pg_stat_io` afterwards shows the startup
process's WAL reads.

```sql
SELECT backend_type, object, reads, pg_size_pretty(read_bytes) AS read
FROM pg_stat_io WHERE backend_type = 'startup' AND reads > 0;
```

## Commit durability: synchronous_commit and the WAL writer

A commit is durable when its commit record is flushed to disk. With `synchronous_commit = on` the backend waits for
that flush; with `off` it returns at once and the WAL writer flushes within `wal_writer_delay` (200 ms), so a crash
can lose the last fraction of a second of commits but never corrupts data. It can be set per transaction for
low-value writes.

```sql
BEGIN;
SET LOCAL synchronous_commit = off;
INSERT INTO ia.fpw VALUES (1000, 0);
COMMIT;
```

## Sources

- https://www.postgresql.org/docs/18/wal-intro.html
- https://www.postgresql.org/docs/18/wal-configuration.html
- https://www.postgresql.org/docs/18/wal-internals.html
- https://www.postgresql.org/docs/18/wal-reliability.html
- https://www.postgresql.org/docs/18/runtime-config-wal.html
- https://www.postgresql.org/docs/18/pgwalinspect.html
- https://www.postgresql.org/docs/18/functions-admin.html
- https://www.postgresql.org/docs/18/functions-info.html
- https://www.postgresql.org/docs/18/release-18.html
