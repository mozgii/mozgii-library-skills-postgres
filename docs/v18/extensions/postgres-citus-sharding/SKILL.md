---
name: postgres-citus-sharding
description: 'Shards PostgreSQL 18 across nodes with Citus 14: when to shard at all versus partitioning, read replicas or a bigger server, choosing the distribution column, distributed and reference tables, colocation, which queries push down to one shard, keys and foreign keys, rebalancing after adding workers, tenant isolation and tenant statistics, schema-based sharding, distributing a live table, and the SQL limits. Use when one PostgreSQL server is no longer enough, for multi-tenant SaaS at scale, real-time analytics over billions of rows, or errors such as "the query contains a join that requires repartitioning".'
metadata:
  tags:
  - postgres
  - citus
  - sharding
  - distributed-tables
  - scale-out
  - multi-tenant
  - rebalancing
  - colocation
---

# PostgreSQL sharding with Citus

Shard last. A single PostgreSQL 18 server on modern hardware handles terabytes and tens of thousands of transactions
per second; partitioning, read replicas, a connection pooler and query tuning are cheaper than a distributed
database. Shard with Citus when one of these is true: the working set or write rate outgrows the largest server you
can buy, a multi-tenant app needs to spread tenants over machines, or analytics must scan billions of rows in
seconds by running on many nodes at once. Then choose one distribution column (usually `tenant_id`), distribute every
large table by it, colocate them, and make every hot query filter on it. Operations (HA, backups, upgrades,
connections) are in [references/citus-operations.md](references/citus-operations.md).

## Step 0: read the Citus version and the cluster

Citus majors track PostgreSQL majors, and most advice below depends on what the cluster holds today.

```sql
SELECT version();
SELECT citus_version();
SELECT nodename, nodeport, noderole, isactive FROM pg_dist_node;
SELECT table_name, citus_table_type, distribution_column, shard_count, table_size FROM citus_tables;
SHOW wal_level;
```

Before Citus is installed, measure the case for it: `SELECT pg_size_pretty(pg_database_size(current_database()));`,
and the top tables and write rates in `pg_stat_user_tables`.

## When to shard, partition, replicate or scale up

Sharding spreads one logical table over several servers; each alternative solves a narrower problem for less effort.

| Problem | First answer | Shard when |
|---|---|---|
| reads overload the primary | read replicas (`postgres-replication-ha`) | writes, not reads, are the bottleneck |
| one huge table, old data must go | partitioning (`postgres-partitioning`) | the table outgrows one server's disk or vacuum capacity |
| too many connections | a pooler (`postgres-connection-pooling`) | never for this alone |
| slow queries | indexes and plans (`postgres-query-performance`) | the query must scan more data than one server reads in time |
| many tenants, one getting large | move it to its own database (`postgres-multitenancy`) | thousands of tenants together outgrow one server |

## Citus architecture: coordinator, workers and shards

Citus is an extension: a coordinator node holds metadata and plans queries, worker nodes hold shards, and each shard
is an ordinary PostgreSQL table such as `tasks_102099`. A row's shard comes from a hash of its distribution column;
the default is 32 shards per distributed table (`citus.shard_count`). Citus 14.3.0 (October 23, 2026) is current;
Citus 14.0 added PostgreSQL 18 and dropped 15, so Citus 14 runs on PostgreSQL 16 to 18; Citus 13.x (13.5.0 is
current) runs on 15 to 17.

| Table type | Stored | Use for |
|---|---|---|
| distributed | hashed into shards across workers | large tables keyed by tenant or entity |
| reference | one shard copied to every node | small lookup tables joined to everything (countries, plans) |
| local | only on the coordinator | admin tables never joined to distributed ones |
| schema (schema-based sharding) | one shard group per schema | schema-per-tenant apps |

## Installing Citus 14 for PostgreSQL 18

The Citus docs install it from Linux packages or Docker; on macOS and Windows use Docker for development. `citus`
must be first in `shared_preload_libraries`. The examples in this skill ran on the `citusdata/citus:14.2.0` image (PostgreSQL 18.4,
package `postgresql-18-citus-14.2`) with a coordinator and two workers:

```bash
docker network create citus-net
for n in coord w1 w2; do
  docker run -d --name citus-$n --network citus-net -e POSTGRES_HOST_AUTH_METHOD=trust \
    citusdata/citus:14.2.0 -c wal_level=logical      # trust: a local lab only
done
```

Register the nodes from the coordinator; workers must reach each other and the coordinator on their PostgreSQL port:

```sql
SELECT citus_set_coordinator_host('citus-coord', 5432);
SELECT citus_add_node('citus-w1', 5432);
SELECT citus_add_node('citus-w2', 5432);
SELECT nodename, nodeport, noderole FROM pg_dist_node;
```

On Debian and Ubuntu, the Citus repository script installs packages named `postgresql-<pg>-citus-<citus major.minor>`.
The lab trusts every connection on the Docker network. In production, nodes connect to each other as a real
role: use scram passwords in a `.pgpass` on every node, or certificates, with `hostssl` lines in `pg_hba.conf`.

## Distributed and reference tables

`create_distributed_table` turns an existing table into shards by a column; `colocate_with` puts tables with the same
key values on the same nodes. `create_reference_table` copies a table to every node. This schema ran on 18.4:

```sql
CREATE TABLE app.tenants  (id bigint PRIMARY KEY, name text NOT NULL);
CREATE TABLE app.projects (tenant_id bigint NOT NULL, id bigint GENERATED BY DEFAULT AS IDENTITY,
                           name text NOT NULL, PRIMARY KEY (tenant_id, id));
CREATE TABLE app.tasks    (tenant_id bigint NOT NULL, id bigint GENERATED BY DEFAULT AS IDENTITY,
                           project_id bigint NOT NULL, title text NOT NULL, done boolean NOT NULL DEFAULT false,
                           PRIMARY KEY (tenant_id, id),
                           FOREIGN KEY (tenant_id, project_id) REFERENCES app.projects (tenant_id, id));
CREATE TABLE app.countries (code text PRIMARY KEY, name text NOT NULL);

SELECT create_distributed_table('app.tenants',  'id');
SELECT create_distributed_table('app.projects', 'tenant_id', colocate_with => 'app.tenants');
SELECT create_distributed_table('app.tasks',    'tenant_id', colocate_with => 'app.projects');
SELECT create_reference_table('app.countries');
SELECT table_name, citus_table_type, distribution_column, colocation_id, shard_count FROM citus_tables;
```

All three distributed tables reported `colocation_id = 1` and 32 shards; the reference table one shard.

## Choosing the distribution column

The distribution column decides which queries stay on one node, so choose the column almost every query filters
and joins on.

- Multi-tenant apps: the tenant id (`tenant_id`, `account_id`, `company_id`), present in every table and every key.
- Analytics on events: the entity that groups most queries (`device_id`, `user_id`), not time; time-ordered keys put
  all current writes on one shard.
- High cardinality and even spread: thousands of distinct values or more; one giant tenant later gets its own shard.
- Never a column that changes: updating it fails with `modifying the partition value of rows is not allowed`.

## Which queries push down to one shard

A router query filters on one value of the distribution column and runs entirely on one worker; a multi-shard
query runs in parallel on all shards and merges on the coordinator. The plans below come from the cluster above:

```sql
-- router: "Task Count: 1", the join and aggregate run on one worker
EXPLAIN (COSTS OFF)
SELECT p.name, count(*) FROM app.projects p
JOIN app.tasks t ON t.tenant_id = p.tenant_id AND t.project_id = p.id
WHERE p.tenant_id = 42 GROUP BY p.name;

-- multi-shard: "Task Count: 32", partial aggregates per shard, final sort on the coordinator
EXPLAIN (COSTS OFF)
SELECT tenant_id, count(*) FROM app.tasks WHERE NOT done GROUP BY tenant_id ORDER BY 2 DESC LIMIT 5;
```

| Query shape | Result |
|---|---|
| `WHERE tenant_id = $1`, joins on `tenant_id` between colocated tables | router, single worker |
| no filter, joins on `tenant_id`, aggregates | parallel on all shards, merged on the coordinator |
| join of distributed tables on another column | `ERROR: the query contains a join that requires repartitioning` until `citus.enable_repartition_joins = on` (default off) |
| join of distributed with reference tables | pushed down, the reference copy is local everywhere |
| `SELECT ... FOR UPDATE`, recursive CTEs, grouping sets | only in single-shard queries |

## Keys, constraints and foreign keys on distributed tables

Uniqueness and foreign keys are checked inside one shard, so they must include the distribution column. 18.4 with
Citus 14.2 refused a global unique title:

```sql
ALTER TABLE app.tasks ADD CONSTRAINT tasks_title_key UNIQUE (title);
-- ERROR: cannot create constraint on "tasks"
-- DETAIL: Distributed relations cannot have UNIQUE, EXCLUDE, or PRIMARY KEY constraints that do not include the partition column ...
```

- Foreign keys between colocated distributed tables must include the distribution column.
- Distributed tables may reference reference tables (`country text REFERENCES app.countries (code)` worked).
- A distributed table referencing a plain local table fails: `referenced table "local_flags" must be a distributed
  table or a reference table`.
- Sequences used on distributed tables should be `bigint`: Citus encodes the node in generated values, which does not
  fit smaller types.

## Rebalancing shards after adding workers

Adding a worker does not move data; the rebalancer does, as a background job that copies shard groups with logical
replication so reads and writes continue. Every node needs `wal_level = logical` for the default transfer mode.
With `wal_level = replica`, our first run failed inside the job with `logical decoding requires "wal_level" >=
"logical"` while `citus_rebalance_wait()` kept waiting. These commands add a worker and rebalance onto it:

```sql
SELECT citus_add_node('citus-w2', 5432);
SELECT count(*) FROM get_rebalance_table_shards_plan();   -- 45 shard moves planned
SELECT citus_rebalance_start();                           -- NOTICE: Scheduled 15 moves as job 2
SELECT citus_rebalance_wait();
SELECT state FROM citus_rebalance_status();               -- finished
SELECT nodename, count(*) FROM citus_shards GROUP BY 1;   -- w1: 52, w2: 46, coordinator: 1 (reference copies)
```

The 45 shard moves were 15 moves of colocated groups: colocated shards always move together. To empty a node before
removing it, run `citus_drain_node('citus-w2', 5432)`; stop a running rebalance with `citus_rebalance_stop()`.

## Tenant isolation and tenant statistics

`isolate_tenant_to_new_shard` splits one tenant's rows into its own shard, with its colocated tables when
`cascade_option => 'CASCADE'`; the shard can then be moved to a dedicated node.

```sql
SELECT isolate_tenant_to_new_shard('app.tenants', 42, cascade_option => 'CASCADE',
                                   shard_transfer_mode => 'force_logical');
-- app.tasks went from 32 to 34 shards: the hash range around tenant 42 was split in three
```

`citus_stat_tenants` shows query counts and CPU per tenant for router queries. It stayed empty until
`citus.stat_tenants_track = 'all'` was set on every node (setting it only on the coordinator was not enough):

```sql
ALTER SYSTEM SET citus.stat_tenants_track = 'all';   -- run on the coordinator and on each worker
SELECT pg_reload_conf();
SELECT tenant_attribute, query_count_in_this_period FROM citus_stat_tenants ORDER BY 2 DESC LIMIT 10;
```

## Schema-based sharding for schema-per-tenant apps

Schema-based sharding (Citus 12 and later) makes each schema its own shard group, so a schema-per-tenant app scales
out without adding a `tenant_id` column. New schemas are distributed while `citus.enable_schema_based_sharding` is
on; existing ones with `citus_schema_distribute`.

```sql
SET citus.enable_schema_based_sharding = on;
CREATE SCHEMA tenant_acme;                         -- distributed: tables created in it become schema tables
RESET citus.enable_schema_based_sharding;
CREATE TABLE tenant_acme.invoices (id bigint PRIMARY KEY, total numeric NOT NULL);
SELECT citus_schema_distribute('tenant_globex');   -- an existing schema
SELECT schema_name, colocation_id FROM citus_schemas;
```

Foreign keys across distributed schemas are not supported, and the docs suggest it for roughly 1 to 10,000 tenants
against 1 million and more for row-based sharding.

## Distributing a live table

`create_distributed_table_concurrently` distributes a table that already has data without blocking writes for the
copy (5,000 rows in our test, with `wal_level = logical` on every node). `undistribute_table` turns a table back into a local one, and `alter_distributed_table`
changes the distribution column or shard count by rewriting.

## Verify a Citus design with EXPLAIN and shard placement

Prove the design from the query side, on a staging cluster with realistic data.

```sql
EXPLAIN (COSTS OFF) SELECT count(*) FROM app.tasks WHERE tenant_id = 42;     -- expect Task Count: 1
SELECT table_name, citus_table_type, colocation_id FROM citus_tables;        -- large tables share one colocation_id
SELECT nodename, count(*), pg_size_pretty(sum(shard_size)) FROM citus_shards GROUP BY 1;  -- placement is even
SELECT count(*) FROM get_rebalance_table_shards_plan();                      -- 0 once balanced
```

Run one rebalance under write traffic in staging, and check that the application sees no errors while shards move.

## Gotchas

These are the failures seen most often with Citus, each with its cause and fix.

1. **The rebalance job never finishes.** `wal_level` is not `logical` on some node; the task error is in
   `pg_dist_background_task.message`. Set it everywhere, restart, `citus_rebalance_stop()` and start again.
2. **`the query contains a join that requires repartitioning`.** Two distributed tables joined on a non-distribution
   column. Add the distribution column to the join, make one side a reference table, or enable repartition joins
   for that session.
3. **`cannot create constraint`.** A unique key without the distribution column. Add it to the key.
4. **One worker is hot.** One tenant dominates a shard. Isolate it with `isolate_tenant_to_new_shard` and move it.
5. **`citus_stat_tenants` is empty.** Tracking is on only on the coordinator. Set it on every node.
6. **Single-tenant queries are slow anyway.** They do not filter on the distribution column, so they fan out to all
   32 shards. Check `Task Count` in `EXPLAIN`.

## Checklist

Check these points before you call a Citus design ready.

- [ ] Sharding is justified against replicas, partitioning and a bigger server.
- [ ] Every large table is distributed by the same column and colocated; small shared tables are reference tables.
- [ ] Every hot query filters on the distribution column; `EXPLAIN` shows `Task Count: 1` for tenant queries.
- [ ] Primary keys, unique constraints and foreign keys include the distribution column.
- [ ] `wal_level = logical` on every node; a rebalance has been run in staging.
- [ ] Each node has an HA plan and backups (`references/citus-operations.md`).

## Anti-patterns in Citus sharding

| Do not | Do this instead |
|---|---|
| shard before trying replicas, partitioning and tuning | shard when one server cannot hold the work |
| distribute by a time column | the tenant or entity id |
| leave a large table local beside distributed ones | distribute it by the same column and colocate it |
| distribute small lookup tables | reference tables |
| run hot queries with no filter on the distribution column | add the column to the query and the join |
| enable repartition joins as a default | fix the join key; use them for one report |

## See also

- `postgres-multitenancy`: row, schema and database per tenant.
- `postgres-partitioning`: splitting a table on one server.
- `postgres-replication-ha`: read replicas and failover.
- `postgres-query-performance`: plans on each shard.
- `postgres-fdw-federation`: a lighter foreign-partition layer.

## Sources

- https://docs.citusdata.com/en/stable/get_started/concepts.html
- https://docs.citusdata.com/en/stable/sharding/data_modeling.html
- https://docs.citusdata.com/en/stable/develop/api_udf.html
- https://docs.citusdata.com/en/stable/develop/api_guc.html
- https://docs.citusdata.com/en/stable/admin_guide/cluster_management.html
- https://docs.citusdata.com/en/stable/develop/reference_workarounds.html
- https://github.com/citusdata/citus/blob/main/CHANGELOG.md (14.0.0, 14.3.0, 13.5.0)
