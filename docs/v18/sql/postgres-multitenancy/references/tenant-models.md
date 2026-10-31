---
title: PostgreSQL tenant models in depth
author: MOZGII, Inc.
lang: en
---

# PostgreSQL tenant models in depth

This reference covers the tenancy models beyond shared tables: schema per tenant, database per tenant and cluster per
tenant, how to provision, migrate, back up and delete tenants in each, and how to move a tenant from one model to
another. Shared tables with row-level security are the default and are covered in the skill itself.

## Schema per tenant: layout and search_path

Schema per tenant puts identical tables in one schema per tenant (`tenant_00042`) inside one database, plus shared
tables (plans, feature flags) in a common schema. The application picks the tenant with `search_path` at the start of
each transaction:

```sql
BEGIN;
SET LOCAL search_path = tenant_00042, public;
SELECT count(*) FROM invoices;            -- tenant_00042.invoices
COMMIT;
```

- Use `SET LOCAL` (or `set_config('search_path', ..., true)`) so a pooled session never keeps another tenant's path.
- Build the name from your own tenant table with `format('%I', schema_name)`; never pass a client value.
- Schema-qualify shared tables (`public.plans`) so a tenant table of the same name cannot shadow them.
- Grant the application role `USAGE` on each tenant schema; a separate role per tenant adds isolation but multiplies
  pools.

## Schema per tenant: provisioning and the catalog

Provision a tenant by creating its schema and running every migration in it, in one transaction, so a failed
signup leaves nothing behind. Each schema adds rows to the system catalogs for every table, index, sequence and
constraint, so thousands of tenants mean a large catalog: `pg_dump` of the whole database slows, autovacuum has more
relations to visit, and each backend caches metadata for the schemas it touches. Measure with:

```sql
SELECT count(*) AS relations FROM pg_class;
SELECT pg_size_pretty(sum(pg_total_relation_size(oid))) AS catalog_size
FROM pg_class WHERE relnamespace = 'pg_catalog'::regnamespace;
```

## Migrations across many schemas

A migration in a schema-per-tenant database runs once per schema. Run it per schema in its own transaction with a
`lock_timeout`, record the version in the schema, and make the runner resumable, so one locked or broken tenant does
not stop the others. [scripts/migrate-schemas.sh](../scripts/migrate-schemas.sh) does that; on 18.6 it applied
`ALTER TABLE invoices ADD COLUMN IF NOT EXISTS due_at date` to three schemas (one named `tenant_O'Brien`), and a
second run skipped all three:

```bash
PGHOST=db.internal PGDATABASE=app PGUSER=migrator \
  ./migrate-schemas.sh migrations/0002_due_at.sql 0002 'tenant\_%'
# applied=3 skipped=0 failed=0
```

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

- Keep each migration backward compatible (expand, then contract), because schemas are on different versions while
  the runner works through them; zero-downtime DDL rules are in `postgres-schema-migrations`.
- Run several runners in parallel on disjoint schema lists for thousands of tenants, watching locks and WAL volume.
- A new tenant created during a rollout must get the new version: provision from the same migration list.

## Database per tenant

Database per tenant gives each tenant its own database in a shared cluster. Roles, `pg_hba.conf` rules and
extensions can differ per tenant, and `pg_dump -d tenant_00042` or `DROP DATABASE tenant_00042` handle one tenant.
Provision a tenant by copying a template database:

```sql
CREATE DATABASE tenant_00042 TEMPLATE tenant_template OWNER app_owner;
```

- `CREATE DATABASE ... TEMPLATE` fails while anyone is connected to the template; keep a dedicated template that the
  application never uses, and run migrations on it too.
- Each database needs its own connection pool, so connections set the limit: 300 databases with a pool of 5 each is
  1,500 server connections. Use PgBouncer with small per-database pools and `max_db_connections`
  (`postgres-connection-pooling`).
- Cross-tenant reporting needs another system: logical replication of selected tables to a reporting database, or
  exports to a warehouse.
- Background workers configured with a database list, such as pg_partman's `pg_partman_bgw.dbname`, must be told
  about every tenant database.

## Cluster per tenant

Cluster per tenant runs a separate PostgreSQL server per tenant. It is the only model that isolates CPU, memory, I/O,
the PostgreSQL version and the encryption keys, and it fits a few large or regulated tenants. Each cluster needs
backups, monitoring, upgrades and failover of its own, so it is practical only with automation: a Kubernetes
operator, a managed service with infrastructure as code, or Patroni with configuration management
(`postgres-patroni-ha`).

## Moving a tenant between models

Moving one tenant out of shared tables into its own database is how a noisy or regulated tenant leaves.

1. Create the target database with the same schema version.
2. Copy the tenant's rows table by table, parents first, with `COPY (SELECT ... WHERE tenant_id = $1) TO STDOUT`
   piped into `COPY ... FROM STDIN` on the target, in one `REPEATABLE READ` transaction on the source for a
   consistent cut.
3. For a short cutover on a busy tenant, use logical replication with a row filter instead:
   `CREATE PUBLICATION t42 FOR TABLE app.customers WHERE (tenant_id = 42), ...` (row filters need PostgreSQL 15 or
   later), then switch the tenant's routing when the subscriber has caught up.
4. Switch routing for that tenant in the application, then delete its rows from the shared tables in batches.

## Per-tenant backup and restore by model

What "restore one tenant" means differs by model; plan it before a customer asks.

| Model | Back up one tenant | Restore one tenant |
|---|---|---|
| Shared tables | `pg_dump --enable-row-security` with the tenant set, or `COPY` per table | load into a staging schema, check, then insert; physical backups restore all tenants |
| Schema per tenant | `pg_dump -n tenant_00042 -Fc` | `pg_restore -n tenant_00042` into the database after dropping or renaming the old schema |
| Database per tenant | `pg_dump -d tenant_00042 -Fc` | `pg_restore -d` into a fresh database, then switch routing |
| Cluster per tenant | the cluster's own base backups and WAL archive | point-in-time recovery of that cluster only |

## Sources

- https://www.postgresql.org/docs/18/ddl-schemas.html
- https://www.postgresql.org/docs/18/manage-ag-templatedbs.html
- https://www.postgresql.org/docs/18/sql-createpublication.html (row filters)
- https://www.postgresql.org/docs/18/app-pgdump.html
