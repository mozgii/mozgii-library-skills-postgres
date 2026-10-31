---
name: postgres-queues-jobs
description: 'Runs job queues and background work on PostgreSQL 18: a queue table claimed with FOR UPDATE SKIP LOCKED, leases and heartbeats, retries with exponential backoff and jitter, dead letters, deduplicated enqueue, LISTEN/NOTIFY wake-ups and their limits, a transactional outbox that never skips rows, the pgmq extension, pg_cron schedules, queue libraries (Procrastinate, River, Graphile Worker, pg-boss, Oban), queue table bloat, measured throughput and when to move to a broker. Use when building a job queue or task runner on Postgres, jobs run twice or get stuck, retries need backoff, the queue table bloats, NOTIFY is slow or lost, or when choosing between Postgres and Kafka, RabbitMQ or SQS.'
metadata:
  tags:
  - postgres
  - job-queue
  - skip-locked
  - background-jobs
  - listen-notify
  - outbox
  - pgmq
  - pg-cron
  - retries
---

# PostgreSQL job queues and background jobs

A Postgres queue is a table workers claim rows from with `FOR UPDATE SKIP LOCKED`. Its strength: a job is enqueued
in the same transaction as the change that caused it, so it exists exactly when the change committed. Use a
maintained library first; build your own table only for its exact shape. Delivery is at least once, so handlers
must be idempotent. The basic claim and outbox are in `postgres-transactions-locking`; this skill adds leases,
retries, dead letters, wake-ups, ordering, bloat and limits. Health queries: [scripts/queue-health.sql](scripts/queue-health.sql); a pgbench claim benchmark:
[scripts/queue-bench.sql](scripts/queue-bench.sql).

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: read the server, the queue extensions and the queue library

The server version sets the `NOTIFY` queue limit and what an extension supports, so read those and the library the
project already has before choosing anything.

```sql
SELECT current_setting('server_version') AS version,
       current_setting('max_notify_queue_pages', true) AS notify_queue_pages;   -- NULL before PostgreSQL 17
SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name IN ('pgmq', 'pg_cron');
```

```bash
uv pip show procrastinate | grep -i '^version'    # Python
npm ls pg-boss graphile-worker                    # Node.js
go list -m github.com/riverqueue/river            # Go
mix deps | grep -A1 oban                          # Elixir
```

## Choose a library, pgmq, your own table or a broker

The choice of queue mechanism follows from your language and how much behaviour you want ready-made.

| Option | Version (Oct 2026) | Fits |
|---|---|---|
| Procrastinate (Python) | 3.10.0 | Python, Django; LISTEN/NOTIFY wake-up |
| River (Go) | 0.50.0 | Go; `InsertTx` enqueues inside your transaction |
| Graphile Worker (Node.js) | 0.18.0 | Node; LISTEN/NOTIFY plus SKIP LOCKED |
| pg-boss (Node.js 22.12+) | 12.38.0 | Node; SKIP LOCKED, cron; PostgreSQL 13+ |
| Oban (Elixir) | 2.24.2 | Elixir; PostgreSQL 14+ |
| pgmq extension | 1.13.1 | any language through SQL; PostgreSQL 14 to 18 |
| Own table | none | one or two job kinds, custom priority |
| Kafka, RabbitMQ, SQS, NATS | none | fan-out, replay, cross-service streams |

Libraries already solve leases, retries, cron and graceful shutdown; read how one does it before writing your own.

## Queue table design for SKIP LOCKED

A queue table needs a state, a time it may run, an attempt count and a lease, plus a partial index that holds only
ready jobs so a claim reads a few index pages however large the table grows.

```sql
CREATE SCHEMA jobs;
CREATE TABLE jobs.job (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  queue        text        NOT NULL DEFAULT 'default',
  kind         text        NOT NULL,
  payload      jsonb       NOT NULL DEFAULT '{}',
  state        text        NOT NULL DEFAULT 'ready' CHECK (state IN ('ready', 'running', 'dead')),
  priority     smallint    NOT NULL DEFAULT 0,
  run_at       timestamptz NOT NULL DEFAULT now(),
  attempts     int         NOT NULL DEFAULT 0,
  max_attempts int         NOT NULL DEFAULT 10,
  lease_until  timestamptz,
  worker       text,
  dedupe_key   text,
  last_error   text,
  created_at   timestamptz NOT NULL DEFAULT now()
) WITH (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_cost_delay = 0);

CREATE INDEX job_ready_idx ON jobs.job (queue, priority DESC, run_at) WHERE state = 'ready';
CREATE INDEX job_lease_idx ON jobs.job (lease_until) WHERE state = 'running';
CREATE UNIQUE INDEX job_dedupe_uq ON jobs.job (dedupe_key)
  WHERE dedupe_key IS NOT NULL AND state IN ('ready', 'running');
```

- Successful jobs are deleted, not marked done: the table holds only live work, and dead rows are reclaimed by
  vacuum. Keep history in a separate table or your logs.
- The two autovacuum settings make vacuum run after 1% of rows change and without throttling on this table.

## Enqueue with deduplication

Enqueue is an `INSERT` in the same transaction as the change that needs the job. A partial unique index on a
dedupe key makes "enqueue unless already waiting or running" one statement.

```sql
INSERT INTO jobs.job (kind, payload, dedupe_key)
VALUES ('send_welcome', '{"user_id": 42}', 'welcome:42')
ON CONFLICT (dedupe_key) WHERE dedupe_key IS NOT NULL AND state IN ('ready', 'running')
DO NOTHING
RETURNING id;            -- no row: an identical job is already queued
```

`ON CONFLICT` must repeat the index predicate, or it fails with `there is no unique or exclusion constraint matching
the ON CONFLICT specification`. A skipped insert still consumes an identity value, so ids have gaps.

## Claiming a batch with a lease

A claim locks ready rows with `SKIP LOCKED`, marks them running and sets a lease: the time after which another
worker may take the job back. Claim in batches and commit at once; never hold the claim transaction open while the
job runs.

```sql
WITH next AS (
  SELECT id FROM jobs.job
  WHERE queue = $1 AND state = 'ready' AND run_at <= now()
  ORDER BY priority DESC, run_at
  LIMIT $2
  FOR UPDATE SKIP LOCKED
)
UPDATE jobs.job j
SET state = 'running', attempts = j.attempts + 1, worker = $3,
    lease_until = now() + interval '5 minutes'
FROM next WHERE j.id = next.id
RETURNING j.id, j.kind, j.payload, j.attempts;
```

- Batch size matters more than worker count. On one laptop (Apple M5 Max, 8 pgbench clients, 3 million queued
  jobs, macOS fsync) claiming and deleting 1 job per transaction ran about 5,100 jobs per second; 100 per
  transaction ran about 108,000. Measure your own with [scripts/queue-bench.sql](scripts/queue-bench.sql).

## Heartbeats for long jobs

A heartbeat extends the lease while a long job is still working, so the reaper does not hand it to another worker.
The `worker` check makes a worker that lost its lease find out and stop.

```sql
UPDATE jobs.job SET lease_until = now() + interval '5 minutes'
WHERE id = $1 AND worker = $2 AND state = 'running'
RETURNING lease_until;                      -- no row: the lease was lost, stop and do not report success
```

Send it every third of the lease. A job that cannot heartbeat needs a lease longer than its worst run.

## Finishing, retrying with backoff and dead letters

Finishing deletes the job. Failing schedules a retry with exponential backoff and jitter, until `max_attempts`
moves it to the dead state, where it waits for a person.

```sql
DELETE FROM jobs.job WHERE id = $1 AND worker = $2 AND state = 'running';   -- success

UPDATE jobs.job                                                              -- failure
SET state       = CASE WHEN attempts >= max_attempts THEN 'dead' ELSE 'ready' END,
    run_at      = now() + least(interval '1 hour',
                    interval '1 second' * power(2, attempts) * (0.5 + random())),
    last_error  = left($3, 2000),
    lease_until = NULL, worker = NULL
WHERE id = $1 AND worker = $2 AND state = 'running'
RETURNING state, run_at;
```

- Backoff grows 2, 4, 8 seconds up to a one-hour cap; the random factor between 0.5 and 1.5 spreads retries so a
  failing downstream service is not hit by every job at once.
- Retry only errors that can pass (timeouts, 5xx, `40001`); send bad input straight to `dead`.
- Retry a dead job with `state = 'ready', attempts = 0, run_at = now()` after fixing the cause.

## Reaping expired leases

The reaper returns jobs whose lease expired (their worker crashed or was killed) to the ready state. Run it every
minute from a worker or pg_cron; running it twice at once is safe.

```sql
UPDATE jobs.job
SET state = CASE WHEN attempts >= max_attempts THEN 'dead' ELSE 'ready' END,
    lease_until = NULL, worker = NULL, last_error = 'lease expired'
WHERE state = 'running' AND lease_until < now()
RETURNING id, state;
```

## Waking workers with LISTEN/NOTIFY and its limits

`NOTIFY` wakes idle workers at once instead of polling every second. A statement-level trigger sends one
notification per insert statement, and identical notifications in one transaction are folded into one.

```sql
CREATE FUNCTION jobs.notify_job() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('jobs', '');
  RETURN NULL;
END $$;
CREATE TRIGGER job_notify AFTER INSERT ON jobs.job
FOR EACH STATEMENT EXECUTE FUNCTION jobs.notify_job();
LISTEN jobs;
SELECT pg_listening_channels(), pg_notification_queue_usage();
```

| Limit | Effect |
|---|---|
| Delivered only at commit | a worker woken by `NOTIFY` always sees the committed job |
| Payload under 8000 bytes | longer fails with `payload string too long`; send ids, not data |
| Commit-time global lock | every committing transaction that ran `NOTIFY` takes one cluster-wide lock (`async.c`), so very high NOTIFY rates serialize commits |
| Queue of 8 GB (`max_notify_queue_pages` = 1048576) | a listener stuck in a long transaction blocks cleanup; when full, `NOTIFY` transactions fail at commit |
| Session-bound | `LISTEN` needs a direct or session-pooled connection; transaction-mode PgBouncer drops it |

Keep a fallback poll: a notification can be missed during a reconnect.

## Transactional outbox without skipped rows

A relay that reads outbox rows "after the last id it saw" loses rows. Identity values are assigned at insert, not
commit: a transaction holding id 1 open while id 2 commits lets the relay move past 1 before it becomes visible
(reproduced on 18.6 with two sessions). Claim unsent rows with `SKIP LOCKED` (`postgres-transactions-locking`), or,
when consumers need a strict order, use a watermark on the inserting transaction id that only advances past
finished transactions.

```sql
CREATE TABLE jobs.outbox (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  txid    xid8  NOT NULL DEFAULT pg_current_xact_id(),
  topic   text  NOT NULL,
  payload jsonb NOT NULL
);
CREATE INDEX outbox_txid_id ON jobs.outbox (txid, id);

SELECT id, txid, topic, payload FROM jobs.outbox
WHERE (txid, id) > ($1::xid8, $2::bigint)                 -- last (txid, id) the relay stored
  AND txid < pg_snapshot_xmin(pg_current_snapshot())      -- only transactions that have all finished
ORDER BY txid, id
LIMIT 500;
```

Any long-running transaction in the cluster holds the relay back, by design. Change data capture
(`postgres-cdc-logical-decoding`) reads the same rows in commit order without polling.

## pgmq: a queue as an extension

pgmq gives each queue a table and SQL functions with SQS-like semantics: `pgmq.read(queue, vt, qty)` hides messages
for a visibility timeout of `vt` seconds, and the consumer must `pgmq.delete` or `pgmq.archive` each one before the
timeout ends, or it is delivered again. It suits teams that want one queue API across languages without a library.
API, dead-letter handling and partitioned queues: [references/pgmq.md](references/pgmq.md).

## Scheduled jobs with pg_cron

pg_cron runs SQL on a cron schedule inside the server, which suits enqueueing periodic jobs, the lease reaper and
cleanup. It needs `shared_preload_libraries = 'pg_cron'`, a restart, and lives in one database
(`cron.database_name`, default `postgres`). The `reap-leases` call below ran on pg_cron 1.6.8 on 18.6; the other two follow its README.

```sql
SELECT cron.schedule('reap-leases', '* * * * *',
  $$UPDATE jobs.job
    SET state = CASE WHEN attempts >= max_attempts THEN 'dead' ELSE 'ready' END,
        lease_until = NULL, worker = NULL, last_error = 'lease expired'
    WHERE state = 'running' AND lease_until < now()$$);
SELECT cron.schedule_in_database('nightly-report', '0 3 * * *',
  $$INSERT INTO jobs.job (kind) VALUES ('nightly_report')$$, 'app');
SELECT cron.schedule('purge-cron-history', '0 12 * * *',
  $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$$);
```

- Times are GMT unless `cron.timezone` is set; `'30 seconds'` style intervals are allowed from 1 to 59 seconds.
- Jobs connect over libpq to `cron.host` (default `localhost`), so `pg_hba.conf` must allow it, or set
  `cron.use_background_workers = on` and raise `max_worker_processes`.
- pg_cron runs nothing on a hot standby; it starts after promotion. `cron.job_run_details` is never purged on its
  own.
- Packages: `postgresql-18-cron` (apt), `pg_cron_18` (yum); Windows builds from source with `nmake`.

## Queue table bloat and vacuum

Every claim, heartbeat and finish writes a new row version, so a busy queue table creates dead rows faster than any
other table. After the benchmark above, the table had 594,000 dead rows next to 2.4 million live ones.

- Keep the table small: delete finished jobs, archive reviewed dead ones, watch `n_dead_tup`.
- One long transaction anywhere in the cluster stops vacuum from removing dead rows in every table, so claims slow
  down as they step over dead index entries. `postgres-transactions-locking` shows how to find it.
- Very high volume: partition the queue by time or generation and drop old partitions.

## When to move to a broker

A broker such as Kafka, RabbitMQ, SQS or NATS fits when you need what a table cannot give cheaply.

| Signal | Why a table struggles |
|---|---|
| Sustained tens of thousands of jobs per second that cannot be batched | each job is several row writes, WAL and vacuum work |
| Many independent consumers of the same event | each would need its own copy or cursor |
| Replay of past events for weeks | rows are deleted on success; keeping them is a log, not a queue |
| Producers outside your database | no shared transaction, so no transactional enqueue |

Keeping the outbox in Postgres and relaying it to the broker keeps the transactional guarantee.

## Gotchas

These are the failures seen most often with Postgres queues, each with its cause and fix.

1. **A job ran twice.** The lease expired during a long job and the reaper handed it out again, or a worker crashed
   after the work and before the delete. Heartbeat, check `worker` on finish, make handlers idempotent.
2. **Claims get slower all day.** Dead rows and index entries pile up: a long transaction blocks vacuum, or
   finished rows are kept in the queue table. End the transaction, delete finished jobs, tune autovacuum.
3. **Workers sleep while jobs wait.** `LISTEN` ran through a transaction-mode pooler or the connection
   reconnected. Listen on a direct connection and keep a fallback poll.
4. **Commit latency spikes under load.** Thousands of transactions per second each ran `NOTIFY` and queued on its
   global commit lock. Notify per statement, or let workers poll in batches.
5. **The outbox relay skipped events.** It used `id > last_id`. Use `SKIP LOCKED` claims or the `xid8` watermark.
6. **pg_cron jobs fail with an authentication error.** Its libpq connection to `localhost` is refused by
   `pg_hba.conf`. Allow it, set `cron.host` to the socket directory, or use background workers.

## Anti-patterns in Postgres job queues

Each of these works in a demo and breaks with several workers or real traffic.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Holding the claim transaction open during the job | it pins a connection and stops vacuum everywhere | claim, commit, work, then finish in a new transaction |
| `SELECT` a job, then `UPDATE` it | two workers take the same row | one statement with `FOR UPDATE SKIP LOCKED` |
| Marking finished jobs done and keeping them | the table and its indexes grow, and claims step over dead rows | delete finished jobs; keep history in another table |
| Retrying at a fixed interval, forever | a failing service gets hit by every job at once, and bad input never leaves | exponential backoff with jitter, then the dead state |
| Handlers that assume one delivery | delivery is at least once, so a crash repeats the side effect | idempotent handlers or a dedupe key |
| `NOTIFY` per row, or data in the payload | commits serialize on the global lock, and payloads stop at 8000 bytes | a statement-level trigger, ids only, and a fallback poll |
| An outbox relay that reads `id > last_id` | it skips rows from transactions that commit late | `SKIP LOCKED` claims or the `xid8` watermark |

## Verify a queue claims every job once and reaps a dead worker

Run this on a scratch database with the table above. Eight clients claim 10 jobs at a time until 20,000 jobs are gone.

```bash
psql -d scratch -c "INSERT INTO jobs.job (kind) SELECT 'demo' FROM generate_series(1, 20000)"
pgbench -n -f scripts/queue-bench.sql -D batch=10 -c 8 -j 8 -t 250 scratch   # 2000/2000 processed, 0 failed
psql -d scratch -Atc "SELECT count(*) FROM jobs.job"                         # 0
psql -X -v ON_ERROR_STOP=1 -v queue_table=jobs.job -d scratch -f scripts/queue-health.sql    # exit 0
```

Zero rows left after 8 × 250 × 10 claims means no batch came back short, so workers skipped each other's locks and
never shared a job. On 18.6 this also ran at about 11,800 batches a second. Then prove the reaper: insert a row with
`state = 'running'` and `lease_until = now() - interval '1 minute'`, run the reaper statement, and its `RETURNING`
shows `ready`. `EXPLAIN` of the claim's `SELECT` must show `Index Scan using job_ready_idx`.

## Checklist

Check these points before you call a Postgres queue done.

- [ ] Jobs are enqueued in the same transaction as the change that needs them.
- [ ] Claims use `FOR UPDATE SKIP LOCKED` in batches and commit before the work starts.
- [ ] Every claim sets a lease; long jobs heartbeat; a reaper returns expired leases.
- [ ] Retries back off exponentially with jitter and stop at a dead state someone monitors.
- [ ] Handlers are idempotent; duplicates are caught by a dedupe key or the handler.
- [ ] Finished jobs are deleted; dead rows and `n_dead_tup` are watched.
- [ ] `LISTEN` uses a direct connection and has a polling fallback.
- [ ] Throughput was measured with batches against the volume you expect.

## See also

Related skills in this library:

- `postgres-transactions-locking`: the basic claim, the outbox and locks
- `postgres-cdc-logical-decoding`: reading changes in commit order without polling
- `postgres-vacuum-bloat`: keeping a busy queue table small
- `postgres-connection-pooling`: why LISTEN needs a direct connection

## Sources

- https://www.postgresql.org/docs/18/sql-select.html (The Locking Clause)
- https://www.postgresql.org/docs/18/sql-notify.html
- https://www.postgresql.org/docs/18/sql-listen.html
- https://www.postgresql.org/docs/18/runtime-config-resource.html (max_notify_queue_pages)
- https://www.postgresql.org/docs/18/functions-info.html (pg_current_xact_id, pg_snapshot_xmin)
- https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/commands/async.c
- https://github.com/pgmq/pgmq (pgmq-extension README)
- https://github.com/citusdata/pg_cron (README)
- https://procrastinate.readthedocs.io/en/stable/discussions.html
- https://github.com/riverqueue/river
- https://worker.graphile.org/docs
- https://github.com/timgit/pg-boss
- https://github.com/oban-bg/oban
