---
title: PostgreSQL version upgrades
author: MOZGII, Inc.
lang: en
---

# PostgreSQL version upgrades

This reference covers minor upgrades, major upgrades with `pg_upgrade`, the alternatives (dump and restore, logical
replication), and what changes when moving to PostgreSQL 18.

## Minor version upgrades

A minor upgrade (18.4 to 18.6; 18.5 was never released) replaces binaries; the data directory stays as it is.
Releases come out quarterly and fix security issues, so apply them within weeks.

1. Read the release notes of every minor you skip; act on each "Migration to Version X.Y" item (a `REINDEX` of
   certain index types, a new full backup).
2. Install the new package, restart PostgreSQL (or fail over to an upgraded replica first, then upgrade the old
   primary).
3. `SELECT version();` and run the health check.

## Choosing a major upgrade method

A major upgrade (17 to 18) changes the on-disk format. Four methods:

| Method | Downtime | Notes |
|---|---|---|
| `pg_upgrade --link` or `--swap` | minutes, independent of size | fast; the old cluster cannot be used after the new one starts |
| `pg_upgrade --copy` / `--clone` | copy time / minutes on filesystems with reflinks (APFS, XFS, Btrfs) | old cluster stays usable as a fallback |
| `pg_dump` + `pg_restore` | proportional to data size | simplest; good for small databases or moving hosts |
| Logical replication | seconds at cutover | most work; see `postgres-replication-ha` |

Managed services offer in-place major upgrades (with downtime) and blue-green deployments built on logical
replication.

## pg_upgrade step by step

`pg_upgrade` creates the new cluster's catalogs and moves or links the user data files.

```bash
OLD=/usr/lib/postgresql/17/bin NEW=/usr/lib/postgresql/18/bin
# 1. a verified backup and a passing restore drill
# 2. create the new cluster with the same encoding, locale and checksum setting as the old one
$NEW/initdb -D /var/lib/postgresql/18/main --encoding=UTF8 --locale-provider=builtin --builtin-locale=C.UTF-8
#    (old cluster without checksums? add --no-data-checksums, or enable them on the stopped old cluster first)
# 3. install the same extensions (built for 18) on the new server
# 4. check, with both clusters stopped
$NEW/pg_upgrade -b $OLD -B $NEW -d /var/lib/postgresql/17/main -D /var/lib/postgresql/18/main --check
# 5. run
$NEW/pg_upgrade -b $OLD -B $NEW -d /var/lib/postgresql/17/main -D /var/lib/postgresql/18/main --link -j 4
# 6. start the new server, then
$NEW/vacuumdb --all --analyze-in-stages --missing-stats-only
```

- Copy `pg_hba.conf` and your settings to the new cluster by hand; `pg_upgrade` does not.
- Run it from a directory the `postgres` user can write; pass `-s <short dir>` when the temporary server's socket
  path would be too long.
- Debian and Ubuntu wrap this in `pg_upgradecluster`; it uses the same mechanism.
- Upgrade replicas by rebuilding them from the new primary, or with the documented `rsync` procedure for `--link`.

## What changes when upgrading to PostgreSQL 18

PostgreSQL 18 changes some defaults and behaviours that affect upgrades and applications.

- `initdb` enables data checksums by default. `pg_upgrade` requires both clusters to match: create the new cluster
  with `--no-data-checksums`, or turn checksums on in the old one with `pg_checksums --enable` while it is stopped.
- `pg_upgrade` keeps optimizer statistics (not extended statistics). Run `vacuumdb --analyze-in-stages
  --missing-stats-only` to fill the gaps, and `ANALYZE` tables with extended statistics.
- New modes: `--swap` (moves directories, fastest) and parallel checks with `--jobs`.
- MD5 passwords are deprecated and warn; move roles to scram (`postgres-security-roles`).
- Generated columns are virtual by default; `VACUUM`/`ANALYZE` now include inheritance children unless `ONLY`.
- Full-text search and `pg_trgm` follow the cluster's default collation provider: on clusters whose default provider
  is not libc, reindex `tsvector` GIN and trigram indexes after the upgrade.
- `EXPLAIN ANALYZE` shows buffers by default; tools parsing plans may need an update.
- `COPY FROM` no longer treats `\.` as end-of-file when reading a CSV file. psql still does for CSV from `STDIN`, and
  `\.` must now be alone on its line, so an older psql's `\copy` can fail against an 18 server.

## After any major upgrade

These steps finish an upgrade.

1. `ALTER EXTENSION <name> UPDATE` in every database.
2. Run statistics (`vacuumdb --analyze-in-stages`) before judging performance.
3. Take a new full backup: old physical backups cannot restore into the new major.
4. Delete the old cluster only after the new one has run in production and a restore drill passed
   (`./delete_old_cluster.sh` written by `pg_upgrade`).
5. Update client libraries and `pg_dump` on backup hosts to the new major.
