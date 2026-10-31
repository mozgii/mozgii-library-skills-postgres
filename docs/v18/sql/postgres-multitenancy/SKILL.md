---
name: postgres-multitenancy
description: 'Builds multi-tenant SaaS data layers on PostgreSQL 18: shared tables with tenant_id and row-level security (ENABLE and FORCE, restrictive policies, tenant context with SET LOCAL or set_config per transaction behind a pooler), RLS that stays fast (indexes leading with tenant_id, leakproof functions), schema, database and cluster per tenant, noisy neighbours, per-tenant export, restore and deletion, and migrations across many tenants. Use when building a SaaS app, isolating customers, choosing "schema per tenant or tenant_id", one tenant sees another''s data, RLS is slow, or a tenant must be exported or deleted.'
metadata:
  tags:
  - postgres
  - multi-tenant
  - saas
  - row-level-security
  - rls
  - tenant-isolation
  - schema-per-tenant
  - noisy-neighbour
---

# PostgreSQL multi-tenancy

Default to shared tables with a `tenant_id` column, keys and indexes that lead with it, and row-level security (RLS)
as the safety net that turns a forgotten `WHERE tenant_id = ...` into zero rows instead of a data leak. Move a tenant
to its own schema, database or cluster only for a reason you can name: contractual isolation, a different region or
key, per-tenant restore, or one tenant big enough to hurt the others. Set the tenant per transaction, never per
session, because poolers hand sessions to other tenants. Table design for tenants (composite keys and foreign keys)
is in `postgres-schema-design`; role setup and RLS basics are in `postgres-security-roles`. The full isolation audit
is [scripts/rls-audit.sql](scripts/rls-audit.sql) (Step 0 inlines its first check); the other models in depth are in
[references/tenant-models.md](references/tenant-models.md).


## Step 0: read who you connect as and which tenant tables lack RLS

RLS does nothing for a superuser or a `BYPASSRLS` role, and without `FORCE` nothing for the owner, so read the role
before you trust any result. The second query lists tenant tables that are not yet protected: on 18.6 it listed a
table without RLS and left out one with `ENABLE` and `FORCE`.

```sql
SELECT current_setting('server_version') AS version, r.rolname, r.rolsuper, r.rolbypassrls
FROM pg_roles r WHERE r.rolname = current_user;
SELECT c.oid::regclass AS table_name, pg_get_userbyid(c.relowner) AS owner, c.relrowsecurity AS rls,
       c.relforcerowsecurity AS forced, (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND NOT (c.relrowsecurity AND c.relforcerowsecurity)
ORDER BY 1;
```

## Choosing a tenancy model

The tenancy model fixes how far isolation goes and what each new tenant costs. Pick per tenant tier if needed:
small tenants share tables, a few large or regulated ones get their own database.

| Model | Tenants it handles | Isolation | Costs |
|---|---|---|---|
| Shared tables + `tenant_id` + RLS | thousands to millions | logical; one bug in a policy is a leak | every key and index carries `tenant_id`; noisy neighbours share everything |
| Schema per tenant | tens to a few thousand | names; same roles and server | migrations run once per schema; catalog and `pg_dump` grow with every tenant |
| Database per tenant | tens to hundreds per cluster | connections, `pg_dump`, extensions | one pool per database; cross-tenant reports need another system |
| Cluster per tenant | a few, high-value | processes, memory, version, region, keys | full operations stack per tenant |
| Sharded shared tables (Citus) | very many, large total size | logical, plus per-tenant shards | a distributed system; see `postgres-citus-sharding` |

## Shared tables with tenant_id: keys and indexes

Shared tables keep one copy of the schema and put `tenant_id` first in every primary key, unique constraint and
index, so each lookup stays inside one tenant and a unique value is unique per tenant only.

```sql
CREATE TABLE app.customers (
  tenant_id bigint NOT NULL REFERENCES app.tenants (id),
  id        bigint GENERATED ALWAYS AS IDENTITY,
  email     text NOT NULL,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, email)
);
```

A global `UNIQUE (email)` is a covert channel: the docs note that unique and foreign key checks bypass RLS, so tenant
A can learn that an address exists in tenant B from a duplicate-key error. Foreign keys between tenant tables carry
`tenant_id` too (`FOREIGN KEY (tenant_id, project_id)`), which makes cross-tenant references impossible.

## Row-level security policies for tenant isolation

Row-level security filters every query on a table with the table's policies. Superusers and roles with `BYPASSRLS`
always bypass it, and the table owner bypasses it unless the table is `FORCE`d. A restrictive policy holds the
tenant rule; a permissive policy must also exist, because with only restrictive policies nothing is visible. This
setup ran on 18.6 with 200,000 rows across 200 tenants:

```sql
CREATE FUNCTION app.current_tenant() RETURNS bigint
  LANGUAGE sql STABLE PARALLEL SAFE
  AS $$ SELECT nullif(current_setting('app.tenant_id', true), '')::bigint $$;

ALTER TABLE app.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.customers FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.customers AS RESTRICTIVE FOR ALL TO PUBLIC
  USING (tenant_id = (SELECT app.current_tenant()))
  WITH CHECK (tenant_id = (SELECT app.current_tenant()));
CREATE POLICY allow_all ON app.customers FOR ALL TO PUBLIC USING (true) WITH CHECK (true);
```

Results for the application role `app_rw` (`NOBYPASSRLS`, not the owner):

| Request | Result on 18.6 |
|---|---|
| no tenant set | 0 rows |
| tenant 42 set | 1,000 rows (its own) |
| insert with `tenant_id = 7` while tenant 42 is set | `new row violates row-level security policy "tenant_isolation" for table "customers"` |
| only the restrictive policy, no permissive one | 0 rows even for tenant 42 |
| superuser | all 200,000 rows |

The `nullif(..., '')` matters: once a session has used `SET LOCAL app.tenant_id`, the setting reads as an empty
string after the transaction ends, and `''::bigint` raises `invalid input syntax for type bigint: ""`.

## Setting the tenant per transaction behind a pooler

The tenant context belongs to the transaction. `set_config(name, value, true)` and `SET LOCAL` end with the
transaction; `set_config(name, value, false)` and plain `SET` stay on the server session, which a transaction-mode
pooler such as PgBouncer then gives to the next client, possibly another tenant. On 18.6, a session-level
`set_config('app.tenant_id', '42', false)` still returned tenant 42's 1,000 rows in the next transaction. Set it
like this at the start of every request's transaction:

```sql
BEGIN;
SELECT set_config('app.tenant_id', $1, true);   -- $1 = tenant id from the authenticated request, as text
-- every query of the request
COMMIT;
```

- Set it in the same transaction as the queries, in one helper the application cannot skip (a repository wrapper,
  an ORM hook on transaction begin).
- Take the tenant from the authenticated session or token, never from a request parameter the client controls.
- Autocommit statements each run in their own transaction: open an explicit transaction per request.
- Pool modes and prepared statements behind PgBouncer: `postgres-connection-pooling`.

## Keeping RLS fast: InitPlans, leakproof functions and indexes

RLS performance depends on whether the planner can use the tenant condition as an index condition. Two rules came
out of 18.6 plans:

1. Wrap the tenant function in a scalar subquery, `(SELECT app.current_tenant())`. It runs once as an InitPlan, and
   the plan showed `Index Cond: ((tenant_id = (InitPlan 1).col1) AND (email = 'user42@example.com'::text))` on the
   `(tenant_id, email)` unique index.
2. Only leakproof functions and operators from the user's query may run before the policy. `lower()` is not
   leakproof, so `WHERE lower(email) = $1` was applied as a `Filter` after the tenant's rows were fetched, and an
   expression index on `(tenant_id, lower(email))` was not used for it. A stored generated column gives the planner
   a plain column compared with `=` on `text`, which is leakproof:

```sql
ALTER TABLE app.customers ADD COLUMN email_lower text GENERATED ALWAYS AS (lower(email)) STORED;
CREATE INDEX customers_tenant_email_lower_idx ON app.customers (tenant_id, email_lower);
-- WHERE email_lower = 'user42@example.com' now uses: Index Cond: ((tenant_id = ...) AND (email_lower = ...))
```

Check a function with `SELECT proname, proleakproof FROM pg_proc WHERE proname = 'lower'`. Marking a function
`LEAKPROOF` needs a superuser and a promise that it never reveals its arguments, including in error messages; do it
only for functions you have read.

## Views, functions and roles that bypass tenant isolation

Several objects run with someone else's rights and skip the caller's policies. Each one below was tested on 18.6
with tenant 42 set:

| Object | Rows returned | Why |
|---|---|---|
| view owned by the table owner, table `FORCE`d | 1,000 | the view checks the owner's rights; `FORCE` applies the policy to the owner |
| view owned by a role with `BYPASSRLS` | 200,000 | the view runs as that role |
| view `WITH (security_invoker = true)` | 1,000 | the view runs as the caller |

- Create views over tenant tables with `security_invoker = true` (PostgreSQL 15 and later).
- `SECURITY DEFINER` functions run as their owner; give them an owner without `BYPASSRLS` and a fixed
  `search_path`, or re-check `tenant_id` inside.
- Migrations and admin jobs that need every tenant use a separate role with `BYPASSRLS`, never the application role.
- [scripts/rls-audit.sql](scripts/rls-audit.sql) lists tenant tables without `ENABLE` or `FORCE`, indexes that do
  not lead with `tenant_id`, roles that bypass RLS, and views without `security_invoker`.

## Schema per tenant and database per tenant

Schema per tenant gives each tenant identical tables in its own schema and selects it with `search_path`; database
per tenant gives each its own database. Both make per-tenant restore and deletion simple and make everything else
scale with the tenant count. Each request selects its schema inside its transaction:

```sql
BEGIN;
SET LOCAL search_path = tenant_00042, public;    -- per transaction, for the same pooler reason
SELECT count(*) FROM invoices;
COMMIT;
```

- Quote and validate the schema name from your tenant table, never from user input (`format('%I', ...)`).
- Migrations run once per schema or database; plan for a runner that records the version per tenant and resumes.
- Database per tenant needs a pool per database, so connections, not storage, usually set the tenant limit.
- Details, provisioning and the migration runner: [references/tenant-models.md](references/tenant-models.md).

## Noisy neighbours

A noisy neighbour is one tenant whose load slows the others. Contain it in layers:

- Per-role limits: `ALTER ROLE app_rw SET statement_timeout = '15s'`; give batch and report traffic its own role with
  higher limits and fewer connections.
- Per-tenant rate limits and job queues in the application, keyed by `tenant_id`.
- Measure per tenant: plain PostgreSQL does not split `pg_stat_statements` by tenant, so log tenant and duration in
  the application; Citus has `citus_stat_tenants`.
- Move the big tenant: its own database or cluster, or with Citus `isolate_tenant_to_new_shard`.
- Hash-partition very large shared tables by `tenant_id` so vacuum and index builds work per partition
  (`postgres-partitioning`).

## Per-tenant export, restore and deletion

Per-tenant export is the request you get when a customer leaves or asks for their data. With shared tables and RLS,
`pg_dump` as a role without `BYPASSRLS` fails by default with `query would be affected by row-level security policy
for table "customers"`. Pass `--enable-row-security` and set the tenant for the session. The role also needs `SELECT`
on the table's identity sequence (`GRANT SELECT ON SEQUENCE app.customers_id_seq TO app_rw`), or `pg_dump` stops with
`failed to get data for sequence "customers_id_seq"`. With that grant, on 18.6 this dumped exactly tenant 42's 1,000
rows:

```bash
PGOPTIONS='-c app.tenant_id=42' pg_dump --data-only --enable-row-security \
  -U app_rw -d app -t app.customers -f tenant-42.sql
```

- The docs advise `--inserts` with `--enable-row-security` when the dump will be restored into tables that have
  row security, because `COPY FROM` does not support it.
- Export the tenant's rows from every table in one transaction with `COPY (SELECT ...) TO STDOUT` per table if you
  need CSV; a `REPEATABLE READ` transaction keeps them consistent.
- Restore one tenant into shared tables by loading its rows into a staging schema and inserting them, so ids and
  foreign keys can be checked first; a physical restore brings back every tenant.
- Delete a tenant in batches, children first, committing between batches so locks and WAL stay small, then delete
  the `tenants` row. `ON DELETE CASCADE` on one huge tenant is one long transaction.
- Schema or database per tenant: `pg_dump -n tenant_00042` or `pg_dump -d tenant_00042`, and `DROP SCHEMA ...
  CASCADE` or `DROP DATABASE` to delete.

## Testing tenant isolation

Tenant isolation tests run as the application role, never as a superuser or the owner, and assert both directions.

```sql
SET ROLE app_rw;
BEGIN;
SELECT set_config('app.tenant_id', '42', true);
SELECT count(*) = 0 AS sees_no_other_tenant FROM app.customers WHERE tenant_id <> 42;
SAVEPOINT s;
INSERT INTO app.customers (tenant_id, email) VALUES (7, 'probe@example.com');   -- must fail
ROLLBACK TO SAVEPOINT s;
ROLLBACK;
```

Run it in CI for every table that has `tenant_id`, and run [scripts/rls-audit.sql](scripts/rls-audit.sql) after
every migration.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Verify tenant isolation

Isolation is proven by a test that tries to cross the wall, run as the application role. Run the transaction under
"Testing tenant isolation", the Step 0 query (no rows expected), and this one, which must return the tenant's own
count for the tenant and 0 with no tenant set:

```sql
SET ROLE app_rw;
BEGIN;
SELECT set_config('app.tenant_id', '42', true);
SELECT count(*) AS own_rows FROM app.customers;     -- 1,000 in the run above
COMMIT;
SELECT count(*) AS no_tenant FROM app.customers;    -- 0
RESET ROLE;
```

Test the pooler as well: open two client connections through PgBouncer with different tenants, and run this
transaction in each many times. A session-level `SET` shows up here as rows from the other tenant.

## Gotchas

These are the failures seen most often in multi-tenant databases, each with its cause and fix.

1. **Tenant A sees tenant B's rows.** The application connects as the table owner (RLS bypassed without `FORCE`), as
   a superuser, or through a view owned by a `BYPASSRLS` role. Use a separate non-owner role, `FORCE` the tables and
   use `security_invoker` views.
2. **Requests sometimes get another tenant's data, only in production.** Tenant context was set per session behind a
   transaction pooler. Use `set_config(..., true)` inside each transaction.
3. **Every query returns nothing after enabling RLS.** No policy, or only restrictive ones. Add a permissive policy.
4. **`invalid input syntax for type bigint: ""`.** The setting is empty after a previous transaction. Use
   `nullif(current_setting('app.tenant_id', true), '')`.
5. **RLS made a lookup slow.** A non-leakproof function in the query cannot use the index. Use a stored generated
   column or compare plain columns.
6. **`pg_dump` fails with `query would be affected by row-level security policy`.** Dump with a `BYPASSRLS` role
   for full backups, or `--enable-row-security` with a tenant set for one tenant.

## Anti-patterns in multi-tenant design

Each of these is one missed `WHERE` or one pooled session away from a leak.

| Do not | Do instead |
|---|---|
| Rely on `WHERE tenant_id = ...` in application code alone | Keep it, and add RLS as the safety net |
| Connect the application as the table owner | Use a separate non-owner role with `NOBYPASSRLS`, and `FORCE` the tables |
| Set the tenant with `SET` or `set_config(..., false)` | Set it inside each transaction with `set_config(..., true)` |
| Take the tenant id from a request parameter | Take it from the authenticated session or token |
| Declare a global `UNIQUE (email)` | Declare `UNIQUE (tenant_id, email)`: a global key leaks that a value exists |
| Give every tenant its own schema because it sounds safer | Pick the model for a reason you can name; schemas multiply migrations and catalog size |

## Checklist

Check these points before you call a multi-tenant design done.

- [ ] Every tenant table has `tenant_id` first in its primary key, unique constraints and indexes.
- [ ] Tenant tables have `ENABLE` and `FORCE ROW LEVEL SECURITY`, a restrictive tenant policy and a permissive one.
- [ ] The application role is not the owner, not a superuser and has `NOBYPASSRLS`.
- [ ] The tenant is set with `set_config(..., true)` in every transaction, from the authenticated identity.
- [ ] Views over tenant tables use `security_invoker = true`.
- [ ] Isolation tests run in CI as the application role; [scripts/rls-audit.sql](scripts/rls-audit.sql) is clean.
- [ ] Export, restore and deletion of one tenant are scripted and have been run once.

## See also

Related skills in this library, each one works on its own:

- `postgres-security-roles`: role setup and RLS basics.
- `postgres-schema-design`: composite keys and foreign keys for tenants.
- `postgres-connection-pooling`: pool modes and prepared statements.
- `postgres-citus-sharding`: sharding shared tables by tenant.
- `postgres-partitioning`: hash partitions by `tenant_id`.
- `postgres-schema-migrations`: lock-safe DDL across many schemas.

## Sources

- https://www.postgresql.org/docs/18/ddl-rowsecurity.html
- https://www.postgresql.org/docs/18/sql-createpolicy.html
- https://www.postgresql.org/docs/18/app-pgdump.html (`--enable-row-security`, `--no-policies`)
- https://www.postgresql.org/docs/18/sql-createview.html (`security_invoker`)
- https://www.postgresql.org/docs/18/functions-admin.html (`set_config`, `current_setting`)
- https://docs.citusdata.com/en/stable/develop/api_udf.html (`isolate_tenant_to_new_shard`, `citus_stat_tenants`)
