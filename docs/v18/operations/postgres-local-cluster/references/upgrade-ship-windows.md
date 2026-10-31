---
title: Local cluster upgrades, bundling and Windows
author: MOZGII, Inc.
lang: en
---

# Local cluster upgrades, bundling and Windows

This reference covers upgrading an app's private PostgreSQL cluster, the binaries an app must bundle, checks for a
relocatable macOS build, and how the setup differs on Windows.

## Contents

The sections of this reference on local cluster upgrades, bundling and Windows:

1. Minor upgrade
2. pgvector upgrade
3. Major upgrade
4. Bundle list
5. Relocatable macOS build checks
6. Windows

## 1. Minor upgrade

A minor upgrade keeps the major and the data folder; only the binaries change.

1. Read the release notes of every minor between the current and the new one
   (`https://www.postgresql.org/docs/<major>/release-<major>-<minor>.html`) and list each "Migration to Version X.Y"
   item: reindexes, `ANALYZE`, new settings, required new backups.
2. Stop the cluster, point the pin file or bundle at the new runtime, start, and run Step 0.
3. Apply the listed items. From 18.6: `ANALYZE` tables whose GIN indexes were built in parallel (their `reltuples`
   may be wrong), reindex `btree_gist` indexes on float and bit columns and large `ltree` B-tree indexes, list any
   third-party logical decoding plugin in the new `output_plugin_libraries`, and start a new incremental chain with a
   full backup.

## 2. pgvector upgrade

The pgvector extension version inside each database is separate from the library version in the runtime.

```sql
SELECT default_version, installed_version FROM pg_available_extensions WHERE name = 'vector';
ALTER EXTENSION vector UPDATE;      -- in every database that has it
```

Refuse to open a database whose `installed_version` is newer than the runtime's `default_version`: an older library is
not guaranteed to read newer extension objects. This happens when a development runtime carries an older pgvector
than the bundle.

## 3. Major upgrade

A major upgrade creates a new cluster with the new runtime and moves the data with `pg_upgrade`.

```bash
OB=<old runtime>/bin NB=<new runtime>/bin
"$OB/pg_ctl" stop -D "$R/data" -m fast -w
"$NB/initdb" -D "$R/data.new" -E UTF8 --locale=C --locale-provider=builtin --builtin-locale=PG_UNICODE_FAST \
  --auth-local=peer --auth-host=reject      # same flags as the old cluster; add --no-data-checksums if it has none
cp "$R/data/pg_hba.conf" "$R/data/app.conf" "$R/data.new/"; echo "include 'app.conf'" >> "$R/data.new/postgresql.conf"
cd "$HOME"                                  # short working directory
"$NB/pg_upgrade" -b "$OB" -B "$NB" -d "$R/data" -D "$R/data.new" -s "$S" -j "$(sysctl -n hw.ncpu)" --check
"$NB/pg_upgrade" -b "$OB" -B "$NB" -d "$R/data" -D "$R/data.new" -s "$S" -j "$(sysctl -n hw.ncpu)" --clone   # APFS; else --copy
mv "$R/data" "$R/data.old-<major>" && mv "$R/data.new" "$R/data"
"$NB/pg_ctl" start -D "$R/data" -l "$R/logs/postgres.log" -w -t 60
"$NB/vacuumdb" -h "$S" -p "$P" --all --analyze-in-stages --missing-stats-only
"$NB/vacuumdb" -h "$S" -p "$P" --all --analyze-only
```

- Before the first command: a verified backup and a passing drill. `--link` makes the old cluster unusable once the
  new one starts, and `--swap` (PG 18) consumes it. `--clone` (APFS, Btrfs, XFS) or `--copy` keep it intact.
- pg_upgrade needs from the old bindir `postgres`, `pg_controldata`, `pg_ctl`, `pg_resetwal`, and from the new one
  also `initdb`, `pg_dump`, `pg_dumpall`, `pg_restore`, `psql`, `vacuumdb`. The new `lib/` needs every library the old
  catalogs use: `SELECT DISTINCT probin FROM pg_proc WHERE probin IS NOT NULL`.
- From 18, pg_upgrade carries optimizer statistics (not extended statistics); the two `vacuumdb` passes fill the rest.
- After the start: `ALTER EXTENSION vector UPDATE`, `ALTER EXTENSION pg_trgm UPDATE`. Crossing into 18 from a cluster
  whose default provider is ICU or builtin, reindex FTS (`tsvector` GIN) and `pg_trgm` indexes.
- Take a new full backup and start a new chain. Delete `data.old-<major>` only after a drill on the new major passes.
- Before a new major is released (RC, beta), run `--check` against it in a scratch copy only.

| Failure at `--check` | Cause | Fix |
|---|---|---|
| "old cluster does not use data checksums but the new one does" | PG 18 initdb enables checksums | `--no-data-checksums` for the new cluster, or `pg_checksums --enable` on the stopped old one |
| "could not load library \"$libdir/vector\"" | the new runtime lacks an extension | bundle every extension built for both majors |
| socket path too long | temporary servers put sockets in the working directory | `-s <socket_dir>` and a short working directory |
| logical decoding plugin not permitted (18.6+) | `output_plugin_libraries` differs | set the same value in the new cluster |

## 4. Bundle list

An app that runs its own cluster must ship every binary its workflows call, plus the libraries and shared files.

- Bin: `postgres`, `pg_ctl`, `pg_isready`, `initdb`, `pg_controldata`, `pg_resetwal`, `psql`, `pg_basebackup`,
  `pg_combinebackup`, `pg_verifybackup`, `pg_waldump` (pg_verifybackup calls it), `pg_dump`, `pg_dumpall`,
  `pg_restore`, `pg_archivecleanup`, `pg_upgrade`, `vacuumdb`, `pg_checksums`, `pg_config`.
- Lib: `libpq` and every library the binaries link (`otool -L`, `ldd`), plus extension modules: `vector`, `pg_trgm`,
  `basic_archive`, `dict_snowball`, `plpgsql`.
- Share: the whole `share/` tree (time zones, `extension/*.control` and SQL, text search data).
- During an upgrade window, the old major's `postgres`, `pg_ctl`, `pg_controldata`, `pg_resetwal`, `lib/` and
  `share/` too.

Derive the shipped inventory with `ls` against this list in CI and fail the build when an entry is missing.

## 5. Relocatable macOS build checks

A PostgreSQL install tree is relocatable as a whole if its relative layout is kept and no binary refers to an
absolute library path.

Configure with `--disable-rpath` (meson `-Drpath=false`), set each dylib's id to `@rpath/<name>` or
`@loader_path/../lib/<name>`, and rewrite references with `install_name_tool -change`. A rewrite invalidates the
signature, so sign after the last rewrite.

```bash
for f in pg/darwin-arm64/bin/* pg/darwin-arm64/lib/*.dylib pg/darwin-arm64/lib/postgresql/*.dylib; do
  otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE '^(@loader_path|@rpath|/usr/lib|/System)/' && echo "NOT RELOCATABLE: $f"
done
codesign --verify --strict -vvv pg/darwin-arm64/bin/postgres
```

The loop must print nothing. Notarization needs Developer ID, Hardened Runtime and a secure timestamp on every
Mach-O, and no `get-task-allow`. Linking OpenSSL, ICU (if used), lz4, zstd and libxml2 into such a build has not been
proven end to end here, so the first build needs the move test from Workflow 8.

## 6. Windows

Windows needs a different network, auth and copy setup; this section is written but has not been run on Windows.

| macOS / Linux | Windows |
|---|---|
| `listen_addresses = ''`, socket 0700 | `listen_addresses = '127.0.0.1'`, own port per cluster (Node uses named pipes; node-postgres and asyncpg treat only `/`-prefixed hosts as sockets) |
| `--auth-local=peer` | `initdb --auth=scram-sha-256 --pwfile=<0600 file> -U <name>_admin` (no peer on Windows) |
| pg_hba: scram app line, peer, replication peer | `host <name> <name>_owner,<name>_app 127.0.0.1/32 scram-sha-256`, `host all <name>_admin 127.0.0.1/32 scram-sha-256`, `host replication <name>_admin 127.0.0.1/32 scram-sha-256` |
| tools run as the OS user | tools get `PGPASSFILE=<secrets>\admin.pgpass` (0600-equivalent ACL) in their own environment only |
| `restore_command = 'cp ...'` | `restore_command = 'copy "<archive>\\%f" "%p"'` |
| `wal_sync_method = fsync_writethrough` (macOS) | `fsync_writethrough` as well: the default `open_datasync` leaves the drive's write cache in play unless disabled in the disk's policies |
| runtime: own relocatable build | EDB "binaries" zip for the major; pgvector built with `nmake /F Makefile.win` (Visual Studio C++ tools) |

Open questions on Windows: an ARM64 runtime source, and whether EDB-signed binaries ship as they are or need
re-signing. Before the first Windows release, add a CI job that runs the cluster setup, the read-back (Workflow 2)
and the drill (backup-restore.md section 8, with `copy`) against the zip.
