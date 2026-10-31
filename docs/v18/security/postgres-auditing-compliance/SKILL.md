---
name: postgres-auditing-compliance
description: 'Makes a PostgreSQL 18 estate auditable and compliant: pgaudit setup, classes, session versus object audit and log volume control, connection and DDL audit with log settings and event triggers, where row-history triggers fit, shipping audit logs to tamper-resistant storage, GDPR right to erasure across tables and backups, retention by partition, masking with PostgreSQL Anonymizer, separation of duties and role reviews, and the evidence SOC 2 and ISO 27001 auditors ask for. Use when a compliance audit is coming, someone asks "who changed or read this data", personal data must be deleted or masked, or you set up pgaudit.'
metadata:
  tags:
  - postgres
  - audit
  - pgaudit
  - compliance
  - gdpr
  - soc2
  - iso27001
  - masking
  - anonymizer
  - retention
---

# PostgreSQL auditing and compliance

An audit trail must answer who did what, to which object, when and from where, and survive the people it audits.
Build it in layers: connection and DDL logging from server settings; pgaudit for statements on sensitive objects
(session audit for DDL and role changes, object audit for chosen tables); row history from triggers only where the
business needs old values; and everything shipped off the host to storage that database administrators cannot
edit. Compliance work adds deletion (GDPR erasure, retention), masking for non-production and support access, and
separation of duties. Trigger-based history and event trigger mechanics are in `postgres-functions-triggers`; roles
and privileges in `postgres-security-roles`; encryption in `postgres-encryption-tls`. pgaudit in depth:
[references/pgaudit.md](references/pgaudit.md). Evidence per control and the erasure runbook:
[references/compliance-evidence.md](references/compliance-evidence.md).

## Step 0: see what is audited today

Read the logging settings and check whether pgaudit is available and loaded.

```sql
SELECT name, setting FROM pg_settings
WHERE name IN ('shared_preload_libraries', 'log_destination', 'log_line_prefix', 'log_connections',
               'log_disconnections', 'log_statement', 'log_file_mode')
   OR name LIKE 'pgaudit.%' ORDER BY name;
SELECT name, default_version, installed_version FROM pg_available_extensions
WHERE name IN ('pgaudit', 'anon', 'pgcrypto');
SELECT evtname, evtevent, evtowner::regrole, evtenabled FROM pg_event_trigger;
```

pgaudit is not part of PostgreSQL and not in Postgres.app; on Debian and Ubuntu it is the PGDG package
`postgresql-18-pgaudit` (pgaudit 18.0 for PostgreSQL 18), elsewhere build it with PGXS from the `REL_18_STABLE`
branch, and on managed services enable it from the provider's extension list.

## Choosing an audit mechanism

Each mechanism records something different; most estates need two or three of them.

| Need | Mechanism | Records |
|---|---|---|
| logins, failed logins, session length | `log_connections`, `log_disconnections` | user, database, client address, auth method, TLS |
| every DDL and role change, with object names | pgaudit session classes `ddl, role` | statement class, command, object, text |
| reads or writes of specific tables or columns | pgaudit object audit (`pgaudit.role`) | each statement touching granted objects |
| old and new values of changed rows | audit triggers (`postgres-functions-triggers`) | row images in a table, transactional |
| DDL history queryable in SQL | event triggers writing to a table | command tag, object, user, query text |
| a change stream for other systems | logical decoding (CDC) | committed row changes |

`log_statement = 'all'` is not an audit: it records what the client sent, not what ran (dynamic SQL inside a
function is invisible), and it cannot be limited to sensitive tables.

## Setting up pgaudit

pgaudit must be in `shared_preload_libraries` (restart), and `CREATE EXTENSION pgaudit` must run before
`pgaudit.log` is set, so DDL entries carry object types and names. Write the library list unquoted in `ALTER
SYSTEM`: `= 'pgaudit,pg_stat_statements'` stores one library named `pgaudit,pg_stat_statements` and the server
does not start.

```sql
ALTER SYSTEM SET shared_preload_libraries = pgaudit, pg_stat_statements;
-- restart, then in each database to audit:
CREATE EXTENSION pgaudit;
ALTER SYSTEM SET pgaudit.log = 'ddl, role, write';
ALTER SYSTEM SET pgaudit.log_catalog = off;
ALTER SYSTEM SET pgaudit.log_relation = on;
ALTER SYSTEM SET pgaudit.log_parameter = on;
ALTER SYSTEM SET pgaudit.log_parameter_max_size = 256;
ALTER SYSTEM SET pgaudit.role = 'auditor';
ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d app=%a client=%h ';
SELECT pg_reload_conf();
```

Classes for `pgaudit.log`: `READ` (SELECT, `COPY ... TO`), `WRITE` (INSERT, UPDATE, DELETE, TRUNCATE, `COPY ... FROM`),
`FUNCTION` (calls and DO), `ROLE` (GRANT, REVOKE, role DDL), `DDL`, `MISC` (VACUUM, SET, FETCH, ...), `MISC_SET`,
`ALL`; subtract with `-` (`'all, -misc'`). Settings can be set per database and per role
(`ALTER ROLE app_api SET pgaudit.log = 'write'`), only by superusers, and are not inherited through role
membership or `SET ROLE`.

## Session audit and object audit

Session audit logs every statement of the chosen classes for the session's role. Object audit logs only
statements on objects (tables, columns) granted to the audit role, which is how you audit reads of one sensitive
table without logging every `SELECT`. Object audit covers SELECT, INSERT, UPDATE and DELETE, not TRUNCATE.

```sql
CREATE ROLE auditor NOLOGIN;
GRANT SELECT (card_last4), DELETE ON app.customers TO auditor;   -- audit reads of that column, and deletes
```

Output from 18.6 with pgaudit 18.0 for role `app_api` (`pgaudit.log = 'write'` on the role); the plain
`SELECT id, email` was not logged, the read of `card_last4` was:

```text
AUDIT: SESSION,1,1,WRITE,INSERT,TABLE,app.customers,"INSERT INTO app.customers VALUES (1, 'ada@example.com', '4242'), ...",<none>
AUDIT: OBJECT,2,1,READ,SELECT,TABLE,app.customers,SELECT card_last4 FROM app.customers WHERE id = $1,1
AUDIT: OBJECT,4,1,WRITE,DELETE,TABLE,app.customers,DELETE FROM app.customers WHERE id = 2,<none>
AUDIT: SESSION,4,1,WRITE,DELETE,TABLE,app.customers,DELETE FROM app.customers WHERE id = 2,<none>
AUDIT: SESSION,1,1,ROLE,CREATE ROLE,,,CREATE ROLE app_api LOGIN PASSWORD <REDACTED>,<none>
```

Fields: audit type, statement id, substatement id, class, command, object type, object name, statement,
parameters (`<none>`, `<not logged>`, or the CSV values). pgaudit redacts passwords in role statements. When a
statement matches both, it is logged twice (the DELETE above).

## Controlling audit log volume

pgaudit can write more than the data itself. The main levers: object audit instead of `READ`/`WRITE` session
classes, per-role `pgaudit.log` (full audit for people, `write` or nothing for the application role),
`pgaudit.log_catalog = off`, `pgaudit.log_statement_once = on`, and `pgaudit.log_parameter_max_size`. Keep
`pgaudit.log_client` off, measure on staging with production-like traffic, and give logs their own disk. The full
table of settings with defaults is in [references/pgaudit.md](references/pgaudit.md).

## Connection and DDL audit with server settings and event triggers

Connection logging and an event-trigger DDL table cover "who logged in" and "who changed the schema" without
pgaudit. `log_connections = 'authentication,authorization'` (18 list syntax) logs the authenticated identity, the
method and TLS details; `system_user` (16+) returns the same identity (`cert:CN=...`, `scram-sha-256:app_pw`).

```sql
CREATE SCHEMA audit;
REVOKE ALL ON SCHEMA audit FROM PUBLIC;
CREATE TABLE audit.ddl_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT clock_timestamp(),
  session_user_ name NOT NULL DEFAULT session_user,
  auth_identity text DEFAULT system_user,
  client_addr inet DEFAULT inet_client_addr(),
  command_tag text NOT NULL, object_type text, object_identity text, statement text);
CREATE FUNCTION audit.log_ddl() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
    INSERT INTO audit.ddl_log (command_tag, object_type, object_identity, statement)
    VALUES (r.command_tag, r.object_type, r.object_identity, current_query());
  END LOOP;
END $$;
CREATE EVENT TRIGGER audit_ddl ON ddl_command_end EXECUTE FUNCTION audit.log_ddl();
```

Add a second function on `sql_drop` that reads `pg_event_trigger_dropped_objects() WHERE original`: tested on
18.6, a `DROP TABLE` left no row from `pg_event_trigger_ddl_commands()`. The table is transactional (a rolled-back DDL leaves no row)
but a superuser can edit it, so treat it as convenience, and the shipped log as the record.

## What pgaudit cannot promise

pgaudit's documentation lists limits an auditor should hear from you: logging is best effort and not transactional
(a crash can lose entries; a rolled-back statement is still logged), superusers cannot be reliably audited (use the
`set_user` extension for audited escalation), and autovacuum is not logged. Details:
[references/pgaudit.md](references/pgaudit.md).

## Shipping and protecting audit logs

An audit log on the database host is only as trustworthy as the host's administrators. Ship it the moment it is
written to storage they cannot change.

- Write jsonlog or csvlog (`postgres-monitoring-observability` has the baseline) and keep `log_file_mode = 0600`
  (default; ignored on Windows).
- Ship with a log agent to a separate account or project, into append-only storage (object lock or WORM retention,
  a SIEM with immutable indexes).
- Synchronize clocks (NTP or chrony; Windows Time) so entries line up with application and network logs.
- Alert on gaps (no audit lines for N minutes from a busy server) and on setting changes: with pgaudit 18.0,
  `ALTER SYSTEM` is logged in the `DDL` class and `SET` in `MISC`.

## GDPR erasure across tables, logs and backups

Right-to-erasure requests delete a person's data from live tables in one transaction, record the erasure, and make
sure restores do not bring the data back. The ledger stores a keyed hash of the subject id, never the id, so it holds
no personal data. `hmac()` comes from `pgcrypto`. `$1` is the HMAC key: bind it from a secret store outside the
database, never as a literal, because a literal lands in logs and audit entries. The live part, proven on 18.6:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE audit.erasure_ledger (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject_hash bytea NOT NULL UNIQUE,
  requested_at timestamptz NOT NULL,
  erased_at    timestamptz NOT NULL DEFAULT now(),
  erased_by    name NOT NULL DEFAULT session_user,
  tables       text[] NOT NULL
);
BEGIN;
DELETE FROM app.people WHERE id = 42;                    -- children via ON DELETE CASCADE, or explicit deletes
INSERT INTO audit.erasure_ledger (subject_hash, requested_at, tables)
VALUES (hmac('42', $1, 'sha256'), '2026-10-20', ARRAY['app.people', 'app.people_orders']);
COMMIT;
```

Backups cannot be edited, so the usual answer is: keep backup retention short and documented, and after any restore
replay the ledger (delete every subject whose keyed hash is in it) before the database serves traffic. Logs hold
personal data too (statement text, parameters); give them the same retention. Crypto-shredding (encrypt each
person's data with a per-person key and destroy the key) works only if those keys live outside the backed-up
database. The full runbook is in [references/compliance-evidence.md](references/compliance-evidence.md).

## Retention by partition

Retention is cheapest when tables are partitioned by time: dropping a partition removes old rows without `DELETE`
bloat or long locks.

```sql
ALTER TABLE audit.access_log DETACH PARTITION audit.access_log_2026_09 CONCURRENTLY;
DROP TABLE audit.access_log_2026_09;
```

`DETACH ... CONCURRENTLY` cannot run in a transaction block. Partition design is covered by
`postgres-schema-design`.

## Masking with PostgreSQL Anonymizer

PostgreSQL Anonymizer (`anon`, 3.3.2) declares masking rules as security labels and applies them dynamically for
masked roles, statically to a copy, or in dumps. Proven on 18.6 with the project's container image:

```sql
ALTER DATABASE app SET anon.transparent_dynamic_masking TO true;
SECURITY LABEL FOR anon ON COLUMN app.customers.full_name IS 'MASKED WITH FUNCTION anon.dummy_name()';
SECURITY LABEL FOR anon ON COLUMN app.customers.phone IS 'MASKED WITH FUNCTION anon.partial(phone, 3, $$*******$$, 2)';
CREATE ROLE support_analyst LOGIN;
SECURITY LABEL FOR anon ON ROLE support_analyst IS 'MASKED';
GRANT USAGE ON SCHEMA app TO support_analyst;
GRANT SELECT ON app.customers TO support_analyst;
```

Without the `USAGE` grant the role gets `permission denied for schema app`. `support_analyst` then reads
`+44*******58` and an invented name while other roles see real values. For a masked
dump, run `pg_dump --no-security-labels --exclude-extension=anon` as a masked role. anon needs
`shared_preload_libraries` (or `session_preload_libraries` per database), `CREATE EXTENSION anon` and
`anon.init()` for the fake data sets; masked roles cannot use `EXPLAIN` or read `SECURITY INVOKER` views.

## Separation of duties and role reviews

Auditors look for named people, least privilege and nobody able to erase their own tracks. The quarterly review:

```sql
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls, rolreplication, rolcanlogin, rolvaliduntil
FROM pg_roles WHERE rolname !~ '^pg_' AND (rolsuper OR rolcreaterole OR rolbypassrls OR rolreplication) ORDER BY 1;
SELECT r.rolname AS member, g.rolname AS granted_role, m.admin_option, m.inherit_option, m.set_option,
       gr.rolname AS grantor
FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member JOIN pg_roles g ON g.oid = m.roleid
JOIN pg_roles gr ON gr.oid = m.grantor
WHERE g.rolname IN ('pg_read_all_data', 'pg_write_all_data', 'pg_monitor', 'pg_maintain', 'pg_signal_backend',
                    'pg_execute_server_program', 'pg_read_server_files', 'pg_write_server_files')
ORDER BY 1, 2;
```

- The application never logs in as a superuser or table owner; migrations use a separate role.
- People get personal login roles that are members of group roles; shared logins defeat the audit trail.
- Since 16, `CREATEROLE` can change only roles it holds `ADMIN OPTION` on, which makes a delegated user-admin role
  practical; membership grants carry `INHERIT` and `SET` options worth reviewing.
- `pg_execute_server_program`, `pg_read_server_files` and `pg_write_server_files` give OS-level access: treat them
  like superuser.

## Verify that the audit trail records

Prove the trail with a probe before an auditor asks: run one statement of each audited kind as a real role, then find
each line in the shipped log, not only on the database host.

```sql
SELECT card_last4 FROM app.customers WHERE id = 1;        -- as the application role: AUDIT: OBJECT ... READ
CREATE TABLE app.audit_probe (id int);                    -- as the migration role: AUDIT: SESSION ... DDL
DROP TABLE app.audit_probe;
```

```bash
# on the database host, with logging_collector on; 0 means nothing is being recorded
grep -c 'AUDIT:' "$PGDATA/$(psql -Atc 'SELECT pg_current_logfile()')"
```

Check the rest by hand: restore a backup into a scratch server and replay the ledger until no erased subject remains,
log in as a masked role and read a masked column, and confirm the gap alert fires when log shipping stops.

## Gotchas

These are the audit and compliance failures seen most often, each with its cause and fix.

1. **No `AUDIT:` lines appear.** pgaudit is not in `shared_preload_libraries`, or `pgaudit.log` is still `none`.
   Check `SHOW shared_preload_libraries` and the per-role settings in `pg_db_role_setting`.
2. **DDL entries lack object names.** `CREATE EXTENSION pgaudit` was not run in that database.
3. **`ERROR` dropping and recreating the extension.** Unset `pgaudit.log` before `DROP EXTENSION pgaudit`.
4. **The audit log filled the disk.** `READ` logged for an application role on hot tables. Move to object audit
   and per-role settings.
5. **Personal data turned up in logs after an erasure.** Parameters were logged. Limit `pgaudit.log_parameter` to
   tables that need it and keep log retention within the erasure policy.
6. **A restored backup brought deleted customers back.** The erasure ledger was not replayed. Make replay a step
   of every restore runbook.
7. **Masked users see real data.** `anon.transparent_dynamic_masking` is off for that database, or the role is not
   labelled `MASKED`.

## Checklist

Check these points before an audit.

- [ ] Connection logging, DDL and role auditing are on, with identity, client address and application in each line.
- [ ] Sensitive tables have object audit; volume was measured on staging.
- [ ] Audit logs ship to append-only storage in another account, with retention and gap alerts.
- [ ] Superuser use is rare, named and logged; no shared admin logins.
- [ ] Role and privilege review queries run on a schedule, with sign-off kept as evidence.
- [ ] Erasure runbook covers tables, logs, backups and post-restore replay.
- [ ] Non-production copies are masked or synthetic.

## Anti-patterns in database auditing

| Do not | Do this instead |
|---|---|
| call `log_statement = 'all'` an audit | pgaudit, which logs the object and the class, including dynamic SQL |
| keep audit logs only on the database host | ship them at once to append-only storage in another account |
| log `READ` for the application role on hot tables | object audit on the sensitive columns |
| write an id or email into the erasure ledger | a keyed hash, with the key outside the database |
| share one admin login | personal login roles that are members of a group role |
| treat a trigger table as tamper-proof | the shipped log is the record; a superuser can edit a table |

## See also

- `postgres-functions-triggers`: row-history triggers and event trigger mechanics.
- `postgres-security-roles`: roles, grants and row-level security.
- `postgres-encryption-tls`: data in transit and at rest.
- `postgres-monitoring-observability`: the log baseline and log shipping.
- `postgres-partitioning`: partitions that make retention a `DROP`.
- `postgres-backup-restore`: backup retention and restores.

## Sources

- https://github.com/pgaudit/pgaudit (README; pgaudit 18.0 tested on 18.6)
- https://www.postgresql.org/docs/18/runtime-config-logging.html
- https://www.postgresql.org/docs/18/event-triggers.html, functions-event-triggers.html
- https://www.postgresql.org/docs/18/functions-info.html (system_user)
- https://www.postgresql.org/docs/18/sql-altertable.html (DETACH PARTITION CONCURRENTLY)
- https://www.postgresql.org/docs/18/release-16.html (CREATEROLE changes)
- https://postgresql-anonymizer.readthedocs.io/ and https://gitlab.com/dalibo/postgresql_anonymizer (3.3.2)
- https://github.com/pgaudit/set_user
