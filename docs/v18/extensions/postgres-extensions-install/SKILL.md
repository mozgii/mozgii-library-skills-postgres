---
name: postgres-extensions-install
description: 'Gets PostgreSQL extensions onto a server and keeps them current: contrib, PGDG apt and dnf packages, PGXS make install, the pgxn client, CREATE EXTENSION with schema, version and CASCADE, trusted extensions, shared_preload_libraries and restarts, which extensions need preloading (pg_stat_statements, pg_cron, auto_explain, timescaledb, pgaudit, pg_partman_bgw), per-OS installs of pgvector, PostGIS, pg_cron, pg_partman, TimescaleDB, pgaudit and pg_repack, ALTER EXTENSION UPDATE, extensions across major upgrades, extension_control_path in 18, and what managed services allow. Use when CREATE EXTENSION fails, "extension is not available" or "must be loaded via shared_preload_libraries" appears, or someone asks how to install or upgrade an extension.'
metadata:
  tags:
  - postgres
  - extensions
  - create-extension
  - shared-preload-libraries
  - pgxs
  - pgvector
  - postgis
  - pg-cron
  - timescaledb
---

# PostgreSQL extensions: install, load and upgrade

An extension needs three things in order: its files on the server (a package or `make install`), its library in
`shared_preload_libraries` when it starts background workers or uses shared memory (one restart), and
`CREATE EXTENSION` in each database that uses it. Upgrading the package changes the files only; every database
still runs `ALTER EXTENSION ... UPDATE`. Per-extension package names, settings and upgrade steps are in
[references/extension-catalog.md](references/extension-catalog.md); a per-database report is
[scripts/extension-report.sql](scripts/extension-report.sql).

## Step 0: what is available, installed and outdated

The catalog views `pg_available_extensions` and `pg_available_extension_versions` show what the server's files offer;
`pg_extension` shows what this database installed.

```sql
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('vector', 'postgis', 'pg_stat_statements', 'pg_cron')
ORDER BY name;

-- installed here but older than the files on disk: run ALTER EXTENSION ... UPDATE
SELECT e.extname, e.extversion, a.default_version
FROM pg_extension e JOIN pg_available_extensions a ON a.name = e.extname
WHERE e.extversion <> a.default_version;

SELECT name, setting FROM pg_settings
WHERE name IN ('shared_preload_libraries', 'session_preload_libraries', 'extension_control_path', 'dynamic_library_path');
```

A name missing from `pg_available_extensions` means the files are not installed for this server's build; no SQL
fixes that. `pg_config --sharedir` and `--pkglibdir` print where that build looks.

## How extension files get onto a server

The extension's source decides the install command; the package must match the server's major version.

| Source | Command | Notes |
|---|---|---|
| contrib (pg_stat_statements, pgcrypto, pg_trgm, postgres_fdw ...) | part of the server package; `postgresql18-contrib` on RHEL | 20 of them are trusted in 18.6 |
| PGDG apt (Debian, Ubuntu) | `sudo apt install postgresql-18-<name>` | e.g. `postgresql-18-pgvector`, `postgresql-18-cron` |
| PGDG dnf (RHEL family) | `sudo dnf install <name>_18` | e.g. `pgvector_18`, `pg_cron_18`; PostGIS needs EPEL and CRB |
| Postgres.app (macOS) | bundled | PostGIS, pgvector, contrib; more on postgresapp.com/extensions |
| Homebrew | `brew install pgvector` | builds against Homebrew's own `postgresql@NN` only |
| Windows (EDB) | StackBuilder for PostGIS; vendor installers; `nmake /F Makefile.win install` from source | no package manager for most extensions |
| Source with PGXS | `make && sudo make install PG_CONFIG=/path/to/pg_config` | needs `postgresql-server-dev-18` or `postgresql18-devel` |
| PGXN | `pip install pgxnclient`, then `pgxn install vector --pg_config /path/to/pg_config` | builds from source with PGXS |

Two installers that appear in older guides are not usable in October 2026: Trunk's registry (pgt.dev) no longer
resolves, and pgxman's last commit is dated 7 September 2024. Use PGDG packages or PGXS.

## Which extensions need shared_preload_libraries

`shared_preload_libraries` loads a library into the postmaster at start; libraries that allocate shared memory or
start background workers must be listed there, and a change needs a full restart. The errors in the last column
were produced on 18.6 without the preload.

| Extension | Preload | Without it |
|---|---|---|
| `pg_stat_statements` | required | `CREATE EXTENSION` works, then `pg_stat_statements must be loaded via "shared_preload_libraries"` |
| `pg_cron` | required, plus `cron.database_name` | `CREATE EXTENSION` fails: `unrecognized configuration parameter "cron.database_name"` |
| `pgaudit` | required | `pgaudit must be loaded via shared_preload_libraries` |
| `timescaledb` | required | `FATAL: extension "timescaledb" must be preloaded` |
| `pg_partman` | only `pg_partman_bgw`, for its maintenance worker | works; `CALL partman.run_maintenance_proc()` from a scheduler |
| `auto_explain` | optional | not an extension: `LOAD 'auto_explain'` per session, or `session_preload_libraries` |
| `pgvector`, PostGIS, `pg_repack`, `pgcrypto` | no | |

## Setting shared_preload_libraries without breaking startup

`ALTER SYSTEM` writes `postgresql.auto.conf`, which overrides `postgresql.conf`. A list setting takes one quoted
string per library: a single quoted string with commas becomes one library name with a comma in it, and the server
then refuses to start.

```sql
-- right: one string per library, written as 'pg_stat_statements, pg_cron'
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements', 'pg_cron', 'pgaudit';
-- wrong: ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements,pg_cron';
--   start fails: FATAL: could not access file "pg_stat_statements,pg_cron": No such file or directory
SELECT name, setting, pending_restart FROM pg_settings WHERE name = 'shared_preload_libraries';
```

Restart the server (`systemctl restart postgresql@18-main`, `systemctl restart postgresql-18`,
`Restart-Service postgresql-x64-18`, `pg_ctl restart`), then confirm with `SHOW shared_preload_libraries`. Keep
what is already in the list: the new value replaces it.

If the server will not start because a listed library is missing, `postgres -D "$PGDATA" -C shared_preload_libraries`
prints the value it would use; fix the line in `postgresql.auto.conf` (or `postgresql.conf`) with a text editor and
start again. On a managed service the same list is a parameter-group or flag value.

## CREATE EXTENSION: schema, version, CASCADE

`CREATE EXTENSION` runs the extension's install script in the current database only. These statements install a
dependency chain, pin a version, and place an extension in its own schema:

```sql
CREATE EXTENSION IF NOT EXISTS postgis_topology CASCADE;          -- installs postgis first
CREATE EXTENSION IF NOT EXISTS hstore VERSION '1.8';             -- a specific version from the files
CREATE SCHEMA IF NOT EXISTS tools;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA tools;             -- pg_partman's README uses SCHEMA partman
SELECT extname, extversion, extnamespace::regnamespace FROM pg_extension ORDER BY extname;
```

- Extensions are per database: `template1` gives every future database the extension, existing ones need their own
  `CREATE EXTENSION`.
- Non-relocatable extensions (pg_partman, PostGIS) keep the schema chosen at install; pick it before creating.
- Install into a schema only trusted roles can create objects in: an install script that resolves names through a
  writable schema can be hijacked.

## Trusted extensions and who may install them

A trusted extension (`trusted = true` in its control file) can be created by any role with `CREATE` on the database;
the objects still belong to the bootstrap superuser except where the script uses `@extowner@`. This query lists them
on this server, and the test that follows ran on 18.6 as a database owner without superuser:

```sql
SELECT string_agg(DISTINCT name, ', ' ORDER BY name) AS trusted
FROM pg_available_extension_versions WHERE trusted;
-- btree_gin, btree_gist, citext, cube, dict_int, fuzzystrmatch, hstore, intarray, isn, lo, ltree, pg_trgm,
-- pgcrypto, plpgsql, seg, tablefunc, tcn, tsm_system_rows, tsm_system_time, unaccent, uuid-ossp

CREATE EXTENSION pgcrypto;   -- as the database owner: works
CREATE EXTENSION postgis;    -- ERROR: permission denied to create extension "postgis"
                             -- HINT: Must be superuser to create this extension.
```

## Updating an extension after a package upgrade

Installing a newer package (say pgvector 0.8.6 to 0.8.7) puts new script files and a new library on disk; databases
keep the old SQL objects until `ALTER EXTENSION ... UPDATE` walks the update scripts. This shows a path and applies
it, using contrib's hstore so it runs anywhere:

```sql
CREATE EXTENSION hstore VERSION '1.4';
SELECT source, target, path FROM pg_extension_update_paths('hstore')
WHERE source = '1.4' AND target = '1.8';      -- 1.4--1.5--1.6--1.7--1.8
ALTER EXTENSION hstore UPDATE TO '1.6';       -- to a named version
ALTER EXTENSION hstore UPDATE;                -- to default_version (ALTER EXTENSION vector UPDATE likewise)
SELECT postgis_extensions_upgrade();          -- PostGIS: updates postgis and its companions together
```

- Run it in every database that has the extension, including `template1`; [scripts/extension-report.sql](scripts/extension-report.sql)
  lists them per database.
- Restart first when the library is preloaded: the running postmaster still holds the old library.
- Some extensions document their own path: pg_repack is dropped and re-created; pgaudit's major version follows the
  server's (pgaudit 18.x for PostgreSQL 18).

## Extensions across major version upgrades

`pg_upgrade` copies each database's extension objects but not the extension's files, so the new major must have the
same extensions installed first (for example `postgresql-18-pgvector` before upgrading 17 to 18). `pg_upgrade
--check` stops at "Checking for presence of required libraries" and writes `loadable_libraries.txt` when one is
missing. After the upgrade it reports "Checking for extension updates" and writes `update_extensions.sql` with the
`ALTER EXTENSION ... UPDATE` statements to run. Copy `shared_preload_libraries` into the new cluster's configuration
too. The full upgrade procedure is in `postgres-operations`.

## Installing from source with PGXS and extension_control_path

PGXS builds an extension against an installed server. PostgreSQL 18 adds `extension_control_path`, so an extension
can live outside the server's own directories (useful for read-only images and per-project builds). `make install
prefix=/opt/pgext` writes control and SQL files under `/opt/pgext/share/postgresql/extension` and libraries under
`/opt/pgext/lib/postgresql` (the `postgresql` part is added when the prefix contains neither `postgres` nor `pgsql`).

This Makefile builds a SQL-only extension; the install and the settings below ran on 18.6:

```makefile
EXTENSION = hello
DATA = hello--1.0.sql hello--1.0--1.1.sql
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
```

After `make install`, these settings let the server find the files, and the extension installs and updates:

```sql
-- after: make install PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config prefix=/opt/pgext
ALTER SYSTEM SET extension_control_path = '/opt/pgext/share/postgresql:$system';
ALTER SYSTEM SET dynamic_library_path = '/opt/pgext/lib/postgresql:$libdir';   -- only for C extensions
SELECT pg_reload_conf();
CREATE EXTENSION hello VERSION '1.0';
ALTER EXTENSION hello UPDATE;          -- runs hello--1.0--1.1.sql
```

The path names the directory that contains `extension/`, not `extension/` itself, and `$system` keeps the built-in
location searchable. The paths use `;` as separator on Windows.

## Extensions on managed services

Managed services install the files for you and decide which extensions exist: `pg_available_extensions` shows the
allowlist for the version you run, and preload libraries are a parameter, not a file. Amazon RDS lists them with
`SHOW rds.extensions`, Azure requires each name in the `azure.extensions` parameter before `CREATE EXTENSION`, and
Cloud SQL turns some on with flags (`cloudsql.enable_pgaudit`). You cannot add your own C extension there; a pure-SQL
one can be installed as plain SQL objects. Provider details: `postgres-operations`.

## Worked example: "CREATE EXTENSION worked, but pg_stat_statements errors"

A package can be installed and the extension created while the library is not loaded. Each step below ran on 18.6, on a
new cluster.

1. `CREATE EXTENSION pg_stat_statements;` succeeds, then `SELECT count(*) FROM pg_stat_statements;` fails with
   `pg_stat_statements must be loaded via "shared_preload_libraries"`.
2. `ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';`, keeping anything already listed, then a restart.
   A reload is not enough.
3. A typo in that name stops the next start with `FATAL: could not access file "pg_stat_statements_typo": No such file
   or directory`. Nothing is broken: delete the line from `postgresql.auto.conf` with an editor and start again.
4. `SHOW shared_preload_libraries;` lists it, `\dx pg_stat_statements` shows version 1.12, and the view now answers.

The extension object and the loaded library are separate things: the first is per database, the second per server.

## Verify an extension install

Prove the files, the preload and the database object separately, because each can pass while another fails.

```sql
SHOW shared_preload_libraries;
SELECT e.extname, e.extversion, a.default_version, e.extversion = a.default_version AS current
FROM pg_extension e JOIN pg_available_extensions a ON a.name = e.extname ORDER BY 1;
SELECT count(*) FROM pg_stat_statements;       -- a preloaded extension answers instead of raising an error
```

Run [scripts/extension-report.sql](scripts/extension-report.sql) in every database that allows connections, and before a major
upgrade, run `pg_upgrade --check` against the new cluster.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Gotchas

These are the extension failures seen most often, each with its cause and fix.

1. **`extension "vector" is not available`** (HINT: must first be installed on the system). The package for this
   server's major is missing, or it was built for another `pg_config`. Install `postgresql-18-<name>` or rebuild
   with the right `PG_CONFIG`.
2. **The server will not start after adding a preload library.** A typo, a library not installed, or a comma inside
   one quoted string in `ALTER SYSTEM`. Fix `postgresql.auto.conf` by hand and start again.
3. **`ALTER EXTENSION ... UPDATE` did nothing on one database.** Updates are per database; run it in each.
4. **`extension "x" has no update path from version "a" to version "b"`.** The package skipped an update script;
   install an intermediate version or follow the extension's documented upgrade.
5. **pg_cron jobs never run.** `cron.database_name` names another database, the server is a hot standby, or
   `cron.timezone` (GMT by default) shifts the schedule.
6. **TimescaleDB features such as compression are missing.** The PGDG package is the Apache-licensed edition; the
   Community edition comes from Timescale's own repository. Never install both.
7. **`pg_upgrade --check` fails on missing libraries.** Install the same extensions for the new major, or drop the
   extension from every database of the old cluster before upgrading.

## Checklist

Check these points before you call an extension install done.

- [ ] The package matches the server's major and the extension appears in `pg_available_extensions`.
- [ ] Preload libraries were added as separate strings, the server restarted, and `SHOW shared_preload_libraries`
      lists them all.
- [ ] `CREATE EXTENSION` ran in every database that needs it, in a schema chosen on purpose.
- [ ] After every package upgrade, `ALTER EXTENSION ... UPDATE` ran in every database (the report shows no gaps).
- [ ] Before a major upgrade, the new major has the same extensions and `pg_upgrade --check` passes.
- [ ] Only trusted extensions are left for non-superusers to create.

## Anti-patterns in extension installs

| Do not | Do this instead |
|---|---|
| put a comma list inside one quoted `ALTER SYSTEM` string | one string per library, or an unquoted list |
| replace `shared_preload_libraries` without reading it | keep what is already there |
| upgrade a package and stop | `ALTER EXTENSION ... UPDATE` in every database |
| create extensions in a schema anyone can write | a schema only trusted roles control |
| install a package built for another major | match `pg_config --version` |
| install PGDG's and Timescale's TimescaleDB together | one source only |

## See also

- `postgres-extension-development`: writing your own.
- `postgres-operations`: major upgrades and managed services.
- `postgres-postgis`, `postgres-vector-search`, `postgres-timeseries`, `postgres-partitioning`: using the main extensions.
- `postgres-docker`: extensions in container images.
- `postgres-install`: the server itself.

## Sources

- postgresql.org docs/18: `sql-createextension`, `sql-alterextension`, `extend-extensions` (control files, trusted,
  update paths), `extend-pgxs` (prefix rule), `runtime-config-client` (`shared_preload_libraries`,
  `session_preload_libraries`, `dynamic_library_path`, `extension_control_path`), `pgstatstatements`,
  `auto-explain`, `pgupgrade`, `release-18`; `src/bin/pg_upgrade` (REL_18_STABLE) for the check messages.
- Project docs: pgvector README (v0.8.7), pg_cron README, pg_partman README, pgaudit README, pg_repack 1.5.3 docs,
  PostGIS getting-started install pages, Tiger Data "Install TimescaleDB", pgxnclient usage.
- PGDG package lists read in containers: Debian 13 `apt-cache policy` and AlmaLinux 9 `dnf list` (October 2026).
- Run on 18.6: Step 0 queries, trusted-extension test, PGXS install with `extension_control_path`, update paths,
  `postgis_extensions_upgrade()`, the `ALTER SYSTEM` list mistake; in `postgres:18`: pg_cron, pgaudit and
  pg_stat_statements without preload.
