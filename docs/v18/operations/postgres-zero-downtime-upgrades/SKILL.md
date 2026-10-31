---
name: postgres-zero-downtime-upgrades
description: 'Plans and runs PostgreSQL major and minor upgrades with little or no downtime: pg_upgrade 17 to 18 with --link, --clone, --copy-file-range or the new --swap, --jobs and kept statistics, the --check failures that stop an upgrade and their fixes, rollback per mode, blue/green upgrades with logical replication, pg_createsubscriber plus pg_upgrade to skip the initial copy, cutover with sequence sync and reverse replication, extension versions, minor updates such as 18.6, and managed-service paths. Use when upgrading PostgreSQL, "pg_upgrade --check" fails, planning a cutover window, or a version nears end of life.'
metadata:
  tags:
  - postgres
  - upgrade
  - pg_upgrade
  - blue-green
  - logical-replication
  - pg_createsubscriber
  - minor-release
  - zero-downtime
---

# PostgreSQL upgrades with little or no downtime

Pick the method by the downtime you can accept and the rollback you need. `pg_upgrade` in link, clone or swap mode
takes minutes regardless of size and needs a stopped server; a logical-replication blue/green upgrade cuts over in
seconds and keeps the old cluster as a fallback, at the cost of more steps and no DDL during the run. Rehearse on a
copy, run `pg_upgrade --check` against the live server days before, and never delete the old cluster until the new
one has run in production and passed a restore drill. Basics of `pg_upgrade` and the PostgreSQL 18 behaviour changes
are in `postgres-operations` (references/upgrades.md); upgrading under Patroni is in `postgres-patroni-ha`. The full
blue/green runbook is [references/blue-green-runbook.md](references/blue-green-runbook.md).

## Step 0: read the source cluster before choosing a method

The version sets the path, and checksums, locale provider, extensions and logical slots each decide what the new
cluster must match. Read them on the old server.

```sql
SELECT current_setting('server_version') AS version, current_setting('data_checksums') AS checksums,
       current_setting('wal_level') AS wal_level;
SELECT datname, datlocprovider, encoding, datcollate FROM pg_database WHERE datallowconn ORDER BY 1;
SELECT extname, extversion FROM pg_extension ORDER BY 1;
SELECT slot_name, slot_type, plugin, active FROM pg_replication_slots;
```

```bash
pg_lsclusters                                                # Debian and Ubuntu: every cluster on the host
```

## Versions and support windows

PostgreSQL supports each major version for five years. Status on October 28, 2026, from the versioning page:

| Version | Current minor | Final release |
|---|---|---|
| 18 | 18.6 (18.5 was never released) | November 14, 2030 |
| 17 | 17.11 | November 8, 2029 |
| 16 | 16.15 | November 9, 2028 |
| 15 | 15.19 | November 11, 2027 |
| 14 | 14.24 | November 12, 2026: end of life next month |

PostgreSQL 19 is in release candidate (RC 1, October 15, 2026). Next minor releases: November 12, 2026, then
February 11, May 13 and August 12, 2027. `pg_upgrade` skips majors; read every skipped major's release notes.

## Choosing an upgrade method

The method decides downtime, disk use and how you roll back.

| Method | Downtime | Rollback | Use when |
|---|---|---|---|
| `pg_upgrade --link` | minutes | only until the new server starts | same filesystem, no reflink support |
| `pg_upgrade --clone` | minutes | old cluster untouched | APFS, XFS or Btrfs with reflinks |
| `pg_upgrade --swap` (new in 18) | minutes, fastest with many relations | none once file transfer begins | very many tables, a verified backup |
| `pg_upgrade --copy` / `--copy-file-range` | proportional to size | old cluster untouched | small clusters, or Linux `copy_file_range` |
| logical replication blue/green | seconds at cutover | reverse replication to the old cluster | downtime budget under a minute |
| `pg_createsubscriber` + `pg_upgrade` | seconds at cutover | as blue/green | blue/green on a large database: no initial copy |
| `pg_dump` / `pg_restore` | proportional to size | old cluster untouched | small databases, moving hosts or platforms |

## pg_upgrade checks that fail and how to fix them

`pg_upgrade --check` runs every compatibility check without changing data, and can run against the live old server
when the ports differ. These failures came from a real PostgreSQL 17.11 to 18.6 run:

| Message | Cause | Fix |
|---|---|---|
| `old cluster does not use data checksums but the new one does` | 18's `initdb` enables checksums by default | `initdb --no-data-checksums`, or `pg_checksums --enable` on the stopped old cluster |
| `Your installation contains one of the reg* data types in user tables` | a `regproc` (or `regclass`-like OID) column; the file `tables_using_reg.txt` lists them | change the column to `text` or drop it; `regclass`, `regrole` and `regtype` are allowed |
| `logical replication slots that cannot be upgraded` (`The slot "cdc_slot" has not consumed the WAL yet`) | a consumer is behind | let the consumer catch up after writes stop, or advance or drop the slot |
| `"wal_level" must be "logical" but is set to "replica"` | the old cluster has logical slots | set `wal_level = logical` in the new cluster |
| plugin not allowed by `output_plugin_libraries` | 18.6 accepts only `pgoutput` and `test_decoding` by default | add plugins such as `wal2json` to the new cluster's setting |
| `could not load library` | an extension's files for 18 are missing | install the extension package built for 18 on the new server |

A live `--check` passed the slot check while `cdc_slot` still had unconsumed WAL; the same check on the stopped
cluster failed. Run the final `--check` after stopping the old server.
[scripts/pg-upgrade-check.sh](scripts/pg-upgrade-check.sh) builds a matching empty new cluster (encoding, locale
provider, checksums, `wal_level`) and runs the live check.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Running pg_upgrade from 17 to 18

`pg_upgrade` creates the new catalogs and moves or shares the user data files; always run the new version's binary.
This run took 2.2 seconds in clone mode on macOS APFS (Postgres.app 17.11 and 18.6):

```bash
OLD=/Applications/Postgres.app/Contents/Versions/17/bin     # Linux: /usr/lib/postgresql/17/bin
NEW=/Applications/Postgres.app/Contents/Versions/18/bin
$NEW/initdb -D "$NEW_DATA" -U postgres --encoding=UTF8 --locale-provider=builtin --builtin-locale=C.UTF-8 \
  --no-data-checksums                                          # match the old cluster
"$OLD/pg_ctl" -D "$OLD_DATA" -w stop
cd /var/tmp/pgupgrade                                          # pg_upgrade writes files into the current directory
"$NEW/pg_upgrade" -b "$OLD" -B "$NEW" -d "$OLD_DATA" -D "$NEW_DATA" -U postgres \
  -s /var/tmp/pgupgrade --check --clone -j 4
"$NEW/pg_upgrade" -b "$OLD" -B "$NEW" -d "$OLD_DATA" -D "$NEW_DATA" -U postgres \
  -s /var/tmp/pgupgrade --clone -j 4
```

- `-j` works on databases and tablespaces in parallel; start with the core count.
- `-s` sets the socket directory; the default (the current directory) can exceed the socket path length.
- On Windows, run `pg_upgrade.exe` from an administrator account with quoted paths, and stop the services
  (`NET STOP postgresql-17`); `-s` is not supported there.
- Pass the mode to `--check` too (`--check --link`) to run that mode's own checks.
- Copy `pg_hba.conf`, settings and custom full-text dictionaries to the new cluster by hand.

## After pg_upgrade: statistics, extensions and replicas

PostgreSQL 18's `pg_upgrade` keeps most optimizer statistics. In our run, `pg_stats` still had the column statistics
of `orders`, `pg_statistic_ext_data` was empty, and `vacuumdb --missing-stats-only` filled it. Start and rebuild:

```bash
"$NEW/pg_ctl" -D "$NEW_DATA" -l upgrade.log -w start
"$NEW/vacuumdb" --all --analyze-in-stages --missing-stats-only -j 4    # extended stats, missing column stats
"$NEW/vacuumdb" --all --analyze-only -j 4                              # cumulative stats for autovacuum
psql -X -U postgres -f update_extensions.sql postgres                  # written by pg_upgrade when versions changed
```

- `update_extensions.sql` held `ALTER EXTENSION "pgcrypto" UPDATE;` (1.3 to 1.4); until it runs, the old extension
  version stays installed.
- Logical slots and subscriptions migrate when the old cluster is 17 or later; our `cdc_slot` existed after the run.
- Physical standbys do not migrate: rebuild them from the new primary, or use the documented `rsync --hard-links`
  procedure after `--link`. Replicas' own physical slots must be recreated.
- Take a new full backup now: old physical backups cannot restore into 18.

## Rolling back a pg_upgrade

How you roll back depends on the mode, and some modes leave no way back but the backup.

| Mode | Before the new server starts | After the new server starts |
|---|---|---|
| `--check` only, `--copy`, `--clone`, `--copy-file-range` | start the old cluster | start the old cluster (writes made on the new one are lost) |
| `--link` | rename `global/pg_control.old` back to `global/pg_control`, then start the old cluster (tested) | restore from backup |
| `--swap` | only if `pg_upgrade` stopped before it reported the old cluster unsafe | restore from backup |

After `--swap`, our old data directory had no `global/pg_control` and `pg_upgrade` printed `Because "swap" mode was
used, the old cluster can no longer be safely started.` The docs recommend `--sync-method=fsync` with `--swap`.

## Blue/green upgrade with logical replication

A blue/green upgrade builds the new version (green) next to the running old one (blue), keeps it in sync with logical
replication, and moves clients over in seconds. Its limits come from logical replication: DDL, sequence values and
large objects are not replicated, and every table needs a primary key or replica identity.

1. Blue: `wal_level = logical`, a replication role, `max_slot_wal_keep_size` sized for the run.
2. Green: a new cluster on the new major; copy roles (`pg_dumpall --roles-only`) and the schema (`pg_dump
   --schema-only`); create a subscription to a `FOR ALL TABLES` publication on blue.
3. Wait until every table is `r` (ready) in `pg_subscription_rel` and lag is near zero; freeze DDL on blue.
4. Cut over (next section), and keep blue as the fallback with reverse replication.

On large databases the initial copy takes hours; the next path avoids it.

## Blue/green without the initial copy: pg_createsubscriber then pg_upgrade

`pg_createsubscriber` turns a physical standby into a logical subscriber, so green starts with all the data already
there. It needs the same major version on both sides, so run it on the old version, then `pg_upgrade` the subscriber:
subscriptions survive `pg_upgrade` from 17 and later. This sequence ran end to end from 17.11 to 18.6 while blue kept
taking writes:

```bash
pg_basebackup -h blue -U replicator -D "$GREEN17" -X stream -c fast -R -C -S green_slot      # 17 binaries
pg_createsubscriber -D "$GREEN17" -P "host=blue dbname=shop user=postgres" -d shop -U postgres \
  --publication=bg_pub --subscription=bg_sub --replication-slot=bg_slot                     # target stopped
# start green17; check it replicates; then:
psql -h green -d shop -c "ALTER SUBSCRIPTION bg_sub DISABLE"
pg_ctl -D "$GREEN17" -w stop
# initdb an 18 cluster and run pg_upgrade from GREEN17 to GREEN18 as above
psql -h green -d shop -c "ALTER SUBSCRIPTION bg_sub ENABLE"   # catches up the writes made during the upgrade
```

- `pg_createsubscriber` creates a `FOR ALL TABLES` publication and a slot on blue, changes green's system identifier,
  and drops the standby's `primary_slot_name` slot (our `green_slot` disappeared).
- The docs ask for `max_slot_wal_keep_size = -1` on blue while it runs, so no needed WAL is removed.
- After `ENABLE`, both sides showed 201,500 rows, including the writes made during the upgrade.

## Cutover: freeze writes, confirm catch-up, sync sequences

The cutover moves writes from blue to green with no lost transaction. These steps ran on the clusters above:

```sql
-- on blue: stop writes and note the final position
ALTER DATABASE shop SET default_transaction_read_only = on;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname = 'shop' AND backend_type = 'client backend' AND pid <> pg_backend_pid();
SELECT pg_current_wal_lsn();                                       -- e.g. 0/50EACA0
SELECT confirmed_flush_lsn >= '0/50EACA0' AS caught_up FROM pg_replication_slots WHERE slot_name = 'bg_slot';
```

Then copy sequence values, which logical replication does not carry, and detach green from blue. This query prints
one `setval` per sequence, with a safety gap of 1000 values; save it as `sequences-setval.sql`
([scripts/sequences-setval.sql](scripts/sequences-setval.sql) is the same query with the gap as a `psql` variable):

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

Run it as a role that can read every sequence: `pg_sequences.last_value` is `NULL` for a sequence the role has no
`USAGE` or `SELECT` on, and the filter would skip that sequence with no warning. A sequence never used is also `NULL`
and needs no `setval`. On green our `orders_id_seq` moved from 200000 to the right value:

```bash
psql -X -At -h blue -d shop -f sequences-setval.sql > setval.sql
psql -X -v ON_ERROR_STOP=1 -h green -d shop -f setval.sql
psql -h green -d shop -c "DROP SUBSCRIPTION bg_sub"      # also drops bg_slot on blue
```

Before opening green to writes, create the reverse subscription on blue (`WITH (copy_data = false)`) so blue stays a
current fallback; it must exist before green's first write, because earlier writes are not sent. Finally, point
clients at green (DNS, proxy or connection string) and release the freeze. Details and rollback:
[references/blue-green-runbook.md](references/blue-green-runbook.md).

## Minor updates such as 18.6

A minor update replaces binaries and restarts; the data directory stays. Read "Migration to Version" in the release
notes of every minor you skip: 18.6 added `output_plugin_libraries`, so slots using plugins other than `pgoutput`
and `test_decoding` stop working until you add them (CVE-2026-6471); it asks to check GIN indexes' table statistics,
and to reindex `btree_gist` and `ltree` indexes in some cases. With replicas, update them first, switch over, then
update the old primary.

## Managed-service upgrade paths

Managed services wrap these mechanisms.

| Service | Major upgrade | Notes from the docs |
|---|---|---|
| Amazon RDS for PostgreSQL | blue/green deployment | logical replication when it includes a major upgrade; switchover usually under a minute; PITR history does not carry over |
| Google Cloud SQL | in-place | uses `pg_upgrade`; a precheck can run first; the instance is unavailable during the upgrade |
| Azure Database for PostgreSQL flexible server | in-place | uses `pg_upgrade`; takes an implicit backup first; read replicas must be deleted first |

## Gotchas

These are the failures seen most often in upgrades, each with its cause and fix.

1. **Plans got slow after the upgrade.** Extended statistics are not carried over. Run
   `vacuumdb --all --analyze-in-stages --missing-stats-only`, then `--analyze-only`.
2. **The final `--check` fails on slots although the live check passed.** Consumers had not read the WAL written up
   to shutdown. Stop writes, let consumers finish, then stop the server.
3. **A CDC tool stopped after a minor update to 18.6.** Its output plugin is not in `output_plugin_libraries`. Add it.
4. **Green has duplicate key errors after cutover.** Sequences were not synced. Run the `setval` script before the
   first write on green.
5. **The old cluster will not start after a `--link` upgrade.** The new server was started, or `pg_control` was not
   renamed back. Restore from backup; prefer `--clone` when the filesystem supports it.
6. **Replication to green stopped: `logical replication target relation "public.t" is missing replicated column`.**
   DDL ran on blue during the run. Apply the same DDL on green and the apply worker resumes (tested); new tables also
   need `ALTER SUBSCRIPTION ... REFRESH PUBLICATION`.

## Anti-patterns in major upgrades

Each of these turns a planned change into a restore.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Upgrading without a rehearsal | extensions and `--check` failures appear in the window | a full run on a copy first |
| `--link` or `--swap` with no verified backup | the old cluster is lost at the new server's first start, or during a `--swap` run | `--clone` where possible, and a tested backup |
| Trusting only the live `--check` | it passed slots that still had unconsumed WAL | check again after the old server stops |
| DDL during a blue/green run | the apply worker stops | freeze DDL until cutover |
| Cutting over without syncing sequences | green raises duplicate key errors | run the `setval` query before the first write |
| Deleting the old cluster on day one | the fallback is gone | keep it until a restore drill passes |
| Skipping the notes of skipped minors | a required step such as `output_plugin_libraries` is missed | read each "Migration to Version" section |

## Verify an upgrade before and after the switch

Rehearse against the running old cluster, then prove the new one. The rehearsal ran from 17 to 18.6 with
[scripts/pg-upgrade-check.sh](scripts/pg-upgrade-check.sh) and changed nothing on the old cluster.

```bash
scripts/pg-upgrade-check.sh "$OLD" "$NEW" "$OLD_DATA" "$NEW_DATA" /var/run/postgresql 5432   # *Clusters are compatible*, exit code: 0
```

```sql
-- on the new cluster, after the switch
SELECT current_setting('server_version');                                     -- the target
SELECT count(*) FROM pg_index WHERE NOT indisvalid;                           -- 0
SELECT name, default_version, installed_version FROM pg_available_extensions
WHERE installed_version IS NOT NULL AND installed_version <> default_version; -- 0 rows after update_extensions.sql
```

For blue/green, confirm first that `apply_error_count` in `pg_stat_subscription_stats` is 0 and that a row count per key
table matches on both sides, and only then move traffic. Each sequence must be past its table's maximum id, or the first
insert fails with a duplicate key.

## Checklist

Check these points before and after an upgrade.

- [ ] Target version and method chosen against the downtime and rollback budget; extensions exist for the target.
- [ ] `pg_upgrade --check` passes live and again after the old server stops; a full rehearsal ran on a copy.
- [ ] A verified backup exists, and the rollback steps for the chosen mode are written down.
- [ ] Blue/green: each table has a replica identity (a primary key counts), DDL is frozen, sequences are synced at cutover.
- [ ] After: statistics rebuilt, `update_extensions.sql` run, replicas rebuilt, new full backup taken.
- [ ] The old cluster is deleted only after the new one ran in production and a restore drill passed.

## See also

Related skills in this library:

- `postgres-operations`: `pg_upgrade` basics and 18 behaviour changes
- `postgres-patroni-ha`: upgrading under Patroni
- `postgres-replication-ha`: logical replication in depth
- `postgres-backup-restore`: the verified backup and restore drill
- `postgres-pg18-features`: what 18 changes

## Sources

- https://www.postgresql.org/docs/18/pgupgrade.html
- https://www.postgresql.org/docs/18/app-pgcreatesubscriber.html
- https://www.postgresql.org/docs/18/logical-replication-upgrade.html
- https://www.postgresql.org/docs/18/logical-replication-restrictions.html
- https://www.postgresql.org/docs/18/release-18.html and https://www.postgresql.org/docs/18/release-18-6.html
- https://www.postgresql.org/support/versioning/ and https://www.postgresql.org/developer/roadmap/
- https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-overview.html
- https://cloud.google.com/sql/docs/postgres/upgrade-major-db-version-inplace
- https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-major-version-upgrade
