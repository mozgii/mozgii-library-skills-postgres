---
name: postgres-cdc-logical-decoding
description: 'Captures row changes from PostgreSQL 18 with logical decoding: wal_level logical, replication slots and the disk and vacuum risks they carry, max_slot_wal_keep_size and idle_replication_slot_timeout, output_plugin_libraries (new in 18.6), publications with row filters, column lists and generated columns, REPLICA IDENTITY, pgoutput versus wal2json and test_decoding, pg_recvlogical, Debezium 3.7, failover slots and consuming changes from an application. Use when streaming database changes to Kafka, a search index, a cache or another service, setting up Debezium, a slot fills the disk, "may not be used as an output plugin" appears, or updates fail with "does not have a replica identity".'
metadata:
  tags:
  - postgres
  - cdc
  - logical-decoding
  - replication-slots
  - debezium
  - wal2json
  - pgoutput
  - publications
  - failover-slots
---

# PostgreSQL change data capture with logical decoding

Change data capture (CDC) reads committed row changes from the write-ahead log through a logical replication slot
and an output plugin, in commit order, without triggers or polling. Use `pgoutput` with a publication for anything
long-lived; it ships with PostgreSQL and Debezium speaks it. A slot keeps WAL and catalog rows until its consumer
confirms them, so every slot needs a size cap, an idle timeout and an alert. Delivery is at least once. Postgres-to-Postgres replication with
subscriptions is in `postgres-replication-ha` and its `references/logical-replication.md`; this skill is about
feeding other systems. Slot report: [scripts/slot-health.sql](scripts/slot-health.sql).

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: read the server settings and the slots that exist

Read the version and what already consumes WAL: an unknown slot is the most common cause of a full disk.

```sql
SELECT version();
SELECT name, setting, pending_restart FROM pg_settings
WHERE name IN ('wal_level', 'max_replication_slots', 'max_wal_senders', 'max_slot_wal_keep_size',
               'idle_replication_slot_timeout', 'output_plugin_libraries');
SELECT slot_name, plugin, slot_type, active, wal_status FROM pg_replication_slots;
SELECT pubname, puballtables FROM pg_publication;
```

## Server settings for logical decoding

Logical decoding needs `wal_level = logical`, which only takes effect after a restart; plan it before you need CDC.
These are the settings a CDC primary should have, with the PostgreSQL 18.6 defaults in comments.

```ini
wal_level = logical                        # default replica; restart required
max_replication_slots = 10                 # default 10; one per consumer, plus spares
max_wal_senders = 10                       # default 10; one per streaming consumer
max_slot_wal_keep_size = 50GB              # default -1 (unlimited): an abandoned slot fills the disk
idle_replication_slot_timeout = 2d         # PG 18, default 0 (off): invalidates slots unused this long
logical_decoding_work_mem = 64MB           # default 64MB; larger transactions spill to disk
output_plugin_libraries = 'pgoutput, test_decoding, wal2json'   # PG 18.6, default 'pgoutput, test_decoding'
```

- `output_plugin_libraries` arrived in 18.6 (CVE-2026-6471): any other plugin, such as `wal2json` or Debezium's
  `decoderbufs`, is refused with `library "wal2json" may not be used as an output plugin` until listed. The
  parameter is superuser-settable and takes effect on reload. `pg_upgrade --check` fails when the new cluster's
  list does not cover the old cluster's logical slots.
- With `ALTER SYSTEM`, list each name as its own literal: `ALTER SYSTEM SET output_plugin_libraries = 'pgoutput',
  'test_decoding', 'wal2json';`. One quoted string `'pgoutput, test_decoding, wal2json'` becomes a single
  library name and every plugin is refused (seen on 18.6).
- A slot past `max_slot_wal_keep_size` becomes `lost` and its consumer must resnapshot: better than a full disk.

## Output plugins: pgoutput, wal2json, test_decoding, decoderbufs

The output plugin turns decoded changes into the consumer's format; the slot is bound to one plugin for life.

| Plugin | Ships with | Format | Use for |
|---|---|---|---|
| `pgoutput` | PostgreSQL | binary logical replication protocol (versions 1 to 4) | Debezium, subscriptions, most CDC tools |
| `test_decoding` | PostgreSQL contrib | human-readable text | learning and debugging only |
| `wal2json` 2.7 | `postgresql-18-wal2json` (apt), `wal2json_18` (yum) | JSON per change or per transaction | simple consumers that want JSON |
| `decoderbufs` | `postgresql-18-decoderbufs` (apt) | Protocol Buffers | Debezium when configured for it |

Only `pgoutput` filters by publication; the others decode every table unless their own options filter it.

| Need | Choose | Why the others lose |
|---|---|---|
| a Kafka or sink pipeline with snapshots and schema handling | Debezium on `pgoutput` | hand-written consumers rebuild all of that |
| a small service reacting to changes | `pglogrepl` or the embedded Debezium engine | Kafka is more than one consumer needs |
| JSON for a simple consumer | `wal2json` | binary `pgoutput` needs a protocol parser |
| another PostgreSQL as the target | subscriptions (`postgres-replication-ha`) | CDC tooling repeats what the server already does |
| events in commit order with no table | `pg_logical_emit_message` | an outbox table needs polling and cleanup |

## Trying logical decoding with test_decoding

The SQL interface creates a slot and reads its changes without a streaming client, which is the quickest way to
see what a consumer will receive. `peek` leaves changes in the slot; `get` consumes them and advances it.

```sql
CREATE SCHEMA shop;
CREATE TABLE shop.orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL,
  status      text   NOT NULL DEFAULT 'new',
  total_cents bigint NOT NULL,
  card_last4  text,
  total_eur   numeric GENERATED ALWAYS AS (total_cents / 100.0) STORED
);
SELECT * FROM pg_create_logical_replication_slot('cdc_debug', 'test_decoding');
INSERT INTO shop.orders (customer_id, total_cents, card_last4) VALUES (7, 4200, '4242');
UPDATE shop.orders SET status = 'paid' WHERE id = 1;
DELETE FROM shop.orders WHERE id = 1;
SELECT lsn, xid, data FROM pg_logical_slot_get_changes('cdc_debug', NULL, NULL,
  'include-xids', '0', 'skip-empty-xacts', '1');
SELECT pg_drop_replication_slot('cdc_debug');
```

The delete arrives as `DELETE: id[bigint]:1`, only the primary key, under the default replica identity. Always drop
test slots.

## REPLICA IDENTITY: what updates and deletes carry

REPLICA IDENTITY decides which old column values the WAL keeps for `UPDATE` and `DELETE`. Consumers that need the
previous row (audit, search index removal by a non-key field) need more than the default.

| Setting | Old values sent | Cost |
|---|---|---|
| `DEFAULT` | primary key columns | none; a table without a primary key behaves as `NOTHING` |
| `USING INDEX idx` | columns of a unique, non-partial, non-deferrable index on `NOT NULL` columns | small |
| `FULL` | every column | more WAL on every update and delete |
| `NOTHING` | none | updates and deletes cannot be published |

This makes a unique index on `(id, status)` the replica identity, so the publication below may filter on `status`.

```sql
CREATE UNIQUE INDEX orders_id_status_uq ON shop.orders (id, status);
ALTER TABLE shop.orders REPLICA IDENTITY USING INDEX orders_id_status_uq;
SELECT relname, relreplident FROM pg_class WHERE oid = 'shop.orders'::regclass;   -- i = index, f = full, d = default
```

- A table in a publication that publishes updates or deletes must have a replica identity, or the application's
  own `UPDATE` fails: `cannot update table "no_pk" because it does not have a replica identity and publishes
  updates`. Add a primary key or set `REPLICA IDENTITY FULL` before publishing.
- Unchanged TOASTed (large, out-of-line) values are not sent on update unless the identity is `FULL`:
  test_decoding prints `unchanged-toast-datum`, Debezium substitutes `unavailable.value.placeholder`.

## Publications for CDC: row filters, column lists, generated columns

A publication picks the tables, operations, rows and columns that `pgoutput` sends. Use one publication per
consumer, named for it, so changing one consumer's scope does not affect another.

```sql
CREATE PUBLICATION cdc_orders
  FOR TABLE shop.orders (id, customer_id, status, total_cents, total_eur)
  WHERE (status <> 'draft')
  WITH (publish = 'insert, update, delete', publish_generated_columns = stored);
SELECT pubname, schemaname, tablename, attnames, rowfilter FROM pg_publication_tables;
```

- Column lists keep sensitive columns (`card_last4` here) out of the stream.
- When a publication publishes updates or deletes, a row filter may use only replica identity columns, and a
  column list must include every replica identity column. Otherwise the application's own `UPDATE` fails with
  `Column used in the publication WHERE expression is not part of the replica identity` or `Column list used by
  the publication does not cover the replica identity`. The example works because the identity index is
  `(id, status)`: the filter column is in it and the column list covers it. With `REPLICA IDENTITY FULL`, a column
  list must name every column (both failures reproduced on 18.6).
- PostgreSQL 18 publishes stored generated columns with `publish_generated_columns = stored` or by naming them in
  the column list; virtual generated columns (the 18 default) cannot be published: `cannot use virtual generated
  column ... in publication column list`.
- `CREATE PUBLICATION` needs `CREATE` on the database and table ownership; `FOR ALL TABLES` needs a superuser.

## Logical decoding messages instead of an outbox table

`pg_logical_emit_message(true, prefix, content)` writes an event into WAL inside the current transaction; decoders
deliver it in commit order with the row changes (`pgoutput` with `messages 'true'`, wal2json as `"action":"M"`).
It is an outbox with no table to poll, delete or vacuum. Peeking `pgoutput` from SQL, wal2json options and a
message example: [references/debezium-and-consumers.md](references/debezium-and-consumers.md).

## Streaming changes with pg_recvlogical

`pg_recvlogical` is the bundled streaming client: it creates slots, streams decoded changes to a file or stdout and
confirms progress to the server. It connects with the replication protocol, so `pg_hba.conf` needs a line for the
database itself; the `replication` keyword matches physical replication only.

```bash
pg_recvlogical -d app --slot=cdc_cli --create-slot --plugin=wal2json --if-not-exists
pg_recvlogical -d app --slot=cdc_cli --start -o format-version=2 -o include-lsn=1 -f changes.jsonl
pg_recvlogical -d app --slot=cdc_cli --drop-slot
```

`--endpos=LSN` stops at a position (useful in tests); `--enable-failover` (PG 18) creates a failover slot.

## Debezium with PostgreSQL

Debezium 3.7 (3.7.0.Final, September 2026) streams changes to Kafka or other sinks and is tested against
PostgreSQL 14 to 18 with the `decoderbufs` and `pgoutput` plugins, on Java 17 or later. Three settings decide
whether it works on the first try:

- `plugin.name` defaults to `decoderbufs`: set `pgoutput`, or install decoderbufs and list it in
  `output_plugin_libraries`.
- `publication.autocreate.mode` defaults to `all_tables`, which runs `CREATE PUBLICATION ... FOR ALL TABLES` and
  needs a superuser: create the publication yourself and set `disabled` (or `filtered`).
- `heartbeat.interval.ms` (default 0, off) lets a connector on a quiet database confirm newer LSNs so its slot
  releases WAL.

A full connector configuration, the database role, snapshots and operations:
[references/debezium-and-consumers.md](references/debezium-and-consumers.md).

## Replication slot risks and monitoring

A logical slot holds WAL from its `restart_lsn` and holds back vacuum of system catalogs (`catalog_xmin`) until
the consumer confirms progress. A stopped consumer therefore grows `pg_wal` and catalog bloat without limit unless
a cap invalidates the slot.

```sql
SELECT slot_name, plugin, active, wal_status, safe_wal_size, invalidation_reason, inactive_since,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))        AS retained_wal,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS consumer_lag
FROM pg_replication_slots WHERE slot_type = 'logical';
SELECT slot_name, spill_txns, spill_bytes, stream_txns, total_txns FROM pg_stat_replication_slots;
```

- `wal_status`: `reserved` (within `max_wal_size`), `extended`, `unreserved` (about to lose WAL), `lost`.
- `invalidation_reason`: `wal_removed`, `rows_removed`, `wal_level_insufficient`, `idle_timeout`. An invalidated
  slot fails with `can no longer access replication slot`; drop it and resnapshot the consumer.
- `idle_replication_slot_timeout` is checked at checkpoints: with `1min`, an idle slot became `lost` with
  `idle_timeout` at the next `CHECKPOINT` (tested on 18.6). Synced slots on a standby are exempt.
- High `spill_bytes` means transactions larger than `logical_decoding_work_mem`; raise it or use streaming.

## Failover slots in PostgreSQL 17 and 18

A logical slot normally exists only on the primary, so after failover the consumer has no slot and must
resnapshot. Failover slots (PG 17+) are copied to a physical standby so the consumer can continue on the new
primary.

| Where | Setting |
|---|---|
| Slot | created with `failover` true: `pg_create_logical_replication_slot(name, plugin, false, false, true)`, `pg_recvlogical --enable-failover`, Debezium `slot.failover = true`, or `CREATE SUBSCRIPTION ... WITH (failover = true)` |
| Primary | `synchronized_standby_slots = 'standby1_slot'` so consumers never get ahead of the standby |
| Standby | `sync_replication_slots = on` (default off), `primary_slot_name` set, `hot_standby_feedback = on`, a `dbname` in `primary_conninfo` |

Only slots with `synced = true` on the standby at failover survive it. Disable the consumer during promotion,
then point it at the new primary.

## Consuming changes from an application

An application consumer streams from its slot over a replication connection and reports the LSN it has applied, so
the server can free WAL. Use `pglogrepl` (Go, with pgx), psycopg2's `LogicalReplicationConnection` (Python;
psycopg 3 has no replication protocol support yet) or the embedded Debezium engine (Java). Store the last applied
LSN in the same transaction as the applied data and skip anything at or below it after a restart: the server may
resend from the slot's last persisted position. Details:
[references/debezium-and-consumers.md](references/debezium-and-consumers.md).

## Worked example: "our consumer gets updates but no old values"

A consumer needs the previous `status` of each order to detect transitions. Reproduce it with a throwaway slot before
touching Debezium. This ran on 18.6 with `wal_level = logical`.

```sql
SELECT pg_create_logical_replication_slot('probe', 'test_decoding');
INSERT INTO app.orders VALUES (1, 'new');
UPDATE app.orders SET status = 'paid' WHERE id = 1;
ALTER TABLE app.orders REPLICA IDENTITY FULL;
UPDATE app.orders SET status = 'sent' WHERE id = 1;
SELECT data FROM pg_logical_slot_get_changes('probe', NULL, NULL) WHERE data LIKE 'table%';
SELECT pg_drop_replication_slot('probe');                -- never leave a probe slot behind: it pins WAL
```

The first update arrives as `UPDATE: id[bigint]:1 status[text]:'paid'`, with no old values, because the default replica
identity is the primary key and that key did not change. After `REPLICA IDENTITY FULL` the second arrives as
`UPDATE: old-key: id[bigint]:1 status[text]:'paid' new-tuple: id[bigint]:1 status[text]:'sent'`. FULL writes the whole
old row to WAL on every update and delete, so set it only on the tables whose consumers need it.

## Verify a CDC pipeline end to end

Prove that a change reaches the consumer, that the slot advances, and that the filter holds, on staging.

```sql
INSERT INTO shop.orders (customer_id, total_cents, card_last4) VALUES (7, 100, '4242');   -- must reach the sink
SELECT slot_name, active, wal_status, confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag
FROM pg_replication_slots WHERE slot_type = 'logical';
```

Run the write twice, a minute apart: `confirmed_flush_lsn` must move and `lag` must fall back near zero. Confirm the sink
never holds `card_last4`. Stop the consumer and check that the retained-WAL alert fires before the disk is at risk,
then restart it and confirm it resumes without a resnapshot, with duplicates tolerated.

## Gotchas

These are the failures seen most often with logical decoding, each with its cause and fix.

1. **`library "wal2json" may not be used as an output plugin` after a minor upgrade to 18.6.** The new
   `output_plugin_libraries` allowlist. Add the plugin as a separate list element and reload.
2. **The primary's disk filled with WAL.** A consumer stopped and its slot kept WAL. Set
   `max_slot_wal_keep_size` and `idle_replication_slot_timeout`, alert on `retained_wal`, drop dead slots.
3. **Application updates fail after creating a publication.** No replica identity, a row filter on a non-identity
   column, or a column list missing an identity column. Add a primary key, or an identity index that covers the
   filter columns and is covered by the column list.
4. **Debezium cannot start: plugin not found.** `plugin.name` defaults to `decoderbufs`. Set `pgoutput`.
5. **The consumer resnapshots after every failover.** The slot was not a failover slot or the standby did not sync
   it (`synced = false`). Set up the three rows of the failover table and check `synced` before failover.

## Checklist

Check these points before you call a CDC pipeline done.

- [ ] `wal_level = logical` is set and the restart is done; slots and senders have spare capacity.
- [ ] `max_slot_wal_keep_size` and `idle_replication_slot_timeout` are set; slot lag is alerted.
- [ ] Every plugin in use is listed in `output_plugin_libraries` (18.6+).
- [ ] Published tables have a primary key or a deliberate replica identity.
- [ ] Each consumer has its own slot and publication, with sensitive columns excluded.
- [ ] Consumers store the applied LSN with the data and tolerate replays.
- [ ] Failover slots are configured and `synced` is true on the standby, or a resnapshot plan exists.
- [ ] Test slots are dropped.

## Anti-patterns in change data capture

| Do not | Do this instead |
|---|---|
| leave a slot with no size cap or alert | `max_slot_wal_keep_size`, `idle_replication_slot_timeout`, and a lag alert |
| leave a test slot behind | drop it in the same session |
| share one slot between consumers | one slot and one publication per consumer |
| publish every column by default | a column list without sensitive columns |
| assume exactly-once delivery | store the applied LSN with the data and tolerate replays |
| use `test_decoding` in production | `pgoutput` |

## See also

- `postgres-replication-ha`: subscriptions between PostgreSQL servers.
- `postgres-queues-jobs`: the transactional outbox.
- `postgres-monitoring-observability`: alerts on slots and WAL.
- `postgres-patroni-ha`: failover around slots.
- `postgres-fdw-federation`: reading another system in place of copying it.

## Sources

- https://www.postgresql.org/docs/18/logicaldecoding-explanation.html
- https://www.postgresql.org/docs/18/logicaldecoding-example.html
- https://www.postgresql.org/docs/18/runtime-config-replication.html
- https://www.postgresql.org/docs/18/release-18-6.html (output_plugin_libraries, CVE-2026-6471)
- https://www.postgresql.org/docs/18/functions-admin.html (replication functions)
- https://www.postgresql.org/docs/18/view-pg-replication-slots.html
- https://www.postgresql.org/docs/18/sql-createpublication.html
- https://www.postgresql.org/docs/18/sql-altertable.html (REPLICA IDENTITY)
- https://www.postgresql.org/docs/18/auth-pg-hba-conf.html
- https://www.postgresql.org/docs/18/app-pgrecvlogical.html and `pg_recvlogical --help` on 18.6
- https://github.com/eulerto/wal2json (README, release wal2json_2_7)
- https://debezium.io/documentation/reference/stable/connectors/postgresql.html
- https://debezium.io/releases/3.7/
- https://github.com/psycopg/psycopg/issues/71
