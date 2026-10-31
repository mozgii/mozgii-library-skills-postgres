---
name: postgres-security-roles
description: 'Secures PostgreSQL access: least-privilege owner, migrator, app and read-only roles, schema and default privileges, predefined roles, pg_hba.conf with scram-sha-256, TLS with verify-full, md5 deprecation in 18, row-level security for multi-tenant data, SECURITY DEFINER functions with a fixed search_path, auditing and keeping passwords out of logs. Use when creating roles or grants, fixing "permission denied", setting up authentication, isolating tenants with RLS, or reviewing database security.'
metadata:
  tags:
  - postgres
  - security
  - roles
  - privileges
  - pg_hba
  - scram
  - tls
  - row-level-security
  - rls
  - multi-tenant
---

# PostgreSQL security, roles and row-level security

Give each component only the rights it needs, authenticate every connection with scram over TLS, and let the
database enforce tenant boundaries where application bugs cannot skip them. Row-level security in depth:
[references/row-level-security.md](references/row-level-security.md). A role setup to adapt:
[scripts/roles-setup.sql](scripts/roles-setup.sql).

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: read the server version and who can do what today

Version decides what is available (md5 warnings and `oauth` need 18, `pg_maintain` needs 17), and any review starts
from the roles and rules already there. `pg_hba_file_rules` needs a superuser by default.

```sql
SELECT current_setting('server_version') AS version, current_setting('password_encryption') AS password_encryption,
       current_setting('ssl') AS ssl;
SELECT rolname, rolsuper, rolcanlogin, rolbypassrls, rolreplication FROM pg_roles
WHERE rolname !~ '^pg_' ORDER BY rolname;
SELECT rule_number, type, database, user_name, address, auth_method, error FROM pg_hba_file_rules ORDER BY 1;
```

## A least-privilege role model

Separate who owns the schema from who uses it. An application role that cannot run DDL cannot be tricked into
dropping a table.

| Role | Rights | Used by |
|---|---|---|
| `app_owner` (NOLOGIN) | owns schema `app` and its objects | nobody logs in as it |
| `app_migrator` (LOGIN, member of `app_owner`) | DDL through `app_owner` | the migration job |
| `app_rw` (NOLOGIN group) | `SELECT, INSERT, UPDATE, DELETE` on tables, `USAGE` on sequences | granted to app users |
| `app_ro` (NOLOGIN group) | `SELECT` only | reporting, support |
| `app_api` (LOGIN, member of `app_rw`) | inherits `app_rw` | the application |

Never let the application log in as a superuser or as the table owner: owners bypass row-level security by default
and can `DROP`.

## Schema and database privileges

Privileges start from the database and the schema; table grants are useless without `USAGE` on the schema.

```sql
REVOKE ALL ON DATABASE app FROM PUBLIC;
GRANT CONNECT ON DATABASE app TO app_rw, app_ro, app_migrator;
CREATE SCHEMA app AUTHORIZATION app_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;                 -- PG 15+ already denies CREATE on public to PUBLIC
GRANT USAGE ON SCHEMA app TO app_rw, app_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app TO app_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO app_ro;
```

## Default privileges for tables created later

`GRANT ... ON ALL TABLES` covers existing tables only. Default privileges grant on objects a given role creates in
the future, so new tables from migrations are usable at once.

```sql
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT EXECUTE ON FUNCTIONS TO app_rw;
```

Default privileges apply to objects created by `app_owner`. Make migrations run `SET ROLE app_owner` first, or
objects end up owned by `app_migrator` and the defaults do not fire.

## Predefined roles instead of superuser

Predefined roles give common administrative rights without superuser.

| Role | Grants |
|---|---|
| `pg_read_all_data`, `pg_write_all_data` | read or write every table (PG 14+) |
| `pg_monitor` | read monitoring views and settings |
| `pg_maintain` | `VACUUM`, `ANALYZE`, `REINDEX`, `REFRESH MATERIALIZED VIEW` on all tables (PG 17+) |
| `pg_signal_backend` | cancel or terminate other non-superuser sessions |
| `pg_create_subscription` | create logical subscriptions (PG 16+) |
| `pg_use_reserved_connections` | use `reserved_connections` slots (PG 16+) |

## Authentication in pg_hba.conf

`pg_hba.conf` decides, per connection type, database, user and address, which authentication method applies. The
first matching line wins; there is no fall-through.

```
# TYPE    DATABASE     USER          ADDRESS        METHOD
local     all          postgres                     peer
hostssl   app          app_api       10.0.1.0/24    scram-sha-256
hostssl   app          +app_ro       10.0.2.0/24    scram-sha-256
hostssl   replication  replicator    10.0.0.0/24    scram-sha-256
host      all          all           0.0.0.0/0      reject
```

- `+group` matches members of a role. `all` does not match `replication`.
- Use `scram-sha-256` (`password_encryption = scram-sha-256`, the default since PG 14). `md5` is deprecated in
  PG 18: `CREATE ROLE`/`ALTER ROLE` with an md5 password warns. Re-set old passwords so they are stored as scram.
- PG 18 adds an `oauth` method with a validator library for single sign-on.
- After editing: `SELECT pg_reload_conf();` then `SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;`.

## TLS for client connections

TLS protects passwords and data on the network; only `sslmode=verify-full` also checks the server's identity.

```ini
# postgresql.conf
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
ssl_min_protocol_version = 'TLSv1.2'
```

Clients connect with `sslmode=verify-full sslrootcert=/path/ca.crt` (libpq). `require` encrypts but accepts any
certificate, so a man in the middle can still read the traffic. PG 17 adds `sslnegotiation=direct` to skip one round
trip.

## Passwords and secrets

A password in a migration file, a log or shell history is a password leaked.

- Set passwords with psql's `\password app_api`: it sends a hashed value, so the clear text never reaches the server
  log even with `log_statement = 'all'`.
- Applications read credentials from a secret store or environment injected at run time, never from the repository.
- Rotate by creating the new password, deploying it, then removing the old one; or use two login roles that share a
  group and switch between them.
- Cloud IAM or token auth (RDS IAM, Azure Entra ID, Cloud SQL IAM) avoids static passwords altogether.

## SECURITY DEFINER functions

A `SECURITY DEFINER` function runs with its owner's rights, which is how you expose one privileged operation to a
weaker role. Without a fixed `search_path`, a caller can plant an object that the function then runs as its owner.

```sql
CREATE FUNCTION app.close_account(p_id bigint) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$ UPDATE app.accounts SET closed_at = now() WHERE id = p_id $$;
REVOKE ALL ON FUNCTION app.close_account(bigint) FROM PUBLIC;     -- functions are executable by PUBLIC by default
GRANT EXECUTE ON FUNCTION app.close_account(bigint) TO app_support;
```

Schema-qualify every object inside the function.

## Row-level security for tenant isolation

Row-level security (RLS) adds a filter the database applies to every query on a table, so a missing `WHERE
tenant_id = ...` in application code cannot leak another tenant's rows.

```sql
ALTER TABLE app.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.projects FORCE ROW LEVEL SECURITY;         -- applies to the table owner too
CREATE POLICY tenant_isolation ON app.projects
  USING (tenant_id = current_setting('app.tenant_id')::bigint)
  WITH CHECK (tenant_id = current_setting('app.tenant_id')::bigint);
-- per request, inside the transaction:
BEGIN;
SELECT set_config('app.tenant_id', '42', true);           -- true = transaction-local, safe with poolers
SELECT * FROM app.projects;                                -- only tenant 42
COMMIT;
```

Policies per command, performance, testing and the managed-auth pattern (Supabase `auth.uid()`):
[references/row-level-security.md](references/row-level-security.md).

## Auditing and logging

Logs show who did what; configure them so they help an investigation without leaking data.

```ini
log_connections = 'authentication,authorization'   # PG 18 accepts a list; earlier versions: on
log_disconnections = on
log_statement = 'ddl'
log_line_prefix = '%m [%p] %q%u@%d %a '
```

The `pgaudit` extension logs reads and writes per role or per object in a structured format, for compliance needs.

## Worked example: "permission denied for table invoices, but I granted it last week"

Last week's grant was `GRANT SELECT ON ALL TABLES IN SCHEMA app TO app_ro`, which covers tables that existed then.
`app.invoices` was created yesterday by a migration. Check who owns it and which default privileges exist:

```sql
SELECT tableowner FROM pg_tables WHERE schemaname = 'app' AND tablename = 'invoices';   -- app_migrator
SELECT pg_get_userbyid(defaclrole) AS creator, defaclobjtype, defaclacl
FROM pg_default_acl WHERE defaclnamespace = 'app'::regnamespace;                        -- set for app_owner
```

The default privileges are for objects created by `app_owner`, but the migration ran as `app_migrator` without
`SET ROLE app_owner`, so they never fired. Fix the table and the cause:

```sql
ALTER TABLE app.invoices OWNER TO app_owner;
GRANT SELECT ON app.invoices TO app_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.invoices TO app_rw;
```

Then make the migration tool run `SET ROLE app_owner;` before its DDL, so the next table gets its grants on creation.

## Verify roles with SET ROLE and has_table_privilege

Test privileges as the role itself, because a superuser passes everything. These ran on 18.6 after
[scripts/roles-setup.sql](scripts/roles-setup.sql), on a table `app_owner` created.

```sql
SET ROLE app_ro;  INSERT INTO app.invoices (amount) VALUES (1); RESET ROLE;    -- ERROR: permission denied for table invoices
SET ROLE app_api; DROP TABLE app.invoices; RESET ROLE;                         -- ERROR: must be owner of table invoices
SELECT rolname, has_table_privilege(rolname, 'app.invoices', 'SELECT') AS can_select,
       has_table_privilege(rolname, 'app.invoices', 'INSERT') AS can_insert,
       has_table_privilege(rolname, 'app.invoices', 'TRUNCATE') AS can_truncate
FROM pg_roles WHERE rolname IN ('app_api', 'app_ro');                          -- app_ro t f f, app_api t t f
SELECT has_database_privilege('public', current_database(), 'CONNECT');        -- f
SELECT rolname FROM pg_roles WHERE rolsuper;                                   -- only the roles you expect
SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;                -- 0
```

Then connect over the network with `sslmode=verify-full`, and once with `sslmode=disable`: the second must be refused.

## Checklist

Check these points before you call database security done.

- [ ] The application logs in as a role with DML only; nobody uses a superuser or the owner for app traffic.
- [ ] `CONNECT` revoked from `PUBLIC`; `USAGE` granted on the app schema only to app roles.
- [ ] Default privileges set for the owner role; migrations `SET ROLE` to it.
- [ ] `pg_hba.conf` uses `hostssl` + `scram-sha-256` and ends with `reject` lines; no `trust` on network lines.
- [ ] Clients use `sslmode=verify-full`.
- [ ] No md5 passwords left: `SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'md5%';` is empty.
- [ ] Multi-tenant tables have `ENABLE` and `FORCE ROW LEVEL SECURITY` with tested policies.
- [ ] `SECURITY DEFINER` functions set `search_path` and revoke `EXECUTE` from `PUBLIC`.

## Gotchas

These are the failures seen most often with database security, each with its cause and fix.

1. **`permission denied for schema app`.** Table grants without `USAGE` on the schema.
2. **New tables are not readable by the app.** Default privileges were set for a different creating role than the
   one that ran the migration.
3. **RLS has no effect.** The query runs as the table owner or a superuser or a role with `BYPASSRLS`. Use `FORCE
   ROW LEVEL SECURITY` and a non-owner app role.
4. **RLS leaks across requests behind a pooler.** The tenant was set with session `SET`. Use
   `set_config(..., true)` or `SET LOCAL` inside the transaction.
5. **`CREATE` on `public` fails after upgrading to 15.** By design; create objects in your own schema or grant
   `CREATE` explicitly.
6. **A password shows up in the server log.** It was sent in an `ALTER ROLE ... PASSWORD 'x'` statement with
   statement logging on. Use `\password`.

## Anti-patterns in database access control

Each of these leaves a door open that a review would otherwise close.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| The application logging in as owner or superuser | it can drop tables and skips RLS | a login role with DML only |
| One login shared by every service | logs cannot tell them apart, and rotating it touches everything | one role per component |
| `GRANT ALL` to make an error go away | least privilege is gone and nobody revokes it later | grant the exact privilege; check schema `USAGE` first |
| `host` lines or `trust` on a network | passwords cross in clear, or none is asked for | `hostssl` with `scram-sha-256`, ending in `reject` |
| Calling `sslmode=require` verified | it accepts any certificate | `sslmode=verify-full` with a CA file |
| Passwords in migrations or `ALTER ROLE` statements | they reach logs and history | `\password`, or a secret store |
| `SECURITY DEFINER` without a fixed `search_path` | a caller can plant an object that runs as the owner | `SET search_path`, qualified names, `REVOKE` from `PUBLIC` |
| Session `SET` for the tenant behind a pooler | the value leaks to the next client on that connection | `set_config(..., true)` inside the transaction |

## See also

Related skills in this library:

- `postgres-encryption-tls`: certificates and encryption in depth
- `postgres-multitenancy`: tenant isolation built on RLS
- `postgres-auditing-compliance`: pgaudit and evidence
- `postgres-connection-pooling`: RLS settings behind a pooler
- `postgres-schema-migrations`: running DDL as the owner role
