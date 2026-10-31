---
title: pg_partman 5 in production
author: MOZGII, Inc.
lang: en
---

# pg_partman 5 in production

This reference covers pg_partman 5.5.0 on PostgreSQL 18: installing it per OS, running it without a superuser,
creating partition sets, retention, the background worker, emptying the default partition and monitoring. Every SQL
block was run against pg_partman 5.5.0 on PostgreSQL 18.6 (the `postgres:18` image with the PGDG package).

## Installing pg_partman on Linux, macOS and Windows

pg_partman 5.5.0 needs PostgreSQL 14 or later and supports only native (declarative) partitioning; trigger-based
sets must be migrated first. The project maintains no OS packages itself; the PGDG repositories do.

| OS | How |
|---|---|
| Debian, Ubuntu (PGDG apt) | `apt-get install postgresql-18-partman` |
| RHEL, Rocky, Alma (PGDG yum) | `dnf install pg_partman_18` |
| Containers | the `postgres:18` image has the PGDG apt source: install `postgresql-18-partman` in your own image |
| macOS | not in Postgres.app; build from source (`make install` with the `pg_config` of your server on `PATH`) |
| Windows | no build from the project; run it on Linux or in a container |
| Managed services | the README names Amazon RDS, Google, Azure and Supabase; check the version each one ships |

The background worker library must be preloaded, which needs a restart:

```ini
# postgresql.conf
shared_preload_libraries = 'pg_partman_bgw'
pg_partman_bgw.dbname = 'app'                    # required; comma-separated for several databases
pg_partman_bgw.role = 'partman_maintainer'       # default since 5.5; never a superuser
pg_partman_bgw.interval = 3600                   # seconds between runs (default 3600)
```

On 18.6 these settings report context `sighup`, so changing them needs only a reload; the preload itself needs a
restart. With `pg_partman_bgw` in `shared_preload_libraries` before the package is installed, the server refuses to
start (`could not access file "pg_partman_bgw"`), so install the package first.

## Running pg_partman without a superuser

Version 5.5 made the non-superuser setup the documented default after a set of CVEs around maintenance run as a
superuser. Create the extension in its own schema, then a maintenance role with the grants from the README:

```sql
CREATE SCHEMA partman;
CREATE EXTENSION pg_partman SCHEMA partman;
CREATE ROLE partman_maintainer WITH LOGIN;
GRANT ALL ON SCHEMA partman TO partman_maintainer;
GRANT ALL ON ALL TABLES IN SCHEMA partman TO partman_maintainer;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA partman TO partman_maintainer;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA partman TO partman_maintainer;
GRANT TEMPORARY ON DATABASE app TO partman_maintainer;   -- temp tables for moving data out of the default
GRANT app_owner TO partman_maintainer;                   -- membership in each role that owns partitioned tables
```

One more grant was needed in our test when the partitioned table is owned by a different role (`app_owner`):
pg_partman creates its template table in the `partman` schema and gives it to the table's owner, which fails with
`permission denied for schema partman` unless that owner may create there. This grant fixed it:

```sql
GRANT USAGE, CREATE ON SCHEMA partman TO app_owner;
```

Since 5.5, a retention schema (`retention_schema`) must be owned by the same role as the child tables
(CVE-2026-61821), and the `maintenance_role` column of `part_config` lets you add row-level security so each owner
maintains only its own sets.

## Creating a partition set with create_partition

`create_partition()` (added in 5.4 to replace `create_parent()`, which remains until the next major release)
registers an existing partitioned table and creates its first partitions:

```sql
CREATE TABLE app.metrics (
  device_id   bigint      NOT NULL,
  recorded_at timestamptz NOT NULL,
  value       double precision NOT NULL,
  PRIMARY KEY (device_id, recorded_at)
) PARTITION BY RANGE (recorded_at);

SET ROLE partman_maintainer;
SELECT partman.create_partition(
  p_parent_table    => 'app.metrics',
  p_control         => 'recorded_at',
  p_interval        => '1 day',
  p_premake         => 7,
  p_start_partition => (now() - interval '10 days')::date::text,
  p_default_table   => true);
RESET ROLE;
SELECT count(*) FROM partman.show_partitions('app.metrics');
```

| Argument | Default | Meaning |
|---|---|---|
| `p_interval` | (required) | an interval for time keys (`'1 day'`, `'1 month'`) or a number for integer keys |
| `p_type` | `'range'` | `range` or `list`; `list` only for integer sets with an interval of 1 |
| `p_premake` | 4 | partitions kept ahead of the current one |
| `p_start_partition` | current time or value | first partition to create, for back-filled data |
| `p_default_table` | true | create a default partition |
| `p_automatic_maintenance` | `'on'` | include the set when maintenance runs without a table argument |

## Retention: dropping or detaching old partitions

Retention is set in `partman.part_config` per partition set and applied by maintenance. By default old partitions
are only detached and kept as tables; set `retention_keep_table = false` to drop them.

```sql
UPDATE partman.part_config
SET retention = '7 days',
    retention_keep_table = false,
    infinite_time_partitions = true
WHERE parent_table = 'app.metrics';
CALL partman.run_maintenance_proc();
```

| Column | Default | Meaning |
|---|---|---|
| `retention` | NULL (keep all) | age (time sets) or value distance (integer sets) beyond which partitions leave |
| `retention_keep_table` | true | true: detach only; false: drop |
| `retention_schema` | NULL | move detached partitions to this schema instead of dropping |
| `retention_keep_index` | true | keep indexes on detached partitions |
| `infinite_time_partitions` | false | keep creating future partitions even when no new data arrives |
| `detach_before_drop` (5.5) | false | detach before dropping, needed when another table has a foreign key to the set |

In the test, a daily set started 10 days back with `retention = '7 days'` kept partitions from 7 days ago onwards
after one maintenance run.

## The background worker and scheduling maintenance

The background worker calls `run_maintenance_proc()` every `pg_partman_bgw.interval` seconds for the databases in
`pg_partman_bgw.dbname`, as `pg_partman_bgw.role`. After a restart the server log shows `pg_partman master
background worker master process initialized with role partman_maintainer`. Without the worker, schedule the same
call with pg_cron or an external scheduler:

```sql
CALL partman.run_maintenance_proc(p_wait => 0, p_analyze => false);
```

Run maintenance several times per partition interval (the default hourly run does this for daily sets), so a failed
run is retried long before the premade partitions run out. Since 5.5, an error in one partition set no longer stops maintenance of the
others; the failure is logged and that set's `last_run` becomes NULL, so alert on it.

## Emptying the default partition

Rows that arrive for a range with no partition land in the default partition, and maintenance cannot create that
partition until they are moved. `check_default()` finds them and `partition_data_proc()` moves them:

```sql
SELECT * FROM partman.check_default();               -- default_table | count
CALL partman.partition_data_proc('app.metrics');     -- creates the missing child and moves the rows
VACUUM ANALYZE app.metrics_default;
```

In the test one row 30 days ahead was moved with `Loop: 1, Rows moved: 1`, after which `check_default()` returned
nothing. For large defaults, `partition_data_async()` moves data in smaller committed batches through a working
table; rows in transit are not visible to readers, so use it only when that is acceptable.

## Monitoring a pg_partman installation

Check these regularly; each catches a failure before inserts start failing.

```sql
SELECT * FROM partman.check_default();                                  -- should be empty
SELECT parent_table, premake, retention, automatic_maintenance, last_run
FROM partman.part_config ORDER BY last_run NULLS FIRST;                 -- NULL last_run: maintenance failed
SELECT partition_tablename FROM partman.show_partitions('app.metrics', 'DESC') LIMIT 1;  -- newest partition
```

Sub-partitioned sets and many sets maintained in one transaction can exceed `max_locks_per_transaction` (default
64); `run_maintenance_proc()` commits after each set to reduce that pressure.

## Sources

- https://github.com/pgpartman/pg_partman/blob/development/README.md
- https://github.com/pgpartman/pg_partman/blob/development/doc/pg_partman.md
- https://github.com/pgpartman/pg_partman/blob/development/CHANGELOG.md (5.4.0, 5.5.0)
- https://download.postgresql.org/pub/repos/yum/18/redhat/rhel-9-x86_64/ (package name `pg_partman_18`)
