---
name: postgres-partitioning
description: 'Runs declarative partitioning on PostgreSQL 18 at scale: choosing the partition key and range, list or hash, partition pruning at plan and run time, primary keys and unique constraints, indexes built without long locks, default partitions, ATTACH with a pre-validated CHECK, DETACH CONCURRENTLY, pg_partman 5.5 with retention and a non-superuser background worker, moving a live table to partitions, partition-wise joins and the limits. Use when a table grows past what one heap handles, old data must be dropped cheaply, "no partition of relation found for row" appears, queries scan every partition, or when setting up pg_partman.'
metadata:
  tags:
  - postgres
  - partitioning
  - pg_partman
  - partition-pruning
  - retention
  - time-series
  - large-tables
  - online-migration
---

# PostgreSQL partitioning at scale

Partition a table when you must drop old data in bulk (detach a month instead of deleting millions of rows) or when
a very large table is almost always filtered by one column. The docs' rule of thumb: the table should exceed the
server's memory first. Pick the key from your `WHERE` clauses and your retention unit, keep partitions in the
hundreds, and create them ahead of time with pg_partman or a job. Creating range, list and hash partitions is in
`postgres-schema-design` (references/partitioning.md); this skill runs them in production. Health report:
[scripts/partition-report.sql](scripts/partition-report.sql); its two checks are inline under Verify.


## Step 0: read the version, pg_partman and the tables already partitioned

`ANALYZE ONLY`, the limits of 18 and pg_partman's function names all depend on versions, so read them before you
change anything. These ran on 18.6 with pg_partman 5.5.0.

```sql
SELECT current_setting('server_version') AS version,
       (SELECT extversion FROM pg_extension WHERE extname = 'pg_partman') AS partman;
SELECT c.oid::regclass AS root, pg_get_partkeydef(c.oid) AS partition_key,
       (SELECT count(*) FROM pg_partition_tree(c.oid) t WHERE t.isleaf) AS leaves
FROM pg_class c WHERE c.relkind = 'p' AND NOT c.relispartition ORDER BY 1;
```

## Choosing the partition key and strategy

The partition key decides pruning, uniqueness and how data leaves the table, so choose it before anything else.

| Strategy | Key looks like | Fits | Watch out for |
|---|---|---|---|
| `RANGE` | `created_at`, an id that grows | time series, logs, events, retention by age | a gap between bounds rejects rows; bounds are values, not names |
| `LIST` | `region`, `tier`, a few big tenants | discrete values with different handling (archive one region) | new values need a partition or a default |
| `HASH` | `tenant_id`, `account_id` | spreading writes and vacuum evenly when no range exists | no pruning for ranges; changing the modulus means rewriting |

- The key must appear in every primary key and unique constraint, so a time-partitioned table cannot enforce a
  globally unique `id` alone; use `PRIMARY KEY (id, created_at)` or a separate lookup table.
- Size partitions (a day to a month of data) so each vacuums and indexes quickly; planning time and memory grow
  with the partitions that survive pruning.
- Sub-partitioning multiplies the count; use it only for one partition that outgrows the rest.

## Partition bounds and time zones

Range bounds on a `timestamptz` key are fixed instants, and a literal without an offset is read in the session's
`TimeZone`, so jobs running under different time zones leave gaps. This 18.6 run made the second partition under
`America/New_York`:

```sql
SET TimeZone = 'UTC';
CREATE TABLE app.tz_a PARTITION OF app.tz_test FOR VALUES FROM ('2026-11-01 00:00+00') TO ('2026-12-01 00:00+00');
SET TimeZone = 'America/New_York';
CREATE TABLE app.tz_b PARTITION OF app.tz_test FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
-- tz_b starts at 2026-12-01 05:00+00: rows between 00:00 and 05:00 UTC fail with
-- ERROR: no partition of relation "tz_test" found for row
```

Write every bound with an explicit offset (`'2026-12-01 00:00+00'`), or pin `SET TimeZone = 'UTC'` in the job that
creates partitions.

## Partition pruning at plan time and at run time

Partition pruning removes partitions whose bounds cannot match the query; it needs the key itself on one side of a
comparison. `enable_partition_pruning` is on by default. These plans come from a monthly-partitioned table on 18.6:

```sql
-- constants: pruned while planning, only events_2026_10 appears in the plan
EXPLAIN (COSTS OFF) SELECT count(*) FROM app.events
WHERE occurred_at >= '2026-10-01' AND occurred_at < '2026-10-08';

-- a stable expression such as now(): pruned at executor start, the plan shows "Subplans Removed: 1"
EXPLAIN (ANALYZE, COSTS OFF) SELECT count(*) FROM app.events WHERE occurred_at >= now() - interval '7 days';

-- a function wrapped around the key: no pruning, every partition is scanned
EXPLAIN (COSTS OFF) SELECT count(*) FROM app.events WHERE date_trunc('day', occurred_at) = '2026-10-03';
```

- Rewrite `date_trunc(...) = x` as a half-open range on the raw column: `occurred_at >= x AND occurred_at < x + 1 day`.
- Prepared statements with a generic plan still prune at run time; the test with `plan_cache_mode =
  force_generic_plan` showed `Subplans Removed: 2`.
- Values that come from a join prune partitions at run time only when they arrive as parameters, as in a
  parameterized nested loop; check the plan for `Subplans Removed` or `never executed` partitions.

## Primary keys, unique constraints and identity columns on partitioned tables

Unique constraints on a partitioned table are enforced per partition, so every partition key column must be in
the constraint. The error on 18.6:

```sql
ALTER TABLE app.events ADD CONSTRAINT events_id_key UNIQUE (id);
-- ERROR: unique constraint on partitioned table must include all partitioning columns
-- DETAIL: UNIQUE constraint on table "events" lacks column "occurred_at" which is part of the partition key.
```

An identity column belongs to the parent: a table that is attached later may not have its own identity column
("table ... being attached contains an identity column"). Drop the identity on the incoming table first and let the
parent's sequence or default supply new values.

## Indexes on partitioned tables without long locks

`CREATE INDEX` on a partitioned parent builds the index on every partition and does not accept `CONCURRENTLY`. For
a live table, create the parent index with `ON ONLY` (it starts invalid), build each partition's index concurrently,
then attach them; the parent index turns valid when the last one is attached.

```sql
CREATE INDEX events_payload_idx ON ONLY app.events USING gin (payload);         -- indisvalid = false
CREATE INDEX CONCURRENTLY events_2026_10_payload_idx ON app.events_2026_10 USING gin (payload);
ALTER INDEX app.events_payload_idx ATTACH PARTITION app.events_2026_10_payload_idx;
-- repeat for each partition; then indisvalid = true
```

[scripts/partition-report.sql](scripts/partition-report.sql) lists parent indexes still invalid.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Default partitions and their traps

A `DEFAULT` partition catches rows no other partition accepts. It hides a missing partition instead of failing, and
it costs you later:

- Creating or attaching a partition scans the default partition under an `ACCESS EXCLUSIVE` lock, and fails if the
  default holds a row for the new range: `updated partition constraint for default partition "events_default" would
  be violated by some row`. Move those rows out first (pg_partman's `partition_data_proc` does this).
- `DETACH PARTITION ... CONCURRENTLY` is refused while a default partition exists: `cannot detach partitions
  concurrently when a default partition exists`.
- Monitor it: `SELECT count(*) FROM app.events_default` (or pg_partman's `check_default()`) should return 0.

For time-based tables, prefer creating partitions far enough ahead and alerting on insert errors over a default
partition. Keep a default only for `LIST` tables where unknown values are expected.

## ATTACH PARTITION with a pre-validated CHECK constraint

`ALTER TABLE ... ATTACH PARTITION` takes `SHARE UPDATE EXCLUSIVE` on the parent and `ACCESS EXCLUSIVE` on the table
being attached, then scans it to prove every row fits the bounds. A valid `CHECK` constraint that implies the bounds
skips that scan. Validate it first with `NOT VALID` plus `VALIDATE`, which scans without blocking writes:

```sql
ALTER TABLE app.events_2026_12 ADD CONSTRAINT events_2026_12_bounds
  CHECK (occurred_at IS NOT NULL AND occurred_at >= '2026-12-01 00:00+00' AND occurred_at < '2027-01-01 00:00+00') NOT VALID;
ALTER TABLE app.events_2026_12 VALIDATE CONSTRAINT events_2026_12_bounds;        -- scans, writes continue
ALTER TABLE app.events ATTACH PARTITION app.events_2026_12
  FOR VALUES FROM ('2026-12-01 00:00+00') TO ('2027-01-01 00:00+00');            -- no scan
ALTER TABLE app.events_2026_12 DROP CONSTRAINT events_2026_12_bounds;
```

At `client_min_messages = debug1`, 18.6 reports `partition constraint ... is implied by existing constraints`
when the scan is skipped. Matching indexes that already exist on the table are attached to the
parent's indexes instead of being rebuilt, so build them before the `ATTACH`.

## DETACH PARTITION CONCURRENTLY and FINALIZE

Detaching removes a partition from the parent so it can be archived or dropped. Plain `DETACH` needs `ACCESS
EXCLUSIVE` on the parent; `CONCURRENTLY` takes `SHARE UPDATE EXCLUSIVE` and waits for running queries in two
transactions. Detach, finish an interrupted detach, then drop:

```sql
ALTER TABLE app.events DETACH PARTITION app.events_2026_09 CONCURRENTLY;   -- not inside BEGIN ... COMMIT
-- interrupted? finish it:
ALTER TABLE app.events DETACH PARTITION app.events_2026_09 FINALIZE;
DROP TABLE app.events_2026_09;                                             -- or pg_dump -t it first
```

`CONCURRENTLY` cannot run in a transaction block or with a default partition, and only one partition per parent can
be pending detach. The detached table keeps a `CHECK` constraint copying its old bounds, which makes re-attaching it
cheap.

## pg_partman 5 for creating and retiring partitions

pg_partman 5.5.0 (July 2026) creates partitions ahead of time and applies retention on a schedule; it supports only
native partitioning and needs PostgreSQL 14 or later. It ships as a PGDG package on Linux (`postgresql-18-partman`
on Debian and Ubuntu, `pg_partman_18` on RHEL), is not in Postgres.app, and the project publishes no Windows build.
This call, run on 18.6 as a non-superuser role, makes daily partitions with seven made ahead (`create_partition`
replaced `create_parent` in 5.4; the old name stays until the next major release):

```sql
SELECT partman.create_partition(p_parent_table => 'app.metrics', p_control => 'recorded_at',
                                p_interval => '1 day', p_premake => 7);
UPDATE partman.part_config SET retention = '7 days', retention_keep_table = false
WHERE parent_table = 'app.metrics';
CALL partman.run_maintenance_proc();     -- creates ahead and drops partitions older than 7 days
```

It adds a default partition unless `p_default_table => false`. Version 5.5 changed the background
worker's default role (`pg_partman_bgw.role`) to `partman_maintainer` and warns against running maintenance as a
superuser; it also requires a retention schema to be owned by the child tables' owner (CVE-2026-61821). Roles,
grants, the worker settings and moving rows out of the default are in [references/pg-partman.md](references/pg-partman.md).

## Moving a big table to partitions online

A live table can become the first partition of a new partitioned table, so no rows are copied during the switch and
the only blocking step is one short transaction. The procedure below ran on 18.6 against a table with an identity
primary key on `id`; every command with its reasons is in [references/online-migration.md](references/online-migration.md).

1. Online: `CREATE UNIQUE INDEX CONCURRENTLY` on `(id, created_at)`, the future primary key.
2. Online: add `CHECK (created_at IS NOT NULL AND created_at < '<cutover>')` as `NOT VALID`, then `VALIDATE` it.
3. Online: create the new partitioned parent and the partitions from the cutover onwards.
4. One transaction with `SET LOCAL lock_timeout`: lock the old table, swap its primary key to the new index
   (`ADD CONSTRAINT ... PRIMARY KEY USING INDEX`), rename both tables, drop the identity on the old one, `ATTACH` it
   `FOR VALUES FROM (MINVALUE) TO ('<cutover>')`, and give the parent a sequence set to the old `max(id)`.
5. After: drop the helper `CHECK`, rebuild foreign keys that pointed at the old `id`, `ANALYZE ONLY` the parent.

The validated `CHECK` makes the `ATTACH` skip its scan, and the existing unique index is attached to the parent's
primary key instead of being rebuilt, so the lock lasts milliseconds. If `lock_timeout` fires, retry the
transaction.

## Partition-wise joins and aggregates

Partition-wise join joins matching partitions pair by pair, and partition-wise aggregate groups inside each
partition. Both are off by default (`enable_partitionwise_join`, `enable_partitionwise_aggregate`) because they
raise planning cost and memory. They need both tables partitioned the same way on the join key; with two tables
hash-partitioned by `tenant_id` into 4 partitions, 18.6 planned four separate hash joins with a `HashAggregate` each:

```sql
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
EXPLAIN (COSTS OFF)
SELECT o.tenant_id, sum(l.qty)
FROM app.orders o JOIN app.order_lines l ON l.tenant_id = o.tenant_id AND l.order_id = o.id
GROUP BY o.tenant_id;
```

Turn them on per role or session for reporting workloads rather than server-wide.

## Statistics and vacuum on partitioned tables

Autovacuum processes each partition, never the partitioned parent, so the parent has no statistics unless you
collect them. PostgreSQL 18 added `ANALYZE ONLY app.orders`, which gathers the parent's statistics without
re-analyzing every partition. `VACUUM ONLY` on a partitioned table only warns
(`VACUUM ONLY of partitioned table "orders" has no effect`). Schedule `ANALYZE ONLY <parent>` after large loads and
after attaching partitions.

## Limits of partitioning

The limits that most often change a design: partitions cannot add columns, `BEFORE ROW` triggers cannot reroute a
row, PostgreSQL 18 refuses unlogged partitioned tables, there is no `SPLIT` or `MERGE` of partitions in 18, and
queries that cannot prune take a lock per partition. The full list with workarounds is in
[references/online-migration.md](references/online-migration.md#partitioning-limits-and-workarounds).

## Verify a partitioned table

Run these after every partition change; they need no script file. Both ran on 18.6, and each listed the invalid
parent index and the default partition planted for the test.

```sql
SELECT i.indrelid::regclass AS parent, i.indexrelid::regclass AS invalid_index
FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid
WHERE c.relkind = 'p' AND NOT i.indisvalid;                -- no rows
SELECT c.oid::regclass AS default_partition, c.reltuples   -- reltuples -1 means never analyzed
FROM pg_class c WHERE c.relispartition AND pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT';
```

Then count the rows in each default partition (0 expected), and run `EXPLAIN (COSTS OFF)` on your main query: only
the partitions it needs may appear. Check that a partition exists for next week, and insert a row into it inside a
rolled-back transaction, before a job has to.

## Gotchas

These are the failures seen most often with partitioned tables, each with its cause and fix.

1. **`no partition of relation "events" found for row`.** No partition covers the value: the scheduler stopped, or
   bounds were written in a different time zone. Create the partition with explicit offsets and alert on this error.
2. **A new partition cannot be created: `updated partition constraint for default partition ... would be violated`.**
   The default partition already holds rows for that range. Move them out (`partition_data_proc`) and keep the
   default empty.
3. **`DETACH ... CONCURRENTLY` fails.** A default partition exists, or it ran inside a transaction. Drop or empty the
   default, run it outside `BEGIN`, finish an interrupted one with `FINALIZE`.
4. **Every partition shows up in `EXPLAIN`.** The key is wrapped in a function or cast, or the filter is on another
   column. Compare the raw key with a range.
5. **Bad plans on the parent after a bulk load.** The parent has no statistics. Run `ANALYZE ONLY <parent>`.
6. **`ATTACH PARTITION` held an `ACCESS EXCLUSIVE` lock for minutes.** It scanned the table. Add and validate the
   matching `CHECK` first.

## Anti-patterns with partitioned tables

Partitioning makes these mistakes more expensive than on a plain table.

| Do not | Do instead |
|---|---|
| Partition a table because it feels big | Partition for bulk retention or one dominant filter; the table should exceed RAM first |
| Create thousands of partitions | Keep them in the hundreds: planning cost grows with the partitions that survive pruning |
| Keep a default partition on a time-ranged table | Create partitions ahead and alert when an insert fails |
| Remove old data with `DELETE` | Use `DETACH ... CONCURRENTLY` or pg_partman retention |
| Run `CREATE INDEX` on the parent of a live table | Use `ON ONLY`, build per partition with `CONCURRENTLY`, then attach |
| Filter with `date_trunc(...)` around the key | Compare the raw key with a half-open range |

## Checklist

Check these points before you call a partitioned table production-ready.

- [ ] The key matches the main filters and the retention unit; every unique constraint includes it.
- [ ] Partitions are created ahead (pg_partman `premake` or a job) and creation failures alert.
- [ ] Bounds on `timestamptz` keys carry an explicit offset.
- [ ] No default partition on time-ranged tables, or it is monitored and empty.
- [ ] New indexes go through `ON ONLY`, `CONCURRENTLY` per partition and `ATTACH`.
- [ ] Old partitions leave with `DETACH ... CONCURRENTLY` (or pg_partman retention), never `DELETE`.
- [ ] `ANALYZE ONLY <parent>` runs after big loads; [scripts/partition-report.sql](scripts/partition-report.sql)
      shows no invalid parent index.

## See also

Related skills in this library, each one works on its own:

- `postgres-schema-design`: creating range, list and hash partitions.
- `postgres-timeseries`: time-based data, including TimescaleDB.
- `postgres-indexing`: index choices per partition.
- `postgres-extensions-install`: installing pg_partman.
- `postgres-schema-migrations`: lock-safe DDL.
- `postgres-citus-sharding`: when one server is not enough.

## Sources

- https://www.postgresql.org/docs/18/ddl-partitioning.html
- https://www.postgresql.org/docs/18/sql-altertable.html
- https://www.postgresql.org/docs/18/release-18.html
- https://github.com/pgpartman/pg_partman (README, doc/pg_partman.md, release 5.5.0 notes)
- PostgreSQL 18.6 `pg_settings` (defaults of the settings named here)
