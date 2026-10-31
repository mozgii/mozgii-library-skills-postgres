---
title: PostgreSQL DDL lock levels
author: MOZGII, Inc.
lang: en
---

# PostgreSQL DDL lock levels

This reference lists the table lock each common statement takes and what that lock blocks, so you can tell before
running a migration whether it will stop reads, writes, or nothing.

## Table lock modes and what they conflict with

PostgreSQL has eight table lock modes; this table shows the ones migrations meet, weakest first.

| Lock mode | Taken by | Blocks reads (SELECT) | Blocks writes (INSERT/UPDATE/DELETE) |
|---|---|---|---|
| `ACCESS SHARE` | `SELECT` | no | no |
| `ROW EXCLUSIVE` | `INSERT`, `UPDATE`, `DELETE`, `MERGE` | no | no |
| `SHARE UPDATE EXCLUSIVE` | `VACUUM`, `ANALYZE`, `CREATE INDEX CONCURRENTLY`, `VALIDATE CONSTRAINT`, `ALTER TABLE ... SET STATISTICS`, `DETACH PARTITION CONCURRENTLY` | no | no |
| `SHARE` | `CREATE INDEX` (not concurrent), `REINDEX` (not concurrent) on the table | no | yes |
| `SHARE ROW EXCLUSIVE` | `CREATE TRIGGER`, `ADD FOREIGN KEY` (on both tables) | no | yes |
| `ACCESS EXCLUSIVE` | most `ALTER TABLE`, `DROP TABLE`, `TRUNCATE`, `VACUUM FULL`, `CLUSTER`, `REFRESH MATERIALIZED VIEW` (not concurrent) | yes | yes |

`SHARE UPDATE EXCLUSIVE` conflicts with itself, so two `VALIDATE` or `CREATE INDEX CONCURRENTLY` on one table run one
after the other, and autovacuum on the table makes them wait (a non-wraparound autovacuum cancels itself for them; an
anti-wraparound one keeps running, so the statement waits for it to end).

A plain `REINDEX` takes `SHARE` on the table and `ACCESS EXCLUSIVE` on the index itself (measured on 18.6 with
`pg_locks`): writes stop, and reads of the table go on unless their plan needs that index, which then blocks them too.

## ALTER TABLE forms and their locks

`ALTER TABLE` takes different locks depending on the subcommand.

| Subcommand | Lock | Rewrites or scans |
|---|---|---|
| `ADD COLUMN` (no default, or non-volatile default) | `ACCESS EXCLUSIVE` (brief) | no |
| `ADD COLUMN` with volatile default | `ACCESS EXCLUSIVE` | rewrites |
| `DROP COLUMN` | `ACCESS EXCLUSIVE` (brief) | no (space reclaimed later) |
| `ALTER COLUMN TYPE` | `ACCESS EXCLUSIVE` | rewrites, unless binary-compatible (`varchar(n)` to `text`, larger `n`) |
| `ALTER COLUMN SET NOT NULL` | `ACCESS EXCLUSIVE` | scans, unless a validated `CHECK (col IS NOT NULL)` exists |
| `ALTER COLUMN SET DEFAULT` / `DROP DEFAULT` | `ACCESS EXCLUSIVE` (brief) | no |
| `ADD CONSTRAINT ... CHECK` | `ACCESS EXCLUSIVE` | scans, unless `NOT VALID` |
| `ADD CONSTRAINT ... FOREIGN KEY` | `SHARE ROW EXCLUSIVE` on both tables | scans, unless `NOT VALID` |
| `VALIDATE CONSTRAINT` | `SHARE UPDATE EXCLUSIVE` | scans, reads and writes continue |
| `ADD CONSTRAINT ... UNIQUE USING INDEX` | `ACCESS EXCLUSIVE` (brief) | no, index already built |
| `RENAME COLUMN` / `RENAME TO` | `ACCESS EXCLUSIVE` (brief) | no |
| `SET (fillfactor = ...)`, autovacuum settings | `SHARE UPDATE EXCLUSIVE` | no |
| `ATTACH PARTITION` | `SHARE UPDATE EXCLUSIVE` on the parent, `ACCESS EXCLUSIVE` on the new partition, and on the default partition when one exists | scans the new partition unless a matching `CHECK` proves the bounds |
| `DETACH PARTITION CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` | no |

"Brief" still means the statement must first acquire the lock, so it waits behind long queries and blocks the queue
while waiting: `lock_timeout` matters even for instant changes.

## Seeing the locks a migration holds or waits for

`pg_locks` joined with `pg_stat_activity` shows who holds and who waits.

```sql
SELECT a.pid, l.mode, l.granted, l.relation::regclass AS relation,
       now() - a.query_start AS running, left(a.query, 60) AS query
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.relation IS NOT NULL AND a.pid <> pg_backend_pid()
ORDER BY l.granted, a.query_start;
```

Run the migration in a test transaction on a copy and read `pg_locks` from a second session to learn the exact lock
before you run it in production.
