---
title: Operating a Citus cluster
author: MOZGII, Inc.
lang: en
---

# Operating a Citus cluster

This reference covers running Citus in production: high availability for the coordinator and each worker, backups
and consistent restore points, connection limits between nodes, Citus and PostgreSQL upgrades, and monitoring.
Facts come from the Citus and Patroni documentation and from a three-node Citus 14.2 cluster on PostgreSQL 18.4.

## High availability for every Citus node

Citus does not replicate shards for availability by default; each node (the coordinator and every worker) is a
normal PostgreSQL primary that needs its own streaming replicas and failover. Losing a worker without a replica makes
its shards unavailable, so plan HA per node group.

Patroni manages Citus clusters directly: each node group runs as a Patroni cluster with a `citus` section, and the
coordinator's Patroni keeps `pg_dist_node` pointing at each group's current primary after failover or switchover.
Each node's `patroni.yml` carries this section:

```yaml
# part of patroni.yml on every node of one group
citus:
  group: 0            # 0 for the coordinator group, 1, 2, ... for worker groups
  database: app       # the one database with the citus extension, the same on all nodes
```

- Superuser credentials must be the same on the coordinator and all workers, and the REST API must be reachable from
  worker nodes to the coordinator (Patroni's Citus page).
- The Patroni docs recommend at least Citus 11.2 for transparent switchovers and restarts of workers.
- On Kubernetes, use an operator that supports Citus, or Patroni on Kubernetes with the same `citus` section.
- Patroni itself: `postgres-patroni-ha`.

## Backups and consistent restore points across nodes

Each node is backed up with the usual tools (pgBackRest or base backups plus WAL archiving, `postgres-backup-restore`),
but restoring nodes to independent points in time can break cross-node consistency. `citus_create_restore_point`
briefly blocks writes and creates the same named restore point on every node:

```sql
SELECT citus_create_restore_point('before-migration-2026-10-28');
```

To restore the whole cluster, recover every node to that restore point name (`recovery_target_name`), then start
them together. Schedule a restore point regularly (for example hourly) so there is always a recent consistent target.

## Connections between nodes

Every multi-shard query opens connections from the coordinator to workers, so connection limits matter on workers.
These settings were read on Citus 14.2:

| Setting | Value on our cluster | Meaning |
|---|---|---|
| `citus.shard_count` | 32 | shards for new hash-distributed tables |
| `citus.max_adaptive_executor_pool_size` | 16 | connections one query may open per worker |
| `citus.max_shared_pool_size` | 100 (by default the coordinator's own `max_connections`; -1 disables throttling) | connections the coordinator may hold per worker across all sessions |
| `citus.max_client_connections` | -1 (no limit) | client connections per node, excluding internal ones |
| `citus.enable_repartition_joins` | off | allow joins that reshuffle rows between workers |
| `citus.local_hostname` | localhost | the address a node uses to connect to itself |

Put PgBouncer in front of the coordinator for application connections, and keep `citus.max_shared_pool_size`
below the workers' `max_connections` minus their own administrative headroom.

## Upgrading Citus

Citus minor and major versions are separate packages (`postgresql-18-citus-14.2`, `postgresql-18-citus-14.3`).
Per the Citus upgrade guide, on every node: install the new package, restart PostgreSQL, then update the extension.

```sql
ALTER EXTENSION citus UPDATE;
SELECT citus_version();
CALL citus_finish_citus_upgrade();       -- on the coordinator, for upgrades to Citus 11.x and later
```

From the moment the new package is installed until the restart and `ALTER EXTENSION`, Citus refuses distributed
queries, so roll it through one node at a time with replicas or in a maintenance window. Read the Citus changelog
for every version you skip.

## Upgrading PostgreSQL under Citus

Upgrade Citus first, then PostgreSQL, never both at once. The Citus guide wraps `pg_upgrade` on every node with two
functions:

```sql
SELECT citus_prepare_pg_upgrade();       -- on the coordinator and every worker, before pg_upgrade
-- stop, run pg_upgrade on each node (postgres-zero-downtime-upgrades), start
SELECT citus_finish_pg_upgrade();        -- on the coordinator and every worker, after
```

Back up the coordinator's Citus metadata before starting. Citus 14 runs on PostgreSQL 16 to 18, so a cluster on 15
must first move to Citus 13.x on 16 or 17 before it can reach Citus 14 and PostgreSQL 18.

## Monitoring a Citus cluster

These queries on the coordinator show placement, size and background work.

```sql
SELECT nodename, count(*) AS shards, pg_size_pretty(sum(shard_size)) AS size
FROM citus_shards GROUP BY 1 ORDER BY 1;                                  -- balance per node
SELECT table_name, citus_table_type, distribution_column, shard_count FROM citus_tables;
SELECT job_id, state FROM pg_dist_background_job ORDER BY job_id DESC LIMIT 5;
SELECT task_id, status, message FROM pg_dist_background_task WHERE status NOT IN ('done', 'cancelled') ORDER BY task_id;
SELECT * FROM citus_check_cluster_node_health();                          -- every node can reach every node
```

A rebalance task that cannot run stays `runnable` and records its error in `message`; in our test that was
`logical decoding requires "wal_level" >= "logical"`, raised on the coordinator while copying a reference table to
the new worker.

## Sources

- https://docs.citusdata.com/en/stable/admin_guide/upgrading_citus.html
- https://docs.citusdata.com/en/stable/admin_guide/cluster_management.html
- https://docs.citusdata.com/en/stable/develop/api_udf.html (`citus_create_restore_point`)
- https://docs.citusdata.com/en/stable/develop/api_guc.html
- https://patroni.readthedocs.io/en/latest/citus.html
- https://patroni.readthedocs.io/en/latest/yaml_configuration.html (`citus` section)
