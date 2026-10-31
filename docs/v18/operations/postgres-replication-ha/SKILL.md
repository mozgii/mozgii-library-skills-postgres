---
name: postgres-replication-ha
description: 'Sets up and runs PostgreSQL replication and high availability: streaming replicas with pg_basebackup and slots, synchronous commit levels, read replicas and recovery conflicts, lag monitoring, slot limits that protect the disk, failover with Patroni, Kubernetes operators or a managed service, and logical replication with publications and subscriptions. Use when adding a replica, routing reads, planning failover, replicating tables to another database, or for lag, cancelled replica queries or WAL filling the primary.'
metadata:
  tags:
  - postgres
  - replication
  - streaming-replication
  - logical-replication
  - high-availability
  - failover
  - patroni
  - replicas
---

# PostgreSQL replication and high availability

Replication copies changes from a primary to other servers. Physical (streaming) replication copies the whole
cluster byte for byte and gives read replicas and failover targets; logical replication copies chosen tables as rows
and works across major versions. Logical details: [references/logical-replication.md](references/logical-replication.md).

## Step 0: read this server's role and replication settings

Advice differs for a primary and a replica, and `idle_replication_slot_timeout` needs 18, so read which one you are
on and what it is set to.

```sql
SELECT current_setting('server_version') AS version, pg_is_in_recovery() AS is_replica;
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('wal_level', 'max_wal_senders', 'max_replication_slots', 'max_slot_wal_keep_size',
               'idle_replication_slot_timeout', 'synchronous_standby_names', 'synchronous_commit',
               'hot_standby_feedback', 'wal_log_hints', 'data_checksums')
ORDER BY name;
SELECT slot_name, slot_type, active, wal_status FROM pg_replication_slots;
```

## Streaming replication setup

A streaming replica is a copy of the primary made with `pg_basebackup` that keeps replaying WAL received over a
replication connection.

On the primary:

```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '<from your secret store>';
```

```ini
# postgresql.conf (defaults in PG 10+ already allow replication)
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
max_slot_wal_keep_size = '50GB'         # cap WAL kept for a lagging or dead replica
```

```
# pg_hba.conf
hostssl  replication  replicator  10.0.0.0/24  scram-sha-256
```

On the new replica host, with an empty data directory:

```bash
pg_basebackup -h primary.internal -U replicator -D /var/lib/postgresql/18/main \
  -X stream -c fast -R -C -S replica1 -P
# -R writes primary_conninfo and standby.signal; -C -S creates and uses replication slot "replica1"
systemctl start postgresql
```

Check on the primary: `SELECT client_addr, state, sync_state FROM pg_stat_replication;` shows the replica as
`streaming`.

## Replication slots and the full-disk risk

A replication slot makes the primary keep WAL until the replica has received it, so a replica can catch up after a
pause. A slot whose replica is gone keeps WAL forever and fills the disk.

```sql
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
SELECT pg_drop_replication_slot('replica1');      -- for a replica that will not come back
```

- Always set `max_slot_wal_keep_size`; a slot past it becomes `lost` and the replica must be rebuilt, instead of
  the primary stopping.
- PG 18 adds `idle_replication_slot_timeout` to invalidate slots unused for a period.
- Inactive logical slots also hold back vacuum (`catalog_xmin`); monitor them.

## Synchronous replication and commit levels

By default replication is asynchronous: a commit returns before any replica has the WAL, so a failover can lose the
last transactions. Synchronous replication waits for replicas.

```ini
synchronous_standby_names = 'ANY 1 (replica1, replica2)'   # quorum: any one of two must confirm
synchronous_commit = on                                     # wait for flush on the sync replica
```

| `synchronous_commit` | Commit waits for | Data loss on primary crash |
|---|---|---|
| `off` | nothing (not even local flush) | last few hundred ms, no corruption |
| `local` | local flush only | changes not yet on replicas |
| `remote_write` | replica received and wrote to OS | if replica OS crashes too |
| `on` (with sync standbys) | replica flushed to disk | none for confirmed commits |
| `remote_apply` | replica applied, visible to reads | none; read-your-writes on that replica |

`synchronous_commit` can be set per transaction: `SET LOCAL synchronous_commit = off` for bulk, low-value writes.
With a single synchronous replica and `ANY 1`, the primary blocks writes when that replica is down; use at least two
candidates.

## Read replicas and query conflicts

A hot standby answers read-only queries. Replay of changes (for example vacuum removing rows) can conflict with a
long query on the replica, which then gets cancelled.

| Setting (on the replica) | Effect |
|---|---|
| `hot_standby_feedback = on` | the primary keeps rows the replica's queries need; fewer cancels, more bloat on the primary |
| `max_standby_streaming_delay = '30s'` | how long replay waits for queries before cancelling them; `-1` waits forever and lets lag grow |

Route only reads that tolerate lag to replicas. For read-your-writes, read from the primary after a write, or wait for
the replica to pass the commit's LSN.

## Monitoring replication lag

Replication lag is how far a replica is behind; measure it in bytes and in time.

```sql
-- on the primary
SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
-- on a replica
SELECT pg_is_in_recovery(), now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

`replay_delay` grows on an idle primary even with no lag (no new transactions to replay); compare with byte lag.

## Failover and promotion

Promotion turns a replica into a primary. Doing it by hand is easy; doing it safely (only one primary, clients
redirected) needs a manager.

```sql
SELECT pg_promote();          -- on the replica; or: pg_ctl promote -D "$PGDATA"
```

- Use an HA manager for automatic failover: Patroni (with etcd, Consul or Kubernetes as the consensus store) is the
  common choice; on Kubernetes, operators such as CloudNativePG, Crunchy PGO or Zalando's operator run Patroni-like
  logic. Managed services do failover for you.
- Never let two servers accept writes (split brain). Patroni uses a leader lock and fences the old primary.
- Clients find the primary through a virtual IP, DNS, a proxy (HAProxy with Patroni's REST health checks), or libpq
  multi-host strings: `host=db1,db2,db3 target_session_attrs=read-write`.
- After failover, rebuild or rewind the old primary (`pg_rewind`, needs `wal_log_hints = on` or data checksums, on
  by default in PG 18) before it rejoins as a replica.

## Logical replication in brief

Logical replication sends row changes of chosen tables from a publication to a subscription. It needs
`wal_level = logical` on the publisher, replicates across major versions, and is the usual tool for low-downtime
major upgrades and for feeding another database.

```sql
-- publisher
CREATE PUBLICATION app_pub FOR TABLE app.customers, app.orders;
-- subscriber (tables must already exist with compatible columns)
CREATE SUBSCRIPTION app_sub
  CONNECTION 'host=primary.internal dbname=app user=replicator'
  PUBLICATION app_pub;
```

DDL, sequences and large objects are not replicated. Details and the upgrade recipe:
[references/logical-replication.md](references/logical-replication.md).

## Worked example: "reports on the replica keep getting cancelled"

Analysts see `canceling statement due to conflict with recovery` on a 10-minute report. Replay on the replica had to
remove row versions the report was still reading (vacuum on the primary cleaned them up), waited
`max_standby_streaming_delay` (30 s by default), then cancelled the query. Choose by what the replica is for:

| Replica's job | Setting on that replica | Cost |
|---|---|---|
| Failover target and short reads | leave defaults; move reports elsewhere | none |
| Dedicated reporting replica | `max_standby_streaming_delay = '15min'` | that replica lags up to 15 minutes during long reports |
| Reports that must see fresh data | `hot_standby_feedback = on` | the primary keeps dead rows for the replica's queries: bloat |

Confirm the cause with `SELECT * FROM pg_stat_database_conflicts WHERE datname = current_database();` on the replica
(`confl_snapshot` counts these cancels), and watch byte lag on the primary after changing the delay.

## Verify replication with a marker row and the slot

A replica that connects proves little; a row that arrives proves replication. These ran on 18.6 with a replica made
by `pg_basebackup -R -C -S replica1`.

```sql
-- on the primary
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;                                  -- one row per replica: streaming, lag_bytes near 0
SELECT slot_name, active, wal_status FROM pg_replication_slots;   -- active t, wal_status reserved
CREATE TABLE app.drill (at timestamptz);
INSERT INTO app.drill VALUES (now());
-- on the replica, a moment later
SELECT pg_is_in_recovery(), count(*) FROM app.drill;       -- t, 1
INSERT INTO app.drill VALUES (now());                      -- ERROR: cannot execute INSERT in a read-only transaction
```

Failover is proved only by a timed drill: promote, write on the new primary, and confirm clients reconnect.

## Checklist

Check these points before you call replication and failover done.

- [ ] Replicas connect over `hostssl` with a dedicated `REPLICATION` role and scram.
- [ ] Every replica uses a slot, and `max_slot_wal_keep_size` caps retained WAL.
- [ ] Lag in bytes and time is monitored and alerted.
- [ ] Synchronous replication, if used, has at least two candidates.
- [ ] Failover is automated by a tested manager (or a managed service), with fencing.
- [ ] Clients reconnect to the new primary without config changes.
- [ ] A failover drill has been run and timed.

## Gotchas

These are the failures seen most often with replication and failover, each with its cause and fix.

1. **The primary's disk filled up.** An abandoned replication slot retained WAL. Drop it and set
   `max_slot_wal_keep_size`.
2. **Queries on the replica fail with `canceling statement due to conflict with recovery`.** Replay needed to remove
   rows the query used. Raise `max_standby_streaming_delay`, enable `hot_standby_feedback`, or move the report to
   a dedicated replica.
3. **Writes hang on the primary.** The only synchronous standby is down. Use `ANY 1 (a, b)` or switch to async.
4. **The old primary comes back as a second primary.** No fencing. Use Patroni or the provider's failover.
5. **A replica cannot be built: `no pg_hba.conf entry for replication connection`.** `all` does not match
   replication; add a `replication` line.
6. **Logical subscription stops on a conflict.** A row already exists on the subscriber. See the reference for
   `ALTER SUBSCRIPTION ... SKIP` and `disable_on_error`.

## Anti-patterns in replication and failover

These setups pass a quiet week and fail on the day they are needed.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| A replication slot with no WAL cap | a dead replica keeps WAL until the primary's disk is full | `max_slot_wal_keep_size` and an alert on inactive slots |
| Treating a replica as the backup | a bad `DELETE` or `DROP` replays on it within seconds | backups with point-in-time recovery (`postgres-backup-restore`) |
| A failover script with no fencing | the old primary comes back and two servers take writes | Patroni, an operator or a managed service |
| One synchronous standby | when it stops, every write on the primary waits | at least two candidates: `ANY 1 (a, b)` |
| Sending read-your-writes queries to a replica | the row may not be there yet | read from the primary, or wait for the commit's LSN |
| `hot_standby_feedback` on every replica by default | long replica queries bloat the primary | set it only where fresh reports need it, on a dedicated replica |
| Expecting logical replication to carry everything | DDL, sequences and large objects stay behind | apply DDL by hand and sync sequences at cutover |

## See also

Related skills in this library:

- `postgres-patroni-ha`: automatic failover with Patroni
- `postgres-kubernetes`: operators that run replicas
- `postgres-cdc-logical-decoding`: logical decoding and slots in depth
- `postgres-zero-downtime-upgrades`: logical replication for major upgrades
- `postgres-backup-restore`: backups, which replication does not replace
