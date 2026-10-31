---
title: Moving a live PostgreSQL table to partitions
author: MOZGII, Inc.
lang: en
---

# Moving a live PostgreSQL table to partitions

This reference gives the full procedure for turning an existing, busy table into a partitioned table without copying
its rows during the switch, then lists the partitioning limits that decide whether a layout works. Every command was
run on PostgreSQL 18.6.

## The idea: the old table becomes the first partition

Copying a large table into a new partitioned table takes hours and needs a second copy of the data. Attaching the old
table as a partition takes milliseconds when PostgreSQL can prove, without scanning, that every old row fits the
partition's bounds and that the parent's unique index already exists on it. Three things make that true: a validated
`CHECK` constraint matching the bounds, a unique index that includes the partition key, and no identity column on
the table being attached.

## Step 1: build the future primary key online

The partitioned parent needs a primary key that includes the partition key, for example `(id, created_at)`. Build a
matching unique index on the old table without blocking writes:

```sql
CREATE UNIQUE INDEX CONCURRENTLY audit_log_id_created_at_key ON app.audit_log (id, created_at);
```

If the build fails, it leaves an invalid index; drop it with `DROP INDEX CONCURRENTLY` and run it again.

## Step 2: prove the range of the old rows online

A `CHECK` constraint added as `NOT VALID` takes a brief lock and checks only new rows; `VALIDATE CONSTRAINT` then
scans the table while writes continue. Include `IS NOT NULL` so the constraint implies the partition constraint:

```sql
ALTER TABLE app.audit_log ADD CONSTRAINT audit_log_legacy_bounds
  CHECK (created_at IS NOT NULL AND created_at < '2026-11-01 00:00+00') NOT VALID;
ALTER TABLE app.audit_log VALIDATE CONSTRAINT audit_log_legacy_bounds;
```

Choose the cutover far enough ahead that no row newer than it arrives before step 4; the validation fails with
`check constraint ... is violated by some row` if one already exists.

## Step 3: create the partitioned parent and future partitions

Create the new parent under a temporary name with the same columns, types and `NOT NULL` constraints, and the
partitions from the cutover onwards:

```sql
CREATE TABLE app.audit_log_p (
  id         bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  actor      text NOT NULL,
  action     text NOT NULL,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CREATE TABLE app.audit_log_2026_11 PARTITION OF app.audit_log_p
  FOR VALUES FROM ('2026-11-01 00:00+00') TO ('2026-12-01 00:00+00');
CREATE TABLE app.audit_log_2026_12 PARTITION OF app.audit_log_p
  FOR VALUES FROM ('2026-12-01 00:00+00') TO ('2027-01-01 00:00+00');
```

Create every other index the old table has on the parent now, with the same definitions, so `ATTACH` finds them on
the old table and attaches them instead of building new ones.

## Step 4: the cutover transaction

The cutover takes one `ACCESS EXCLUSIVE` lock on the old table for milliseconds. `lock_timeout` makes it give up
instead of queueing behind a long query and blocking everyone behind it:

```sql
BEGIN;
SET LOCAL lock_timeout = '3s';
LOCK TABLE app.audit_log IN ACCESS EXCLUSIVE MODE;
ALTER TABLE app.audit_log DROP CONSTRAINT audit_log_pkey;
ALTER TABLE app.audit_log ADD CONSTRAINT audit_log_legacy_pkey PRIMARY KEY USING INDEX audit_log_id_created_at_key;
ALTER TABLE app.audit_log RENAME TO audit_log_legacy;
ALTER TABLE app.audit_log_p RENAME TO audit_log;
ALTER TABLE app.audit_log_legacy ALTER COLUMN id DROP IDENTITY IF EXISTS;
ALTER TABLE app.audit_log ATTACH PARTITION app.audit_log_legacy
  FOR VALUES FROM (MINVALUE) TO ('2026-11-01 00:00+00');
CREATE SEQUENCE app.audit_log_id_seq OWNED BY app.audit_log.id;
SELECT setval('app.audit_log_id_seq', (SELECT max(id) FROM app.audit_log_legacy));
ALTER TABLE app.audit_log ALTER COLUMN id SET DEFAULT nextval('app.audit_log_id_seq');
COMMIT;
```

- `DROP IDENTITY` must come before `ATTACH`; otherwise 18.6 refuses with `table "audit_log_legacy" being attached
  contains an identity column "id"`.
- `ADD CONSTRAINT ... PRIMARY KEY USING INDEX` renames the index to the constraint name (18.6 prints a `NOTICE`).
- Applications see the same table name, so no code change is needed; prepared statements are re-planned.
- After commit, an insert with `created_at = '2026-11-15'` landed in `audit_log_2026_11` with the next id.

## Step 5: clean up after the cutover

The helper constraint and anything that referenced the old key need attention once the switch is done.

```sql
ALTER TABLE app.audit_log_legacy DROP CONSTRAINT audit_log_legacy_bounds;
ANALYZE ONLY app.audit_log;
-- foreign keys that pointed at the old primary key:
SELECT conrelid::regclass, conname FROM pg_constraint
WHERE contype = 'f' AND confrelid = 'app.audit_log_legacy'::regclass;
```

Foreign keys from other tables referenced `audit_log (id)`; recreate them against `(id, created_at)` as `NOT VALID`,
then `VALIDATE`, or drop them if the application enforces the link. Check them before step 4: dropping the old
primary key fails while a foreign key depends on it, so drop or replace those constraints inside the cutover.

## Splitting the legacy partition later

The legacy partition covers everything before the cutover. Leave it until retention removes it whole, or split it in
a quiet window: detach it (`DETACH PARTITION ... CONCURRENTLY` needs no default partition on the parent), create
monthly tables, copy each month with `INSERT ... SELECT`, attach each with a validated `CHECK`, then drop the legacy
table. During the copy the old rows are not visible through the parent, so do it only when readers can tolerate that,
or copy first and swap in one transaction.

## Partitioning limits and workarounds

These limits shape designs; check them before committing to a layout.

| Limit | Workaround |
|---|---|
| Partitions cannot have columns the parent lacks; `ATTACH` needs exactly matching columns and types | add columns on the parent, which adds them to every partition |
| Unique and primary keys must include every partition key column | composite keys, or a separate lookup table for a global unique value |
| `BEFORE ROW` triggers cannot change a row's destination partition | compute the key before the insert |
| `UPDATE` of the key moves the row to another partition (a delete plus an insert) | expected; a concurrent update or delete of the moved row may fail with SQLSTATE 40001 and must retry |
| PostgreSQL 18 refuses unlogged partitioned tables (`partitioned tables cannot be unlogged`) | use unlogged regular tables, or logged partitions |
| No `SPLIT PARTITION` or `MERGE PARTITIONS` in 18 | detach, copy, attach |
| A query that cannot prune locks every partition; thousands of partitions can exhaust the lock table sized by `max_locks_per_transaction` (default 64) | prune with the key, or raise the setting (restart needed) |
| Temporary and permanent tables cannot be mixed in one partition tree | keep scratch data out of the tree |
| `CREATE INDEX CONCURRENTLY` on the parent is refused | `ON ONLY` parent index, `CONCURRENTLY` per partition, `ALTER INDEX ... ATTACH PARTITION` |

PostgreSQL 18 also allows `NOT VALID` foreign keys on partitioned tables and dropping constraints `ONLY` on a
partitioned table, which makes adding constraints to large partitioned tables cheaper.

## Sources

- https://www.postgresql.org/docs/18/ddl-partitioning.html
- https://www.postgresql.org/docs/18/sql-altertable.html
- https://www.postgresql.org/docs/18/release-18.html
