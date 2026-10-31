---
name: postgres-operations
description: 'Runs PostgreSQL in production: a daily health check, autovacuum tuning per table, bloat, transaction ID wraparound, disk and WAL growth, checkpoints, a postgresql.conf baseline (memory, io_method in 18, logging), minor and major upgrades, extension upkeep, and what differs on managed services (RDS, Aurora, Cloud SQL, Azure, Supabase, Neon). Use when setting up or tuning a server, autovacuum lags or a table keeps growing, the disk fills, or planning an upgrade to PostgreSQL 18.'
metadata:
  tags:
  - postgres
  - operations
  - autovacuum
  - bloat
  - wraparound
  - configuration
  - tuning
  - pg_upgrade
  - monitoring
---

# PostgreSQL operations, vacuum, tuning and upgrades

A healthy PostgreSQL server needs three habits: vacuum keeps up with writes, monitoring catches trends before they
become outages, and upgrades happen on schedule. Detail: [monitoring queries](references/monitoring-queries.md),
[configuration baseline](references/configuration.md), [upgrades](references/upgrades.md). Run
[scripts/health-check.sql](scripts/health-check.sql) daily or from monitoring.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: read the version and the settings that differ from defaults

Operations advice depends on the version and on what was already changed.

```sql
SELECT version();
SELECT name, setting, unit, source FROM pg_settings
WHERE source NOT IN ('default', 'override') ORDER BY name;
SELECT pg_size_pretty(pg_database_size(current_database()));
```

Current supported majors (October 2026): 18 (18.6), 17, 16, 15 and 14. PostgreSQL 14 reaches end of life on
12 November 2026; PostgreSQL 19 is in release candidate. Check https://www.postgresql.org/support/versioning/.

## How vacuum and autovacuum work

`VACUUM` removes dead row versions left by updates and deletes, so their space can be reused, updates the visibility
map (for index-only scans) and freezes old transaction ids. Autovacuum runs it per table when changes pass a
threshold:

`dead tuples > autovacuum_vacuum_threshold (50) + autovacuum_vacuum_scale_factor (0.2) × rows`

On a 100-million-row table the default waits for 20 million dead rows. PG 18 caps this with
`autovacuum_vacuum_max_threshold` (100 million by default); for large busy tables, set per-table values lower.

## Tuning autovacuum per table

Per-table settings make autovacuum visit big, busy tables more often without affecting the rest.

```sql
ALTER TABLE app.orders SET (
  autovacuum_vacuum_scale_factor = 0.01,          -- vacuum at 1% dead rows
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_vacuum_insert_scale_factor = 0.05    -- insert-only tables also get vacuumed (visibility map, freezing)
);
```

Server-wide, on modern SSDs:

```ini
autovacuum_max_workers = 6                 # PG 18: changeable at runtime up to autovacuum_worker_slots (16)
autovacuum_vacuum_cost_limit = 2000        # default -1 uses vacuum_cost_limit (200): too slow for big servers
autovacuum_naptime = '30s'
maintenance_work_mem = '1GB'               # autovacuum_work_mem defaults to it
```

Check that autovacuum keeps up: `n_dead_tup` and `last_autovacuum` in `pg_stat_user_tables`, and long-running
vacuums in `pg_stat_progress_vacuum`.

## Bloat and how to reclaim space

Bloat is space inside tables and indexes held by dead rows or left empty after them. Some is normal; a table many
times its live size wastes cache and I/O.

- Prevent it: keep transactions short (an old transaction stops vacuum from removing anything newer), and let
  autovacuum run often.
- Indexes: `REINDEX INDEX CONCURRENTLY` rebuilds without blocking writes.
- Tables: `VACUUM FULL` and `CLUSTER` rewrite the table under an `ACCESS EXCLUSIVE` lock: downtime. The `pg_repack`
  or `pg_squeeze` extensions rewrite online.
- Estimate bloat with the `pgstattuple` extension (`SELECT * FROM pgstattuple_approx('app.orders')`).

| To reclaim | Use | Why the others lose |
|---|---|---|
| Space inside a table for new rows | autovacuum, tuned per table | it does not shrink the file, and needs no lock on writers |
| A bloated index | `REINDEX INDEX CONCURRENTLY` | a plain `REINDEX` blocks writes |
| A table's file on a live system | `pg_repack` or `pg_squeeze` | `VACUUM FULL` locks the table for the whole rewrite |
| A table's file in a maintenance window | `VACUUM FULL` | nothing to install, but it needs the downtime and free disk |

## Transaction ID wraparound

PostgreSQL transaction ids are 32-bit, so old rows must be frozen before the counter wraps. If a database's oldest
unfrozen id ages past about 2 billion, the server refuses writes to protect data. Autovacuum prevents this with
anti-wraparound vacuums after `autovacuum_freeze_max_age` (200 million).

```sql
SELECT datname, age(datfrozenxid) AS xid_age,
       round(100.0 * age(datfrozenxid) / 2000000000, 1) AS pct_to_stop
FROM pg_database ORDER BY 2 DESC;
```

Alert above 40% (800 million). The usual blockers are a long-open transaction, an abandoned replication slot, or an
old prepared transaction; remove the blocker, then run a plain `VACUUM (VERBOSE)` as a superuser on the oldest
tables (the docs advise against `VACUUM FULL` and `VACUUM FREEZE` here). PG 18's eager
freezing (`vacuum_max_eager_freeze_failure_rate`) spreads freezing over normal vacuums.

## Disk, WAL and checkpoints

Most "database down" pages are a full disk. Watch three things.

- **WAL directory** (`pg_wal`) grows when archiving fails, a replication slot lags, or `max_wal_size` is large. Never
  delete files there by hand. Check `pg_stat_archiver` and `pg_replication_slots`.
- **Checkpoints**: `pg_stat_checkpointer.num_requested` much higher than `num_timed` means `max_wal_size` is too small
  for the write rate; raise it (for example to 8-16 GB on busy servers) and keep `checkpoint_timeout` at 5-15 min.
- **Temporary files**: big sorts and hashes spill to disk; `log_temp_files = '100MB'` names the queries.

## Configuration baseline

A new server's defaults are sized for a tiny machine. Start from this table and adjust with measurements; the full
list with reasons is in [references/configuration.md](references/configuration.md).

| Setting | Starting point |
|---|---|
| `shared_buffers` | 25% of RAM (restart) |
| `effective_cache_size` | 50-75% of RAM |
| `work_mem` | 16-64 MB; raise per query |
| `maintenance_work_mem` | 1-2 GB |
| `max_wal_size` | 4-16 GB |
| `random_page_cost` | 1.1 on SSD |
| `io_method` (PG 18) | `worker` (default); `io_uring` on Linux builds that support it |
| `wal_compression` | `lz4` or `zstd` |
| `track_io_timing` | `on` |
| `log_min_duration_statement` | `1s` (or lower) |

Change settings with `ALTER SYSTEM SET ...` then `SELECT pg_reload_conf();`, or in `postgresql.conf`; check
`pending_restart` in `pg_settings` for the ones that need a restart.

## Upgrades: minor and major

Minor releases (18.4 to 18.6, as 18.5 was never released) fix bugs and security issues and keep the data format: install the new binaries and
restart, after reading each skipped release's notes for required steps (some need a `REINDEX` or new backups).
Major releases (17 to 18) change the data format and need `pg_upgrade`, a dump and restore, or logical replication.

```bash
pg_upgrade -b /usr/lib/postgresql/17/bin -B /usr/lib/postgresql/18/bin \
  -d /var/lib/postgresql/17/main -D /var/lib/postgresql/18/main --check
```

Steps, modes (`--copy`, `--clone`, `--link`, `--swap`), checksums, extensions and post-upgrade tasks:
[references/upgrades.md](references/upgrades.md).

## Extensions upkeep

Extensions have their own versions inside each database; upgrading the server package does not upgrade them.

```sql
SELECT name, default_version, installed_version FROM pg_available_extensions
WHERE installed_version IS NOT NULL AND installed_version <> default_version;
ALTER EXTENSION vector UPDATE;          -- in each database that has it
```

## Managed services: what differs on RDS, Cloud SQL, Azure, Supabase and Neon

On a managed service you get an admin role, not a superuser, and the provider owns the configuration files, so some
advice above takes a different path. Settings change through the provider's parameter groups or flags instead of
`ALTER SYSTEM`; extensions come from an allowlist; `pg_hba.conf` and the server's file system are out of reach;
major upgrades go through the provider's tool. Per provider (admin role, how to enable logical replication, where
the pooler is): [references/managed-services.md](references/managed-services.md).

## Worked example: "the events table is 90 GB but holds 15 GB of rows"

A table far larger than its rows is bloated; remove what caused it before reclaiming the space.

1. Confirm the bloat: `SELECT * FROM pgstattuple_approx('app.events');` shows `dead_tuple_percent` small but
   `approx_free_percent` 80: vacuum removed the dead rows, but the space stayed inside the file.
2. Find why it grew: `pg_stat_user_tables` shows `last_autovacuum` days apart, and the monitoring query for the
   xmin horizon shows a replication slot for a decommissioned replica holding `xmin` since last month.
3. Remove the cause first, or the table bloats again: drop the stale slot, then set per-table autovacuum
   (`autovacuum_vacuum_scale_factor = 0.01`) on the table.
4. Reclaim the space online: `pg_repack --table=app.events --jobs=2 -d app` rewrites the table and its indexes
   with only brief locks at the start and end. Avoid `VACUUM FULL`: it locks the table for the whole rewrite.
5. Check: `pg_total_relation_size('app.events')` is near the live size, and the slot no longer appears in
   `pg_replication_slots`.

## Verify server health

These read-only queries are the heart of the daily check and work where the script file is not available; `psql -X -d
app -f health-check.sql` runs the full set. Each ran on 18.6 and returns rows only when something needs attention.

```sql
SELECT pid, usename, state, now() - xact_start AS xact_age, left(query, 60) AS query
FROM pg_stat_activity
WHERE xact_start < now() - interval '5 minutes' AND backend_type = 'client backend' ORDER BY xact_start;
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots
WHERE NOT active OR pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824;
SELECT archived_count, failed_count, last_failed_wal FROM pg_stat_archiver WHERE failed_count > 0;
SELECT indexrelid::regclass AS invalid_index FROM pg_index WHERE NOT indisvalid;
SELECT name, setting FROM pg_settings WHERE pending_restart;
```

After a tuning change, read `last_autovacuum` and `n_dead_tup` in `pg_stat_user_tables` a day later: dead rows must
level off. After an upgrade, `SELECT version();` must print the new release.

## Checklist

Check these points before you call a production server done.

- [ ] The daily health check runs and alerts (connections, long transactions, wraparound age, replication, archive,
      disk).
- [ ] Large busy tables have per-table autovacuum settings; autovacuum cost limit raised.
- [ ] `idle_in_transaction_session_timeout` set; no transaction older than minutes.
- [ ] `pg_stat_statements` and slow-query logging are on.
- [ ] Disk usage and `pg_wal` size are monitored with alerts well before full.
- [ ] Minor releases applied within weeks; a plan exists before the major reaches end of life.
- [ ] Extensions updated after package upgrades.

## Gotchas

These are the failures seen most often with a production server, each with its cause and fix.

1. **Vacuum runs but the table keeps growing.** An old transaction, replication slot or prepared transaction holds
   back the xmin horizon. Find it (`backend_xmin` in `pg_stat_activity`, `xmin` in `pg_replication_slots`).
2. **`database is not accepting commands that assign new transaction IDs`.** Wraparound protection, 3 million ids
   before the limit. Resolve prepared transactions, end long transactions, drop stale slots, then run `VACUUM` as a
   superuser in that database. Do not stop the server or use single-user mode: the docs advise against it.
3. **`VACUUM FULL` took the site down.** It locks the table for its whole run. Use `pg_repack`.
4. **The disk filled with WAL.** Failed archiving or a stale slot. Fix the cause; never delete `pg_wal` files.
5. **A setting change did nothing.** It needs a restart (`pending_restart = true`) or was overridden later in the
   file or by `postgresql.auto.conf`.
6. **Out-of-memory kills after raising `work_mem`.** It applies per sort or hash node per connection.

## Anti-patterns in running a server

Each of these trades a small saving now for an outage later.

| Do not | Do instead |
|---|---|
| Turn autovacuum off on a busy table | Tune it per table; a table it skips bloats and ages |
| Run `VACUUM FULL` on a live table | Use `pg_repack` or `pg_squeeze` |
| Delete files in `pg_wal` to free disk | Fix archiving or drop the stale slot; the server removes WAL itself |
| Raise `work_mem` for the whole server | Raise it per role or per query; it applies per sort or hash node |
| Skip minor releases until the next major | Apply them within weeks and read each skipped release's notes |
| Change settings in production without recording them | Keep `postgresql.conf` or the provider's settings in version control |

## See also

Related skills in this library, each one works on its own:

- `postgres-vacuum-bloat`: vacuum and bloat in depth.
- `postgres-monitoring-observability`: the always-on metrics and alerts.
- `postgres-os-kernel-tuning`: the operating system under the server.
- `postgres-zero-downtime-upgrades`: major upgrades without an outage.
- `postgres-backup-restore`: backups and restore drills.
- `postgres-troubleshooting`: working a live incident.
