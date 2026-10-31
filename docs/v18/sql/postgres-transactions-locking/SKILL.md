---
name: postgres-transactions-locking
description: 'Gets PostgreSQL concurrency right: MVCC, isolation levels and retrying serialization failures, lost updates, SELECT FOR UPDATE, SKIP LOCKED job queues, the transactional outbox, advisory locks, deadlocks, idle in transaction sessions, timeouts and finding who blocks whom. Use when writes race, stock is oversold, two workers take the same job, "could not serialize access" or "deadlock detected" appears, sessions hang on locks, or when choosing an isolation level.'
metadata:
  tags:
  - postgres
  - transactions
  - isolation
  - locking
  - skip-locked
  - advisory-locks
  - deadlocks
  - mvcc
---

# PostgreSQL transactions, isolation and locking

PostgreSQL runs each statement on a snapshot of committed data (MVCC): readers never block writers and writers never
block readers. Writers do block writers on the same rows, and that is where races, deadlocks and stalls come from.
The blocking report is [scripts/blocking-locks.sql](scripts/blocking-locks.sql).

## Step 0: read the isolation default and the timeouts

Whether a race is possible, and how long a stuck session can hold locks, depends on these settings. A timeout of 0
means no limit, and `transaction_timeout` exists from 17.

```sql
SELECT current_setting('server_version') AS version;
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('default_transaction_isolation', 'deadlock_timeout', 'lock_timeout', 'statement_timeout',
               'idle_in_transaction_session_timeout', 'transaction_timeout', 'max_prepared_transactions')
ORDER BY name;
```

## MVCC in one paragraph

MVCC (multi-version concurrency control) means an `UPDATE` writes a new row version and marks the old one dead; each
transaction sees the versions committed before its snapshot. Dead versions stay until vacuum removes them, and a
long-running transaction keeps every version since its start alive for everyone, which bloats tables
(`postgres-operations`). So keep transactions short.

## Isolation levels and when to use each

PostgreSQL offers three effective isolation levels (`READ UNCOMMITTED` behaves as `READ COMMITTED`).

| Level | Snapshot | Anomalies prevented | Use for |
|---|---|---|---|
| `READ COMMITTED` (default) | new snapshot per statement | dirty reads | most OLTP; conditional single-statement writes |
| `REPEATABLE READ` | one snapshot for the transaction | non-repeatable reads, phantoms | consistent reports, multi-query reads |
| `SERIALIZABLE` | one snapshot plus conflict detection | all, including write skew | invariants across rows ("at least one doctor on call") |

## could not serialize access errors: retry the whole transaction on 40001

`ERROR: could not serialize access due to concurrent update` (or `... due to read/write dependencies among
transactions`) is SQLSTATE `40001`, and it is expected under `REPEATABLE READ` and `SERIALIZABLE`: the database
refused a transaction that conflicted with another, and your code must run it again.

```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
-- reads and writes
COMMIT;      -- may fail with SQLSTATE 40001: retry the whole transaction
```

Under `REPEATABLE READ` and `SERIALIZABLE`, the application must retry on `40001` (`serialization_failure`); under
any level, retry on `40P01` (`deadlock_detected`). Retry the whole transaction from the start, with a small random
delay and a cap on attempts. Read-only serializable transactions can use `SET TRANSACTION READ ONLY, DEFERRABLE` to
never fail.

## Lost updates and how to prevent them

A lost update happens when two sessions read a value, compute in the application, and write back: the second write
erases the first. Three fixes, best first:

```sql
-- 1. one atomic statement
UPDATE app.stock SET qty = qty - $2 WHERE sku = $1 AND qty >= $2 RETURNING qty;

-- 2. lock the row for the read-modify-write
BEGIN;
SELECT qty FROM app.stock WHERE sku = $1 FOR UPDATE;    -- other writers wait here
UPDATE app.stock SET qty = $2 WHERE sku = $1;
COMMIT;

-- 3. optimistic concurrency with a version column
UPDATE app.docs SET body = $2, version = version + 1
WHERE id = $1 AND version = $3;     -- 0 rows updated: someone else won, reload and retry
```

Row lock strengths: `FOR UPDATE` (will change or delete), `FOR NO KEY UPDATE` (will change non-key columns; does
not block foreign key checks), `FOR SHARE`, `FOR KEY SHARE`. Add `NOWAIT` to fail at once instead of waiting.

## Job queues with FOR UPDATE SKIP LOCKED

`SKIP LOCKED` makes each worker skip rows another worker has locked, so many workers can pull from one table without
taking the same job and without waiting on each other.

```sql
CREATE TABLE app.jobs (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  queue      text NOT NULL DEFAULT 'default',
  payload    jsonb NOT NULL,
  run_at     timestamptz NOT NULL DEFAULT now(),
  attempts   int NOT NULL DEFAULT 0,
  locked_at  timestamptz,
  done_at    timestamptz
);
CREATE INDEX jobs_ready_idx ON app.jobs (queue, run_at) WHERE done_at IS NULL;

-- worker: claim one job
UPDATE app.jobs SET locked_at = now(), attempts = attempts + 1
WHERE id = (
  SELECT id FROM app.jobs
  WHERE queue = $1 AND done_at IS NULL AND run_at <= now()
    AND (locked_at IS NULL OR locked_at < now() - interval '10 minutes')   -- reclaim from crashed workers
  ORDER BY run_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
RETURNING id, payload;
-- after the work: UPDATE app.jobs SET done_at = now() WHERE id = $1;
```

- Claim in a short transaction and commit, do the work outside it, then mark it done. Holding the transaction open
  during the work pins a connection and blocks vacuum.
- Delete or archive done rows regularly (or partition by time), or the queue table bloats.
- `LISTEN`/`NOTIFY` can wake workers instead of polling; `NOTIFY` is sent at commit. Libraries built on this pattern:
  pg-boss (Node), River (Go), Procrastinate (Python), Oban (Elixir), Graphile Worker; the `pgmq` extension offers a
  queue API.

## Transactional outbox: publish events without losing or inventing them

The transactional outbox writes an event row in the same transaction as the business change, so an event exists if
and only if the change committed. Sending to a broker (Kafka, SQS, a webhook) inside the transaction cannot give that:
the send may succeed and the commit fail, or the reverse.

```sql
CREATE TABLE app.outbox (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  topic       text NOT NULL,
  payload     jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  lease_until timestamptz,
  sent_at     timestamptz
);
CREATE INDEX outbox_unsent_idx ON app.outbox (id) WHERE sent_at IS NULL;

BEGIN;
UPDATE app.orders SET status = 'paid' WHERE id = $1;
INSERT INTO app.outbox (topic, payload) VALUES ('order.paid', jsonb_build_object('order_id', $1::bigint));
COMMIT;
```

`$1` needs its cast in the `INSERT`: a parameter passed to `jsonb_build_object` has no type of its own, so the
statement fails with `could not determine data type of parameter $1`.

The relay worker runs in a loop: claim a batch with a lease in one short transaction, commit, send to the broker with
no transaction open, then mark the batch. A broker call inside a transaction would hold row locks and the vacuum
horizon for as long as the broker takes.

```sql
UPDATE app.outbox o SET lease_until = now() + interval '2 minutes'
FROM (
  SELECT id FROM app.outbox
  WHERE sent_at IS NULL AND (lease_until IS NULL OR lease_until < now())
  ORDER BY id LIMIT 100
  FOR UPDATE SKIP LOCKED
) next
WHERE o.id = next.id
RETURNING o.id, o.topic, o.payload;
-- commit, send each row to the broker, then, with the ids the broker accepted:
UPDATE app.outbox SET sent_at = now(), lease_until = NULL WHERE id = ANY($1);
```

- Delivery is at least once: a relay that crashes after sending and before marking leaves the lease to expire, and
  the batch is sent again. Consumers deduplicate by the outbox `id`.
- Keep the lease longer than the slowest send, or a second relay sends the batch while the first is still working.
- Delete or partition sent rows, or the table bloats like any queue.
- Change data capture (Debezium and similar tools reading logical replication) can read the outbox table instead of
  a polling relay.

## Advisory locks for application-defined mutual exclusion

Advisory locks lock a number you choose, not a row, for things like "only one instance runs this cron job".

```sql
SELECT pg_try_advisory_lock(hashtext('nightly-report'));     -- true: you hold it until unlock or disconnect
SELECT pg_advisory_unlock(hashtext('nightly-report'));
BEGIN; SELECT pg_advisory_xact_lock(42); /* ... */ COMMIT;   -- released at transaction end
```

- Session-level advisory locks do not work through a transaction-mode pooler: the lock stays on a server connection
  another client may get. Use the `_xact_` variants there, or a direct connection.
- `hashtext()` can collide; for distinct resources use the two-key form `pg_advisory_lock(class_id, object_id)`.

## Deadlocks and how to avoid them

A deadlock is two transactions each waiting for a lock the other holds. Postgres detects it after
`deadlock_timeout` (1 s) and aborts one with `40P01`.

- Lock rows in a consistent order: sort ids before updating many rows (`UPDATE ... WHERE id = ANY($1)` on a sorted
  array, or `SELECT ... ORDER BY id FOR UPDATE` first).
- Keep transactions short and avoid user think-time inside them.
- Foreign keys take `KEY SHARE` locks on the parent row; frequent updates of parent key columns cause lock waits.
- The server log has both statements of every deadlock; read it there.

## Timeouts that stop runaway sessions

Timeouts keep one bad session from holding locks or connections forever. Set them per role or per database.

```sql
ALTER ROLE app_rw SET statement_timeout = '30s';
ALTER ROLE app_rw SET lock_timeout = '5s';
ALTER ROLE app_rw SET idle_in_transaction_session_timeout = '60s';   -- kills sessions that opened a transaction and went quiet
ALTER ROLE app_rw SET transaction_timeout = '5min';                  -- PG 17+: whole-transaction cap
```

`idle in transaction` sessions are the most common cause of bloat and blocked migrations: an application opened a
transaction, then waited on a network call or a bug skipped the commit.

## Finding who blocks whom

When sessions hang, find the blocking process first. `pg_blocking_pids()` gives the blocker of each waiting session.

```sql
SELECT pid, pg_blocking_pids(pid) AS blocked_by, wait_event_type, state,
       now() - xact_start AS xact_age, left(query, 60) AS query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;

SELECT pg_cancel_backend(12345);      -- cancel the blocker's current query
SELECT pg_terminate_backend(12345);   -- end its session (rolls back its transaction)
```

The full report with the blocker's own query is [scripts/blocking-locks.sql](scripts/blocking-locks.sql).

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Worked example: "we oversold the last item in stock"

Two checkouts read `qty = 1`, both decided there was stock, and both wrote `qty = 0`: a lost update under the default
`READ COMMITTED`. The code did `SELECT qty`, compared in the application, then `UPDATE ... SET qty = $new`. Replace
the read and write with one conditional statement, which locks the row and re-checks the condition:

```sql
UPDATE app.stock SET qty = qty - $2
WHERE sku = $1 AND qty >= $2
RETURNING qty;          -- no row: out of stock, tell the customer
```

The second checkout waits for the first one's row lock, re-reads the committed row, finds `qty = 0`, and updates
nothing. Add `CHECK (qty >= 0)` on the column so any future code path that forgets the condition fails loudly
instead of overselling.

## Verify concurrent code under real contention

One session never shows a race, so run the statement from many clients at once. Both of these ran on 18.6 with
`pgbench`. First the worked example: 8 clients try 200 sales of 20 items.

```sql
-- oversell.sql
WITH s AS (UPDATE app.stock SET qty = qty - 1 WHERE sku = 'a' AND qty >= 1 RETURNING 1)
INSERT INTO app.sold SELECT FROM s;
-- serial.sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
UPDATE app.c SET n = n + 1;
COMMIT;
```

```bash
pgbench -n -f oversell.sql -c 8 -j 8 -t 25 app                  # 0 failed; then qty = 0 and 20 rows in app.sold
pgbench -n -f serial.sql -c 8 -j 8 -t 50 --max-tries=100 app    # 0 failed, 231 of 400 retried; then n = 400
psql -X -d app -f scripts/blocking-locks.sql                    # every section 0 rows on an idle system
```

The retried count shows the retry is doing real work: with `--max-tries=1` those transactions fail with `40001`.

## Checklist

Check these points before you call concurrent code done.

- [ ] Transactions are short; no network calls or user waits inside one.
- [ ] Read-modify-write is one statement, a `FOR UPDATE` lock, or a version check.
- [ ] `REPEATABLE READ`/`SERIALIZABLE` code retries on `40001`; all code retries deadlocks `40P01`.
- [ ] Queues claim with `FOR UPDATE SKIP LOCKED` in a short transaction.
- [ ] Multi-row updates lock rows in a consistent order.
- [ ] `statement_timeout`, `lock_timeout` and `idle_in_transaction_session_timeout` are set for application roles.
- [ ] No session advisory locks through a transaction pooler.

## Gotchas

These are the failures seen most often with concurrent code, each with its cause and fix.

1. **Two workers processed the same job.** The claim read without a lock, or the lock was released before the update.
   Claim with one `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED)`.
2. **`could not serialize access due to concurrent update`.** Expected under `REPEATABLE READ`/`SERIALIZABLE`:
   retry the transaction.
3. **A table bloats and vacuum does nothing.** An old open transaction (or a replication slot, or a prepared
   transaction) holds back the xmin horizon. Find it by `xact_start` in `pg_stat_activity`.
4. **`SELECT ... FOR UPDATE` with `LIMIT` returns fewer rows than asked.** Rows locked by others are skipped
   (`SKIP LOCKED`) or re-checked after waiting; this is by design.
5. **Prepared transactions (`PREPARE TRANSACTION`) left behind.** They hold locks across restarts. Check
   `pg_prepared_xacts`; keep `max_prepared_transactions = 0` unless you use two-phase commit.
6. **`NOTIFY` never arrives.** It is delivered on commit, and listeners behind a transaction pooler lose their
   session. Listen on a direct connection.

## Anti-patterns in concurrent code

These pass every single-user test and fail under real concurrency.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| A network call inside a transaction | locks and the vacuum horizon stay held for as long as the other side takes | commit first, then call; use the outbox for events |
| Read in the application, then write back | the second writer erases the first | one conditional statement, `FOR UPDATE`, or a version column |
| `SERIALIZABLE` with no retry | expected `40001` errors reach the user | retry the whole transaction with a capped backoff |
| Catching an error and carrying on in the transaction | the next statement fails with `current transaction is aborted` | roll back, or use a savepoint |
| `LOCK TABLE` to protect a few rows | every other session waits | row locks, or a conditional `UPDATE` |
| Updating many rows in arbitrary order | two batches deadlock | sort the ids first |
| Session advisory locks through a transaction pooler | the lock stays on a connection another client may get | the `_xact_` variants, or a direct connection |

## See also

Related skills in this library:

- `postgres-queues-jobs`: leases, retries and dead letters
- `postgres-internals-mvcc-storage`: row versions and snapshots in depth
- `postgres-vacuum-bloat`: what a long transaction costs
- `postgres-troubleshooting`: finding blockers during an incident
- `postgres-schema-migrations`: DDL locks
