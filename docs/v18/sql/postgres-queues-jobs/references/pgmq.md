---
title: pgmq message queues in PostgreSQL
author: MOZGII, Inc.
lang: en
---

# pgmq message queues in PostgreSQL

pgmq is a PostgreSQL extension that turns each queue into a table plus SQL functions with SQS-like semantics. This
reference covers pgmq 1.13.1 (October 2026, supported on PostgreSQL 14 to 18). Every example was run on the
`ghcr.io/pgmq/pg18-pgmq:v1.13.1` image (PostgreSQL 18.6).

## Contents

The sections of this reference on pgmq:

1. Installing pgmq
2. Creating queues: logged, unlogged and partitioned
3. Sending, reading, deleting and archiving messages
4. Visibility timeouts and long-running consumers
5. Dead letters with read_ct
6. Monitoring queues

## Installing pgmq

pgmq is installed as an extension in each database that hosts queues. The project publishes a PostgreSQL 18 image
with it preinstalled; on other systems install the package for your platform or build from source, then create the
extension.

```bash
docker run -d --name pgmq-try -e POSTGRES_PASSWORD=change-me ghcr.io/pgmq/pg18-pgmq:v1.13.1
docker exec -it pgmq-try psql -U postgres -c "CREATE EXTENSION pgmq;"
```

## Creating queues: logged, unlogged and partitioned

A pgmq queue is a table `pgmq.q_<name>` with an archive table `pgmq.a_<name>`. Unlogged queues skip WAL and are
emptied after a crash; partitioned queues need the pg_partman extension.

```sql
CREATE EXTENSION IF NOT EXISTS pgmq;
SELECT pgmq.create('emails');
SELECT pgmq.create_unlogged('thumbnails');
SELECT queue_name, is_partitioned, is_unlogged FROM pgmq.list_queues();
```

`pgmq.create_partitioned('name', partition_interval, retention_interval)` fails with `pg_partman is required for
partitioned queues` when pg_partman is not installed.

## Sending, reading, deleting and archiving messages

Messages are `jsonb`. `send` returns the message id; an optional delay in seconds (or a `timestamptz`) keeps the
message invisible until then. `read(queue, vt, qty)` returns up to `qty` messages and hides them for `vt` seconds.

```sql
SELECT * FROM pgmq.send('emails', '{"to": "a@example.com"}');
SELECT * FROM pgmq.send('emails', '{"to": "b@example.com"}', 60);
SELECT * FROM pgmq.send_batch('emails', ARRAY['{"to": "c@example.com"}', '{"to": "d@example.com"}']::jsonb[]);
SELECT msg_id, read_ct, message FROM pgmq.read('emails', 30, 10);
SELECT pgmq.archive('emails', 1);
SELECT pgmq.delete('emails', 3);
```

- `pgmq.pop(queue)` reads and deletes in one call: at-most-once delivery, so a crash loses the message.
- `archive` moves the row to `pgmq.a_<name>` for auditing; `delete` removes it.

## Visibility timeouts and long-running consumers

The visibility timeout is pgmq's lease: a message read and neither deleted nor archived within `vt` seconds is
delivered again. Extend it for long work with `set_vt`, the equivalent of a heartbeat.

```sql
SELECT msg_id FROM pgmq.set_vt('emails', 4, 120);                        -- visible again in 120 s
SELECT msg_id, read_ct FROM pgmq.read_with_poll('emails', 30, 5, 2, 100);   -- wait up to 2 s, poll every 100 ms
```

`read_with_poll(queue, vt, qty, max_poll_seconds, poll_interval_ms)` holds a connection while it waits; give
long-polling consumers their own connections, not the request pool.

## Dead letters with read_ct

pgmq has no built-in dead-letter queue. Each read increments `read_ct`, so when a consumer reads a message whose
`read_ct` is above its limit, it copies the message to a second queue and archives the original in one transaction.

```sql
SELECT pgmq.create('emails_dead');
BEGIN;
SELECT pgmq.send('emails_dead', message) FROM pgmq.q_emails WHERE msg_id = 4 AND read_ct > 1;
SELECT pgmq.archive('emails', 4);
COMMIT;
```

## Monitoring queues

`pgmq.metrics(queue)` reports queue length, the age of the newest and oldest message and the total ever sent.
Alert on the oldest message age, not on length alone.

```sql
SELECT queue_name, queue_length, newest_msg_age_sec, oldest_msg_age_sec, total_messages
FROM pgmq.metrics('emails');
```

The queue tables bloat like any queue table: each read updates the row and each delete leaves a dead one, so the
autovacuum advice in the skill applies to `pgmq.q_*` tables too.

## Sources

- https://github.com/pgmq/pgmq/blob/main/pgmq-extension/README.md
- https://github.com/pgmq/pgmq/releases/tag/v1.13.1
- function signatures read from `\df pgmq.*` on pgmq 1.13.1
