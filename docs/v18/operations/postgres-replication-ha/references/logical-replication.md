---
title: PostgreSQL logical replication
author: MOZGII, Inc.
lang: en
---

# PostgreSQL logical replication

This reference covers logical replication with publications and subscriptions: setup, what it does not copy,
conflicts, monitoring, and using it for a major-version upgrade with little downtime.

## Contents

The sections of this reference on postgreSQL logical replication:

1. Logical replication setup
2. What logical replication does not copy
3. Row filters and column lists
4. Conflicts and errors on the subscriber
5. Monitoring logical slots on the publisher
6. Major upgrade with logical replication

## Logical replication setup

Logical replication decodes WAL into row changes and sends them to subscribers. The publisher needs
`wal_level = logical` (restart required) and enough slots and senders.

```ini
# publisher postgresql.conf
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
```

```sql
-- publisher: a role that can read the tables and replicate
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '<from your secret store>';
GRANT USAGE ON SCHEMA app TO replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO replicator;
CREATE PUBLICATION app_pub FOR TABLES IN SCHEMA app;          -- PG 15+; or FOR TABLE a, b

-- subscriber: create the same tables first (pg_dump --schema-only), then
CREATE SUBSCRIPTION app_sub
  CONNECTION 'host=primary.internal dbname=app user=replicator sslmode=verify-full'
  PUBLICATION app_pub
  WITH (copy_data = true, disable_on_error = true);
```

The subscription copies existing rows first (initial sync), then streams changes.

## What logical replication does not copy

Logical replication copies row changes of published tables only.

- **DDL**: schema changes are not replicated. Apply each migration to the subscriber first (adding columns), then
  the publisher.
- **Sequences**: values are not replicated; after cutover, set each sequence past the max id
  (`SELECT setval('app.orders_id_seq', (SELECT max(id) FROM app.orders))`).
- **Large objects**, materialized views, and `TRUNCATE` on tables with foreign keys to unpublished tables.
- **Tables without a primary key** replicate inserts, but once a publication publishes updates and deletes those
  statements fail on the publisher: `ERROR: cannot update table "nokey" because it does not have a replica identity
  and publishes updates`. Set `REPLICA IDENTITY FULL` (slow for updates) or `REPLICA IDENTITY USING INDEX`.
- **Generated columns**: PG 18 can publish them with `publish_generated_columns = stored`; earlier versions compute
  them on the subscriber.

## Row filters and column lists

Publications can send a subset of rows or columns (PG 15+). This one publishes inserts only, because `region` is not
in the replica identity of a table keyed on `id`:

```sql
CREATE PUBLICATION eu_pub FOR TABLE app.customers (id, email, region) WHERE (region = 'eu')
  WITH (publish = 'insert');
```

A row filter on `UPDATE`/`DELETE` may only use columns in the replica identity. Without `publish = 'insert'`, updates
to the table fail on the publisher, on 18.6 with `ERROR: cannot update table "customers"` and `DETAIL: Column used in
the publication WHERE expression is not part of the replica identity.` To publish them too, make `region` part of the
identity: set it `NOT NULL`, create a unique index on `(id, region)` and run `ALTER TABLE app.customers REPLICA
IDENTITY USING INDEX customers_id_region_key`. `REPLICA IDENTITY FULL` does not help here, because a publication with
a column list refuses it (`Column list used by the publication does not cover the replica identity`).

## Conflicts and errors on the subscriber

The subscriber applies changes as normal writes, so a unique violation or a missing table stops the apply worker.

```sql
SELECT subname, worker_type, pid, received_lsn, latest_end_lsn, last_msg_receipt_time FROM pg_stat_subscription;
SELECT subname, apply_error_count, sync_error_count FROM pg_stat_subscription_stats;
-- PostgreSQL 19 replaces sync_error_count with sync_table_error_count and sync_seq_error_count
-- after fixing the cause, or to skip one failed transaction (LSN from the server log):
ALTER SUBSCRIPTION app_sub SKIP (lsn = '0/14C0378');
ALTER SUBSCRIPTION app_sub ENABLE;
```

With `disable_on_error = true` the subscription disables itself instead of retrying in a loop.

## Monitoring logical slots on the publisher

Each subscription holds a logical slot on the publisher; a stopped subscriber makes it retain WAL.

```sql
SELECT slot_name, plugin, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS behind
FROM pg_replication_slots WHERE slot_type = 'logical';
```

Dropping a subscription drops its remote slot; if the publisher is unreachable, run
`ALTER SUBSCRIPTION app_sub SET (slot_name = NONE)` before `DROP SUBSCRIPTION`, then drop the slot on the publisher
when it is back.

## Major upgrade with logical replication

Logical replication lets you upgrade to a new major with downtime of seconds: the new cluster follows the old one,
then clients switch.

1. Build the new-major cluster; restore roles (`pg_dumpall --globals-only`) and schema (`pg_dump --schema-only`).
2. Publish all tables on the old cluster; subscribe from the new one; wait until initial sync finishes
   (`pg_subscription_rel.srsubstate = 'r'` for all tables).
3. Freeze schema changes. Check row counts on both sides.
4. Stop writes on the old cluster (maintenance mode or revoke the app role's write rights); wait for lag to reach 0.
5. Set sequences on the new cluster past the old values.
6. Point clients at the new cluster; drop the subscription.

PG 17 adds `pg_createsubscriber`, which turns a physical replica into a logical subscriber without the initial copy,
and `pg_upgrade` keeps logical slots from PG 17 on, so subscriptions survive an upgrade of the publisher.
