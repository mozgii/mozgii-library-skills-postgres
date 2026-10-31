---
name: postgres-schema-migrations
description: 'Ships PostgreSQL schema changes without downtime in any migration tool: lock_timeout on every migration, which ALTER TABLE forms rewrite or lock, NOT VALID then VALIDATE, CREATE INDEX CONCURRENTLY outside transactions, expand and contract for renames and type changes, batched backfills, one runner in CI under an advisory lock, and forward-only rollback. Use for any ALTER TABLE on a live database, writing or reviewing a migration, or when "the migration locked the table".'
metadata:
  tags:
  - postgres
  - migrations
  - zero-downtime
  - ddl
  - locks
  - expand-contract
  - backfill
  - ci
---

# PostgreSQL zero-downtime schema migrations

A migration that takes the wrong lock for a second can stop every request to a table. This skill keeps schema
changes safe on a live database, whatever tool runs them (Flyway, Liquibase, Sqitch, golang-migrate, dbmate,
Alembic, Prisma Migrate, Drizzle Kit, Rails, Django). Lock levels per statement:
[references/ddl-lock-levels.md](references/ddl-lock-levels.md).

## Step 0: read the server version, the migration tool and the table size

The version decides the safe path (`NOT NULL ... NOT VALID` needs 18), the tool decides how to turn its transaction
off, and the table size decides whether a statement is a problem at all.

```sql
SELECT current_setting('server_version_num')::int AS version_num;       -- 180006 = 18.6
SELECT pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size, c.reltuples::bigint AS est_rows
FROM pg_class c WHERE c.oid = 'app.orders'::regclass;
SELECT setting FROM pg_settings WHERE name = 'lock_timeout';            -- 0 means a migration waits forever
```

```bash
flyway --version; liquibase --version; alembic --version; bin/rails -v; npx prisma -v    # the one the project uses
```

## Why DDL blocks traffic: the lock queue

Most `ALTER TABLE` forms take an `ACCESS EXCLUSIVE` lock, which conflicts with every other lock, including plain
`SELECT`. If a long query holds a lock on the table, the `ALTER` waits, and every query that arrives after the `ALTER`
queues behind it. One slow report plus one migration takes the table offline until the report ends.

## A small ALTER TABLE froze the whole site: start every migration with lock_timeout

A small `ALTER TABLE` can freeze a whole site: it waits for its lock behind one long query, and every query after it
queues behind the `ALTER`. Start every migration with `lock_timeout` and `statement_timeout`.
`lock_timeout` makes the migration give up quickly instead of queueing traffic behind it; retry later.

```sql
SET lock_timeout = '3s';
SET statement_timeout = '15min';     -- an upper bound for this migration's statements
-- the DDL follows
```

A migration that hits `lock_timeout` fails with SQLSTATE `55P03` (`lock_not_available`) and changes nothing. Retry it
with a growing pause; see "Retrying a migration after lock_timeout" below. Also check for long transactions before you
start:

```sql
SELECT pid, now() - xact_start AS age, state, left(query, 60) AS query
FROM pg_stat_activity WHERE xact_start < now() - interval '1 minute' ORDER BY xact_start;
```

## Safe and unsafe operations on a live table

Some DDL is metadata-only and instant; some rewrites or scans the table under a heavy lock. This table assumes
PostgreSQL 12 or later.

| Change | Safe? | Safe way |
|---|---|---|
| Add a nullable column, no default | yes | `ADD COLUMN c text` |
| Add a column with a constant or stable default (`0`, `'x'`, `now()`) | yes (PG 11+) | instant: the default is stored once |
| Add a column with a volatile default (`clock_timestamp()`, `gen_random_uuid()`, `random()`) | no: rewrites the table | add without default, backfill, then `SET DEFAULT` |
| Add a `STORED` generated column | no: rewrites | `VIRTUAL` (PG 18), or a column filled by a backfill |
| Set `NOT NULL` | no: full scan under `ACCESS EXCLUSIVE` | PG 18: `ADD CONSTRAINT c_nn NOT NULL col NOT VALID`, then `VALIDATE CONSTRAINT`; PG 12-17: `CHECK (col IS NOT NULL) NOT VALID`, `VALIDATE`, then `SET NOT NULL` (skips the scan) |
| Add a `CHECK` or foreign key | no: scans under a heavy lock | `NOT VALID`, then `VALIDATE CONSTRAINT` (weaker lock) |
| Add a unique constraint | no: builds an index under lock | `CREATE UNIQUE INDEX CONCURRENTLY`, then `ADD CONSTRAINT ... UNIQUE USING INDEX` |
| Create an index | no: blocks writes | `CREATE INDEX CONCURRENTLY` |
| Drop an index | no: brief exclusive lock | `DROP INDEX CONCURRENTLY` |
| Change a column type | usually rewrites | new column, backfill, swap (expand and contract); `varchar(n)` to larger `n` or to `text` is safe |
| Rename a column or table | instant, but breaks running code | expand and contract, or a view for the old name |
| Drop a column | instant, breaks code that selects it | stop using it in code first, deploy, then drop |

## Retrying a migration after lock_timeout

A short `lock_timeout` only works with a retry, and the retry belongs outside the database: with
`--single-transaction` each attempt is one new transaction that releases everything it holds and leaves nothing behind.
This wrapper retries only on `55P03` and stops at once on any other error, so a real bug never loops. Run on
PostgreSQL 18.6 against a table held by another session. A file of `CREATE INDEX CONCURRENTLY` cannot use that flag:
drop it there and make the file idempotent (`IF NOT EXISTS`), because a plain `psql -f` commits statement by statement.
Without the flag and without idempotence, attempt 1 kept its first `ADD COLUMN` and the retry died on `42701`.

```bash
#!/usr/bin/env bash
# usage: migrate-retry.sh <file.sql> [attempts]; needs DATABASE_URL
set -u
file=${1:?usage: migrate-retry.sh <file.sql> [attempts]}
attempts=${2:-8}
for ((try = 1; try <= attempts; try++)); do
  if output=$(PGOPTIONS='-c lock_timeout=2s' psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose --single-transaction -f "$file" 2>&1); then
    echo "applied on attempt $try"; exit 0
  fi
  grep -q '55P03' <<<"$output" || { echo "$output" >&2; exit 1; }
  echo "lock busy, attempt $try of $attempts" >&2
  sleep $((try * 3))
done
echo "gave up after $attempts attempts" >&2; exit 1
```

A retry loop written in PL/pgSQL (`BEGIN ... EXCEPTION WHEN lock_not_available`) also works, but every pass opens a
subtransaction and the whole loop stays one transaction, so anything taken before the failure stays held. On a busy
server prefer the client loop. For the hottest tables, `LOCK TABLE app.orders IN ACCESS EXCLUSIVE MODE NOWAIT` inside
the migration's transaction fails at once instead of joining the lock queue at all; expect more retries.

## NOT VALID then VALIDATE for constraints

Adding a constraint as `NOT VALID` enforces it for new writes at once without checking old rows; `VALIDATE` checks
old rows later under a `SHARE UPDATE EXCLUSIVE` lock that allows reads and writes.

```sql
SET lock_timeout = '3s';
ALTER TABLE app.orders ADD CONSTRAINT orders_customer_fk
  FOREIGN KEY (customer_id) REFERENCES app.customers (id) NOT VALID;
-- separate migration or statement:
ALTER TABLE app.orders VALIDATE CONSTRAINT orders_customer_fk;
```

## Idempotent migrations: ADD CONSTRAINT has no IF NOT EXISTS

`ALTER TABLE ... ADD CONSTRAINT IF NOT EXISTS` does not exist in PostgreSQL; it stops with `syntax error at or near
"exists"`. A migration that must survive a second run checks the catalog first, by table and name together, because
constraint names are only unique per table.

```sql
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'app.orders'::regclass AND conname = 'orders_total_positive'
  ) THEN
    ALTER TABLE app.orders ADD CONSTRAINT orders_total_positive CHECK (total_cents > 0) NOT VALID;
  END IF;
END $$;
```

| Statement | Has `IF [NOT] EXISTS`? |
|---|---|
| `ADD COLUMN`, `DROP COLUMN`, `DROP CONSTRAINT` | yes |
| `CREATE TABLE`, `CREATE INDEX`, `CREATE SCHEMA`, `CREATE EXTENSION`, `CREATE SEQUENCE` | yes |
| `ADD CONSTRAINT` | no: use the `DO` block |
| `CREATE TRIGGER`, `CREATE POLICY` | no `IF NOT EXISTS`: drop with `IF EXISTS` first, or check `pg_trigger` and `pg_policy` |

`CREATE UNIQUE INDEX IF NOT EXISTS` looks only at the name. After a failed concurrent build it finds the `INVALID`
leftover, prints `already exists, skipping` and succeeds with no working index behind it. Check `pg_index.indisvalid`
after every concurrent build.

## CREATE INDEX CONCURRENTLY in its own migration

`CREATE INDEX CONCURRENTLY` cannot run inside a transaction, and most runners wrap each file in one. Put each
concurrent statement in its own migration with the transaction off.

| Tool | How to turn the transaction off |
|---|---|
| Flyway | `executeInTransaction=false` in a script config file next to the migration |
| Liquibase | `runInTransaction:false` on the changeset |
| golang-migrate | multi-statement mode off; one statement per file runs outside a transaction |
| dbmate | `-- migrate:up transaction:false` |
| Alembic | `with op.get_context().autocommit_block():` |
| Rails | `disable_ddl_transaction!` and `algorithm: :concurrently` |
| Django | `atomic = False` on the migration and `AddIndexConcurrently` |
| Prisma Migrate | create an empty migration (`prisma migrate dev --create-only`) holding only the concurrent statement; a file with several statements runs as one implicit transaction |
| Drizzle Kit | its migrator runs every pending file in one transaction: build the index with `psql` in a CI step before `migrate`, and write `CREATE INDEX IF NOT EXISTS` in the migration |

A failed concurrent build leaves an `INVALID` index: drop it (`DROP INDEX CONCURRENTLY`) and run again.

## Expand and contract for renames and type changes

Expand and contract splits a breaking change into steps where every step works with both the old and the new
application version. Renaming `full_name` to `display_name`:

| Step | Database | Application |
|---|---|---|
| 1 expand | `ADD COLUMN display_name text` | |
| 2 | | write both columns, read `full_name` |
| 3 backfill | copy old rows in batches | |
| 4 | | read `display_name`, still write both |
| 5 | add `NOT NULL` the safe way | |
| 6 | | stop writing `full_name` |
| 7 contract | `DROP COLUMN full_name` | |

A trigger can do the dual write in step 2 when several services write the table. Each step is its own deploy; the
contract step ships only after every running instance uses the new column.

## Backfilling large tables in batches

One `UPDATE` over millions of rows holds row locks for its whole run, bloats the table and floods replicas with WAL.
Update in small committed batches instead.

```sql
-- repeat until it reports UPDATE 0; commit between runs (a script loop or a procedure)
UPDATE app.customers
SET display_name = full_name
WHERE id IN (
  SELECT id FROM app.customers
  WHERE display_name IS NULL AND full_name IS NOT NULL
  ORDER BY id LIMIT 5000
  FOR UPDATE SKIP LOCKED
);
```

```sql
-- the same loop as a procedure: COMMIT inside a procedure is allowed (call it outside a transaction)
CREATE OR REPLACE PROCEDURE app.backfill_display_name(batch int DEFAULT 5000)
LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  LOOP
    UPDATE app.customers SET display_name = full_name
    WHERE id IN (SELECT id FROM app.customers WHERE display_name IS NULL AND full_name IS NOT NULL
                 ORDER BY id LIMIT batch);
    GET DIAGNOSTICS n = ROW_COUNT;
    EXIT WHEN n = 0;
    COMMIT;
    PERFORM pg_sleep(0.1);       -- let replicas and vacuum keep up
  END LOOP;
END $$;
CALL app.backfill_display_name();
```

Watch replica lag on the primary while it runs (`SELECT application_name, replay_lag FROM pg_stat_replication;`)
and lengthen the pause if lag grows.

## Running migrations: in CI, before the deploy, one runner at a time

Migrations belong in a deploy step, not in application startup: with many instances, startup migrations race each
other, and a failed migration should fail the deploy, not crash-loop the app.

1. Build and test; check that migration history has no conflicts.
2. Apply migrations from one job with the migration role and a direct (not transaction-pooled) connection.
3. Deploy the new application version.
4. Contract migrations ship in a later release.

Serialize runners with a session advisory lock so retried or parallel jobs cannot overlap (Flyway, Liquibase,
Alembic with a wrapper, and Drizzle with a wrapper do this; check yours):

```sql
SELECT pg_advisory_lock(hashtext('app-migrations'));
-- apply pending migrations
SELECT pg_advisory_unlock(hashtext('app-migrations'));
```

A session advisory lock does not work through a transaction-mode pooler (PgBouncer, Supavisor, Hyperdrive): run
migrations on the direct connection.

## Rehearse on production-sized data, with preflight queries

An empty test database proves only that the SQL parses. Bad data and slow rewrites show up on a copy, so restore a
recent dump or use a provider's database branch, run the migration, and time each step. `createdb -T prod rehearsal`
needs no other session connected to the source, so use it only on a copy you can take offline. A rehearsal has no
concurrent traffic: it finds data problems and durations, not lock contention or replica lag.

Before a constraint or a type change, ask the data the question the constraint will ask. Each query below returns the
rows that would make the step fail.

```sql
-- UNIQUE: values held by more than one row
SELECT code, count(*) FROM shop.tickets WHERE code IS NOT NULL GROUP BY code HAVING count(*) > 1 LIMIT 20;
-- FOREIGN KEY: rows pointing at nothing
SELECT t.id, t.ref FROM shop.tickets t
WHERE t.ref IS NOT NULL AND NOT EXISTS (SELECT 1 FROM shop.refs r WHERE r.id = t.ref) LIMIT 20;
-- type change: text that the new type would refuse (pg_input_is_valid is PostgreSQL 16+)
SELECT id, amount FROM shop.tickets
WHERE amount IS NOT NULL AND NOT pg_input_is_valid(amount, 'numeric(12,2)') LIMIT 20;
```

`NOT VALID` adds a check for new rows only, so old offenders stay until `VALIDATE` fails on them: run these first.

## Rollback is a forward fix

Down migrations look safe and are not: a down that drops a column you just backfilled destroys data. Keep every
migration expand-only so the previous application version still runs against the new schema; rollback is then
"redeploy the previous version". A bad migration is fixed by a new forward migration. Backups and point-in-time
recovery are for data loss, not for undoing an `ALTER`.

## Roles for migrations

Run migrations as a role that owns the schema objects and has DDL rights; run the application as a role with only
DML. The app cannot drop a table it does not own (`postgres-security-roles`).

## Worked example: "make orders.customer_id NOT NULL on a 200 million row table"

A plain `ALTER TABLE app.orders ALTER COLUMN customer_id SET NOT NULL` scans all 200 million rows under
`ACCESS EXCLUSIVE`, so every read and write waits for minutes. Ship it as three short steps instead (PostgreSQL 18):

```sql
-- migration 1: enforce for new rows at once, no scan
SET lock_timeout = '3s';
ALTER TABLE app.orders ADD CONSTRAINT orders_customer_id_nn NOT NULL customer_id NOT VALID;
-- between migrations: backfill or delete the old NULL rows in batches, then confirm
SELECT count(*) FROM app.orders WHERE customer_id IS NULL;        -- must be 0
-- migration 2: check old rows under a lock that allows reads and writes
SET lock_timeout = '3s';
ALTER TABLE app.orders VALIDATE CONSTRAINT orders_customer_id_nn;
```

On PostgreSQL 12 to 17 use `CHECK (customer_id IS NOT NULL) NOT VALID`, `VALIDATE CONSTRAINT`, then
`SET NOT NULL` (which skips the scan because the valid check proves it) and drop the check. If a step fails on
`lock_timeout`, look for the long transaction in `pg_stat_activity` and retry.

## Verify a migration after it runs and when it is run again

Rehearse on a copy, then run these on the target. Both queries return no rows when nothing was left half done, and
they ran on 18.6.

```sql
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;              -- a failed CONCURRENTLY build shows here
SELECT conrelid::regclass, conname FROM pg_constraint WHERE NOT convalidated;   -- a NOT VALID still waiting for VALIDATE
```

```bash
./migrate-retry.sh 0042_add_column.sql       # applied on attempt 1
./migrate-retry.sh 0042_add_column.sql       # a file with IF NOT EXISTS applies again; anything else stops on 42701
```

To prove the retry itself, hold `LOCK TABLE` in a second session for a few seconds and run the wrapper: it prints `lock
busy, attempt 1 of 8`, then `applied on attempt 2`, and with `--single-transaction` every statement landed exactly
once.

## Checklist

Check these points before you call a migration done.

- [ ] The migration begins with `SET lock_timeout` and `SET statement_timeout`.
- [ ] Every statement is on the safe side of the table above, or uses the safe way.
- [ ] A failed lock is retried from outside the database, and only on `55P03`.
- [ ] A rerun is safe: `IF NOT EXISTS` where it exists, a catalog check for `ADD CONSTRAINT`.
- [ ] Preflight queries ran, and the migration was timed on a production-sized copy.
- [ ] Concurrent index builds are in their own non-transactional migration; `indisvalid` was checked after each.
- [ ] Constraints are added `NOT VALID` and validated separately.
- [ ] Renames and type changes use expand and contract across several deploys.
- [ ] Backfills run in committed batches with replica lag watched.
- [ ] Migrations run once, from CI, under an advisory lock, on a direct connection, before the app deploy.
- [ ] No down migration that destroys data; rollback means redeploying the previous app.

## Gotchas

These are the failures seen most often with a migration, each with its cause and fix.

1. **The whole site stalled during a small `ALTER`.** The `ALTER` waited on a long query and blocked everything
   behind it. Fix: `lock_timeout`, and kill or wait out long transactions first.
2. **`CREATE INDEX CONCURRENTLY cannot run inside a transaction block`.** The tool wrapped the file. Turn the
   transaction off for that migration.
3. **Adding a column with `DEFAULT gen_random_uuid()` locked the table for minutes.** Volatile defaults rewrite the
   table. Add the column bare, backfill, then set the default.
4. **`SET NOT NULL` scanned a huge table under lock.** Use the `NOT VALID` route for the version you run.
5. **An ORM generated a rename.** Tools such as Drizzle Kit and Prisma offer a rename when a column disappears and
   another appears. On a live system, decline and write expand and contract.
6. **An enum value added in a migration fails when used in the same migration.** `ALTER TYPE ... ADD VALUE` must
   commit first.
7. **Migrations through a transaction pooler fail oddly.** Session state, advisory locks and prepared statements do
   not survive. Use the direct URL.
8. **A dropped column's sensitive values are still on disk.** `DROP COLUMN` only hides the column: `pg_attribute`
   keeps a `........pg.dropped.N........` entry, and old row versions keep the bytes until they are rewritten. To
   clear data at once, run a statement that rewrites the table (`VACUUM FULL`) in a window, then remember that WAL
   archives, replicas' history and backups still hold the old values until they expire.
9. **`VALIDATE CONSTRAINT` hangs with no blocker in the application.** It conflicts with an autovacuum on the same
   table. An ordinary autovacuum cancels itself; one marked `(to prevent wraparound)` in `pg_stat_activity` does not.
   Let it finish: cancelling it only delays the freeze the table needs.

## Anti-patterns in shipping schema changes

These are how a safe statement still takes a site down.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Migrating at application startup | instances race, and a failure crash-loops the app | one CI job before the deploy, under an advisory lock |
| DDL with no `lock_timeout` | the `ALTER` queues all traffic behind a long query | `SET lock_timeout` first and a retry from outside |
| Many steps in one transaction | every lock is held until the last step commits | small migrations, one risky step each |
| One `UPDATE` for the whole table | long locks, bloat and a burst of WAL | committed batches with a pause |
| A rename or type change in one deploy | running instances still use the old name | expand and contract across deploys |
| Editing a migration that already ran | environments drift apart with no record | a new forward migration |
| Testing only on an empty database | bad rows and rewrite times stay hidden | preflight queries and a timed run on a production-sized copy |

## See also

Related skills in this library:

- `postgres-schema-design`: what the tables should look like
- `postgres-transactions-locking`: locks and finding blockers
- `postgres-testing-ci`: testing migrations down and up in CI
- `postgres-zero-downtime-upgrades`: major version upgrades, a different job
- `postgres-constraints-integrity`: `NOT VALID` constraints in depth
