---
title: pg_dump, pg_restore, pg_dumpall, pg_basebackup and pg_isready flags
author: MOZGII, Inc.
lang: en
---

# pg_dump, pg_restore, pg_dumpall, pg_basebackup and pg_isready flags

This reference lists the flags of the PostgreSQL 18 client tools that change what gets copied or how a run fails,
with the commands that were run against 18.6 to check them. Which backup method to choose, retention and
point-in-time recovery are covered by `postgres-backup-restore`.

## Contents

The sections of this reference on client tool flags:

1. pg_dump formats and parallelism
2. pg_dump: choosing what to dump, and filter files
3. pg_dump statistics in PostgreSQL 18
4. pg_restore: lists, sections and transactions
5. pg_dumpall: roles and tablespaces
6. pg_basebackup flags
7. pg_isready in health checks
8. Plain-format dumps and the restrict key

## pg_dump formats and parallelism

The output format decides what pg_restore can do later.

| Format | Flag | Parallel dump | Parallel restore | Pick objects at restore |
|---|---|---|---|---|
| plain SQL | `-Fp` (default) | no | no (psql runs it) | no |
| custom | `-Fc` | no | yes (`pg_restore -j`) | yes |
| directory | `-Fd` | yes (`-j`) | yes | yes |
| tar | `-Ft` | no | no | yes |

These commands make a parallel, compressed directory dump with statistics, and a custom-format dump:

```bash
pg_dump -Fd -j 4 -Z zstd:3 --statistics -f app.dir app
pg_dump -Fc -f app.dump app
```

`-j N` opens N worker connections plus one leader. pg_dump holds `ACCESS SHARE` locks on the dumped tables, so DDL
waits for it; `--lock-wait-timeout` makes the dump fail instead of waiting for its own locks. `-Z` takes `gzip`, `lz4`, `zstd` or
`none` with an optional level (`zstd:3`).

## pg_dump: choosing what to dump, and filter files

Selection flags take patterns (`app.*`, `"Mixed Case"`), and can repeat.

| Flag | Effect |
|---|---|
| `-n`, `-N` | include or exclude schemas |
| `-t`, `-T`, `--table-and-children`, `--exclude-table-and-children` | include or exclude tables (with partitions) |
| `--exclude-table-data`, `--exclude-table-data-and-children` | keep the definition, skip the rows (logs, caches) |
| `-e`, `--exclude-extension` (17+) | include or exclude extensions |
| `-s` / `--schema-only`, `-a` / `--data-only`, `--no-schema`, `--no-data` | definitions only or rows only |
| `-O` / `--no-owner`, `-x` / `--no-privileges`, `--no-policies` | leave out ownership, grants, row security policies |
| `--filter=FILE` | read include and exclude rules from a file (17+) |

A filter file has one rule per line: `include` or `exclude`, then an object type (`extension`, `foreign_data`,
`table`, `table_and_children`, `table_data`, `table_data_and_children`, `schema`), then a pattern; `#` starts a
comment. This file ran on 18.6:

```text
exclude table_data app.orders
include schema app
```

The filter file and a table-data exclusion on the command line:

```bash
pg_dump -Fc --filter=dump.filter -f app.dump app
pg_dump -Fc --exclude-table-data='app.events*' -f app-nodata.dump app
```

## pg_dump statistics in PostgreSQL 18

PostgreSQL 18 can dump planner statistics so a restored database plans well before `ANALYZE` finishes. In 18.6
pg_dump does not include them unless asked (checked: a default dump had no `pg_restore_relation_stats` calls,
`--statistics` added them).

| Flag | Effect |
|---|---|
| `--statistics` | add statistics to schema and data |
| `--statistics-only` | only statistics |
| `--no-statistics` | leave them out (the default) |

Statistics from `CREATE STATISTICS`, extensions and the cumulative statistics views are not dumped, so run
`ANALYZE` (or `vacuumdb --analyze-in-stages --missing-stats-only`) after a restore anyway.

## pg_restore: lists, sections and transactions

pg_restore works on custom, directory and tar archives. Its table of contents (TOC) can be printed, edited and fed
back to restore a subset or a different order.

```bash
pg_restore -l app.dir > toc.list                 # comment out lines with ';' to skip them
pg_restore -d app_copy --section=pre-data --no-owner --no-privileges --exit-on-error app.dir
pg_restore -d app_copy --section=data -j 4 --exit-on-error -L toc.list app.dir
pg_restore -d app_copy --section=post-data -j 4 --exit-on-error app.dir
pg_restore -d app_copy --transaction-size=100 --no-owner app.dir
pg_restore -f - --section=post-data app.dir      # print the SQL instead of running it
```

| Flag | Effect |
|---|---|
| `--section=pre-data / data / post-data` | tables and types; rows; indexes, constraints, triggers. Split to load data before indexes |
| `-L FILE` | restore only the TOC entries in the (edited) list |
| `-j N` | parallel restore of data and indexes |
| `-e`, `--exit-on-error` | stop at the first error (the default is to continue and report a count) |
| `-1`, `--single-transaction` | all or nothing; cannot combine with `-j`; locks every object at once |
| `--transaction-size=N` (17+) | commit every N objects; implies `--exit-on-error`; the middle ground for big restores |
| `-c --if-exists` | drop objects before creating them, without errors for missing ones |
| `-C` | create the database from the archive, connecting to `-d` first |
| `--no-owner`, `--no-privileges` | restore into a different set of roles |
| `--statistics`, `--no-statistics`, `--statistics-only` | restore or skip statistics present in the archive |

## pg_dumpall: roles and tablespaces

pg_dump never includes roles or tablespaces; pg_dumpall does. Use it for globals and keep pg_dump for databases.

```bash
pg_dumpall --globals-only --no-role-passwords -f globals.sql
```

`--no-role-passwords` reads roles from `pg_roles` instead of `pg_authid`, which helps where `pg_authid` is not
readable, and keeps password hashes out of the file; set passwords again after restoring. `-r` dumps roles only, `-t` tablespaces only, `--exclude-database`
skips databases in a full dump.

## pg_basebackup flags

pg_basebackup copies a whole cluster over the replication protocol, for a replica or a physical backup.

```bash
pg_basebackup -D /backups/base -X stream -c fast -P --manifest-checksums=SHA256
pg_verifybackup /backups/base
pg_basebackup -D /backups/base-tar -Ft -Z server-zstd:3 -X fetch -c fast -l nightly
pg_basebackup -D /var/lib/postgresql/18/replica -X stream -R -C -S replica1
```

| Flag | Effect |
|---|---|
| `-X stream` (default) / `fetch` / `none` | stream WAL during the copy (a second replication connection), fetch it at the end, or skip it (backup unusable alone) |
| `-c fast` / `spread` | immediate checkpoint, or a spread one that is gentler but makes the start slow |
| `-Ft`, `-Z [client-\|server-]METHOD[:LEVEL]` | tar output, compressed on the client or the server |
| `-R`, `-C -S name` | write `standby.signal` and `primary_conninfo`; create and use a replication slot |
| `-i OLD_MANIFEST` | incremental backup against an earlier one; without `summarize_wal = on` it fails with `incremental backups cannot be taken unless WAL summarization is enabled`; `pg_combinebackup` rebuilds a full copy |
| `-r RATE`, `-P` | limit transfer rate; show progress |
| `--manifest-checksums`, `--no-manifest` | checksum algorithm in `backup_manifest` (CRC32C default); `pg_verifybackup` uses it |

The connecting role needs the `REPLICATION` attribute and a `replication` line in `pg_hba.conf`.

## pg_isready in health checks

pg_isready asks the server whether it accepts connections without logging in, so it suits container health checks
and start-up waits. It only checks the listener; it does not run a query.

```bash
pg_isready -h db1.internal -p 5432 -t 3
```

| Exit code | Meaning |
|---|---|
| 0 | accepting connections |
| 1 | rejecting (for example during start-up or recovery) |
| 2 | no response |
| 3 | no attempt (bad parameters) |

A wrong user or database name is not checked, but the server logs a failed connection attempt for it; pass a real
role and database to keep the log clean.

## Plain-format dumps and the restrict key

Plain dumps from pg_dump, pg_dumpall and `pg_restore -f` start with `\restrict KEY` and end with `\unrestrict KEY`,
which block psql meta-commands hidden in data from a malicious source server (CVE-2025-8714, fixed in the August 2025
minor releases; the 18.6 release fixed a gap in it, CVE-2026-18408). `--restrict-key=KEY` sets a fixed key, for
example to make dumps reproducible in tests. Restore plain dumps with a psql at least as new as those releases, and
with `-X` so a `.psqlrc` cannot change behaviour.
