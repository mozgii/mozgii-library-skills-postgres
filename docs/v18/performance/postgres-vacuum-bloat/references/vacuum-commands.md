---
title: PostgreSQL VACUUM, vacuumdb and vacuum progress commands
author: MOZGII, Inc.
lang: en
---

# PostgreSQL VACUUM, vacuumdb and vacuum progress commands

This reference lists the manual vacuum commands worth knowing on PostgreSQL 18.6: the `VACUUM` options, the
`vacuumdb` client for whole databases, and the views that show a vacuum while it runs. Every command here was run on
18.6.

## Contents

The sections of this reference on vacuum commands:

1. VACUUM options that matter
2. vacuumdb for databases and clusters
3. Watching a running vacuum
4. Reading VACUUM VERBOSE output

## VACUUM options that matter

Manual `VACUUM` takes options in parentheses. These are the ones that change what it does.

```sql
VACUUM (VERBOSE, ANALYZE) app.orders;
VACUUM (FREEZE, SKIP_LOCKED, BUFFER_USAGE_LIMIT '256MB', PARALLEL 2) app.events_2026_10;
VACUUM (INDEX_CLEANUP OFF, TRUNCATE OFF, PROCESS_TOAST OFF) app.orders;
ANALYZE ONLY app.events;
VACUUM (ONLY_DATABASE_STATS);
```

| Option | Effect |
|---|---|
| `VERBOSE` | per-table report: removed and unremovable tuples, frozen pages, WAL, buffer use |
| `ANALYZE` | refresh planner statistics in the same pass |
| `FREEZE` | freeze every row it can (aggressive); more I/O than a normal vacuum |
| `SKIP_LOCKED` | skip tables it cannot lock at once instead of waiting |
| `BUFFER_USAGE_LIMIT` | ring buffer size (default `vacuum_buffer_usage_limit`, 2 MB; capped at 1/8 of `shared_buffers`; 0 means no limit) |
| `PARALLEL n` | parallel workers for the index phases, at most one per index larger than `min_parallel_index_scan_size` |
| `INDEX_CLEANUP OFF` | skip index vacuuming; fastest way to advance freezing, leaves dead line pointers |
| `TRUNCATE OFF` | do not cut empty pages off the end, so no `ACCESS EXCLUSIVE` lock |
| `PROCESS_TOAST OFF`, `PROCESS_MAIN OFF` | skip the TOAST table or the main table |
| `DISABLE_PAGE_SKIPPING` | visit every page, ignoring the visibility map (for suspected visibility map corruption) |
| `ONLY_DATABASE_STATS` | only recompute the database's `datfrozenxid`; no table work |
| `ONLY` before a table name (18) | process a partitioned or inheritance parent without its children |

Since PostgreSQL 18, `VACUUM` and `ANALYZE` of an inheritance parent also process its children by default; `ONLY`
restores the old behaviour. Autovacuum never processes partitioned parents, so analyze them after large loads.

## vacuumdb for databases and clusters

`vacuumdb` runs `VACUUM` or `ANALYZE` over many tables with several connections. It is the tool for the post-restore
analyze, the post-upgrade analyze and wraparound clean-up.

```bash
vacuumdb --all --jobs=4 --min-xid-age=1000000000 --skip-locked --buffer-usage-limit=256MB
vacuumdb -d app --analyze-only --missing-stats-only --jobs=4
vacuumdb -d app --analyze-in-stages --missing-stats-only
vacuumdb -d app --table='app.orders(customer_id, status)' --analyze-only
```

| Flag | Use |
|---|---|
| `-j`, `--jobs` | parallel connections, one table each |
| `--min-xid-age`, `--min-mxid-age` | only tables at least this old: the wraparound shortcut |
| `-Z`, `--analyze-only`; `--analyze-in-stages` | statistics only; in three passes of growing accuracy, so the planner has rough numbers fast |
| `--missing-stats-only` (18) | only relations without statistics; superuser, with `--analyze-only` or `--analyze-in-stages` |
| `-n`, `--schema`; `-N`, `--exclude-schema`; `-t`, `--table` | limit the scope |
| `-P`, `--parallel` | parallel index vacuum workers per table |
| `--no-index-cleanup`, `--no-truncate`, `--no-process-toast`, `--no-process-main`, `--skip-locked` | the matching `VACUUM` options |

## Watching a running vacuum

`pg_stat_progress_vacuum` shows each running vacuum's phase and progress. Join it to `pg_stat_activity` to tell a
manual vacuum from autovacuum and to see `(to prevent wraparound)` in the query text.

```sql
SELECT p.pid, p.relid::regclass AS table_name, p.phase,
       round(100.0 * p.heap_blks_scanned / nullif(p.heap_blks_total, 0), 1) AS scanned_pct,
       p.index_vacuum_count, p.indexes_total, p.indexes_processed,
       pg_size_pretty(p.dead_tuple_bytes) AS dead_items, p.delay_time,
       a.query, now() - a.xact_start AS running
FROM pg_stat_progress_vacuum p JOIN pg_stat_activity a USING (pid);
```

- `index_vacuum_count` above 1: the dead item store filled and every index was scanned again; give that vacuum more
  `maintenance_work_mem` (manual) or `autovacuum_work_mem` (autovacuum).
- `delay_time` (18): milliseconds spent sleeping on the cost budget; filled only with `track_cost_delay_timing = on`.
- Phase `truncating heap`: it is waiting for or holding the `ACCESS EXCLUSIVE` lock for truncation.

Time spent per table over its life is in `pg_stat_user_tables` (18): `total_vacuum_time`,
`total_autovacuum_time`, `total_analyze_time`, `total_autoanalyze_time`, all in milliseconds.

## Reading VACUUM VERBOSE output

`VACUUM (VERBOSE)` prints one block per table. These lines carry the decisions, as printed by 18.6:

```text
tuples: 0 removed, 210000 remain, 10000 are dead but not yet removable
removable cutoff: 779, which was 0 XIDs old when operation ended
new relfrozenxid: 770, which is 2 XIDs ahead of previous value
frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
index scan needed: 368 pages from table (20.01% of total) had 50000 dead item identifiers removed
```

- `dead but not yet removable` greater than 0: the xmin horizon is held; see the holder query in the skill.
- `removable cutoff ... XIDs old` large: the same, measured in transactions.
- `new relfrozenxid` advanced: freezing works; if it never advances, the table is never vacuumed aggressively to the
  end.
- `index scan needed`: how much index work the dead rows caused; HOT updates reduce it.
