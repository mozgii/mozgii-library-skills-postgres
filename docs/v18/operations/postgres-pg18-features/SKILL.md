---
name: postgres-pg18-features
description: 'What PostgreSQL 18 changes and how to use it, each item run on 18.6: asynchronous I/O (io_method worker, io_uring, sync; io_workers; pg_aios), uuidv7(), virtual generated columns as the default, OLD and NEW in RETURNING, B-tree skip scan, OAuth authentication, statistics kept by pg_upgrade and pg_dump --statistics, data checksums on by default, MD5 password deprecation, NOT NULL and temporal constraints, EXPLAIN ANALYZE with BUFFERS by default, pg_stat_io in bytes with WAL rows, wire protocol 3.2, casefold and PG_UNICODE_FAST, and the incompatibilities and 18.6 minor-release steps to check before upgrading. Use when upgrading to PostgreSQL 18, asking "what is new in Postgres 18", tuning io_method, or when something behaves differently after the upgrade.'
metadata:
  tags:
  - postgres
  - postgresql-18
  - release-notes
  - async-io
  - uuidv7
  - oauth
  - upgrade
  - incompatibilities
---

# PostgreSQL 18 features and upgrade changes

PostgreSQL 18.0 was released on 25 September 2025; 18.6 (13 August 2026) is the current minor release (18.5 was never
released), and 18 is supported until 14 November 2030. Before upgrading, read the incompatibilities section and the
migration notes of every minor release you skip; after upgrading, use the new features where they remove work. Each
item below was run on 18.6 (Postgres.app on macOS, and the `postgres:18` image on Linux for io_uring and
`pg_upgrade`). Deep coverage lives in the owning skills named in each section; the upgrade procedure itself is in
`postgres-operations` and `postgres-zero-downtime-upgrades`.


## Step 0: read the server and client versions and two defaults

What applies depends on the exact minor and on how the cluster was created. `io_method` does not exist before 18, so
the query reads it without failing on an older server. It ran on 18.6.

```bash
psql --version; pg_dump --version; pg_upgrade --version
```

```sql
SELECT current_setting('server_version_num')::int AS version_num, current_setting('data_checksums') AS checksums,
       current_setting('io_method', true) AS io_method;     -- 180006 | on | worker on a fresh 18.6
```

## Incompatibilities to check before upgrading to 18

The release notes list these changes as incompatible; each can break a working system.

| Change | What breaks | Check or fix |
|---|---|---|
| `initdb` enables data checksums by default | `pg_upgrade` from a cluster without checksums | `initdb --no-data-checksums`, or `pg_checksums --enable` on the stopped old cluster |
| MD5 passwords deprecated | warnings on `CREATE/ALTER ROLE ... PASSWORD` with md5 | move roles to `scram-sha-256` (`postgres-security-roles`) |
| `VACUUM`/`ANALYZE` process inheritance children | longer maintenance runs on inheritance parents | `VACUUM ONLY` / `ANALYZE ONLY` for the old behaviour |
| `COPY FROM` CSV no longer treats `\.` as end of data | old psql `\copy` against 18 | use a psql 18 client |
| unlogged partitioned tables refused | DDL that created them | create the partitions unlogged instead |
| `AFTER` triggers run as the role active when the event was queued | triggers that relied on the role at `COMMIT` | review `SET ROLE` inside transactions |
| `RESTRICT` foreign keys raise `23001 restrict_violation`, not `23503` (added to the release notes after 18.6; measured on 17.11 and 18.6) | code that catches `23503` or `foreign_key_violation` for a blocked parent delete or update | catch `23001` too; `NO ACTION` still raises `23503` |
| time zone abbreviations: session time zone first | parsing of ambiguous abbreviations | test date parsing with your `timezone` |
| `pg_backend_memory_contexts.level` one-based, `parent` removed | monitoring queries | update the queries |
| full-text search and `pg_trgm` use the cluster's default collation provider | results on ICU or builtin clusters | reindex `tsvector` and trigram indexes after `pg_upgrade` |

## Data checksums on by default and pg_upgrade

`initdb` in 18 turns data checksums on, and `pg_upgrade` refuses clusters whose settings differ. Proven with a 17.11
cluster (checksums off) and 18.6 binaries in one container:

```bash
initdb -D /tmp/new18                     # 18 default: checksums on
pg_upgrade -b $OLD -B $NEW -d /tmp/old -D /tmp/new18 --check
# old cluster does not use data checksums but the new one does
# Failure, exiting
initdb -D /tmp/new --no-data-checksums   # match the old cluster
pg_upgrade -b $OLD -B $NEW -d /tmp/old -D /tmp/new --check
# *Clusters are compatible*
```

## Statistics kept by pg_upgrade and pg_dump --statistics

`pg_upgrade` in 18 carries optimizer statistics into the new cluster, so plans are good right after the upgrade;
extended statistics (`CREATE STATISTICS`) are not carried. After the 17 to 18 upgrade above, `pg_stats` already held
the old cluster's values (`n_distinct` 7 and -1) before any `ANALYZE`. Fill only what is missing:

```bash
vacuumdb --all --analyze-in-stages --missing-stats-only
```

`pg_upgrade --no-statistics` turns this off; `--swap` (new) moves directories instead of copying or linking.
`pg_dump` writes statistics only with `--statistics` (default off in 18.6, proven: no `pg_restore_relation_stats`
calls without it); `--statistics-only`, `--no-statistics`, `--no-data` and `--no-schema` are new too.

## Asynchronous I/O: io_method, io_workers and pg_aios

PostgreSQL 18 adds an asynchronous I/O subsystem: sequential scans, bitmap heap scans and vacuum queue several reads
at once. `io_method` chooses how (restart required):

| `io_method` | How | Platforms |
|---|---|---|
| `worker` (default) | `io_workers` processes (default 3, reloadable) do the I/O | all |
| `io_uring` | Linux kernel `io_uring` | Linux builds with `--with-liburing` |
| `sync` | I/O done synchronously, the pre-18 behaviour | all |

This query shows the settings and the three `io worker` processes on a default server:

```sql
SELECT name, setting, unit, context FROM pg_settings
WHERE name IN ('io_method', 'io_workers', 'io_combine_limit', 'io_max_combine_limit',
               'io_max_concurrency', 'effective_io_concurrency', 'maintenance_io_concurrency');
SELECT backend_type FROM pg_stat_activity WHERE backend_type = 'io worker';
SELECT pid, state, operation, length, target_desc FROM pg_aios;     -- I/O in flight right now
```

- `effective_io_concurrency` and `maintenance_io_concurrency` now default to 16 (were 1 and 10).
- `io_combine_limit` (default 16 blocks, 128 kB) is capped by `io_max_combine_limit` (server start).
- The `postgres:18` image is built with liburing, but Docker's default seccomp profile blocked it:
  `FATAL: could not setup io_uring queue: Operation not permitted`. It started with
  `--security-opt seccomp=unconfined`; in production allow the io_uring system calls in a custom profile instead,
  or keep `worker`. macOS has no io_uring.
- Tuning and kernel settings: `postgres-operations`; Linux kernel tuning: `postgres-os-kernel-tuning`.

## uuidv7() for time-ordered keys

`uuidv7()` generates a version 7 UUID whose first 48 bits are a Unix timestamp in milliseconds, so new keys land at
the right edge of a B-tree index like a sequence. `uuidv4()` is a new alias of `gen_random_uuid()`. Proven on 18.6:

```sql
CREATE TABLE app.ev (id uuid PRIMARY KEY DEFAULT uuidv7(), payload text);
SELECT uuid_extract_version(uuidv7()),                    -- 7
       uuid_extract_timestamp(uuidv7()),                  -- the creation time
       uuid_extract_timestamp(uuidv7(interval '-1 day'))  -- shift the embedded time
;
```

The timestamp in the key is visible to anyone who sees the id. Key choice: `postgres-schema-design`.

## Virtual generated columns as the default

`GENERATED ALWAYS AS (expr)` now creates a `VIRTUAL` column, computed when read and not stored; write `STORED` for
the old behaviour. `pg_attribute.attgenerated` is `v` or `s`. Limits proven on 18.6:

```sql
CREATE TABLE app.items (
  price_cents bigint NOT NULL, qty int NOT NULL,
  total_cents  bigint GENERATED ALWAYS AS (price_cents * qty),          -- virtual
  total_stored bigint GENERATED ALWAYS AS (price_cents * qty) STORED);
CREATE INDEX ON app.items (total_cents);
-- ERROR: indexes on virtual generated columns are not supported
-- a virtual column calling app.double_it(a):
-- ERROR: generation expression uses user-defined function
```

Index the expression itself, or use `STORED` when the column needs an index or a user-defined function.

## OLD and NEW in RETURNING

`RETURNING` in `INSERT`, `UPDATE`, `DELETE` and `MERGE` can name `old` and `new`, so one statement reports the
value before and after. In an upsert, `old` is NULL when the row was inserted:

```sql
UPDATE app.stock SET qty = qty - 2 WHERE sku = 'a' RETURNING old.qty AS before, new.qty AS after;   -- 5 | 3
INSERT INTO app.stock VALUES ('a', 9) ON CONFLICT (sku) DO UPDATE SET qty = excluded.qty
RETURNING old.qty IS NULL AS inserted, new.qty;                                                     -- f | 9
DELETE FROM app.stock WHERE sku = 'a' RETURNING WITH (OLD AS o, NEW AS n) o.qty, n.qty;             -- 9 | NULL
```

Patterns built on it: `postgres-sql-patterns`.

## B-tree skip scan and EXPLAIN changes

A multicolumn B-tree index can now serve a query that does not constrain its first column, by skipping through the
distinct values of that column. On 400,000 rows with 20 tenants, an index on `(tenant_id, created_on)` answered
`WHERE created_on = '2026-03-01'` with 72 buffers instead of 2,163 for a sequential scan:

```text
Index Only Scan using orders18_tenant_created_idx on orders18 (actual rows=1334.00 loops=1)
  Index Cond: (created_on = '2026-03-01'::date)
  Index Searches: 22
  Buffers: shared hit=45 read=27
```

EXPLAIN in 18 also prints `Buffers:` under `ANALYZE` without asking, fractional `rows=` counts, and
`Index Searches` per index node; tools that parse plans need updating. Skip scan pays off when the leading column has
few distinct values; index design is in `postgres-indexing`.

## OAuth authentication

PostgreSQL 18 accepts OAuth 2.0 bearer tokens: `oauth` in `pg_hba.conf` with `issuer` and `scope` (required),
`validator`, `map` and `delegate_ident_mapping`. The server validates tokens only through a validator module named
in `oauth_validator_libraries`; PostgreSQL ships none. On the client, libpq needs `oauth_issuer` and
`oauth_client_id` (`oauth_client_secret` and `oauth_scope` are optional) and runs the RFC 8628 device flow from the
`libpq-oauth` module, which needs a build `--with-libcurl` (Postgres.app 18 has it: `libpq-oauth-18.dylib`). A server line and a client connection look like this:

```text
# pg_hba.conf
host  all  all  0.0.0.0/0  oauth  issuer=https://login.example.com  scope="openid postgres"
# client
psql "host=db.example.com dbname=app oauth_issuer=https://login.example.com oauth_client_id=psql-cli"
```

Without a validator the server rejects the line: `pg_hba_file_rules` on 18.6 reported `oauth_validator_libraries
must be set for authentication method oauth`. A full login was not run here (no identity provider or validator). The built-in device flow does not work on Windows;
`PGOAUTHDEBUG=UNSAFE` is for local development only.

## MD5 password deprecation

Setting an MD5 password now warns, and support will be removed in a future major release. Proven on 18.6:

```sql
SET password_encryption = 'md5';
CREATE ROLE legacy_md5 LOGIN PASSWORD 'x';
-- WARNING: setting an MD5-encrypted password
-- DETAIL: MD5 password support is deprecated and will be removed in a future release of PostgreSQL.
```

`md5_password_warnings = off` silences it during a migration; the fix is `scram-sha-256` hashes and `pg_hba.conf`
entries (`postgres-security-roles`).

## pg_stat_io in bytes, WAL rows and pg_stat_wal

`pg_stat_io` now reports `read_bytes`, `write_bytes` and `extend_bytes` (the `op_bytes` column is gone) and has rows
with `object = 'wal'`. `pg_stat_wal` lost `wal_write`, `wal_sync`, `wal_write_time` and `wal_sync_time`; on 18.6 it
has `wal_records, wal_fpi, wal_bytes, wal_buffers_full, stats_reset`. This query reads WAL I/O by process type:

```sql
SELECT backend_type, context, writes, write_bytes, write_time
FROM pg_stat_io WHERE object = 'wal' ORDER BY write_bytes DESC NULLS LAST;
```

`track_wal_io_timing` now controls WAL timing in `pg_stat_io`. Dashboards: `postgres-monitoring-observability`.

## Constraints, protocol and other changes for developers

These 18 changes are covered in depth by other skills.

- Named `NOT NULL` constraints, `NOT NULL ... NOT VALID`, `NOT ENFORCED` checks and foreign keys, temporal
  `WITHOUT OVERLAPS` keys and `PERIOD` foreign keys, `NOT VALID` foreign keys on partitioned tables:
  `postgres-constraints-integrity`.
- Wire protocol 3.2 (longer cancel key) with `max_protocol_version=latest`; libpq still defaults to 3.0:
  `postgres-libpq-protocol`.
- `extension_control_path`, `PG_MODULE_MAGIC_EXT` and `pg_get_loaded_modules()`: `postgres-extension-development`.
- `file_copy_method = clone` for fast `CREATE DATABASE ... STRATEGY FILE_COPY`: `postgres-testing-ci`.
- `casefold()` and the `PG_UNICODE_FAST` builtin collation: `casefold('Straße' COLLATE pg_unicode_fast)` returns
  `strasse`, while under `pg_c_utf8` it stays `straße`.
- `array_sort()`, `log_connections` options (`receipt`, `authentication`, `authorization`, `setup_durations`,
  `all`; the last logs `connection ready: setup total=6.287 ms, fork=0.524 ms, authentication=0.076 ms`),
  `log_lock_failures`, `idle_replication_slot_timeout`, `autovacuum_worker_slots`.

## What the 18.6 minor release asks you to do

PostgreSQL 18.6 needs no dump and restore, but its release notes ask for steps after updating:

- psql now skips the in-line data after a scripted `COPY ... FROM STDIN` even when the `COPY` fails at start. A test
  script that exercises a failing `COPY ... FROM STDIN` on purpose must add a `\.` line after each such command.
- Logical decoding output plugins are limited to `output_plugin_libraries` (default `pgoutput, test_decoding`);
  add any other plugin (for example `wal2json`) there before `pg_upgrade --check` and before slots are used.
- Reindex `btree_gist` indexes on `float4`/`float8` columns that may hold NaN and on `bit`/`varbit` columns;
  reindex B-tree indexes on `ltree` columns if any value passes roughly 14,653 labels.
- Check `pg_class.reltuples` of tables with GIN indexes (parallel GIN builds could store a wrong value); run
  `ANALYZE` on any table whose value looks wrong.
- pgcrypto now refuses to decrypt PGP data that a rejected cipher left unencrypted; see `ignore-cipher-failure`.
- Upgrading from before 18.2: also read the 18.2 notes.

## Verify a server after moving to 18

These checks ran on 18.6 and list what is left to do after an upgrade. The first needs a superuser, because
`pg_authid` holds password hashes; it prints role names only.

```sql
SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'md5%';               -- no rows
SELECT name, installed_version, default_version FROM pg_available_extensions
WHERE installed_version IS NOT NULL AND installed_version <> default_version;   -- no rows
SELECT n.nspname, s.stxname FROM pg_statistic_ext s
JOIN pg_namespace n ON n.oid = s.stxnamespace;                              -- ANALYZE these tables
SELECT backend_type, object, writes, write_bytes FROM pg_stat_io WHERE object = 'wal' LIMIT 3;   -- new columns answer
```

Before the upgrade, `pg_upgrade --check` must end with `*Clusters are compatible*`. After it, run your plan parsers
and dashboards once against a real `EXPLAIN (ANALYZE)` and `pg_stat_io`.

## Gotchas

These are the PostgreSQL 18 surprises seen most often, each with its cause and fix.

1. **`old cluster does not use data checksums but the new one does`.** 18's `initdb` enables checksums; create the
   new cluster with `--no-data-checksums` or enable them on the old one.
2. **Plans are bad right after a dump and restore, but not after `pg_upgrade`.** `pg_dump` skips statistics unless
   `--statistics`; run `ANALYZE` or `vacuumdb --analyze-in-stages`.
3. **`indexes on virtual generated columns are not supported`.** Generated columns are virtual by default; add
   `STORED` or index the expression.
4. **`could not setup io_uring queue: Operation not permitted` in a container.** The seccomp profile blocks
   io_uring; allow it or use `io_method = worker`.
5. **Plan parsers break.** EXPLAIN ANALYZE adds `Buffers:` lines, fractional `rows=` and `Index Searches`.
6. **A CDC tool stops after the 18.6 update.** Its output plugin is not in `output_plugin_libraries`.

## Anti-patterns when moving to PostgreSQL 18

Each of these is a default that changed under an old habit.

| Do not | Do instead |
|---|---|
| Assume `GENERATED ALWAYS AS (...)` stores the value | Write `STORED` when you need an index or a user-defined function |
| Assume `pg_dump` carries statistics | Pass `--statistics`, or run `ANALYZE` after the restore |
| Switch to `io_uring` because it sounds faster | Keep `worker` until you measure a gain where the kernel and container allow it |
| Keep new `md5` passwords with `md5_password_warnings = off` | Use that only during a migration; move roles to `scram-sha-256` |
| Skip the migration notes of the minors between | Read every skipped release, as 18.6 has steps of its own |
| Expect plan text to stay the same | Update parsers for `Buffers:` lines, fractional rows and `Index Searches` |

## Checklist

Check these points before and after moving a system to PostgreSQL 18.

- [ ] Every incompatibility in the table reviewed against the application and monitoring.
- [ ] New cluster's checksum setting matches the old one for `pg_upgrade`, or checksums enabled first.
- [ ] `vacuumdb --analyze-in-stages --missing-stats-only` after `pg_upgrade`; `ANALYZE` for extended statistics.
- [ ] MD5 roles moved to SCRAM.
- [ ] `io_method` chosen on purpose; io_uring only where the kernel and container allow it.
- [ ] 18.6 steps done: `output_plugin_libraries`, `btree_gist`/`ltree` reindexes, GIN `reltuples` check.
- [ ] Plan parsers and `pg_stat_io`/`pg_stat_wal` queries updated.

## See also

Related skills in this library, each one works on its own:

- `postgres-operations`: the upgrade procedure and server settings.
- `postgres-zero-downtime-upgrades`: moving with logical replication.
- `postgres-libpq-protocol`: protocol 3.2 from the client side.
- `postgres-security-roles`: SCRAM and role changes.
- `postgres-os-kernel-tuning`: kernel settings for io_uring.
- `postgres-constraints-integrity`: the new constraint forms.

## Sources

- https://www.postgresql.org/docs/18/release-18.html
- https://www.postgresql.org/docs/18/release-18-6.html
- https://www.postgresql.org/versions.json (support dates)
- https://www.postgresql.org/docs/18/runtime-config-resource.html
- https://www.postgresql.org/docs/18/runtime-config-logging.html
- https://www.postgresql.org/docs/18/functions-uuid.html
- https://www.postgresql.org/docs/18/auth-oauth.html, https://www.postgresql.org/docs/18/libpq-oauth.html,
  https://www.postgresql.org/docs/18/oauth-validators.html
- https://www.postgresql.org/docs/18/pgupgrade.html
- https://www.postgresql.org/docs/18/app-pgdump.html
- https://www.postgresql.org/docs/18/monitoring-stats.html
- https://www.postgresql.org/docs/18/protocol-overview.html
