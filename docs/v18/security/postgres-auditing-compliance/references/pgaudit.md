---
title: pgaudit settings, output and limits on PostgreSQL 18
author: MOZGII, Inc.
lang: en
---

# pgaudit settings, output and limits on PostgreSQL 18

This reference covers the pgAudit extension in depth: installation per platform, every setting with its default,
the log format, tested behaviour and the documented limits. Tested with pgaudit 18.0 (the release for PostgreSQL 18)
on PostgreSQL 18.6, installed from the PGDG package `postgresql-18-pgaudit` in the official `postgres:18` image.

## Contents

The sections of this reference on pgaudit:

1. Installing pgaudit per platform
2. All pgaudit settings and defaults
3. The audit log line format
4. Behaviour observed on 18.6
5. Volume control in practice
6. Documented limits and caveats
7. pgaudit on managed services

## Installing pgaudit per platform

pgAudit versions follow PostgreSQL majors: pgaudit 18.x for PostgreSQL 18, 17.x for 17, 16.x for 16, 1.7.x for 15,
1.6.x for 14. Use the build for your major exactly.

- Debian and Ubuntu with the PGDG repository: `apt install postgresql-18-pgaudit`.
- Other Unix-like systems: `git clone https://github.com/pgaudit/pgaudit`, `git checkout REL_18_STABLE`, then
  `make install USE_PGXS=1 PG_CONFIG=/path/to/pg_config`.
- macOS with Postgres.app: not included; use a Linux container or VM to test.
- Windows: the README gives build steps only for Unix-like systems; run audited databases on Linux, or confirm
  that your Windows distribution ships pgaudit for your major version.

Then load it and create it in each audited database:

```sql
ALTER SYSTEM SET shared_preload_libraries = pgaudit, pg_stat_statements;   -- unquoted list; restart after
CREATE EXTENSION pgaudit;
SELECT extversion FROM pg_extension WHERE extname = 'pgaudit';
```

## All pgaudit settings and defaults

Read from `pg_settings` on 18.6 with pgaudit 18.0; all have context `superuser`, so only superusers can change them
(globally, per database or per role).

| Setting | Default | Meaning |
|---|---|---|
| `pgaudit.log` | `none` | session audit classes: `read`, `write`, `function`, `role`, `ddl`, `misc`, `misc_set`, `all`; `-class` subtracts |
| `pgaudit.log_catalog` | `on` | log statements whose relations are all in `pg_catalog` |
| `pgaudit.log_client` | `off` | also send audit messages to the client |
| `pgaudit.log_level` | `log` | level used only when `log_client` is on |
| `pgaudit.log_parameter` | `off` | append bind parameters as CSV |
| `pgaudit.log_parameter_max_size` | `0` | longer parameters become `<long param suppressed>`; 0 means no limit |
| `pgaudit.log_relation` | `off` | one entry per relation referenced by SELECT or DML |
| `pgaudit.log_rows` | `off` | append the number of rows retrieved or affected |
| `pgaudit.log_statement` | `on` | include the statement text |
| `pgaudit.log_statement_once` | `off` | statement text only with the first entry of a statement |
| `pgaudit.role` | empty | the master role for object audit |

Settings are not inherited through role membership, and `SET ROLE` does not change the auditing of the session.

## The audit log line format

Each entry goes through the standard logging facility as a `LOG` line starting with `AUDIT:`, followed by
comma-separated fields; the line is valid CSV once the `log_line_prefix` part is removed.

| Field | Content |
|---|---|
| AUDIT_TYPE | `SESSION` or `OBJECT` |
| STATEMENT_ID, SUBSTATEMENT_ID | sequence per session, and per statement for nested calls |
| CLASS | `READ`, `WRITE`, `FUNCTION`, `ROLE`, `DDL`, `MISC`, `MISC_SET` |
| COMMAND | for example `SELECT`, `ALTER TABLE` |
| OBJECT_TYPE, OBJECT_NAME | for SELECT, DML and most DDL; fully qualified name |
| STATEMENT | the statement text |
| PARAMETER | parameters as CSV, `<none>`, or `<not logged>` |

pgaudit adds no user, database or client address of its own: put them in `log_line_prefix` (for example
`%m [%p] %q%u@%d app=%a client=%h `), or use jsonlog, whose fixed keys include user, database, application and
session id.

## Behaviour observed on 18.6

These points were checked on PostgreSQL 18.6 with pgaudit 18.0.

- `CREATE ROLE ... PASSWORD 'x'` is logged with `PASSWORD <REDACTED>`.
- A `CREATE TABLE` with a primary key logs two DDL entries under one statement id: the table and its index.
- Object audit through a column grant (`GRANT SELECT (card_last4) ... TO auditor`) logged the query that read
  `card_last4` and did not log a query that read only `id` and `email`.
- A `DELETE` matching both object audit and the session class `write` was logged twice: once `OBJECT`, once
  `SESSION`.
- A bound parameter was logged in the parameter field when `pgaudit.log_parameter = on`.
- `ALTER SYSTEM` is in the `DDL` class; `SET`, `SET ROLE` and `RESET` were logged in `MISC`.
- Writes by background workers of other extensions (pg_squeeze's scheduler) are logged when their role's settings
  include the class, which adds noise; exclude such roles with a per-role `pgaudit.log = 'none'`.

## Volume control in practice

Audit volume is driven by the busiest roles and tables; control it per role and per object.

| Lever | Effect |
|---|---|
| object audit (`pgaudit.role` plus grants) instead of `read`/`write` session classes | only the granted tables and columns |
| per-role `pgaudit.log` | full audit for people and admin tools, `write` or `none` for the application role |
| `pgaudit.log_catalog = off` | skips catalog-only statements from psql and GUI tools |
| `pgaudit.log_statement_once = on` | statement text only on the first entry of a statement |
| `pgaudit.log_statement = off` | object names only, no text |
| `pgaudit.log_parameter_max_size` | caps parameter length |
| `pgaudit.log_relation = on` | more lines, but each names one table, which makes searching simple |

Estimate before enabling: count statements per role from `pg_stat_statements` (`calls` by `userid`) and multiply
by the average logged line length. New tables are not covered by object audit until granted to the audit role;
add the grant to the migration that creates a sensitive table.

## Documented limits and caveats

The pgaudit README lists these; state them in your audit documentation.

- Audit logging is best effort and not transactional. Entries are not flushed with the commit, so a crash or a
  full log volume can lose entries for committed transactions; a statement is logged when it executes, even if
  its transaction later rolls back.
- Superusers cannot be reliably audited. Restrict superuser access and use the `set_user` extension to escalate
  with logging.
- Autovacuum and autoanalyze are not logged.
- Statements run after a transaction enters an aborted state are not audit logged; the error itself is in the
  standard log.
- Renamed objects are logged under the new name.
- Without `CREATE EXTENSION pgaudit`, DDL entries lack object type and name; to recreate the extension, unset
  `pgaudit.log` first.

## pgaudit on managed services

Managed services that offer pgaudit expose it as an allow-listed extension: you add it to the preload list and set
`pgaudit.*` through the provider's parameter group or database flags, then `CREATE EXTENSION pgaudit` as the admin
role. The audit lines go to the provider's log service, which becomes the shipping path. Check each provider's
documentation for the flag names and whether `pgaudit.role` object audit is supported; this section was not
tested on any provider.
