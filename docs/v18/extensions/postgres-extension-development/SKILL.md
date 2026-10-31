---
name: postgres-extension-development
description: 'Writes, tests and ships PostgreSQL extensions: SQL-only extensions (control file, versioned scripts, upgrade scripts, @extschema@, configuration tables, superuser and trusted), C extensions with PGXS (Makefile, PG_MODULE_MAGIC_EXT, version-1 functions, palloc and memory contexts, ereport, SPI, GUCs, hooks, shared memory, background workers), Rust extensions with pgrx, pg_regress tests, extension_control_path in PostgreSQL 18 for installs outside the server, and packaging for apt, dnf and PGXN with macOS and Windows notes. Use when building a Postgres extension, "CREATE EXTENSION could not open extension control file", writing an upgrade script, adding a hook or background worker, or choosing between SQL, C and Rust.'
metadata:
  tags:
  - postgres
  - extensions
  - pgxs
  - c
  - pgrx
  - rust
  - pg-regress
  - packaging
---

# PostgreSQL extension development

An extension packages SQL objects, and optionally a shared library, so `CREATE EXTENSION` installs them as one
versioned unit that `pg_dump` records by name and `ALTER EXTENSION ... UPDATE` upgrades. Write SQL or PL/pgSQL first:
it needs no compiler and runs wherever its files can be installed. Move to C only for speed, a new data type or index
method, or server internals (hooks, shared memory, workers); prefer Rust with pgrx when the team does not write C.
Installing third-party extensions is in `postgres-extensions-install`; functions themselves are in
`postgres-functions-triggers`. Every example here was built and run against Postgres.app 18.6 on macOS, installed
into a separate prefix, never into the server's own directories.

## Step 0: read the server's build and the toolchain

An extension is built against one server's headers and installed where that server looks, so read those first.

```bash
pg_config --version; pg_config --sharedir; pg_config --pkglibdir; pg_config --pgxs; pg_config --cc
cargo pgrx --version 2>/dev/null; rustc --version 2>/dev/null
```

```sql
SHOW server_version;
SELECT name, setting FROM pg_settings WHERE name IN ('extension_control_path', 'dynamic_library_path', 'shared_preload_libraries');
```

## Choose SQL, C or Rust for an extension

Pick the simplest language that can do the job, because each step down adds a compiler and a build per major version.

| Language | Wins when | Loses when | Build and ship |
|---|---|---|---|
| SQL and PL/pgSQL | functions, tables and views; no compiler; any host where files can be installed | a tight loop, a new type, a hook | control file and scripts |
| C with PGXS | hot functions, data types, index methods, hooks, shared memory, workers | the team does not write C; a bug can crash the server | one build per major and OS |
| Rust with pgrx | the same reach with memory safety, for teams that know Rust | a very small extension, or a platform pgrx does not target | `cargo pgrx package`, one build per major and OS |

Managed services allow only their own extension list, so none of the three helps there unless the SQL is installed as
plain objects.

## Extension files: control file and scripts

An extension is a control file `<name>.control` plus at least one script `<name>--<version>.sql`, both in a
`share/.../extension` directory the server searches. This control file was used for the SQL-only example:

```ini
# slugify.control
comment = 'URL slugs from text'
default_version = '1.1'
relocatable = false
schema = slugify
superuser = false
```

| Key | Meaning |
|---|---|
| `default_version` | version `CREATE EXTENSION` installs without `VERSION` |
| `module_pathname` | replaces `MODULE_PATHNAME` in scripts; set it to the library name without `$libdir/` |
| `requires` | extensions that must be installed first, e.g. `'btree_gist, pg_trgm'` |
| `relocatable` | `true` lets `ALTER EXTENSION ... SET SCHEMA` move the objects (default `false`) |
| `schema` | fixed schema for a non-relocatable extension; created if missing |
| `superuser` | `true` (default) allows only superusers to install or update |
| `trusted` | with `superuser = true`, lets users with `CREATE` on the database install it; the script then runs as the bootstrap superuser |
| `directory`, `encoding`, `comment`, `no_relocate` | script directory, script encoding, description, required extensions whose schema must not move |

With `superuser = false` the script runs as the calling user, who owns the objects. Mark an extension `trusted` only
when it gives no access beyond what a database owner already has.

## Versioned install and upgrade scripts

Each released version gets a full install script, and each step between versions gets an upgrade script
`<name>--<from>--<to>.sql`; `ALTER EXTENSION ... UPDATE` and `CREATE EXTENSION ... VERSION` chain them, preferring the shortest path. Never edit a released
script: write a new version. These two files make version 1.0 and the step to 1.1:

```sql
-- slugify--1.0.sql
\echo Use "CREATE EXTENSION slugify" to load this file. \quit
CREATE FUNCTION @extschema@.slugify(input text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
RETURN trim(BOTH '-' FROM regexp_replace(lower(input), '[^a-z0-9]+', '-', 'g'));

CREATE TABLE @extschema@.reserved (slug text PRIMARY KEY, builtin boolean NOT NULL DEFAULT false);
INSERT INTO @extschema@.reserved VALUES ('admin', true), ('api', true);
SELECT pg_catalog.pg_extension_config_dump('@extschema@.reserved', 'WHERE NOT builtin');

-- slugify--1.0--1.1.sql
\echo Use "ALTER EXTENSION slugify UPDATE TO '1.1'" to load this file. \quit
CREATE FUNCTION @extschema@.is_reserved(slug text) RETURNS boolean
LANGUAGE sql STABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
RETURN EXISTS (SELECT 1 FROM @extschema@.reserved r WHERE r.slug = is_reserved.slug);
```

- `\echo ... \quit` stops a person who feeds the file to psql by hand; `CREATE EXTENSION` ignores `\echo` lines.
- Scripts run inside one transaction: no `BEGIN`, `COMMIT`, `VACUUM` or `CREATE INDEX CONCURRENTLY`.
- `@extschema@` is the extension's schema; `@extschema:other@` names a required extension's schema.
- `SET search_path = pg_catalog, pg_temp` on each function stops callers' `search_path` from hijacking it.
- `pg_extension_config_dump` makes `pg_dump` save the table's user rows (here only `NOT builtin`); the rows the
  script inserts come back with `CREATE EXTENSION` on restore.

These catalog queries show what the server sees, including the update path:

```sql
SELECT name, version, superuser, trusted, relocatable, schema
FROM pg_available_extension_versions WHERE name = 'slugify';
SELECT * FROM pg_extension_update_paths('slugify') WHERE path IS NOT NULL;   -- 1.0 | 1.1 | 1.0--1.1
CREATE EXTENSION slugify VERSION '1.0';
ALTER EXTENSION slugify UPDATE;                                             -- to default_version
```

## Installing outside the server directory: extension_control_path in 18

PostgreSQL 18 adds `extension_control_path`, so control files can live outside `pg_config --sharedir`; set
`dynamic_library_path` to match for C libraries. Each path element must contain an `extension` subdirectory, which
the server appends. PGXS installs into such a tree with `prefix=`:

```bash
make PG_CONFIG=/Applications/Postgres.app/Contents/Versions/18/bin/pg_config install prefix=/opt/pgext
# -> /opt/pgext/share/postgresql/extension/*.control, *.sql   and   /opt/pgext/lib/postgresql/*.dylib
```

```sql
ALTER SYSTEM SET extension_control_path = '/opt/pgext/share/postgresql:$system';
ALTER SYSTEM SET dynamic_library_path   = '/opt/pgext/lib/postgresql:$libdir';
SELECT pg_reload_conf();
```

- Both settings are `superuser` context; use the configuration file in production, not a session `SET`.
- On Windows separate path elements with `;`.
- `module_pathname = '$libdir/name'` bypasses the search; write `module_pathname = 'name'`.
- `make install DESTDIR=/stage` copies the full installation path under `/stage` for packaging.

## C extensions with PGXS

PGXS is the makefile framework every PostgreSQL installation ships (`pg_config --pgxs`). This Makefile builds one
shared library from C sources and runs `pg_regress` tests; `MODULES` instead builds one library per source file:

```make
MODULE_big = pgl_hello
OBJS = pgl_hello.o
EXTENSION = pgl_hello
DATA = sql/pgl_hello--1.0.sql
REGRESS = pgl_hello
REGRESS_OPTS = --inputdir=test --outputdir=test/out
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
```

A version-1 C function takes `PG_FUNCTION_ARGS`, reads arguments with `PG_GETARG_*`, allocates with `palloc` and
reports errors with `ereport`. This one, from the tested extension, adds two `bigint` values without wrapping:

```c
#include "postgres.h"
#include "common/int.h"
#include "fmgr.h"

PG_MODULE_MAGIC_EXT(.name = "pgl_hello", .version = "1.0.0");   /* PostgreSQL 18; PG_MODULE_MAGIC before */

PG_FUNCTION_INFO_V1(pgl_add_checked);
Datum
pgl_add_checked(PG_FUNCTION_ARGS)
{
    int64 a = PG_GETARG_INT64(0), b = PG_GETARG_INT64(1), result;
    if (pg_add_s64_overflow(a, b, &result))
        ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE), errmsg("bigint out of range")));
    PG_RETURN_INT64(result);
}
```

```sql
CREATE FUNCTION add_checked(bigint, bigint) RETURNS bigint
AS 'MODULE_PATHNAME', 'pgl_add_checked' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
```

- Memory from `palloc` belongs to the current memory context and is freed with it (per call or per transaction);
  never `malloc` for data returned to the server.
- `ereport(ERROR, ...)` jumps out of the function; do not hold resources that need manual release across it.
- `PG_FUNCTION_INFO_V1` exports the symbol (`PGDLLEXPORT`), which Windows requires.
- `pg_get_loaded_modules()` (18) lists the name and version given to `PG_MODULE_MAGIC_EXT`.
- A library stays loaded for the session: reconnect after `make install` to test the new build.

Text handling, SPI, a GUC, the full source and the hook code are in
[references/c-extension.md](references/c-extension.md).

## Hooks, shared memory and background workers

Hooks, shared memory and background workers must be set up while the postmaster starts, so the library must be in
`shared_preload_libraries` and `_PG_init` checks `process_shared_preload_libraries_in_progress`. The tested
extension requests shared memory in `shmem_request_hook`, creates it in `shmem_startup_hook` under
`AddinShmemInitLock`, counts finished queries in `ExecutorEnd_hook`, and registers a worker with
`RegisterBackgroundWorker`. Each hook saves the previous value and calls it, so several extensions can chain. These
statements preload it and read the counter:

```sql
ALTER SYSTEM SET shared_preload_libraries = pg_stat_statements, pgl_hello;   -- a list, not one quoted string
-- restart the server; then:
SELECT executor_runs();                                                       -- 0, 1, 2, ... per query
```

On Windows (`EXEC_BACKEND`) every backend runs `shmem_startup_hook` after attaching, so the lock is required there.
Check hook signatures in the target version's headers: in 18.6 `ExecutorStart_hook` still returns `void`.

## Rust extensions with pgrx

pgrx builds extensions in Rust: `#[pg_extern]` turns a function into SQL, and the SQL script is generated. pgrx
0.19.3 (September 2026) supports PostgreSQL 13 to 18, with a 19 beta, on Linux, macOS and Windows (MSVC). The
workflow, from its README (not run here: no Rust toolchain on the test machine):

```bash
cargo install --locked cargo-pgrx
cargo pgrx init --pg18 download        # or the pg_config of a user-writable install
cargo pgrx new my_extension && cd my_extension
cargo pgrx run pg18          # build, install into the pgrx-managed server, open psql
cargo pgrx test pg18         # run #[pg_test] functions inside a real server
cargo pgrx package           # target/release/<name>-pg<N>/ tree for packaging
```

pgrx has no minimum Rust version policy; use the latest stable Rust. A Rust `panic!` becomes a PostgreSQL `ERROR`
that aborts the transaction, not the process. Details:
[references/pgrx.md](references/pgrx.md).

## Testing extensions with pg_regress

`pg_regress` runs each `test/sql/<name>.sql` through psql and compares the output with `test/expected/<name>.out`.
`make installcheck` runs it against a running server whose files are installed; this run passed for both examples:

```bash
make install prefix=/opt/pgext
PGHOST=/tmp/pg PGPORT=5432 PGUSER=postgres make installcheck
# ok 1 - slugify   22 ms
# All 1 tests passed.
```

Write the first expected file by reviewing `test/out/results/<name>.out` and copying it. Test `CREATE EXTENSION` at
the newest version and the upgrade from every released one. `TAP_TESTS = 1` adds Perl TAP tests that start their own
servers; pgTAP and CI pipelines are in `postgres-testing-ci`.

## Packaging for apt, dnf and PGXN

Distribution packages are built per PostgreSQL major version, because a C library is compiled against one major.

| Channel | Naming and tooling |
|---|---|
| Debian/Ubuntu (apt.postgresql.org) | `postgresql-18-<name>`; build with `postgresql-server-dev-18` and `pg_buildext` from `postgresql-common-dev` |
| RHEL/Rocky/Fedora (yum.postgresql.org) | `<name>_18`; build with `postgresql18-devel` |
| PGXN | a zip with `META.json` (required: `name`, `abstract`, `version`, `maintainer`, `license`, `provides`, `meta-spec`) |
| macOS | build per installation (Postgres.app, Homebrew); Postgres.app 18 libraries end in `.dylib` |
| Windows | MSVC or MinGW builds (`.dll`); pgrx supports MSVC; not tested here |

Build with the same compiler settings as the server (`pg_config --cc --cflags`), and keep each SQL-only version
script in the package forever so old installs can upgrade.

## Verify an extension: install, upgrade and dump

Prove all three paths, because a passing `CREATE EXTENSION` says nothing about upgrades or restores.

```bash
make && make install prefix=/opt/pgext && make installcheck
```

```sql
CREATE EXTENSION slugify VERSION '1.0';
ALTER EXTENSION slugify UPDATE;
SELECT extversion FROM pg_extension WHERE extname = 'slugify';          -- the default_version
SELECT * FROM pg_extension_update_paths('slugify') WHERE path IS NOT NULL;
```

```bash
pg_dump -d test -Fc -f ext.dump && createdb restored && pg_restore -d restored ext.dump   # user rows come back
```

A fresh install at the newest version and an install at 1.0 then updated must give the same objects: compare `\dx+`
in both databases.

## Gotchas

These are the extension failures seen most often, each with its cause and fix.

1. **`extension "x" is not available` / `could not open extension control file`.** The control file is not in
   `sharedir/extension` or an `extension_control_path` element; check `pg_available_extensions`.
2. **`could not access file "pg_stat_statements, pgl_hello"` and the server does not start.** `ALTER SYSTEM SET
   shared_preload_libraries = 'a, b'` stored one name; write the list unquoted (`= a, b`) and fix the file by hand.
3. **The new build changed nothing.** The session still has the old library loaded; reconnect.
4. **`extension "x" has no update path from version "1.0" to version "1.2"`.** An upgrade script is missing; add
   `x--1.0--1.1.sql` and `x--1.1--1.2.sql`, or a direct one.
5. **The function found the wrong `lower()` or table.** It ran with the caller's `search_path`; use `@extschema@`
   and `SET search_path = pg_catalog, pg_temp` on each function.
6. **The library loads from the server's directory instead of yours.** `module_pathname` starts with `$libdir/`;
   use the bare name so `dynamic_library_path` is searched.
7. **Rows inserted by users vanish after dump and restore.** The table is not a configuration table; call
   `pg_extension_config_dump` in the install script.

## Checklist

Check these points before you release an extension version.

- [ ] SQL-only unless C or Rust is needed; control file has `default_version`, `superuser` and `relocatable` set.
- [ ] A full script for each version and an upgrade script for each step; released scripts are unchanged.
- [ ] Functions use `@extschema@` and a fixed `search_path`; volatility and `PARALLEL` labels are honest.
- [ ] User-editable tables are registered with `pg_extension_config_dump`.
- [ ] C code uses `palloc`, `ereport`, `PG_MODULE_MAGIC_EXT`, and chains previous hooks.
- [ ] `make installcheck` passes for a fresh install and for each upgrade path, on every supported major.
- [ ] Packages are built per major version with that version's headers.

## Anti-patterns in extension development

| Do not | Do this instead |
|---|---|
| edit a released version script | a new version and an upgrade script |
| use bare names in extension functions | `@extschema@` and a fixed `search_path` |
| `malloc` data returned to the server | `palloc` in the right memory context |
| replace a hook without chaining | save the previous hook and call it |
| mark an extension `trusted` by default | only when it gives no more than a database owner has |
| write C for logic that fits in SQL | stay in SQL until measurements say otherwise |

## See also

- `postgres-extensions-install`: installing and updating extensions on a server.
- `postgres-functions-triggers`: SQL and PL/pgSQL functions.
- `postgres-testing-ci`: pgTAP and CI pipelines.
- `postgres-internals-architecture`: shared memory, backends and hooks in context.

## Sources

- https://www.postgresql.org/docs/18/extend-extensions.html
- https://www.postgresql.org/docs/18/extend-pgxs.html
- https://www.postgresql.org/docs/18/xfunc-c.html
- https://www.postgresql.org/docs/18/spi.html
- https://www.postgresql.org/docs/18/bgworker.html
- https://www.postgresql.org/docs/18/runtime-config-client.html
- https://www.postgresql.org/docs/18/regress-tap.html
- https://www.postgresql.org/docs/18/installation-platform-notes.html
- https://www.postgresql.org/docs/18/release-18.html
- https://github.com/pgcentralfoundation/pgrx (README, cargo-pgrx README, new-project templates)
- https://crates.io/crates/pgrx
- https://pgxn.org/spec/
- https://apt.postgresql.org and https://yum.postgresql.org package listings
