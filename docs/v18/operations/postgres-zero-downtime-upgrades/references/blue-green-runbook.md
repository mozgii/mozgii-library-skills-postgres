---
title: PostgreSQL blue/green upgrade runbook
author: MOZGII, Inc.
lang: en
---

# PostgreSQL blue/green upgrade runbook

This runbook moves a production database from an old major version (blue) to a new one (green) with logical
replication, with a cutover of seconds and a fallback to blue. It was run end to end from PostgreSQL 17.11 to 18.6
on scratch clusters, including the `pg_createsubscriber` path, sequence sync, cutover and reverse replication.

## Readiness checks on blue

Logical replication needs a primary key or a replica identity to apply updates and deletes, and it does not copy
large objects, sequence values or DDL. Run these on blue in every database you will move:

```sql
-- tables that logical replication cannot update or delete in
SELECT c.oid::regclass AS table_name, c.relreplident
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary)
  AND c.relreplident IN ('d', 'n')
ORDER BY 1;
-- large objects are not replicated
SELECT count(*) AS large_objects FROM pg_largeobject_metadata;
```

Fix each table found: add a primary key, or `ALTER TABLE ... REPLICA IDENTITY USING INDEX <unique index>`, or as a
last resort `REPLICA IDENTITY FULL` (every update then logs the whole old row). Move large objects into `bytea`
columns or copy them during the freeze.

## Settings on blue and green

Blue publishes and green subscribes; both need room for slots and workers.

| Setting | Blue | Green |
|---|---|---|
| `wal_level` | `logical` (restart) | `logical` if green will publish back to blue for rollback |
| `max_replication_slots`, `max_wal_senders` | existing use plus one per subscription | room for the reverse slot |
| `max_slot_wal_keep_size` | large enough for the longest pause; `-1` while `pg_createsubscriber` runs | as usual |
| `max_active_replication_origins` (18) | | at least the number of subscriptions (default 10) |
| `max_logical_replication_workers`, `max_worker_processes` | | enough for apply and table sync workers |
| `output_plugin_libraries` (18.6) | | includes `pgoutput` (the default does) |

## Path A: plain logical replication with an initial copy

Path A copies all data through the subscription. It is simple and works from any supported old version. Copy the
roles and the schema first:

```bash
pg_dumpall -h blue --roles-only | psql -h green -d postgres        # roles first; passwords come along as hashes
pg_dump -h blue --schema-only -d app | psql -h green -d app        # the schema, without data
```

```sql
-- on blue
CREATE PUBLICATION upgrade_pub FOR ALL TABLES;
-- on green
CREATE SUBSCRIPTION upgrade_sub
  CONNECTION 'host=blue dbname=app user=replicator'
  PUBLICATION upgrade_pub
  WITH (copy_data = true);
-- wait until every table is ready ('r')
SELECT srsubstate, count(*) FROM pg_subscription_rel GROUP BY 1;
```

Build secondary indexes on green after the initial copy if the copy is slow; each index slows every copied row.

## Path B: pg_createsubscriber, then pg_upgrade

Path B starts green as a physical copy of blue, so nothing is copied through logical replication. It needs blue on
17 or later, because `pg_createsubscriber` exists from 17 and subscriptions survive `pg_upgrade` only from 17.

1. On a green host with the old binaries: `pg_basebackup -h blue -D <green-old> -X stream -c fast -R -C -S green_slot`
   and start it as a standby; wait until it streams.
2. Stop it, then run `pg_createsubscriber -D <green-old> -P "host=blue dbname=app user=postgres" -d app -U postgres
   --publication=bg_pub --subscription=bg_sub --replication-slot=bg_slot`. It must run on the target, with the
   target stopped and the same major version on both sides.
3. Start green (still old version) and confirm rows arrive. In our run, `pg_subscription_rel` showed state `r` and
   blue's `green_slot` was gone, replaced by `bg_slot`.
4. `ALTER SUBSCRIPTION bg_sub DISABLE`, stop green, `initdb` a new-version cluster matching green, and `pg_upgrade`
   green to the new version (`--clone` or `--link`).
5. Start green on the new version and `ALTER SUBSCRIPTION bg_sub ENABLE`. Writes made on blue during the upgrade
   arrive; in our run both sides then held the same 201,500 rows.

`pg_createsubscriber` changes green's system identifier with `pg_resetwal`, so any standby of green must be rebuilt.
If it fails after promoting the target, the docs advise building a new standby rather than repairing it.

## Watching replication before cutover

Lag must be near zero and stable before you freeze writes. On blue, the slot's position shows how far green is
behind; on green, `pg_stat_subscription` shows the apply worker:

```sql
-- on blue
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS behind
FROM pg_replication_slots WHERE slot_type = 'logical';
-- on green
SELECT subname, worker_type, received_lsn, latest_end_lsn, last_msg_receipt_time FROM pg_stat_subscription;
```

Freeze DDL on blue from now on. If DDL slips through, the apply worker stops with an error such as `logical
replication target relation "public.t" is missing replicated column: "note"`; run the same DDL on green and it
resumes.

## Cutover steps

The cutover stops writes on blue, waits for green to apply the last change, copies sequences and moves clients.

1. Stop writes on blue: `ALTER DATABASE app SET default_transaction_read_only = on;`, then terminate client
   sessions (`pg_terminate_backend` on `backend_type = 'client backend'`). Sessions that reconnect start read-only.
2. Note `pg_current_wal_lsn()` on blue and wait until the subscription slot's `confirmed_flush_lsn` is at or past it.
3. Sync sequences. Logical replication leaves green's sequences at their old values; ours sat at 200000 while the
   table held ids up to 201500. On blue, as a role that can read every sequence, run this query with `psql -X -At`,
   then apply its output on green with `psql -X -v ON_ERROR_STOP=1 -f`:

   ```sql
   SELECT format('SELECT setval(%L, %s, true);',
                 format('%I.%I', schemaname, sequencename),
                 CASE WHEN increment_by > 0
                      THEN least(last_value + 1000 * increment_by, max_value)
                      ELSE greatest(last_value + 1000 * increment_by, min_value) END)
   FROM pg_sequences
   WHERE last_value IS NOT NULL
   ORDER BY schemaname, sequencename;
   ```

   The 1000 is a safety gap. A `NULL` `last_value` means the sequence was never used, or the role cannot read it.
4. Create the reverse path for rollback, before green takes any write: on green `CREATE PUBLICATION rollback_pub FOR
   ALL TABLES;`, on blue (in a session with `SET default_transaction_read_only = off`) `CREATE SUBSCRIPTION
   rollback_sub CONNECTION 'host=green ...' PUBLICATION rollback_pub WITH (copy_data = false);`. Blue's apply
   worker wrote into the read-only-by-default database in our test.
5. On green: `DROP SUBSCRIPTION bg_sub;` (it drops `bg_slot` on blue).
6. Move clients: DNS, a proxy or PgBouncer `[databases]` entry, or the connection string. Check that writes land on
   green and arrive on blue.

## Rolling back after cutover

With reverse replication running, blue stays current. To roll back: freeze writes on green the same way, wait for
`rollback_sub` to catch up, sync sequences from green to blue, drop `rollback_sub` on blue, set blue writable
(`ALTER DATABASE app RESET default_transaction_read_only`) and move clients back. Keep blue and the reverse path for
a fixed period (a week of normal traffic), then drop the subscription on blue and retire blue.

## Sources

- https://www.postgresql.org/docs/18/logical-replication.html
- https://www.postgresql.org/docs/18/logical-replication-restrictions.html
- https://www.postgresql.org/docs/18/logical-replication-upgrade.html
- https://www.postgresql.org/docs/18/app-pgcreatesubscriber.html
- https://www.postgresql.org/docs/18/sql-createsubscription.html
- https://www.postgresql.org/docs/18/monitoring-stats.html (`pg_stat_subscription`)
