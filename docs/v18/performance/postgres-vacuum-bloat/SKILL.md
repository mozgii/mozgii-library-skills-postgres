---
name: postgres-vacuum-bloat
description: 'Keeps PostgreSQL 18 tables and indexes small and safe from wraparound: autovacuum trigger math and per-table settings (scale factors, cost limits, autovacuum_vacuum_max_threshold, autovacuum_worker_slots), freezing, xid age and the failsafe, measuring bloat with pgstattuple, HOT updates and fillfactor, VACUUM FULL versus pg_repack versus pg_squeeze, REINDEX CONCURRENTLY, and what blocks vacuum (old transactions, slots, prepared transactions, hot_standby_feedback). Use when a table keeps growing, dead tuples pile up, autovacuum never finishes, "dead but not yet removable" appears, xid age climbs, or a big table must shrink without downtime.'
metadata:
  tags:
  - postgres
  - vacuum
  - autovacuum
  - bloat
  - wraparound
  - freezing
  - hot-updates
  - fillfactor
  - pg_repack
  - pg_squeeze
---

# PostgreSQL vacuum, bloat and wraparound

Vacuum work has three jobs: remove dead row versions, keep the visibility map current, and freeze old transaction
ids before the 32-bit counter wraps. Decide in this order: first find what holds the xmin horizon back (nothing
else matters while it is held), then make autovacuum visit the table often enough, then reclaim space online with
pg_repack or pg_squeeze, and use `VACUUM FULL` only inside a maintenance window. The daily overview of autovacuum is
in `postgres-operations`; this skill goes into the mechanics, the numbers and the tools. A read-only report with
these queries: [scripts/vacuum-report.sql](scripts/vacuum-report.sql). Manual `VACUUM` options, `vacuumdb` and
progress views: [references/vacuum-commands.md](references/vacuum-commands.md).

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: read the vacuum settings and the biggest tables

Vacuum advice depends on the server's settings and on which tables carry the dead rows, so read both first.

```sql
SELECT name, setting, unit, context FROM pg_settings
WHERE name ~ '^(autovacuum|vacuum_)' ORDER BY name;
SELECT relid::regclass AS table_name, n_live_tup, n_dead_tup, n_ins_since_vacuum,
       last_autovacuum, autovacuum_count, total_autovacuum_time
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 20;
```

Defaults on 18.6: scale factor 0.2, threshold 50, `autovacuum_vacuum_max_threshold` 100,000,000, insert scale
factor 0.2 and threshold 1000, naptime 60 s, 3 workers, cost limit -1 (`vacuum_cost_limit`, 200), cost delay 2 ms.

## When autovacuum triggers: the threshold formula

Autovacuum vacuums a table when dead tuples pass the vacuum threshold, and PostgreSQL 18 caps that threshold:

`vacuum threshold = min(autovacuum_vacuum_max_threshold, autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * reltuples)`

Inserts trigger their own vacuum (for freezing and the visibility map) at
`autovacuum_vacuum_insert_threshold + autovacuum_vacuum_insert_scale_factor * reltuples * fraction not frozen`.
Analyze uses `autovacuum_analyze_threshold + autovacuum_analyze_scale_factor * reltuples` with no cap. A table also
gets an anti-wraparound vacuum when `age(relfrozenxid)` passes `autovacuum_freeze_max_age`, even with autovacuum
off. The report script computes `vacuum_at_dead` per table with per-table overrides applied, so you can see how far
each table is from its next autovacuum.

## Per-table autovacuum settings for large, busy tables

Per-table storage parameters change autovacuum for one table without touching the rest. On a 200-million-row
table the global 0.2 waits for 40 million dead rows; the 18 cap of 100 million barely helps such a table, so set
your own cap.

```sql
ALTER TABLE app.orders SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_vacuum_threshold = 1000,
  autovacuum_vacuum_max_threshold = 500000,         -- PG 18: never wait for more than 500k dead rows
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_vacuum_cost_limit = 2000,              -- this table's workers may do more work per round
  autovacuum_vacuum_cost_delay = 1
);
ALTER TABLE app.orders SET (toast.autovacuum_vacuum_scale_factor = 0.05);   -- the TOAST table has its own
ALTER TABLE app.orders RESET (autovacuum_vacuum_cost_delay);
SELECT oid::regclass, reloptions FROM pg_class WHERE reloptions IS NOT NULL AND relkind IN ('r', 'm', 'p');
```

Also per table in 18: `vacuum_max_eager_freeze_failure_rate` and `vacuum_truncate`.

## Autovacuum workers, cost limits and runtime changes in PostgreSQL 18

Autovacuum throughput is set by the number of workers and the cost budget. The cost limit is distributed
proportionally among running workers, so more workers without a higher `autovacuum_vacuum_cost_limit` means each
one runs slower.

| Setting | Context | Starting point on SSD |
|---|---|---|
| `autovacuum_worker_slots` (new in 18) | restart | 16 (default); the ceiling for `autovacuum_max_workers` |
| `autovacuum_max_workers` | reload in 18 (restart before) | 4-8 |
| `autovacuum_vacuum_cost_limit` | reload | 1000-4000 |
| `autovacuum_vacuum_cost_delay` | reload | 2 ms (default) |
| `autovacuum_naptime` | reload | 15-30 s on many-table databases |
| `maintenance_work_mem` / `autovacuum_work_mem` | reload | 1 GB; each autovacuum worker may use this much |

Raising workers at runtime in 18 is a reload, not a restart:

```sql
ALTER SYSTEM SET autovacuum_max_workers = 6;
SELECT pg_reload_conf();
SHOW autovacuum_max_workers;
```

`track_cost_delay_timing = on` (18) fills `delay_time` in `pg_stat_progress_vacuum`: time spent sleeping on the
cost budget. The role `pg_signal_autovacuum_worker` (18) lets a non-superuser signal autovacuum workers.

## What blocks vacuum: the xmin horizon

Vacuum can remove a dead row only when no snapshot can still see it. The oldest snapshot held by a session, a
replication slot, a prepared transaction, or a standby with `hot_standby_feedback = on` sets that horizon. `VACUUM (VERBOSE)` reports the symptom as `N are dead but not yet removable`.

This query lists every kind of holder with its age in transactions:

```sql
SELECT 'session' AS holder, pid::text AS id, state, age(backend_xmin) AS xmin_age, now() - xact_start AS xact_age
FROM pg_stat_activity WHERE backend_xmin IS NOT NULL AND pid <> pg_backend_pid()
UNION ALL
SELECT 'prepared xact', gid, NULL, age(transaction), now() - prepared FROM pg_prepared_xacts
UNION ALL
SELECT 'slot', slot_name, NULL, greatest(age(xmin), age(catalog_xmin)), NULL FROM pg_replication_slots
WHERE xmin IS NOT NULL OR catalog_xmin IS NOT NULL
UNION ALL
SELECT 'standby feedback', application_name, NULL, age(backend_xmin), NULL FROM pg_stat_replication
WHERE backend_xmin IS NOT NULL
ORDER BY xmin_age DESC NULLS LAST;
```

| Holder | Fix |
|---|---|
| `idle in transaction` session | `pg_terminate_backend(pid)`; set `idle_in_transaction_session_timeout` |
| long report or `REPEATABLE READ` export | move it to a replica without feedback, or split it |
| prepared transaction | `COMMIT PREPARED 'gid'` or `ROLLBACK PREPARED 'gid'` after checking its owner |
| physical slot of a removed standby (`xmin` set by its feedback) | `pg_drop_replication_slot('name')` |
| logical slot with a dead consumer (`catalog_xmin`: holds catalog cleanup and WAL) | restart the consumer, or drop the slot |
| standby with `hot_standby_feedback` running long queries | cap them on the standby (`statement_timeout`), or turn feedback off and accept cancellations |

## Measuring bloat with pgstattuple

Bloat is space inside a table or index that holds no live rows. `pgstattuple` measures it exactly by reading every
page; `pgstattuple_approx` uses the visibility map and reads only pages that are not all-visible, so it is the one
to run on large tables in production.

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;
SELECT table_len, scanned_percent, approx_tuple_percent, dead_tuple_percent, approx_free_percent
FROM pgstattuple_approx('app.orders');
SELECT avg_leaf_density, leaf_fragmentation FROM pgstatindex('app.orders_customer_idx');
```

Read it this way: high `dead_tuple_percent` means vacuum has not run or is blocked; high `approx_free_percent`
after a vacuum means the space is reusable inside the file but not returned to the OS. A B-tree with
`avg_leaf_density` below about 50% (fresh ones sit near 90%) is a `REINDEX CONCURRENTLY` candidate. Bloat estimates
computed from `pg_class` and `pg_stats` alone are fast but can be far off; confirm with `pgstattuple_approx`
before a rewrite.

## HOT updates and fillfactor

A HOT (heap-only tuple) update writes the new row version on the same page and adds no index entries, so it creates
no index bloat and its dead versions are pruned during normal reads. It needs two things: the update changes no
indexed column (BRIN excepted), and the page has room. Lowering `fillfactor` leaves that room.

```sql
SELECT relid::regclass AS table_name, n_tup_upd, n_tup_hot_upd, n_tup_newpage_upd,
       round(100.0 * n_tup_hot_upd / nullif(n_tup_upd, 0), 1) AS hot_pct
FROM pg_stat_user_tables WHERE n_tup_upd > 0 ORDER BY n_tup_upd DESC LIMIT 20;
ALTER TABLE app.orders SET (fillfactor = 85);   -- applies to pages written from now on; a rewrite applies it everywhere
```

Measured on 18.6 (200,000 rows, one non-indexed column updated in every tenth row): `hot_pct` 100.0 after a
rewrite with `fillfactor = 85`, 0.0 with `fillfactor = 100`. Fillfactor helps when a few rows per page change
between vacuums. An index on `updated_at` makes every update non-HOT; add it only if a query needs it.

## Reclaiming space: VACUUM FULL, pg_repack or pg_squeeze

Plain `VACUUM` makes space reusable but shrinks the file only when the empty pages are at its end. Returning space
to the OS means rewriting the table. Install steps, every flag and scheduling:
[references/reclaiming-space.md](references/reclaiming-space.md).

| Tool | Lock during the copy | Needs |
|---|---|---|
| `VACUUM FULL` / `CLUSTER` | `ACCESS EXCLUSIVE` for the whole run: downtime for the table | room for the new copy |
| pg_repack 1.5.3 | `SHARE UPDATE EXCLUSIVE`; `ACCESS EXCLUSIVE` only briefly at start and swap | primary key or unique NOT NULL index; about twice the table and index size free; no DDL while it runs |
| pg_squeeze 1.9.4 | exclusive lock only at the swap, bounded by `squeeze.max_xlock_time` | `shared_preload_libraries`, `wal_level = logical`, a free slot, and from 18.6 `output_plugin_libraries` |

pg_repack is a client program (`pg_repack --dry-run --table=app.events -d app` first); `--wait-timeout` bounds how
long it waits for conflicting locks before it cancels the blockers. pg_squeeze runs inside the server. The 18.6 minor release added `output_plugin_libraries` (CVE-2026-6471), and
without `pg_squeeze` in it a squeeze fails:

```sql
ALTER SYSTEM SET output_plugin_libraries = pgoutput, test_decoding, pg_squeeze;   -- unquoted list
SELECT pg_reload_conf();
CREATE EXTENSION pg_squeeze;
SELECT squeeze.squeeze_table('app', 'events');
```

Both ran on 18.6 (PGDG packages in the `postgres:18` image): a 52 MB table with 80% of rows deleted shrank to
10 MB with pg_squeeze, and to 5.3 MB with pg_repack after a second delete.

## Rebuilding indexes with REINDEX CONCURRENTLY

`REINDEX ... CONCURRENTLY` builds a new copy of each index next to the old one and swaps it in without blocking
writes. It cannot run inside a transaction block, takes two table scans, and waits for older transactions.

```sql
REINDEX INDEX CONCURRENTLY app.orders_customer_idx;
REINDEX TABLE CONCURRENTLY app.orders;
SELECT indexrelid::regclass AS index_name, indrelid::regclass AS table_name FROM pg_index WHERE NOT indisvalid;
```

A failed run leaves an invalid index ending in `_ccnew` (drop it, run again) or `_ccold` (drop it; the rebuild
succeeded).

## Freezing, transaction ID age and the failsafe

Transaction ids are 32-bit, so old rows must be frozen before the counter wraps. Vacuum freezes rows older than
`vacuum_freeze_min_age` (50 million), scans whole tables past `vacuum_freeze_table_age` (150 million), and
autovacuum forces a vacuum at `autovacuum_freeze_max_age` (200 million). PostgreSQL 18 also freezes some
all-visible pages during normal vacuums (eager freezing, capped by `vacuum_max_eager_freeze_failure_rate`, 0.03).

```sql
SELECT datname, age(datfrozenxid) AS xid_age, mxid_age(datminmxid) AS mxid_age,
       round(100.0 * age(datfrozenxid) / 2147483647, 1) AS pct_of_wrap
FROM pg_database ORDER BY 2 DESC;
```

At `vacuum_failsafe_age` (1.6 billion) a running vacuum drops its cost delay and skips index vacuuming to finish
freezing. 40 million transactions before wraparound the server warns; at 3 million it refuses new transaction ids.
Per-table ages, the documented recovery steps and multixact wraparound:
[references/wraparound-runbook.md](references/wraparound-runbook.md).

## Worked example: "the events table doubled in a week and autovacuum runs all day"

1. `pg_stat_user_tables` shows `n_dead_tup` near 30 million and `last_autovacuum` updated every few minutes, so
   autovacuum runs but removes nothing.
2. `VACUUM (VERBOSE) app.events` prints `0 removed, ... 28000000 are dead but not yet removable`.
3. The xmin horizon query shows a physical slot `replica_old` with `xmin_age` 90 million: a standby that ran
   with `hot_standby_feedback = on` was shut down, and its slot kept its last `xmin`.
4. Confirm the standby is gone, run `SELECT pg_drop_replication_slot('replica_old');`; the next autovacuum removes
   the dead rows.
5. Shrink the file online: `pg_repack --table=app.events --jobs=2 --wait-timeout=60 -d app`.
6. Prevent a repeat: alert on slot age and on `active = false`, and set `idle_replication_slot_timeout` (18,
   applied at checkpoints) or `max_slot_wal_keep_size`.

## Gotchas

These are the vacuum failures seen most often, each with its cause and fix.

1. **`N are dead but not yet removable`.** Something holds the xmin horizon. Run the holder query; vacuum settings
   cannot fix it.
2. **Autovacuum restarts on the same huge table forever.** Cost limit too low, or `index_vacuum_count` climbing
   from too little memory. Raise the table's `autovacuum_vacuum_cost_limit` and the server's `autovacuum_work_mem`.
3. **`VACUUM FULL` blocked the application.** It holds `ACCESS EXCLUSIVE` for the whole rewrite. Use pg_repack or
   pg_squeeze.
4. **pg_squeeze fails with `may not be used as an output plugin` after the 18.6 update.** Add it to
   `output_plugin_libraries` and reload.
5. **`ALTER SYSTEM SET shared_preload_libraries = 'a,b'` and the server will not start.** The quoted string becomes
   one library named `a,b` (`could not access file "a,b"`). Write the list unquoted: `= a, b`.
6. **Plain `VACUUM` truncated the table end and stalled queries.** Truncation takes a brief `ACCESS EXCLUSIVE` lock,
   which is also replayed on hot standbys. Set `vacuum_truncate = false` on that table (18) or `VACUUM (TRUNCATE OFF)`.
7. **Partitioned parent has no statistics.** Autovacuum skips partitioned parents. Run `ANALYZE` on the parent after
   loads.

## Anti-patterns in vacuum tuning

These trade a quiet day now for a long lock or a wraparound scare later.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Turning autovacuum off on a busy table | bloat grows, and anti-wraparound vacuum runs anyway at the worst time | tune that table's settings |
| Tuning settings while the xmin horizon is held | vacuum runs often and removes nothing | find the holder first |
| A scheduled `VACUUM FULL` | `ACCESS EXCLUSIVE` for each rewrite | autovacuum, then pg_repack or pg_squeeze when needed |
| More workers with the same cost limit | each worker gets a smaller share and runs slower | raise `autovacuum_vacuum_cost_limit` with them |
| Rewriting from a bloat estimate alone | estimates from `pg_stats` can be far off | confirm with `pgstattuple_approx` |
| Low `fillfactor` on every table | space is wasted on tables that are rarely updated | only where the HOT ratio shows it helps |
| An index on `updated_at` nobody queries | every update stops being HOT | add it only for a real query |

## Verify vacuum removed the dead rows

Vacuum's own report tells you whether it could work. On 18.6, after updating every row of a 100,000-row table:

```sql
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'b';       -- 100000, 100000
VACUUM (VERBOSE, ANALYZE) app.b;       -- tuples: 100000 removed, 100000 remain, 0 are dead but not yet removable
SELECT n_dead_tup, last_vacuum IS NOT NULL FROM pg_stat_user_tables WHERE relname = 'b';   -- 0, t
SELECT coalesce(max(age(backend_xmin)), 0) FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL AND pid <> pg_backend_pid();                       -- small: nothing holds the horizon
```

A number above 0 in `dead but not yet removable` means something still holds the xmin horizon: find it before you tune
anything. The table's size on disk does not shrink after a plain `VACUUM`; the space is reused. Then run
`psql -X -v ON_ERROR_STOP=1 -d <db> -f scripts/vacuum-report.sql`, which exits 0 and lists what is left.

## Checklist

Check these points before you call vacuum handled.

- [ ] The xmin horizon query runs in monitoring, with alerts on age and on inactive slots.
- [ ] Tables over about 10 million rows have per-table scale factors and a `autovacuum_vacuum_max_threshold`.
- [ ] `autovacuum_vacuum_cost_limit` is raised and `autovacuum_max_workers` fits the number of busy tables.
- [ ] `age(datfrozenxid)` is graphed, alerting well before 1 billion.
- [ ] Update-heavy tables have a HOT ratio checked and a fillfactor below 100 where it helps.
- [ ] Space is reclaimed with pg_repack or pg_squeeze, tested on a copy first; `VACUUM FULL` only in a window.
- [ ] Invalid indexes (`NOT indisvalid`) are checked after every concurrent build.

## See also

Related skills in this library:

- `postgres-operations`: the daily overview of autovacuum
- `postgres-internals-mvcc-storage`: why dead rows exist
- `postgres-transactions-locking`: long transactions that hold the horizon
- `postgres-replication-ha`: slots and `hot_standby_feedback`
- `postgres-indexing`: index bloat and rebuilds

## Sources

- https://www.postgresql.org/docs/18/routine-vacuuming.html
- https://www.postgresql.org/docs/18/runtime-config-vacuum.html
- https://www.postgresql.org/docs/18/sql-vacuum.html
- https://www.postgresql.org/docs/18/sql-reindex.html
- https://www.postgresql.org/docs/18/storage-hot.html
- https://www.postgresql.org/docs/18/pgstattuple.html
- https://www.postgresql.org/docs/18/monitoring-stats.html
- https://www.postgresql.org/docs/18/release-18.html
- https://www.postgresql.org/docs/release/18.6/
- https://reorg.github.io/pg_repack/ and https://github.com/reorg/pg_repack (1.5.3)
- https://github.com/cybertec-postgresql/pg_squeeze (1.9.4)
