---
title: Reclaiming space in PostgreSQL with VACUUM FULL, pg_repack and pg_squeeze
author: MOZGII, Inc.
lang: en
---

# Reclaiming space in PostgreSQL with VACUUM FULL, pg_repack and pg_squeeze

This reference covers the rewrite tools that return a bloated table's space to the operating system, how to install
and run each on PostgreSQL 18.6, and how to recover from a failed concurrent index rebuild. Remove the cause of the
bloat first (the xmin horizon holder, or autovacuum settings); a rewrite of a table that keeps bloating buys a week.

## Contents

The sections of this reference on reclaiming space:

1. Choosing a rewrite method
2. VACUUM FULL and CLUSTER
3. pg_repack: install and run
4. pg_squeeze: install, run and schedule
5. Disk space needed for a rewrite
6. Recovering from a failed REINDEX CONCURRENTLY

## Choosing a rewrite method

A rewrite method is chosen by how long the table may be locked and what you can install.

| Situation | Method |
|---|---|
| maintenance window, small table, nothing extra installed | `VACUUM FULL` |
| live table, managed service that offers pg_repack | pg_repack |
| live table, you control `postgresql.conf`, want scheduled runs without a client | pg_squeeze |
| only the indexes are bloated | `REINDEX INDEX CONCURRENTLY`, or `pg_repack --only-indexes` |
| table without a primary key | `VACUUM FULL`, or add a key; pg_squeeze also accepts `REPLICA IDENTITY USING INDEX` |

## VACUUM FULL and CLUSTER

`VACUUM FULL` writes a compact copy of the table and its indexes and drops the old files; `CLUSTER` does the same
in index order. Both hold `ACCESS EXCLUSIVE` on the table for the whole run, so even `SELECT` waits.

```sql
SET lock_timeout = '5s';          -- fail fast instead of queueing every other session behind the lock
VACUUM (FULL, VERBOSE) app.orders;
```

Measured on 18.6, `VACUUM FULL` of a 200,000-row table took under a second; on hundreds of gigabytes it takes hours,
and every query on the table waits for it.

## pg_repack: install and run

pg_repack (current release 1.5.3, supports PostgreSQL 9.5 to 19) is an extension plus a client program. It copies
the table, logs concurrent changes with a trigger, replays them, and swaps the files in the catalog. It holds
`ACCESS EXCLUSIVE` only briefly at the start and at the swap; during the copy it holds `SHARE UPDATE EXCLUSIVE`, so
reads and writes continue but DDL on the table waits.

Install it per platform:

- Debian and Ubuntu (PGDG repository): `apt install postgresql-18-repack`.
- macOS and Windows: build from source with PGXS, or use a distribution that ships it; it is not in Postgres.app.
- Managed services: check the provider's extension list for `pg_repack`; where it is offered, run the client from a
  host that can reach the database, with `-k` as the table owner.

Then create the extension in the database and run the client of the same version:

```bash
psql -d app -c 'CREATE EXTENSION pg_repack'
pg_repack --dry-run --table=app.events -d app
pg_repack --table=app.events --jobs=2 --wait-timeout=60 -d app
pg_repack --table=app.events --only-indexes -d app
pg_repack --table=app.events --order-by='created_at' -d app      # rewrite in a chosen order
```

| Flag | Meaning |
|---|---|
| `-t`, `--table` | one table (repeat for more); `-I`, `--parent-table` takes a parent and its children |
| `-j`, `--jobs` | parallel jobs for the index builds of each table |
| `-x`, `--only-indexes` | rebuild only the indexes (`CREATE INDEX CONCURRENTLY` and a swap) |
| `-n`, `--no-order` | plain compaction, like `VACUUM FULL`; `-o`, `--order-by` sorts by columns |
| `-T`, `--wait-timeout` | seconds to wait for conflicting locks before cancelling the blockers |
| `-D`, `--no-kill-backend` | when the timeout passes, give up instead of cancelling other sessions |
| `-k`, `--no-superuser-check` | run as the table owner instead of a superuser (managed services) |
| `--apply-count`, `--switch-threshold` | how many logged changes to replay per transaction, and when to swap |
| `-N`, `--dry-run` | print what would be repacked |

pg_repack refuses temporary tables, cannot cluster by a GiST index, and stops on an invalid index unless
`--no-error-on-invalid-index` is given (stopping is the default since 1.5.2). Since 1.5.3 it holds
`SHARE UPDATE EXCLUSIVE` during a full-table repack instead of `ACCESS SHARE`.

## pg_squeeze: install, run and schedule

pg_squeeze (current release 1.9.4) is a server-side extension from Cybertec that uses logical decoding instead of
triggers to capture concurrent changes, so no client stays connected and runs can be scheduled.

Server settings it needs, then a restart:

```ini
shared_preload_libraries = 'pg_squeeze'         # add to the existing list
wal_level = logical                             # needed before PostgreSQL 19
max_replication_slots = 10                      # one free slot per running squeeze
output_plugin_libraries = 'pgoutput, test_decoding, pg_squeeze'   # PostgreSQL 18.6 and later minors
```

`output_plugin_libraries` was added in the 18.6 minor release (and the matching minors of older branches) to fix
CVE-2026-6471; its default allows only `pgoutput` and `test_decoding`. Without `pg_squeeze` in it, a squeeze fails
with `library "pg_squeeze" may not be used as an output plugin`. Its context is `superuser`, so a reload applies it.

A manual squeeze and its log:

```sql
CREATE EXTENSION pg_squeeze;
SET squeeze.max_xlock_time TO 100;              -- milliseconds the final exclusive lock may be held
SELECT squeeze.squeeze_table('app', 'events');
SELECT tabschema, tabname, started, finished, ins_initial FROM squeeze.log ORDER BY finished DESC LIMIT 5;
SELECT * FROM squeeze.errors ORDER BY occurred DESC LIMIT 5;
```

A schedule: register the table in `squeeze.tables` with a cron-like `schedule` (minutes, hours, days of month,
months, days of week) and start the scheduler worker with `squeeze.start_worker()`, or set
`squeeze.worker_autostart = 'app'` and `squeeze.worker_role` so it starts with the server.

```sql
INSERT INTO squeeze.tables (tabschema, tabname, schedule, free_space_extra)
VALUES ('app', 'events', ('{30}', '{2}', NULL, NULL, '{0, 6}'), 30);   -- 02:30 on Sundays and Saturdays
SELECT squeeze.start_worker();
```

`free_space_extra` (default 50) is the share of free space beyond what `fillfactor` leaves that makes a table
eligible; `min_size` (default 8 MB) skips small tables. When upgrading a cluster that has pg_squeeze, put it in
`shared_preload_libraries` of the new cluster before `pg_upgrade`, or the upgrade fails.

## Disk space needed for a rewrite

Every rewrite writes a full new copy before it drops the old one, so check free space first.

```sql
SELECT pg_size_pretty(pg_total_relation_size('app.events')) AS table_with_indexes_and_toast;
```

pg_repack documents about twice the table and index size free; `VACUUM FULL` and pg_squeeze need room for the new
copy plus the WAL it generates, which replicas and the archive must also absorb. On a primary with replicas, watch
replication lag during the rewrite.

## Recovering from a failed REINDEX CONCURRENTLY

A `REINDEX CONCURRENTLY` or `CREATE INDEX CONCURRENTLY` that fails or is cancelled leaves an invalid index that
still slows writes. Find it and act by its suffix.

```sql
SELECT indexrelid::regclass AS index_name, indrelid::regclass AS table_name
FROM pg_index WHERE NOT indisvalid;
```

- Suffix `_ccnew`: the transient copy. `DROP INDEX CONCURRENTLY` it and run the reindex again.
- Suffix `_ccold`: the original index the swap could not drop. Drop it; the rebuild succeeded.
- No suffix (a failed `CREATE INDEX CONCURRENTLY`): drop it and create it again.

`REINDEX CONCURRENTLY` cannot run inside a transaction block, and on system catalogs it is not allowed at all.
