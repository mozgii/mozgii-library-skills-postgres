---
title: Debezium, pgoutput and custom CDC consumers for PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Debezium, pgoutput and custom CDC consumers for PostgreSQL

This reference goes deeper than the skill on the consumer side of change data capture: checking a publication's
`pgoutput` stream from SQL, wal2json options and logical messages, a full Debezium 3.7 connector setup, and what a
hand-written consumer must do. SQL examples were run on PostgreSQL 18.6 after the skill's examples (they reuse
`shop.orders` and the `cdc_orders` publication).

## Contents

The sections of this reference on CDC consumers:

1. Peeking the pgoutput stream from SQL
2. wal2json options and logical decoding messages
3. A database role for CDC consumers
4. Debezium connector configuration for PostgreSQL
5. Debezium snapshots, heartbeats and slot handling
6. Writing your own consumer on the replication protocol
7. pg_hba.conf for logical replication connections

## Peeking the pgoutput stream from SQL

The binary `pgoutput` stream can be read from SQL with the `*_binary_changes` functions, which shows whether a
publication sends what a consumer expects before any consumer exists. The first byte of each message is its type.

```sql
SELECT * FROM pg_create_logical_replication_slot('cdc_pgoutput', 'pgoutput');
UPDATE shop.orders SET status = 'shipped' WHERE status = 'new';
INSERT INTO shop.orders (customer_id, total_cents) VALUES (10, 500);
SELECT count(*) AS messages, string_agg(DISTINCT chr(get_byte(data, 0)), '') AS message_types
FROM pg_logical_slot_peek_binary_changes('cdc_pgoutput', NULL, NULL,
  'proto_version', '4', 'publication_names', 'cdc_orders', 'messages', 'true');
SELECT pg_drop_replication_slot('cdc_pgoutput');
```

- Message types include `B` (begin), `R` (relation, the table's column list, sent before its first change), `I`,
  `U`, `D` (insert, update, delete) and `C` (commit).
- `proto_version` 2 allows streaming of large in-progress transactions, 3 two-phase commits, 4 (PostgreSQL 16+)
  parallel apply of streamed transactions. `origin = none` drops changes that came from another replication node.

## wal2json options and logical decoding messages

wal2json 2.7 turns each change (format version 2) or each transaction (version 1) into JSON. Its options filter
tables and messages and add metadata; `pg_logical_emit_message` adds events that are not table rows.

```sql
SELECT * FROM pg_create_logical_replication_slot('cdc_json', 'wal2json');
BEGIN;
INSERT INTO shop.orders (customer_id, total_cents) VALUES (9, 999);
SELECT pg_logical_emit_message(true, 'order.events', '{"type": "order.created"}');
COMMIT;
SELECT data FROM pg_logical_slot_get_changes('cdc_json', NULL, NULL,
  'format-version', '2', 'include-lsn', '1', 'include-pk', '1', 'add-tables', 'shop.*');
SELECT pg_drop_replication_slot('cdc_json');
```

| Option | Default | Effect |
|---|---|---|
| `format-version` | 1 | 2 emits one JSON object per change plus `B`/`C` records |
| `add-tables` / `filter-tables` | all / none | include or exclude `schema.table`, with `*` wildcards |
| `include-lsn` | false | adds `nextlsn` to each record |
| `include-pk` | false | adds the primary key columns |
| `include-xids`, `include-timestamp` | false | transaction id and commit time |
| `add-msg-prefixes` / `filter-msg-prefixes` | all / none | which logical messages to emit |
| `actions` | all | limit to insert, update, delete, truncate |

wal2json must be listed in `output_plugin_libraries` on 18.6 and later.

## A database role for CDC consumers

A CDC consumer needs a role with the `REPLICATION` attribute to create and stream slots, `SELECT` on the captured
tables for the initial snapshot, and nothing else. Publications are created by the table owner, not the consumer.

```sql
CREATE ROLE cdc_reader WITH LOGIN REPLICATION PASSWORD 'change-me';
GRANT USAGE ON SCHEMA shop TO cdc_reader;
GRANT SELECT ON shop.orders TO cdc_reader;
```

Use scram-sha-256 and TLS for its `pg_hba.conf` line, and keep its password in your secret store.

## Debezium connector configuration for PostgreSQL

Debezium's PostgreSQL connector runs in Kafka Connect (or Debezium Server) and turns each change into an event on
a topic named `<topic.prefix>.<schema>.<table>`. This configuration uses a publication and slot created for it and
a failover slot. Property names and defaults were checked against the Debezium 3.7 documentation; the connector
itself was not run for this reference.

```json
{
  "name": "orders-cdc",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "db.internal",
    "database.port": "5432",
    "database.user": "cdc_reader",
    "database.password": "<from your secret store>",
    "database.dbname": "app",
    "topic.prefix": "app",
    "plugin.name": "pgoutput",
    "slot.name": "debezium_orders",
    "publication.name": "cdc_orders",
    "publication.autocreate.mode": "disabled",
    "table.include.list": "shop.orders",
    "slot.failover": "true",
    "heartbeat.interval.ms": "10000"
  }
}
```

| Property | Default | Set to |
|---|---|---|
| `plugin.name` | `decoderbufs` | `pgoutput` |
| `slot.name` | `debezium` | a unique name per connector |
| `publication.name` | `dbz_publication` | the publication you created |
| `publication.autocreate.mode` | `all_tables` | `disabled` or `filtered` |
| `snapshot.mode` | `initial` | keep; `no_data` streams without copying existing rows |
| `slot.failover` | `false` | `true` on PostgreSQL 17+ with a synced standby |
| `heartbeat.interval.ms` | `0` | a few seconds on databases with quiet periods |

## Debezium snapshots, heartbeats and slot handling

Debezium's initial snapshot reads every captured table in a repeatable-read transaction, then streams from the
slot. Plan its duration and its load on the primary like a full table scan of each table.

- Incremental (ad hoc) snapshots re-read tables in chunks while streaming continues; they need a signalling table
  or topic.
- `heartbeat.action.query` runs a statement on each heartbeat (for example an `UPDATE` of a one-row table) so a
  slot on a database whose captured tables are quiet still advances.
- Unchanged TOASTed values arrive as the `unavailable.value.placeholder` string unless the table has
  `REPLICA IDENTITY FULL`.
- `slot.drop.on.stop` is for tests only. Before a PostgreSQL major upgrade, stop the connector, let it finish,
  drop the slot, upgrade, and restart with a new snapshot or the documented upgrade steps.

## Writing your own consumer on the replication protocol

A custom consumer opens a connection with `replication=database`, creates or reuses a slot, and runs
`START_REPLICATION SLOT name LOGICAL lsn (options)`. The server then sends CopyData messages with WAL data; the
consumer replies with standby status updates that carry the written, flushed and applied LSNs.

- The server frees WAL only up to the flushed LSN the consumer reports. Report after the target has committed the
  changes, never on receipt.
- After a crash the slot may restart from its last persisted position (slot positions are saved at checkpoint),
  so changes can repeat: store the applied LSN with the data and skip what is at or below it.
- For a consistent start, create the slot with `CREATE_REPLICATION_SLOT ... LOGICAL pgoutput (SNAPSHOT 'export')`
  on the replication connection, read existing rows in another session with `SET TRANSACTION SNAPSHOT` using the
  exported name, then start streaming from the slot.
- Libraries: `pglogrepl` (Go, built on pgx) implements the messages and the pgoutput parser; psycopg2's
  `LogicalReplicationConnection` and `send_feedback()` cover Python; psycopg 3 does not support the replication
  protocol yet (issue 71 is open).

## pg_hba.conf for logical replication connections

A logical replication connection names a database, so the `replication` keyword in `pg_hba.conf` does not match
it; a normal database line does. This line allows the CDC role from the Kafka Connect network over TLS.

```text
# TYPE  DATABASE  USER        ADDRESS        METHOD
hostssl app       cdc_reader  10.20.0.0/16   scram-sha-256
```

Reload with `SELECT pg_reload_conf();` after editing. Physical replication (standbys, `pg_basebackup`) still needs
a `replication` line (`postgres-replication-ha`).

## Sources

- https://www.postgresql.org/docs/18/protocol-logical-replication.html
- https://www.postgresql.org/docs/18/protocol-replication.html
- https://www.postgresql.org/docs/18/logicaldecoding-explanation.html
- https://www.postgresql.org/docs/18/functions-admin.html
- https://www.postgresql.org/docs/18/auth-pg-hba-conf.html
- https://github.com/eulerto/wal2json (README)
- https://debezium.io/documentation/reference/stable/connectors/postgresql.html
- https://debezium.io/releases/3.7/
- https://pkg.go.dev/github.com/jackc/pglogrepl
- https://www.psycopg.org/docs/extras.html (replication support objects)
- https://github.com/psycopg/psycopg/issues/71
