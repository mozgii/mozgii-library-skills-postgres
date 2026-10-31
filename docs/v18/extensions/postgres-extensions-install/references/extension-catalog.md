---
title: PostgreSQL extension catalog - install, settings and upgrades per extension
author: MOZGII, Inc.
lang: en
---

# PostgreSQL extension catalog: install, settings and upgrades per extension

This reference gives, for each common extension, the package name per OS, whether it must be preloaded, the
settings it needs and how it is upgraded. Versions are the ones PGDG shipped for PostgreSQL 18 in October 2026.

## Contents

The extensions covered, in this order:

- Package names at a glance
- pgvector
- PostGIS
- pg_cron
- pg_partman
- TimescaleDB
- pgaudit
- pg_repack
- pg_stat_statements and auto_explain
- A custom image or package with several extensions

## Package names at a glance

The PGDG repositories name extension packages after the server major. This table was read from the PGDG apt
repository (Debian 13) and the PGDG dnf repository (EL 9) in October 2026.

| Extension | Version | Debian, Ubuntu (PGDG) | RHEL family (PGDG) | macOS | Windows |
|---|---|---|---|---|---|
| pgvector | 0.8.7 | `postgresql-18-pgvector` | `pgvector_18` | Postgres.app bundles it; `brew install pgvector` for Homebrew's Postgres | `nmake /F Makefile.win install` |
| PostGIS | 3.7.0 | `postgresql-18-postgis-3` | `postgis37_18` (EPEL and CRB enabled); `postgis36_18` is the stable 3.6.4 until PGDG's rpm leaves release candidate | Postgres.app bundles 3.6.3 | StackBuilder with the EDB installer |
| pg_cron | 1.6.8 | `postgresql-18-cron` | `pg_cron_18` | build with PGXS | `nmake /F Makefile.win install` |
| pg_partman | 5.5.0 | `postgresql-18-partman` | `pg_partman_18` | build with PGXS | not documented |
| TimescaleDB | 2.31.0 | `timescaledb-2-postgresql-18` (Timescale's repo); `postgresql-18-timescaledb` (PGDG, Apache-licensed edition) | `timescaledb-2-postgresql-18` (Timescale's repo); `timescaledb_18` (PGDG) | `brew install timescaledb` (`timescale/tap`) | zip with `setup.exe` from Tiger Data |
| pgaudit | 18.0 | `postgresql-18-pgaudit` | `pgaudit_18` | build with PGXS | not documented |
| pg_repack | 1.5.3 | `postgresql-18-repack` | `pg_repack_18` | `pgxn install pg_repack` | not documented |

## pgvector

pgvector adds the `vector`, `halfvec` and `sparsevec` types with HNSW and IVFFlat indexes; it needs no preload.

```bash
sudo apt install postgresql-18-pgvector          # Debian, Ubuntu (PGDG)
sudo dnf install pgvector_18                      # RHEL family (PGDG)
# from source on Linux or macOS, against a chosen server:
git clone --branch v0.8.7 https://github.com/pgvector/pgvector.git && cd pgvector
make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config && sudo --preserve-env=PG_CONFIG make install
```

On Windows, run the "x64 Native Tools Command Prompt for VS" as administrator, `set "PGROOT=C:\Program Files\PostgreSQL\18"`,
then `nmake /F Makefile.win` and `nmake /F Makefile.win install`. In each database: `CREATE EXTENSION vector;`.
After a package upgrade: `ALTER EXTENSION vector UPDATE;` in every database. Index building and tuning are in
`postgres-vector-search`.

## PostGIS

PostGIS adds geometry and geography types; `postgis_raster` and `postgis_topology` are separate extensions in the same
package. PostGIS 3.7, for PostgreSQL 14 to 19, moved `address_standardizer` and `postgis_tiger_geocoder` out into their
own repositories. No preload.

```bash
sudo apt install postgresql-18-postgis-3
# RHEL 9 family: GDAL, GEOS and PROJ come from EPEL, which needs CRB
sudo dnf install -y epel-release && sudo crb enable && sudo dnf install -y postgis37_18
```

In each database that stores spatial data:

```sql
CREATE EXTENSION postgis;
CREATE EXTENSION postgis_raster;          -- only if you store rasters
SELECT postgis_full_version();
SELECT postgis_extensions_upgrade();      -- after a package upgrade: updates postgis and its companions
```

The RHEL package carries the PostGIS minor in its name (`postgis37_18`), so a new PostGIS minor is a new package. On
31 October 2026 the apt package was at 3.7.0, and the EL 9 rpm `postgis37_18` still at `3.7.0-rc3`.
Usage is in `postgres-postgis`.

## pg_cron

pg_cron runs SQL on a cron schedule from a background worker, so it must be preloaded, and it lives in exactly one
database per cluster.

```ini
# postgresql.conf (restart after changing shared_preload_libraries)
shared_preload_libraries = 'pg_cron'
cron.database_name = 'app'          # default 'postgres': the one database that holds cron.job
cron.timezone = 'UTC'               # default GMT
cron.use_background_workers = on    # default off: jobs connect over libpq to cron.host (default localhost)
```

After the restart, create the extension in that database and schedule jobs (this ran in `postgres:18.6`):

```sql
CREATE EXTENSION pg_cron;                                   -- only in cron.database_name
SELECT cron.schedule('nightly-vacuum', '0 3 * * *', 'VACUUM ANALYZE');
SELECT cron.schedule_in_database('purge', '30 3 * * 6', $$DELETE FROM events WHERE ts < now() - interval '90 days'$$, 'other_db');
SELECT jobid, schedule, command, database FROM cron.job;
```

- Jobs do not run while the server is a hot standby; they start after promotion.
- With the default (client connections), `pg_hba.conf` or a `.pgpass` entry must let the job's role connect to
  `cron.host`; background workers avoid that.
- `cron.max_running_jobs` (default 32) caps concurrent jobs.

## pg_partman

pg_partman creates and drops time or id partitions ahead of need. The extension itself needs no preload; its
background worker does.

```ini
shared_preload_libraries = 'pg_partman_bgw'      # optional: the maintenance scheduler
pg_partman_bgw.dbname = 'app'                    # required for the worker to run
pg_partman_bgw.role = 'partman_maintainer'       # required; not a superuser
pg_partman_bgw.interval = 3600                   # seconds
```

The extension goes into its own schema (this ran in `postgres:18.6`):

```sql
CREATE SCHEMA partman;
CREATE EXTENSION pg_partman SCHEMA partman;      -- the schema cannot be changed later
CALL partman.run_maintenance_proc();             -- what the worker runs; call it from a scheduler without the worker
```

The maintenance role needs ownership (or the owner role) of every partitioned table it manages. After an upgrade
that drops and re-creates objects, revoked `PUBLIC` privileges come back; install into its own schema and revoke
there. Partition design is in `postgres-schema-design`.

## TimescaleDB

TimescaleDB must be preloaded (`FATAL: extension "timescaledb" must be preloaded` otherwise) and comes in two
editions; do not install both on one server.

| Edition | Where | Includes |
|---|---|---|
| Community (Timescale License) | Timescale's packagecloud repository: `timescaledb-2-postgresql-18`; the `timescale/timescaledb` and `timescale/timescaledb-ha` images | hypertables plus compression, continuous aggregates and the other TSL features |
| Apache 2 | PGDG: `postgresql-18-timescaledb` (Debian, described as "the Apache-licensed version"), `timescaledb_18` (RHEL) | hypertables; TSL features absent |

These commands add Timescale's repository on Debian or Ubuntu and install the Community edition:

```bash
# Debian, Ubuntu: Timescale's repository (after the PGDG one)
echo "deb https://packagecloud.io/timescale/timescaledb/debian/ $(lsb_release -c -s) main" | sudo tee /etc/apt/sources.list.d/timescaledb.list
wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg
sudo apt update && sudo apt install timescaledb-2-postgresql-18 postgresql-client-18
sudo timescaledb-tune          # edits postgresql.conf, including shared_preload_libraries
```

`SHOW timescaledb.license;` returns `timescale` for the Community edition. On Windows, unzip Tiger Data's
installer, run `setup.exe` as administrator, then `Restart-Service postgresql-x64-18`. Upgrade with the new package,
then `psql -X -d app -c "ALTER EXTENSION timescaledb UPDATE TO '<version>';"` in each database (Tiger Data's
procedure; `-X` keeps a `.psqlrc` from running anything first). Across a PostgreSQL major upgrade the TimescaleDB
version must be the same before and after.

## pgaudit

pgaudit writes audit records to the server log; its major version follows PostgreSQL's (pgaudit 18.x for 18), and
it must be preloaded.

```ini
shared_preload_libraries = 'pgaudit'
pgaudit.log = 'ddl, role'          # set after CREATE EXTENSION pgaudit
```

`CREATE EXTENSION pgaudit` installs event triggers that add object names to DDL records; create it before setting
`pgaudit.log`. On Cloud SQL the flag `cloudsql.enable_pgaudit` replaces the preload.

## pg_repack

pg_repack rebuilds bloated tables and indexes online with a short exclusive lock at the end. It is a server
extension plus a client program of the same version.

```bash
sudo apt install postgresql-18-repack            # or: sudo dnf install pg_repack_18 ; or: pgxn install pg_repack
psql -d app -c "CREATE EXTENSION pg_repack"
pg_repack --dry-run -d app -t public.events      # check before running
```

- Each table needs a primary key or a unique index on NOT NULL columns.
- It needs free disk of about twice the table and its indexes.
- Superusers or table owners only (owners pass `--no-superuser-check`).
- To upgrade: `DROP EXTENSION pg_repack;` then `CREATE EXTENSION pg_repack;` with the new package installed.
Bloat diagnosis is in `postgres-operations`.

## pg_stat_statements and auto_explain

Both ship in contrib. `pg_stat_statements` needs `shared_preload_libraries` and `CREATE EXTENSION` in the database you
query it from. `auto_explain` has no extension object at all: `LOAD 'auto_explain'` in a session, add it to
`session_preload_libraries` for a role or database, or to `shared_preload_libraries` for every session. This logs
every plan of the current session to the client, which is how it was checked on 18.6:

```sql
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_level = notice;
SELECT count(*) FROM generate_series(1, 10);   -- NOTICE: duration ... plan: Aggregate ...
```

Reading the output is covered in `postgres-query-performance`.

## A custom image or package with several extensions

A Debian-based image or host gets several extensions from PGDG in one step; this Dockerfile was built and run on
`postgres:18.6-trixie`, and every extension was created in one database.

```dockerfile
FROM postgres:18.6-trixie
RUN set -eux; apt-get update; \
    apt-get install -y --no-install-recommends postgresql-18-pgvector postgresql-18-cron \
      postgresql-18-partman postgresql-18-pgaudit postgresql-18-repack postgresql-18-postgis-3; \
    rm -rf /var/lib/apt/lists/*
CMD ["postgres", "-c", "shared_preload_libraries=pg_stat_statements,pg_cron,pgaudit,pg_partman_bgw", \
     "-c", "cron.database_name=app", "-c", "pgaudit.log=ddl,role"]
```

On the `postgres` command line the list is one `-c` value with commas; that differs from `ALTER SYSTEM`, which
needs one quoted string per library. Container details are in `postgres-docker`.
