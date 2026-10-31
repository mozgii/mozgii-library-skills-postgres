---
title: PostgreSQL table partitioning
author: MOZGII, Inc.
lang: en
---

# PostgreSQL table partitioning

This reference covers declarative partitioning: when to use it, how to create and maintain partitions, and the
limits that surprise people.

## When to partition a table

Partitioning pays off in two cases: you drop old data by time (detach a month instead of deleting millions of rows),
or a very large table is almost always queried by the partition key, so pruning skips most partitions. It adds
planning cost and rules (the key must be in every unique constraint), so a table under tens of GB rarely needs it.

## Range partitioning by time

Range partitioning by a timestamp is the common case: one partition per day, week or month.

```sql
CREATE TABLE app.events (
  id          bigint GENERATED ALWAYS AS IDENTITY,
  occurred_at timestamptz NOT NULL,
  kind        text NOT NULL,
  data        jsonb,
  PRIMARY KEY (id, occurred_at)                 -- the partition key must be part of every unique key
) PARTITION BY RANGE (occurred_at);

CREATE TABLE app.events_2026_11 PARTITION OF app.events
  FOR VALUES FROM ('2026-11-01 00:00+00') TO ('2026-12-01 00:00+00');
CREATE TABLE app.events_default PARTITION OF app.events DEFAULT;   -- catches rows with no partition yet
CREATE INDEX ON app.events (occurred_at);                          -- created on every partition
```

- Create partitions ahead of time with a scheduled job (pg_cron or the app's scheduler), or use the `pg_partman`
  extension, which creates and drops them on a schedule.
- Keep the `DEFAULT` partition empty. Attaching a new partition scans the default for rows that belong to it.

## Throwing away old months of data: DETACH PARTITION and DROP instead of a giant DELETE

To throw away an old month of event data without a giant `DELETE`, detach that month's partition and drop it: no
row-by-row delete, no dead rows for vacuum, no long lock. `DETACH PARTITION` removes the partition from the parent;
`CONCURRENTLY` avoids blocking queries on the parent.

```sql
ALTER TABLE app.events DETACH PARTITION app.events_2025_01 CONCURRENTLY;   -- not inside a transaction block
DROP TABLE app.events_2025_01;                                              -- or archive it first with pg_dump -t
```

## Attaching a large partition without a long lock

Attaching an existing table checks every row against the bounds unless a matching `CHECK` constraint proves it
already.

```sql
ALTER TABLE app.events_2026_12 ADD CONSTRAINT bounds
  CHECK (occurred_at >= '2026-12-01 00:00+00' AND occurred_at < '2027-01-01 00:00+00') NOT VALID;
ALTER TABLE app.events_2026_12 VALIDATE CONSTRAINT bounds;          -- scans, but allows writes
ALTER TABLE app.events ATTACH PARTITION app.events_2026_12
  FOR VALUES FROM ('2026-12-01 00:00+00') TO ('2027-01-01 00:00+00');   -- skips the scan
ALTER TABLE app.events_2026_12 DROP CONSTRAINT bounds;
```

## List and hash partitioning

List partitioning splits by discrete values (region, tenant tier); hash partitioning spreads rows evenly by a key
when there is no natural range.

```sql
CREATE TABLE app.accounts (id bigint NOT NULL, region text NOT NULL, PRIMARY KEY (id, region))
  PARTITION BY LIST (region);
CREATE TABLE app.accounts_eu PARTITION OF app.accounts FOR VALUES IN ('eu');

CREATE TABLE app.sessions (id uuid NOT NULL PRIMARY KEY) PARTITION BY HASH (id);
CREATE TABLE app.sessions_p0 PARTITION OF app.sessions FOR VALUES WITH (MODULUS 4, REMAINDER 0);
```

## Partitioning gotchas

These partitioning problems come up most often, each with its cause and fix.

1. **Queries scan every partition.** Cause: the `WHERE` clause does not filter on the partition key, or wraps it in a
   function. Check `EXPLAIN` for the list of partitions.
2. **`unique constraint on partitioned table must include all partitioning columns`.** A global unique id needs the
   key in it, or a separate lookup table.
3. **Too many partitions.** Thousands of partitions slow planning and use locks per partition. Prefer monthly over
   daily unless volume demands it.
4. **Unlogged partitioned tables are refused in PG 18.**
5. **Foreign keys pointing at a partitioned table** work (PG 12+), but each referencing row is checked against the
   partitioned parent; index the referencing column.
