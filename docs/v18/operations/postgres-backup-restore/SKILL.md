---
name: postgres-backup-restore
description: 'Backs up and restores PostgreSQL: choosing pg_dump or physical backups with WAL archiving, pg_dump and pg_restore formats and flags, pg_dumpall globals, pg_basebackup and incremental backups, point-in-time recovery, pgBackRest, WAL-G and Barman, managed-service snapshots, retention, encryption and scheduled restore drills. Use when setting up backups, restoring a database or one table, undoing a bad DELETE by recovering to a moment, moving data between servers, or proving backups restore.'
metadata:
  tags:
  - postgres
  - backup
  - restore
  - pg_dump
  - pg_restore
  - pitr
  - pgbackrest
  - wal-archiving
---

# PostgreSQL backup and restore

A backup you have never restored is a hope, not a backup. This skill picks the backup method, gives exact commands,
and ends with the drill that proves a restore works. pgBackRest setup: [references/pgbackrest.md](references/pgbackrest.md).
The logical restore drill is written out in Restore drills and packaged as
[scripts/restore-drill.sh](scripts/restore-drill.sh). For one app's private local cluster, see
`postgres-local-cluster`.

## Step 0: read the tools, the archive and the sizes

Backup advice depends on the client version, the size of the data and whether WAL archiving already works, so read
all three first.

```bash
pg_dump --version; pg_restore --version; pg_basebackup --version
pgbackrest version 2>/dev/null; wal-g --version 2>/dev/null; barman -v 2>/dev/null
```

```sql
SELECT version(), pg_is_in_recovery() AS standby;
SELECT name, setting FROM pg_settings
WHERE name IN ('wal_level', 'archive_mode', 'archive_command', 'archive_library', 'summarize_wal');
SELECT archived_count, failed_count, last_archived_time, last_failed_time FROM pg_stat_archiver;
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database ORDER BY pg_database_size(datname) DESC;
```

## Choose a backup method

Backups come in two kinds: logical (SQL-level copies of data) and physical (copies of the data files plus WAL).
Production usually needs physical backups with WAL for point-in-time recovery, plus periodic logical dumps.

| Method | Restores to | Good for | Limits |
|---|---|---|---|
| `pg_dump` per database | the moment the dump started | small and medium databases, one table, moving across major versions | slow restore on big data; no point in time |
| `pg_basebackup` + WAL archive | any moment covered by the WAL | whole-cluster recovery, PITR | same major version; cluster-wide only |
| pgBackRest / WAL-G / Barman | any moment, with retention, compression, encryption, object storage | production servers | a tool to run and monitor |
| Managed service (RDS, Cloud SQL, Azure, Supabase, Neon) | provider's PITR window | hosted databases | provider-bound; still take your own dumps for exit and long retention |

Write down your RPO (how much data you may lose) and RTO (how long a restore may take); they decide the method.

## Logical backups with pg_dump

`pg_dump` writes a consistent snapshot of one database without blocking writes. Use the custom (`-Fc`) or directory
(`-Fd`) format: both compress and let `pg_restore` pick objects and run in parallel.

```bash
# one database, custom format
pg_dump -h db.internal -U backup -d app -Fc -Z zstd:3 -f app-$(date -u +%Y%m%dT%H%M%SZ).dump
# large database: directory format with 4 parallel jobs (opens 5 connections)
pg_dump -h db.internal -U backup -d app -Fd -j 4 -f app-dir/
# roles, tablespaces and other cluster-wide objects: pg_dump never includes them
pg_dumpall -h db.internal -U postgres --globals-only -f globals.sql
```

- Use the `pg_dump` of the newest major among source and target: a newer `pg_dump` reads older servers, never the
  reverse.
- PG 18 does not dump optimizer statistics by default (`--statistics` adds them); run `ANALYZE` after a restore.
- `--no-owner --no-privileges` makes a dump restorable into a database with different roles.
- Read the password from `~/.pgpass` (0600) or `PGPASSFILE`, never from the command line.

## Restoring with pg_restore

`pg_restore` reads custom, directory and tar dumps; it can restore everything, chosen objects, or one table.

```bash
psql -h db.new -U postgres -f globals.sql                         # roles first: createdb -O needs the owner
createdb -h db.new -U postgres -O app_owner app
pg_restore -h db.new -U postgres -d app -j 4 --exit-on-error app.dump
# preview, then restore a chosen subset
pg_restore -l app.dump > toc.txt          # edit toc.txt: comment out lines with ;
pg_restore -h db.new -d app -L toc.txt app.dump
vacuumdb -h db.new -U postgres -d app --analyze-in-stages
```

### Replacing one table: what pg_restore -t leaves out

`pg_restore -t orders` restores only the table and its rows. Combined with `--clean` it drops the live table and
brings it back without its primary key, indexes, triggers, foreign keys and identity sequence (seen on 18.6). If
another table references it, the `DROP` fails, and the rows then collide with the old ones. To replace a table, select
all of its objects from the dump's table of contents and read the file before you run it:

```bash
pg_restore -l app.dump | grep orders > toc.txt     # table, data, sequence, constraints, indexes, triggers
pg_restore -h db.new -U postgres -d app --clean --if-exists -L toc.txt app.dump
```

On 18.6 this brought back the primary key, index, trigger, foreign key and identity. Drop foreign keys that point at
the table first. On a live database, prefer the worked example: restore into a scratch database and copy the rows back.

- `-j` parallel restore works with custom and directory formats, not with `--single-transaction`.
- A plain SQL dump (`-Fp`) restores only with `psql -v ON_ERROR_STOP=1 -f dump.sql`.
- Extensions must be installed on the target server (the `vector` library, PostGIS) before restore.

## Physical backups with pg_basebackup and WAL archiving

A physical backup copies the cluster's data files; WAL archiving keeps every change after it, so recovery can replay
to any moment. Both need the server configured.

```ini
# postgresql.conf
wal_level = replica
archive_mode = on                          # restart required
archive_command = 'test ! -f /backup/wal/%f && cp %p /backup/wal/%f'   # example only; use a real tool in production
archive_timeout = '5min'                   # caps data loss on a quiet server
```

```bash
pg_basebackup -h db.internal -U replicator -D /backup/base/$(date -u +%Y%m%d) -Ft -z -X stream -c fast -P
pg_verifybackup -n /backup/base/20261128                # checks the backup_manifest; tar format (PG 18) needs -n
```

- `archive_command` must return non-zero on failure and never overwrite a different file; `cp` alone is not durable
  (no fsync). pgBackRest, WAL-G and Barman do this correctly.
- PG 17+ supports incremental backups: `summarize_wal = on`, then
  `pg_basebackup --incremental=<previous>/backup_manifest`, and `pg_combinebackup` to rebuild a full one at restore.
- Monitor `pg_stat_archiver.failed_count`: a failing archive fills the WAL disk and stops the server.

## Point-in-time recovery

PITR restores a base backup and replays archived WAL up to a chosen moment, such as just
before a bad `DELETE`.

```bash
# 1. stop the server and keep the broken data directory aside, never delete it
pg_ctl stop -D "$PGDATA" -m fast
mv "$PGDATA" "$PGDATA.broken-$(date -u +%Y%m%dT%H%M%SZ)"
# 2. restore the newest base backup taken BEFORE the target time into $PGDATA, then:
cat >> "$PGDATA/postgresql.auto.conf" <<'EOF'
restore_command = 'cp /backup/wal/%f "%p"'
recovery_target_time = '2026-11-28 09:41:00+00'
recovery_target_action = 'promote'
EOF
touch "$PGDATA/recovery.signal"
pg_ctl start -D "$PGDATA" -w -t 600
psql -c "SELECT pg_is_in_recovery();"      # f once promoted
```

- Always give the target time a time zone.
- The base backup must have finished before the target, because recovery only moves forward from the backup. With an
  older target on a busy server (commits ran during the backup), start-up stops with `FATAL: requested recovery stop
  point is before consistent recovery point`. After a quiet backup it promotes with no error at the first commit
  past the backup, and rows newer than the target stay in the data. Both ran on 18.6.
- After promotion the cluster is on a new timeline: take a new full backup.
- Other targets: `recovery_target_lsn`, `recovery_target_xid`, `recovery_target_name` (from `pg_create_restore_point('before-deploy')`).

## Backup tools for production: pgBackRest, WAL-G, Barman

Dedicated tools handle archiving, compression, encryption, parallelism, retention and object storage correctly.

| Tool | Licence | Strengths |
|---|---|---|
| pgBackRest | MIT | full, differential, incremental and block-level backups; S3, GCS, Azure; async archiving; parallel restore with `--delta` |
| WAL-G | Apache-2.0 | simple, cloud-first, delta backups, used widely on Kubernetes |
| Barman | GPL-3.0 | backup server for many Postgres hosts, streaming WAL |

Configuration and commands for pgBackRest: [references/pgbackrest.md](references/pgbackrest.md).

## Retention, encryption and off-site copies

A backup on the same disk or account as the database protects against nothing that takes both.

- Keep at least two full backups plus all WAL between them; delete whole chains, oldest first.
- Store backups off the database host and in another account or region, with object lock or versioning against
  deletion by an attacker who has the database credentials.
- Encrypt at rest (pgBackRest `repo1-cipher-type`, bucket encryption) and keep the key outside the backup.
- Logical dumps on a longer schedule cover long-term retention and exits from a managed provider.

## Restore drills

A restore drill restores the latest backup into a scratch server, runs checks, records the time it took, and deletes
the scratch copy. Run it on a schedule (weekly) and alert on failure. The drill measures your real RTO.

```bash
scratch="drill_$(date +%s)_$$"
start=$(date +%s)
createdb "$scratch"
pg_restore --no-owner --no-privileges --exit-on-error -j 4 -d "$scratch" app.dump
vacuumdb --analyze-only -d "$scratch"
psql -X -At -v ON_ERROR_STOP=1 -d "$scratch" -c "SELECT count(*) > 0 FROM app.orders"     # expect t
echo "restore took $(( $(date +%s) - start )) seconds"
dropdb "$scratch"
```

`scripts/restore-drill.sh` is the same drill with cleanup on failure, an expected value and a `PASS` or `FAIL` line for
a scheduler: `restore-drill.sh app.dump "SELECT count(*) > 0 FROM app.orders" t`.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

For physical backups, the drill restores with the tool (`pgbackrest restore --pg1-path=/scratch ...`), starts on a
spare port with `archive_mode = off` so the drill never writes into the real archive, and runs the same checks.

## Worked example: "someone deleted customer 4211's orders an hour ago"

Only a few rows are gone and the rest of the database must keep running, so do not roll the whole server back.
Restore a copy beside production and copy the rows back:

1. Note the time just before the bad statement from the application log or `log_statement` output:
   `2026-11-28 09:41:00+00`.
2. With physical backups and WAL: restore into a scratch data directory on another port
   (`pgbackrest --stanza=main --pg1-path=/scratch/pg --type=time "--target=2026-11-28 09:40:59+00" --target-action=promote restore`),
   start it with `archive_mode = off`, and confirm the rows are there.
3. With only last night's dump, create a scratch database and its schema first, or the restore fails with
   `schema "app" does not exist`: `createdb scratch`, `psql -d scratch -c 'CREATE SCHEMA app'`, then
   `pg_restore -d scratch -n app -t orders app.dump` (rows changed after the dump are not in it; say so).
4. Copy the rows back in one transaction:
   `\copy (SELECT * FROM app.orders WHERE customer_id = 4211) TO 'orders-4211.csv' WITH (FORMAT csv)` on the scratch
   server, then `\copy app.orders FROM 'orders-4211.csv' WITH (FORMAT csv)` on production. `COPY FROM` writes
   identity column values as given, so the rows keep their old ids.
5. Drop the scratch server, and record how long it took: that is your real RTO for a partial restore.

## Checklist

Check these points before you call a backup setup done.

- [ ] RPO and RTO written down; method chosen from them.
- [ ] Physical backups with continuous WAL archiving for production, via a dedicated tool.
- [ ] `pg_dumpall --globals-only` saved with every logical dump.
- [ ] Backups stored off-host, in another account or region, encrypted, protected against deletion.
- [ ] Archiver health (`pg_stat_archiver.failed_count`) and backup age are monitored.
- [ ] A scheduled restore drill passes and records its duration.
- [ ] Restores never delete the old data directory first.

## Gotchas

These are the failures seen most often with a backup setup, each with its cause and fix.

1. **`pg_restore: error: unsupported version (1.16) in file header`.** The dump came from a newer `pg_dump` than
   the `pg_restore` running. Use the newer client binaries.
2. **Restore fails on missing roles.** `pg_dump` has no roles. Restore `globals.sql` first or use `--no-owner`.
3. **`FATAL: requested recovery stop point is before consistent recovery point`, or PITR kept later data than
   requested.** The base backup ended after the target time: commits during the backup give the error, a quiet backup
   promotes with the newer rows. Choose an older backup.
4. **The disk filled with WAL.** `archive_command` was failing; WAL is kept until archived. Fix the archive, never
   delete files in `pg_wal` by hand.
5. **Slow queries right after a restore.** No statistics. Run `vacuumdb --analyze-in-stages`.
6. **A drill wrote into the production archive.** It ran with `archive_mode = on` and the real archive path. Drills
   run with `archive_mode = off`.

## Anti-patterns in backup and restore

| Do not | Do this instead |
|---|---|
| trust a backup nobody restored | a scheduled drill that restores, checks and records the time |
| run `pg_restore --clean -t` on a live table | restore beside it and copy rows, or restore every object through a table of contents |
| delete the old data directory before a restore | move it aside and keep it until the new one is proven |
| keep backups on the database host or account | another account or region, with object lock or versioning |
| delete files in `pg_wal` when the disk fills | fix the archive and let the server recycle them |
| use `cp` as an `archive_command` in production | pgBackRest, WAL-G or Barman |

## See also

- `postgres-local-cluster`: backups for one app's private cluster.
- `postgres-replication-ha`: standbys, which complement backups and never replace them.
- `postgres-psql-cli`: `pg_dump`, `pg_restore` and `pg_basebackup` flags in depth.
- `postgres-zero-downtime-upgrades`: moving between major versions.
- `postgres-encryption-tls`: encrypting data at rest.

## Sources

- https://www.postgresql.org/docs/18/app-pgdump.html, /app-pgrestore.html, /app-pg-dumpall.html
- https://www.postgresql.org/docs/18/continuous-archiving.html, /app-pgbasebackup.html, /app-pgverifybackup.html
- https://pgbackrest.org/user-guide.html and https://github.com/pgbackrest/pgbackrest (`src/common/ini.c`)
- Run on 18.6: restores with `-t` and with a table of contents, the scratch restore, the drill. With pgBackRest 2.60.0:
  `stanza-create`, `check`, a full backup, and the inline comment failure.
