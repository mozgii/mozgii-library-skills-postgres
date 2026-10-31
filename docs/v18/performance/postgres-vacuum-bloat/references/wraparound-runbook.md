---
title: PostgreSQL transaction ID wraparound runbook
author: MOZGII, Inc.
lang: en
---

# PostgreSQL transaction ID wraparound runbook

This runbook covers freezing, the warning and stop thresholds for transaction ids (XIDs) and multixact ids (MXIDs),
and the documented recovery procedure on PostgreSQL 18. The short version: find and remove what blocks vacuum, then
run a plain `VACUUM` as a superuser in the affected database. Do not stop the server.

## Contents

The sections of this reference on wraparound:

1. How freezing works and the settings that drive it
2. Thresholds: warnings, stop and failsafe
3. Measuring XID and MXID age
4. Emergency procedure when writes stop
5. Multixact wraparound
6. After recovery: prevent a repeat

## How freezing works and the settings that drive it

Freezing marks a row as visible to every transaction, so its 32-bit inserting XID no longer matters when the
counter wraps. Vacuum freezes rows during normal runs and scans whole tables when they get old.

| Setting (18.6 default) | Effect |
|---|---|
| `vacuum_freeze_min_age` (50,000,000) | rows older than this are frozen when vacuum visits their page |
| `vacuum_freeze_table_age` (150,000,000) | vacuum scans every not-all-frozen page (aggressive) past this table age |
| `autovacuum_freeze_max_age` (200,000,000, restart) | autovacuum forces a vacuum past this age, even when autovacuum is off |
| `vacuum_max_eager_freeze_failure_rate` (0.03) | PG 18 eager freezing of all-visible pages during normal vacuums; 0 disables |
| `vacuum_failsafe_age` (1,600,000,000) | a running vacuum drops cost delays, skips index vacuuming and may use all shared buffers |
| `vacuum_multixact_freeze_min_age` (5,000,000), `vacuum_multixact_freeze_table_age` (150,000,000), `autovacuum_multixact_freeze_max_age` (400,000,000), `vacuum_multixact_failsafe_age` (1,600,000,000) | the same for multixact ids |

`vacuum_failsafe_age` is silently raised to at least 105% of `autovacuum_freeze_max_age`. Insert-only tables
get vacuumed (and frozen) through the insert threshold, which in 18 scales with the part of the table that is not
yet frozen.

## Thresholds: warnings, stop and failsafe

The server protects data by refusing new XIDs before the counter can wrap.

| Distance to wraparound | What happens |
|---|---|
| 40 million XIDs | each new XID logs `WARNING: database "x" must be vacuumed within N transactions` |
| 3 million XIDs | `ERROR: database is not accepting commands that assign new transaction IDs to avoid wraparound data loss`; read-only work and `VACUUM` still run |

The same two thresholds apply to MXIDs. Multixact member storage has its own limit: past about 10 GB aggressive
vacuums run more often, and it wraps at about 20 GB.

## Measuring XID and MXID age

Age is the number of transactions between a table's oldest unfrozen XID and now; the database's age is the oldest
of its tables.

```sql
SELECT datname, age(datfrozenxid) AS xid_age, mxid_age(datminmxid) AS mxid_age,
       2147483647 - age(datfrozenxid) AS xids_left
FROM pg_database ORDER BY 2 DESC;

SELECT c.oid::regclass AS table_name, age(c.relfrozenxid) AS xid_age, mxid_age(c.relminmxid) AS mxid_age,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c WHERE c.relkind IN ('r', 'm', 't')
ORDER BY age(c.relfrozenxid) DESC LIMIT 20;
```

Alert at 500 million and page at 1 billion; a healthy server stays near `autovacuum_freeze_max_age` (200 million)
because autovacuum freezes tables as they pass it.

## Emergency procedure when writes stop

This is the procedure from the PostgreSQL 18 documentation, in order. Each step removes something that keeps vacuum
from advancing `datfrozenxid`.

1. Resolve old prepared transactions: `SELECT gid, owner, database, age(transaction) FROM pg_prepared_xacts ORDER
   BY 4 DESC;` then `COMMIT PREPARED 'gid'` or `ROLLBACK PREPARED 'gid'`.
2. End long-running transactions: find large `age(backend_xid)` or `age(backend_xmin)` in `pg_stat_activity`, and
   `SELECT pg_terminate_backend(pid)`.
3. Drop stale replication slots: large `age(xmin)` or `age(catalog_xmin)` in `pg_replication_slots`; a replica that
   still uses a dropped slot may need to be rebuilt.
4. Run `VACUUM` in the affected database as a superuser (a non-superuser cannot process system catalogs, so
   `datfrozenxid` would not move). A database-wide `VACUUM` is simplest; to go faster, vacuum the oldest tables
   first with `vacuumdb --min-xid-age`.
5. When writes work again, fix the autovacuum configuration so it cannot recur.

Do not use `VACUUM FULL` (it needs an XID) or `VACUUM FREEZE` (it does more work than needed). Single-user mode is
no longer needed and is riskier because it disables the wraparound safeguards; the only documented reason to use
it is to `TRUNCATE` or `DROP` tables you do not need instead of vacuuming them.

This shell form vacuums only tables older than 1 billion XIDs, four at a time, across all databases:

```bash
vacuumdb --all --jobs=4 --min-xid-age=1000000000 --skip-locked --buffer-usage-limit=256MB
```

## Multixact wraparound

Multixact ids record several transactions locking one row (foreign key checks, `SELECT ... FOR SHARE`). Recovery
follows the same steps with three differences from the documentation: running and prepared transactions matter only
if they could appear in a multixact; replication slots do not hold back multixact cleanup; and MXID exhaustion
blocks only writes that need a new multixact, not all writes. `mxid_age(relminmxid)` finds the tables.

## After recovery: prevent a repeat

Wraparound is always the end of a long chain; fix each link.

- Alert on `age(datfrozenxid)` and `mxid_age(datminmxid)`, and on the xmin horizon holders in the main skill.
- Set `idle_in_transaction_session_timeout` for application roles, and `idle_replication_slot_timeout` (18) or
  `max_slot_wal_keep_size` for slots.
- Keep `max_prepared_transactions = 0` unless you use two-phase commit, and then monitor `pg_prepared_xacts`.
- Raise `autovacuum_vacuum_cost_limit` so anti-wraparound vacuums of the largest tables finish in hours, not days.
- Log autovacuum (`log_autovacuum_min_duration`); a line containing `to prevent wraparound` that repeats for one
  table every few hours means it never finishes.
