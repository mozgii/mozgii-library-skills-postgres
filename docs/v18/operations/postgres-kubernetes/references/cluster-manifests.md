---
title: CloudNativePG manifests for a production PostgreSQL cluster
author: MOZGII, Inc.
lang: en
---

# CloudNativePG manifests for a production PostgreSQL cluster

This reference holds a complete, consistent set of manifests for one production cluster named `pg-main` in
namespace `db`: credentials, object store, the `Cluster`, scheduled backups, a `Pooler`, a `PodMonitor`, a
declarative `Database`, and a point-in-time restore. Every resource was validated field by field against the CRD
schemas of CloudNativePG 1.30.1 and the Barman Cloud plugin 0.15.1; none was applied to a running cluster, so run
`kubectl apply --dry-run=server` against yours first.

## Contents

The manifests, in apply order:

- Secrets for the application owner and the object store
- ObjectStore for backups and WAL
- Cluster
- ScheduledBackup
- Pooler for the application
- PodMonitor for Prometheus
- Database with extensions
- Point-in-time restore into a new cluster
- Commands to check the result

## Secrets for the application owner and the object store

The application owner's password and the object store keys come from Secrets you create (from your secret manager,
never committed). `kubernetes.io/basic-auth` is the type CNPG expects for `bootstrap.initdb.secret`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pg-main-app-owner
  namespace: db
type: kubernetes.io/basic-auth
stringData:
  username: app
  password: change-me-from-your-secret-manager
---
apiVersion: v1
kind: Secret
metadata:
  name: pg-backup-s3
  namespace: db
stringData:
  ACCESS_KEY_ID: change-me
  ACCESS_SECRET_KEY: change-me
```

On AWS, prefer IAM roles for service accounts (`s3Credentials.inheritFromIAMRole: true`) over static keys.

## ObjectStore for backups and WAL

The `ObjectStore` resource of the Barman Cloud plugin names the bucket, the credentials, compression and retention.

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: pg-main-store
  namespace: db
spec:
  retentionPolicy: "30d"
  configuration:
    destinationPath: s3://acme-pg-backups/pg-main
    s3Credentials:
      accessKeyId:
        name: pg-backup-s3
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: pg-backup-s3
        key: ACCESS_SECRET_KEY
    wal:
      compression: gzip
      maxParallel: 4
    data:
      compression: gzip
      jobs: 2
```

Leave `serverName` out of the `ObjectStore`: the plugin keeps it only for compatibility, and the cluster's own
`serverName` parameter is the place to set it.

## Cluster

The `Cluster` resource runs three instances spread across zones, with separate WAL storage, pinned image, managed
configuration and WAL archiving through the plugin.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main
  namespace: db
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie
  primaryUpdateStrategy: unsupervised
  primaryUpdateMethod: switchover
  failoverDelay: 0
  switchoverDelay: 300
  enablePDB: true

  storage:
    storageClass: fast-ssd
    size: 200Gi
  walStorage:
    storageClass: fast-ssd
    size: 50Gi

  resources:
    requests:
      cpu: "4"
      memory: 16Gi
    limits:
      cpu: "4"
      memory: 16Gi

  postgresql:
    parameters:
      shared_buffers: 4GB
      effective_cache_size: 12GB
      max_connections: "200"
      work_mem: 32MB
      maintenance_work_mem: 1GB
      max_wal_size: 8GB
      log_min_duration_statement: 1s
    shared_preload_libraries:
      - pg_stat_statements
    pg_hba:
      - hostssl app app 10.0.0.0/8 scram-sha-256
    synchronous:
      method: any
      number: 1
      dataDurability: preferred

  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: pg-main-app-owner
      localeProvider: builtin
      builtinLocale: C.UTF-8
      dataChecksums: true

  affinity:
    enablePodAntiAffinity: true
    topologyKey: topology.kubernetes.io/zone
    podAntiAffinityType: required
    nodeSelector:
      node-role.kubernetes.io/postgres: ""
    tolerations:
      - key: node-role.kubernetes.io/postgres
        operator: Exists
        effect: NoSchedule

  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: pg-main-store
        serverName: pg-main
```

- Requests equal to limits for CPU and memory give the pods the Guaranteed QoS class, which CNPG recommends; with
  it CNPG sets `PG_OOM_ADJUST_VALUE=0`, so the OOM killer picks backends before the postmaster.
- `synchronous` with `dataDurability: preferred` lets writes continue when no standby answers; `required` stops
  writes instead. The trade-off is in `postgres-replication-ha`.
- The webhook refuses operator-owned settings in `parameters` (`port`, `listen_addresses`, `archive_command`,
  `archive_mode`, `cluster_name`, `log_destination`, `primary_conninfo` and others), and values must be strings.

## ScheduledBackup

A `ScheduledBackup` takes a base backup through the plugin on a six-field cron schedule (seconds first).

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: pg-main-daily
  namespace: db
spec:
  schedule: "0 0 2 * * *"
  backupOwnerReference: self
  immediate: true
  cluster:
    name: pg-main
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

`immediate: true` takes the first backup as soon as the resource exists. `spec.cluster` cannot be changed later;
create another `ScheduledBackup` for another cluster.

## Pooler for the application

A `Pooler` runs PgBouncer in front of the primary; applications connect to the service `pg-main-pooler-rw`.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: pg-main-pooler-rw
  namespace: db
spec:
  cluster:
    name: pg-main
  instances: 3
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "2000"
      default_pool_size: "25"
```

## PodMonitor for Prometheus

The Prometheus Operator scrapes the `metrics` port (9187) of every instance through this `PodMonitor`; the
`cnpg.io/cluster` label selects the cluster's pods.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: pg-main
  namespace: db
spec:
  selector:
    matchLabels:
      cnpg.io/cluster: pg-main
  podMetricsEndpoints:
    - port: metrics
```

## Database with extensions

The `Database` resource declares a database and the extensions in it, so `CREATE EXTENSION` and updates are part of
the manifests instead of a manual step.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: pg-main-app
  namespace: db
spec:
  name: app
  owner: app
  cluster:
    name: pg-main
  extensions:
    - name: vector
      ensure: present
    - name: pg_stat_statements
      ensure: present
```

`vector` is available because the `standard` image carries pgvector; with a `minimal` image, add it as an image
volume under `spec.postgresql.extensions` first.

## Point-in-time restore into a new cluster

A restore creates a new cluster that replays base backup and WAL from the object store up to the target; the
original keeps running.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main-restore
  namespace: db
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie
  storage:
    storageClass: fast-ssd
    size: 200Gi
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "2026-10-28T09:55:00Z"
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-main-store
          serverName: pg-main
```

Check the data, then either copy what you need back into `pg-main` (for one deleted table) or move the application
to `pg-main-restore` and give it its own `plugins` entry with a new `serverName` before it archives.

## Commands to check the result

These `kubectl` and `kubectl cnpg` commands show whether the cluster, archiving and backups are healthy.

```bash
kubectl apply --dry-run=server -f pg-main.yaml          # schema and admission checks, nothing created
kubectl cnpg status pg-main -n db                        # instances, replication, WAL archiving, last backup
kubectl get backups -n db                                # each Backup with its phase
kubectl cnpg psql pg-main -n db -- -c "select now() - pg_last_xact_replay_timestamp()"
kubectl get secret pg-main-app -n db -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'   # key names only
```

The last command lists the keys of the application Secret without showing a value. Read `uri` into your application
through `secretKeyRef`; printing it puts the password in your terminal history and logs.
