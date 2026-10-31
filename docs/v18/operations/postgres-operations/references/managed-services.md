---
title: PostgreSQL on managed services
author: MOZGII, Inc.
lang: en
---

# PostgreSQL on managed services

Managed PostgreSQL (Amazon RDS and Aurora, Google Cloud SQL, Azure Database for PostgreSQL, Supabase, Neon) runs
the same engine, but the provider keeps the superuser, the configuration files and the host. Names of roles,
parameters and limits change; check the provider's current documentation before relying on a value here.

## Contents

This reference covers what changes when the server is not yours.

- What every managed service takes away
- Amazon RDS and Aurora PostgreSQL
- Google Cloud SQL for PostgreSQL
- Azure Database for PostgreSQL flexible server
- Supabase
- Neon
- Leaving a provider

## What every managed service takes away

A managed service gives the first role an admin role with most superuser rights, and keeps the rest. These
differences catch people moving from a self-hosted server:

| Self-hosted | Managed |
|---|---|
| `ALTER SYSTEM SET ...` or `postgresql.conf` | parameter groups, flags or the dashboard; some need a restart from the console |
| any extension in `pkglibdir` | an allowlist per version; preload libraries set through parameters |
| `COPY ... FROM '/file'` on the server | `\copy` from the client, or the provider's import from object storage |
| edit `pg_hba.conf` | network rules, private networking and the provider's TLS settings |
| `pg_upgrade` by hand | the provider's major-version upgrade, or logical replication to a new instance |
| your own base backups and WAL | the provider's snapshots and point-in-time window; take logical dumps for exit and long retention |

Superuser-only commands (`CREATE EXTENSION` of an untrusted extension that is not on the allowlist, reading
`pg_authid`, `ALTER SYSTEM`) fail with `permission denied` or `must be superuser`; look for the provider's
equivalent instead of a workaround.

## Amazon RDS and Aurora PostgreSQL

On RDS and Aurora the master user belongs to `rds_superuser`. Parameters live in a DB parameter group (Aurora also
has a cluster parameter group); static parameters apply after a reboot.

- Allowed extensions: `SHOW rds.extensions;`.
- Logical replication: set `rds.logical_replication = 1` in the parameter group and reboot.
- Connection pooling: RDS Proxy, which pins a client to one connection when it uses session features.
- Authentication: passwords, or IAM database authentication with short-lived tokens.
- Low-downtime major upgrades: blue/green deployments, built on logical replication.

## Google Cloud SQL for PostgreSQL

On Cloud SQL, users created through the console or `gcloud` belong to `cloudsqlsuperuser`. Parameters are database
flags.

- `gcloud sql instances patch <instance> --database-flags=...` replaces every flag set before; pass the full list
  each time or you silently reset the others.
- Logical decoding: the flag `cloudsql.logical_decoding=on` (restart).
- Auditing: the flag `cloudsql.enable_pgaudit=on`, then `CREATE EXTENSION pgaudit`.
- Authentication: built-in passwords or IAM database authentication; the Cloud SQL Auth Proxy handles TLS and IAM.

## Azure Database for PostgreSQL flexible server

On Azure the admin role is a member of `azure_pg_admin`. Server parameters are set in the portal or with
`az postgres flexible-server parameter set`.

- Extensions must be allowlisted in the server parameter `azure.extensions` before `CREATE EXTENSION`; libraries
  such as `pg_stat_statements` or `pg_cron` also need `shared_preload_libraries` and a restart.
- Logical replication: `wal_level = logical`, then restart.
- Built-in PgBouncer: `pgbouncer.enabled = true`, reached on port 6432.
- Authentication: passwords or Microsoft Entra ID tokens.

## Supabase

Supabase runs Postgres with an HTTP Data API in front, so table security matters even for tables your own backend
never exposes.

- Enable row-level security on every table the Data API can reach (the `public` schema by default); without it the
  public API key can read and write the table. Tables made in the dashboard start with RLS on; tables made with SQL
  do not.
- A table needs grants as well as policies: a role without them gets error `42501`, and RLS only decides which rows
  a role with grants sees. Supabase is changing its platform default so exposure becomes opt-in, so a new table may need an
  explicit `GRANT` to `anon` or `authenticated`; check the **Automatically expose new tables** setting.
- The `anon`, `authenticated` and `service_role` roles carry requests; `service_role` has `BYPASSRLS`, so its secret
  key never reaches a browser. A secret key sent together with a user's token runs under that user's policies.
- Functions are not covered by RLS. Each new function is executable by `PUBLIC`, so a `SECURITY DEFINER` function in
  an exposed schema is a public endpoint: keep it in a private schema with `SET search_path = ''`.
- Views run as their owner by default and skip RLS: create them `WITH (security_invoker = true)` on PostgreSQL 15+.
- Connections: the direct host for migrations and long-lived servers; the Supavisor pooler in transaction mode
  (port 6543) for serverless, in session mode (port 5432) for clients that need session state. The direct host is
  IPv6 only unless the project has the IPv4 add-on, so an IPv4-only CI runner must use the session pooler.
- Extensions: enable them in the dashboard or with `CREATE EXTENSION ... WITH SCHEMA extensions`.
- The `postgres` role is an admin role, not a true superuser.

## Neon

Neon separates storage from compute: a compute can scale to zero and start again on the next connection, and
branches copy a database instantly for tests and previews.

- Pooled connections: the host name with `-pooler` (PgBouncer in transaction mode); direct host for migrations,
  `LISTEN` and session work.
- The first query after scale-to-zero waits for the compute to start; keep a minimum compute for latency-sensitive
  production, or accept the cold start.
- Serverless and edge runtimes can use the `@neondatabase/serverless` driver over HTTP or WebSocket.
- Logical replication is enabled in the project settings.

## Leaving a provider

Moving off a managed service, or between them, uses logical tools, because physical backups and WAL stay with the
provider.

1. Small databases: `pg_dump -Fd -j 4` from the old one and `pg_restore -j 4` into the new one during a write freeze.
2. Large databases: logical replication from the old instance (publication) to the new one (subscription), then
   switch the application and copy sequence values (`setval`) before opening writes.
3. Roles: `pg_dumpall --globals-only` often fails on managed servers (no access to `pg_authid` passwords); use
   `--no-role-passwords` and set passwords again.
