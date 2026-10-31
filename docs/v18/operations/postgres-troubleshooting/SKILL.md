---
name: postgres-troubleshooting
description: 'Diagnoses a live PostgreSQL problem from its symptom and fixes it in order of risk: everything is slow, CPU at 100%, "sorry, too many clients already", queries hanging on locks, disk full or WAL growing, writes stopped for transaction ID wraparound, replica lag, a server that will not start, connections refused or rejected, out-of-memory kills and sudden plan regressions. Gives the first read-only queries, how to read them, and the safe fix for each. Use when something is wrong with Postgres right now and the cause is unknown.'
metadata:
  tags:
  - postgres
  - troubleshooting
  - incident
  - slow-database
  - too-many-connections
  - locks
  - disk-full
  - wraparound
  - out-of-memory
---

# PostgreSQL troubleshooting

Start from the symptom, collect evidence with read-only queries, and apply the least risky fix that removes the
cause. Restarting the server first throws the evidence away and often brings the problem back minutes later. The
queries work on PostgreSQL 14 and later and need `pg_monitor` (or superuser) to see other sessions.

## Step 0: everything got slow at once? Start with a one-minute snapshot of the server

When everything in the database gets slow at once, start here, not with one query: a one-minute snapshot of the
server's sessions, waits, blockers and the big risks answers most "what is wrong" questions before you look at any
single query. Run it as a role with `pg_monitor`.

```sql
SELECT version(), now() - pg_postmaster_start_time() AS uptime;
SELECT state, wait_event_type, count(*) FROM pg_stat_activity
WHERE backend_type = 'client backend' GROUP BY 1, 2 ORDER BY 3 DESC;          -- what sessions are doing
SELECT current_setting('max_connections')::int AS max_conn,
       count(*) FILTER (WHERE backend_type = 'client backend') AS clients
FROM pg_stat_activity;
SELECT pid, usename, state, now() - xact_start AS xact_age, wait_event, left(query, 60) AS query
FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY xact_start LIMIT 5;  -- oldest transactions
SELECT count(*) AS blocked FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;
SELECT datname, age(datfrozenxid) AS xid_age FROM pg_database ORDER BY 2 DESC LIMIT 3;
SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_held
FROM pg_replication_slots;
```

Then read the server log from the minutes before the symptom: errors, `FATAL`, `PANIC`, `terminated by signal`,
checkpoint warnings and lock waits are logged there (`log_lock_waits = on`).

## Symptom map: from what you see to where to look

Each row names the first check and the section below that handles it.

| Symptom | First check | Section |
|---|---|---|
| Everything slow at once | waits by `wait_event_type` | "The database is slow" |
| CPU near 100% | active sessions and top queries by total time | "CPU at 100%" |
| `sorry, too many clients already` | connections by application and state | "Too many connections" |
| Requests hang, then time out | `pg_blocking_pids` | "Queries hang on locks" |
| `No space left on device`, disk alerts | `pg_wal` size, slots, archiver | "Disk full or filling" |
| `database is not accepting commands that assign new transaction IDs` | `age(datfrozenxid)` | "Writes stopped: wraparound" |
| Replica shows old data | lag in bytes and time | "Replica lag" |
| Server does not come up | the server log | "Server will not start" |
| Clients get an error at connect | the exact error text | "Cannot connect" |
| `terminated by signal 9`, restarts | kernel OOM log, `work_mem` | "Out of memory" |
| One query got slow after a deploy or overnight | its plan now and before | "A query got slow suddenly" |

## The database is slow: read the wait events

When everything slows down at once, the wait events of active sessions show what they are waiting for, which is
usually one shared cause.

```sql
SELECT wait_event_type, wait_event, count(*) FROM pg_stat_activity
WHERE state = 'active' AND backend_type = 'client backend'
GROUP BY 1, 2 ORDER BY 3 DESC;
```

| Mostly | Means | Next |
|---|---|---|
| `Lock` / `relation`, `transactionid`, `tuple` | sessions blocked by another session | "Queries hang on locks" |
| `LWLock` / `LockManager` | many sessions taking many locks (many partitions or indexes per query, too many connections) | fewer connections through a pooler; fewer partitions touched per query |
| `IO` / `DataFileRead` | data not in cache, reading from disk | top queries by `shared_blks_read`; missing index or a new big scan |
| `IO` / `WalSync`, `WalWrite`; `LWLock` / `WALWrite` | commits waiting on the WAL disk, or on another session's WAL flush | slow disk, or a burst of small commits; batch writes |
| no wait event (NULL) while `active` | running on CPU | "CPU at 100%" |
| `Client` / `ClientRead` | the server waits for the application | app is slow or stuck between statements; check `idle in transaction` |

Then ask what changed in the last hour: a deploy, a migration, a batch job, autovacuum on a huge table, a failover.

## CPU at 100%

High CPU means many sessions are running query work at once, usually one query shape that became expensive. Count
active sessions against cores, then find the query.

```sql
SELECT count(*) AS active FROM pg_stat_activity WHERE state = 'active' AND wait_event IS NULL;
SELECT queryid, calls, round(total_exec_time) AS total_ms, round(mean_exec_time::numeric, 1) AS mean_ms,
       left(query, 80) AS query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;          -- needs pg_stat_statements
SELECT relname, seq_scan, seq_tup_read, idx_scan FROM pg_stat_user_tables
ORDER BY seq_tup_read DESC LIMIT 10;                                    -- tables read by full scans
```

Relief first, then the fix:

1. Cancel runaway statements: `SELECT pg_cancel_backend(pid)` for the worst ones (the transaction rolls back; the
   connection stays).
2. Cap the damage: `ALTER ROLE app_api SET statement_timeout = '15s';` applies to new sessions.
3. Fix the cause: `EXPLAIN (ANALYZE, BUFFERS)` the top query, add the missing index with `CREATE INDEX CONCURRENTLY`,
   or `ANALYZE` the table if estimates are wrong.

`pg_stat_statements` totals count since its last reset, so compare two snapshots taken a few minutes apart to see
what is expensive now.

## Too many connections

`FATAL: sorry, too many clients already` means `max_connections` client slots are full; `remaining connection slots
are reserved` means only reserved slots are left. Superusers can still connect through
`superuser_reserved_connections`, so connect as one and look.

```sql
SELECT usename, application_name, client_addr, state, count(*),
       max(now() - state_change) AS longest_in_state
FROM pg_stat_activity WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC;
-- free slots now: end sessions of one app that sat idle for over 10 minutes
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE usename = 'app_api' AND state = 'idle' AND state_change < now() - interval '10 minutes';
```

Many `idle` sessions mean pools that are too large for the number of instances; many `idle in transaction` mean
code that holds transactions open. The lasting fix is smaller pools and a transaction-mode pooler (PgBouncer) in
front, not a higher `max_connections`: each connection is a process with its own memory. Set
`idle_in_transaction_session_timeout` for application roles.

## Queries hang on locks

Sessions that wait on `Lock` are blocked by another session's lock. Find the root of the chain: the blocker that is
not itself waiting.

```sql
SELECT w.pid AS waiting_pid, left(w.query, 50) AS waiting_query,
       b.pid AS blocking_pid, b.state AS blocking_state, now() - b.xact_start AS blocking_xact_age,
       left(b.query, 50) AS blocking_query
FROM pg_stat_activity w
JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS bp(pid) ON true
JOIN pg_stat_activity b ON b.pid = bp.pid
ORDER BY blocking_xact_age DESC NULLS LAST;
```

- A blocker in `idle in transaction` is an application that opened a transaction and stopped; terminate it with
  `pg_terminate_backend(pid)` (its transaction rolls back).
- A waiting `ALTER TABLE`, `CREATE INDEX` or `VACUUM FULL` at the head of the queue makes every later query wait
  behind it. Cancel the DDL first (`pg_cancel_backend`) to release the queue, then deal with the long transaction it
  waited for, and rerun the DDL with `SET lock_timeout = '3s'`.
- Prevent it: `lock_timeout` in migrations, `idle_in_transaction_session_timeout` and `statement_timeout` on
  application roles.

## Disk full or filling

A full disk stops the server (`PANIC: could not write to file ... No space left on device`). Find which part is
growing before deleting anything; never delete files in `pg_wal` or the data directory by hand, because that
corrupts the cluster.

```sql
SELECT pg_size_pretty(sum(size)) AS wal FROM pg_ls_waldir();
SELECT archived_count, failed_count, last_failed_wal, last_failed_time FROM pg_stat_archiver;
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained FROM pg_replication_slots;
SELECT datname, pg_size_pretty(temp_bytes) AS temp_written FROM pg_stat_database ORDER BY temp_bytes DESC LIMIT 3;
SELECT relid::regclass, pg_size_pretty(pg_total_relation_size(relid)) FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;
```

| Growing | Cause | Fix |
|---|---|---|
| `pg_wal` with `failed_count` rising | `archive_command` fails; WAL is kept until archived | fix the archive target (permissions, bucket, credentials); WAL drains on its own |
| `pg_wal` with a slot retaining GBs | replica or subscriber gone or far behind | `SELECT pg_drop_replication_slot('name')` for one that will not return; set `max_slot_wal_keep_size` |
| temporary files | big sorts and hashes spilling | find them with `log_temp_files`; fix the query or `work_mem` for it |
| one table | bloat or real growth | measure with `pgstattuple_approx`; remove what blocks vacuum; `pg_repack` reclaims space online |
| server log files | logging every statement | lower `log_statement`, rotate and remove old log files |

If the server already stopped: free space outside the data directory (old logs, other files), or grow the volume,
then start it. Crash recovery replays WAL and needs a little free space.

## Writes stopped: transaction ID wraparound

`ERROR: database is not accepting commands that assign new transaction IDs to avoid wraparound data loss` means the
oldest unfrozen transaction id is about 3 million away from the limit. Reads still work. Something prevented
vacuum from freezing old rows; remove it, then vacuum.

```sql
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;
SELECT gid, prepared, owner FROM pg_prepared_xacts;                                  -- old two-phase transactions
SELECT slot_name, xmin, catalog_xmin FROM pg_replication_slots;                       -- slots holding xmin
SELECT pid, now() - xact_start, backend_xmin FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL ORDER BY age(backend_xmin) DESC LIMIT 5;              -- old snapshots
-- in the affected database, oldest tables first:
SELECT c.oid::regclass, age(c.relfrozenxid) FROM pg_class c
WHERE c.relkind IN ('r', 'm', 't') ORDER BY 2 DESC LIMIT 10;
```

1. `ROLLBACK PREPARED 'gid'` for abandoned prepared transactions, drop stale slots, end old sessions.
2. As a superuser in that database, run `VACUUM (VERBOSE)` on the oldest tables, or `vacuumdb --all --min-xid-age=1000000000`
   for every table past a billion. Do not use `VACUUM FULL` or `VACUUM FREEZE` here, and do not stop the server for single-user mode:
   the PostgreSQL docs advise against both.
3. Afterwards alert on `age(datfrozenxid)` above 800 million so this never reaches the limit again.

## Replica lag

A lagging replica serves old data and, on failover, loses more. Measure the lag in bytes on the primary and in time
on the replica, then find which side is slow.

```sql
-- on the primary
SELECT application_name, state, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS behind,
       write_lag, flush_lag, replay_lag FROM pg_stat_replication;
-- on the replica
SELECT now() - pg_last_xact_replay_timestamp() AS replay_delay,
       pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS received_not_replayed;
```

- `write_lag` high: the network or the replica's disk cannot keep up with the WAL rate (often a bulk load or
  backfill on the primary: slow it down with batches).
- Received but not replayed: replay waits for a long query on the replica (`max_standby_streaming_delay`), or the
  replica's I/O is slower than the primary's.
- No row in `pg_stat_replication`: the replica is disconnected; read its log (authentication, a removed WAL segment,
  a lost slot).
- A logical subscriber stopped: `SELECT subname, pid, last_msg_receipt_time FROM pg_stat_subscription;` and
  the subscriber's log for the conflict.

## Server will not start

The server log (or `pg_ctl start -l logfile`, or `journalctl -u postgresql`) states the reason in its last lines.
Read it before changing anything.

| Log line | Cause | Fix |
|---|---|---|
| `could not bind IPv4 address ... Address already in use` | another server or program on the port | stop it, or change `port` |
| `lock file "postmaster.pid" already exists` | another postmaster on this data directory, or a stale file after a crash | check the PID in the file with `ps`; remove the file only if that PID is not a postgres |
| `data directory ... has invalid permissions` | mode not 0700 or 0750, or wrong owner | `chmod 700` and `chown` to the server's OS user |
| `invalid value for parameter` / `syntax error in file` | a bad edit in `postgresql.conf` or `postgresql.auto.conf` | fix the named line; `ALTER SYSTEM RESET name` once it runs |
| `could not map anonymous shared memory` | `shared_buffers` larger than the OS allows | lower `shared_buffers` or raise the OS limit |
| `database files are incompatible with server` | binaries of another major version | start with the matching major, or `pg_upgrade` |
| `could not locate a valid checkpoint record` | WAL or control file damaged | copy the whole data directory aside first, then restore from backup; `pg_resetwal` only as a last resort, it loses data |

## Cannot connect

Connection errors name their cause exactly; match the message, not the symptom "it doesn't work".

| Error | Meaning | Fix |
|---|---|---|
| `Connection refused` | nothing listens at that host and port | server down, wrong port, or `listen_addresses` excludes the interface |
| `timeout expired` | packets dropped on the way | firewall, security group, private network, wrong host |
| `no pg_hba.conf entry for host "x", user "u", database "d", SSL off` | no `pg_hba.conf` line matches | add a `hostssl` line for that network and reload (`SELECT pg_reload_conf()`) |
| `password authentication failed for user "u"` | wrong password, or a role without a password | reset with `\password u`; the server log shows which `pg_hba.conf` line matched |
| `SSL connection is required` / `server does not support SSL` | client `sslmode` and server `ssl` disagree | `sslmode=verify-full` with a CA file, and `ssl = on` on the server |
| `database "d" does not exist` | name typo or wrong server | `\l` on the server; names are case-sensitive when quoted |
| `remaining connection slots are reserved` | the server is full | "Too many connections" |

## Out of memory and crashed backends

`server process (PID n) was terminated by signal 9: Killed` in the log is usually the Linux OOM killer; every session
restarts while the server recovers. Memory per session is `work_mem` per sort or hash node (times
`hash_mem_multiplier` for hashes), plus `maintenance_work_mem` for vacuum and index builds, on top of
`shared_buffers`.

- Confirm: `dmesg` or `journalctl -k` shows `Out of memory: Killed process ... (postgres)`.
- Find the query: the log line before the crash, or `log_temp_files` and `pg_stat_statements` for large sorts.
- Fix: lower the global `work_mem` and raise it only per query (`SET LOCAL`); cap connections with a pooler; on a
  dedicated Linux host set `vm.overcommit_memory = 2` so a backend gets an `out of memory` error instead of a kill.
- Inspect a live session's memory with `SELECT pg_log_backend_memory_contexts(pid);` (written to the server log).

## A query got slow suddenly

A query that was fast yesterday and slow today usually got a new plan: statistics changed, data crossed a
threshold, or a parameter value is unusual.

1. Get today's plan with `EXPLAIN (ANALYZE, BUFFERS)` and real parameters; compare with the plan in `auto_explain`
   logs or a known-good environment.
2. Wrong row estimates: `ANALYZE` the tables, then consider `CREATE STATISTICS` for correlated columns.
3. Fast in psql, slow from the app: a generic plan for a prepared statement; test with `PREPARE` and six `EXECUTE`s,
   and use `plan_cache_mode = force_custom_plan` for that role if the data is skewed.
4. Ship a durable fix (an index or statistics), not a planner setting changed server-wide.

## Worked example: "API latency jumped at 14:05 and requests time out"

The snapshot shows 180 sessions with `wait_event_type = Lock`. The blocking query shows they all wait for pid 4410,
`ALTER TABLE app.orders ADD COLUMN note text`, from the 14:05 deploy. Pid 4410 itself waits for pid 3982,
`idle in transaction` since 13:48: a support script opened a transaction on `app.orders` and never committed.

1. `SELECT pg_cancel_backend(4410);` cancels the migration; the 180 waiting queries run at once and latency recovers.
2. `SELECT pg_terminate_backend(3982);` ends the forgotten transaction.
3. Rerun the migration with `SET lock_timeout = '3s';` at its top, so next time it fails fast instead of queueing
   traffic behind it.
4. Set `idle_in_transaction_session_timeout = '5min'` for the support role.

## Verify the incident is over

Relief is not proof. Compare these with the numbers from the Step 0 snapshot, then watch them for one more cycle of the
traffic that caused the problem. They ran on 18.6.

```sql
SELECT count(*) FILTER (WHERE wait_event_type = 'Lock') AS lock_waits,            -- 0
       count(*) AS connections, current_setting('max_connections') AS max_conn,   -- well below the limit
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_xact,     -- 0 or short-lived
       count(*) FILTER (WHERE state = 'active'
                        AND now() - query_start > interval '5 minutes') AS long_running   -- 0
FROM pg_stat_activity WHERE backend_type = 'client backend';
SELECT max(age(datfrozenxid)) FROM pg_database;                                   -- far below 1 billion
SELECT slot_name FROM pg_replication_slots WHERE NOT active;                      -- no forgotten slot
```

Then repeat the user's own check, such as the slow page or the failed login: the numbers can look healthy while the
application still holds broken connections from the incident.

## Checklist

Check these points before you call an incident handled.

- [ ] The cause is named with evidence (a query, a session, a log line), not guessed.
- [ ] Relief steps (cancel, terminate, timeouts) were the least destructive that worked.
- [ ] No file was deleted from `pg_wal` or the data directory; no `pg_resetwal` without a full copy.
- [ ] The lasting fix is scheduled: an index, a timeout, pool sizes, a slot limit, an alert.
- [ ] An alert now fires earlier for this cause (connections, xid age, WAL size, lag, disk).

## Gotchas

These are the moves that make an incident worse, each with the reason and what to do instead.

1. **Restarting first.** It ends every session, loses `pg_stat_activity` evidence, and the cause (a pool, a job)
   comes back. Snapshot first; restart only to apply a setting.
2. **Deleting WAL files to free space.** The cluster can no longer recover. Fix archiving or drop the stale slot.
3. **`kill -9` on a backend.** The postmaster resets every connection and runs crash recovery. Use
   `pg_terminate_backend`.
4. **Raising `max_connections` to fix "too many clients".** More processes, more memory, often more contention. Pool.
5. **`VACUUM FULL` during an incident.** It takes an exclusive lock for the whole rewrite. Use plain `VACUUM` or
   `pg_repack`.
6. **Cancelling the blocked query instead of the blocker.** The queue stays. Follow `pg_blocking_pids` to the root.

## Anti-patterns in incident response

These do not make the incident worse at once; they cost the diagnosis or the next week.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Changing several settings together | you cannot tell which one helped, and the rest stay | one change at a time, written down |
| Heavy diagnostics on a struggling server | `count(*)` or `pgstattuple` adds load | the catalog and `pg_stat_*` views |
| `pg_stat_statements_reset()` during an incident | the baseline is gone | two snapshots a few minutes apart |
| `pg_resetwal` as a first resort | it loses data | copy the data directory aside, then restore from backup |
| Cancelling an anti-wraparound autovacuum repeatedly | the freeze it needs moves further off | let it finish and remove what blocks it |
| Closing the incident at relief | the same cause returns | name the cause and schedule the lasting fix |

## See also

Related skills in this library:

- `postgres-query-performance`: the slow query, once found
- `postgres-transactions-locking`: locks and blockers
- `postgres-vacuum-bloat`: wraparound and what holds vacuum back
- `postgres-connection-pooling`: the lasting fix for too many connections
- `postgres-replication-ha`: replica lag and slots
- `postgres-monitoring-observability`: alerts that fire earlier next time
