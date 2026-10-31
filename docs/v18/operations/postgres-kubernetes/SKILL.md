---
name: postgres-kubernetes
description: 'Runs PostgreSQL on Kubernetes with an operator, CloudNativePG first: installing the operator, a production Cluster resource (images, storage classes, WAL volumes, resources, anti-affinity across nodes and zones), backups to object storage with the Barman Cloud plugin, scheduled backups, point-in-time recovery, failover and switchover, rolling updates, the Pooler for PgBouncer, Prometheus monitoring, extensions as image volumes, and in-place major upgrades; Crunchy PGO and the Zalando operator compared; when not to run Postgres on Kubernetes. Use when someone deploys Postgres to Kubernetes, writes a CloudNativePG Cluster YAML, sets up backups or PITR on k8s, or asks which Postgres operator to pick.'
metadata:
  tags:
  - postgres
  - kubernetes
  - cloudnativepg
  - operator
  - barman-cloud
  - high-availability
  - pitr
---

# PostgreSQL on Kubernetes with CloudNativePG

Run PostgreSQL on Kubernetes only through an operator, never a hand-written StatefulSet: failover, replica rebuilds,
backups and upgrades are the operator's job. CloudNativePG (CNPG) 1.30 is the default choice in October 2026; it
manages failover itself without Patroni or StatefulSets, and backs up through the Barman Cloud plugin. The CRD fields here were
checked against the CNPG 1.30.1 API reference and the Barman Cloud plugin 0.15.1 docs; no Kubernetes cluster was
created for this skill. Complete manifests are in [references/cluster-manifests.md](references/cluster-manifests.md).
Replication concepts are in `postgres-replication-ha`, PgBouncer settings in `postgres-connection-pooling`.


## Step 0: read the cluster, operator and storage you already have

Supported combinations change with each CNPG minor, so read the versions before writing a manifest.

```bash
kubectl version
kubectl get deployment -n cnpg-system cnpg-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'      # the operator version in its image tag
kubectl get crd clusters.postgresql.cnpg.io objectstores.barmancloud.cnpg.io
kubectl get storageclass                                             # VOLUMEBINDINGMODE, ALLOWVOLUMEEXPANSION
kubectl get clusters.postgresql.cnpg.io -A
```

No operator found means a fresh install. Check the rest against the supported versions under the operator comparison.

## When not to run Postgres on Kubernetes

Kubernetes puts a scheduler, a storage layer and an operator between you and the database; that pays off only
when the team already runs Kubernetes well.

| Situation | Better choice |
|---|---|
| No one on the team operates Kubernetes storage and upgrades day to day | a managed service (`postgres-operations`) |
| Only network storage with high latency or no snapshot support | VMs with local NVMe, or a managed service |
| One small database for one app | a managed service or a VM; an operator is overhead |
| You need superuser-level OS tuning (huge pages, kernel settings per node) and cannot dedicate nodes | VMs (`postgres-os-kernel-tuning`) |
| Many databases, GitOps already in place, a platform team | CNPG, with dedicated nodes and local or fast block storage |

## Operators compared: CloudNativePG, Crunchy PGO, Zalando

All three run streaming replication with automated failover; they differ in how and in what they ship.

| | CloudNativePG 1.30.1 | Crunchy PGO 6.0.3 | Zalando postgres-operator 2.0.3 |
|---|---|---|---|
| Resource | `Cluster` (`postgresql.cnpg.io/v1`) | `PostgresCluster` (`postgres-operator.crunchydata.com/v1beta1`; `v1` also served in 6.0) | `postgresql` (`acid.zalan.do/v1`) |
| Failover | the operator and its instance manager, no external tool | Patroni 4.1 | Patroni, in the Spilo image |
| Backups | Barman Cloud plugin, volume snapshots | pgBackRest | WAL-G (or WAL-E) through Spilo |
| Images | `ghcr.io/cloudnative-pg/postgresql`, minimal and standard | Crunchy's images, under the Crunchy Data Developer Program terms | Spilo; default image `spilo-18:4.1-p2` in 2.0.3 |
| PostgreSQL | 14 to 18 | 14 to 18 | 14 to 18 |
| Licence | Apache 2.0, CNCF project | operator Apache 2.0; images under Crunchy's terms | MIT |

CNPG 1.30.x supports Kubernetes 1.34, 1.35 and 1.36. The release-1.30 branch gives it end of life about March 2027
and plans 1.31.0 for about December 2026; plan the move to 1.31 with those dates in mind.

## Installing the operator and the plugin

The operator installs from one manifest, applied server-side as the CNPG docs do. The Barman Cloud plugin needs
CNPG 1.26 or newer and cert-manager.

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.1.yaml
kubectl rollout status deployment -n cnpg-system cnpg-controller-manager
# cert-manager must be running before the plugin:
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.1/manifest.yaml
```

The `kubectl cnpg` plugin adds `status`, `promote`, `backup`, `psql`, `restart`, `reload`, `maintenance`, `fio`
and `pgbench`.

## A production Cluster resource

The `Cluster` resource declares the whole database: image, instance count, storage, configuration, placement and
backups. This is the core of a three-instance production cluster; the full file with every companion resource is in
[references/cluster-manifests.md](references/cluster-manifests.md).

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie
  primaryUpdateStrategy: unsupervised
  primaryUpdateMethod: switchover
  storage:
    storageClass: fast-ssd
    size: 200Gi
  walStorage:
    storageClass: fast-ssd
    size: 50Gi
  resources:
    requests: {cpu: "4", memory: 16Gi}
    limits: {cpu: "4", memory: 16Gi}       # Guaranteed QoS, as CNPG recommends
  postgresql:
    parameters:
      shared_buffers: 4GB
      max_connections: "200"
    shared_preload_libraries: [pg_stat_statements]
  bootstrap:
    initdb:
      database: app
      owner: app
      localeProvider: builtin
      builtinLocale: C.UTF-8
  affinity:
    enablePodAntiAffinity: true
    topologyKey: topology.kubernetes.io/zone
    podAntiAffinityType: required
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: pg-main-store
      serverName: pg-main
```

- Pin the image to a full tag (or a digest). The operator's default is `18.6-system-trixie`; the `system` images are
  deprecated, and with the Barman Cloud plugin `standard` (pgaudit, pgvector, failover slots, all locales, JIT) or
  `minimal` is the replacement.
- The operator creates services `pg-main-rw` (primary), `pg-main-ro` (replicas) and `pg-main-r` (any instance), and
  the secret `pg-main-app` with `username`, `password`, `uri`, `jdbc-uri` and a `.pgpass` entry for the app.
- Data checksums are on by default from PostgreSQL 18 (`bootstrap.initdb.dataChecksums`).
- `ALTER SYSTEM` is off unless `postgresql.enableAlterSystem` is true; set parameters (as strings) in the manifest.

## Storage classes, volume expansion and WAL volumes

CNPG creates one PersistentVolumeClaim per instance (plus one for WAL with `walStorage`) from the storage class.

- CNPG recommends local or dedicated storage per node: a shared-nothing layout suits high availability, and
  PostgreSQL replication already keeps the copies.
- `size` can grow but never shrink; growth needs a class with `allowVolumeExpansion: true`.
- A separate `walStorage` volume keeps a full WAL disk from filling the data volume and gives WAL its own I/O. It
  cannot be removed once added.
- Use a class with `volumeBindingMode: WaitForFirstConsumer` with local volumes so the claim follows the pod's node.

## Scheduling: anti-affinity, zones and dedicated nodes

Anti-affinity keeps instances of one cluster off the same node (`topologyKey: kubernetes.io/hostname`, the default)
or zone (`topology.kubernetes.io/zone`). `podAntiAffinityType: preferred` (the default) lets two instances share a
node when no other fits; `required` leaves a pod pending instead, which is what you want for a real HA promise. To
reserve nodes for Postgres, label and taint them `node-role.kubernetes.io/postgres` and add the matching
`affinity.nodeSelector` and `affinity.tolerations`. The PodDisruptionBudget (`enablePDB`, default true) protects the
primary during node drains.

## Backups to object storage with the Barman Cloud plugin

This plugin archives WAL continuously and stores base backups in S3, Azure Blob or Google Cloud Storage;
the in-tree `barmanObjectStore` method is deprecated since CNPG 1.26, and native Barman support is removed from 1.32,
so migrate before that upgrade. An `ObjectStore` resource holds the destination and credentials, the `Cluster` references it under `plugins`, and a `ScheduledBackup` takes base backups.

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: pg-main-store
spec:
  retentionPolicy: "30d"
  configuration:
    destinationPath: s3://acme-pg-backups/pg-main
    s3Credentials:
      accessKeyId: {name: pg-backup-s3, key: ACCESS_KEY_ID}
      secretAccessKey: {name: pg-backup-s3, key: ACCESS_SECRET_KEY}
    wal:
      compression: gzip
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: pg-main-daily
spec:
  schedule: "0 0 2 * * *"          # six fields, seconds first: 02:00:00 every day
  backupOwnerReference: self
  cluster:
    name: pg-main
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

`kubectl cnpg backup pg-main --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io` takes one now. Restore
drills are the only proof a backup works (`postgres-backup-restore`).

## Point-in-time recovery into a new cluster

Recovery in CNPG always creates a new `Cluster` that bootstraps from the object store; the source keeps running. The
`recoveryTarget` takes one of `targetTime`, `targetLSN`, `targetName`, `targetXID` or `targetImmediate`.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main-restore
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie
  storage: {storageClass: fast-ssd, size: 200Gi}
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

The restored cluster does not archive WAL until you add its own `plugins` entry. Point it at a different
`ObjectStore` or `serverName`: CNPG refuses to archive into a non-empty archive (`Expected empty archive`).

## Failover, switchover and rolling updates

When the primary fails, CNPG promotes the most advanced replica after `failoverDelay` (default 0 seconds) and points
the `-rw` service at it. A planned switchover (`kubectl cnpg promote pg-main pg-main-2`) shuts the old primary down
within `switchoverDelay` (default 3600 seconds). Image or configuration changes roll through replicas first; then
`primaryUpdateStrategy` decides whether the operator continues on its own (`unsupervised`, the default) or waits for
you (`supervised`), and `primaryUpdateMethod` decides between restarting the primary in place (`restart`, the
default) and switching over to an updated replica first (`switchover`). With `switchover`, change the image and the
parameters in two separate steps: the operator rejects both at once.

## Connection pooling with the Pooler resource

The `Pooler` resource runs PgBouncer pods in front of the `-rw` (or `-ro`) service, with their own Deployment and
Service named after the Pooler: `spec.cluster.name`, `instances`, `type: rw`, and under `pgbouncer` the `poolMode` and
string `parameters` such as `max_client_conn` and `default_pool_size`. The manifest is in
[references/cluster-manifests.md](references/cluster-manifests.md).

Transaction mode breaks session features (session advisory locks, `LISTEN`, `SET` without `LOCAL`); keep a direct
`-rw` connection for migrations and listeners.

## Monitoring with Prometheus

Each instance exposes Prometheus metrics on port 9187 (named `metrics`), with default queries plus your own from a
ConfigMap or Secret (`monitoring.customQueriesConfigMap`). `monitoring.enablePodMonitor` is deprecated; create a
`PodMonitor` yourself that selects `cnpg.io/cluster: pg-main` (example in the reference). `kubectl cnpg status
pg-main` shows replication, WAL archiving and backups at a glance.

## Extensions as image volumes

With PostgreSQL 18's `extension_control_path`, CNPG mounts an extension's files from its own OCI image instead of
baking them into the PostgreSQL image (Kubernetes 1.35 enables `ImageVolume` by default; 1.33 and 1.34 need the
feature gate):

```yaml
  postgresql:
    extensions:
    - name: pgvector
      image:
        reference: ghcr.io/cloudnative-pg/pgvector:0.8.7-18-trixie
```

Then `CREATE EXTENSION vector;`, or declare it on a `Database` resource (`spec.extensions`). Installing extensions in
general is `postgres-extensions-install`.

## Major version upgrades

Changing `imageName` (or the image catalog's major) to a higher major triggers an offline in-place upgrade: CNPG stops
every pod, runs `pg_upgrade --link` in a job, and starts the cluster on the new major. The whole cluster, replicas
included, is down meanwhile, and replicas are cloned again afterwards. Take a backup first, and keep the same OS base
(a `bookworm` image cannot upgrade to `trixie`).

`pg_upgrade` creates a new system identifier and resets the timeline to 1, and the Barman Cloud plugin does not
separate archives by itself. Change `serverName` in the same edit as `imageName`, so the old archive stays whole and
new WAL goes to its own path:

```yaml
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: pg-main-store
      serverName: pg-main-pg18                  # was pg-main
```

Point-in-time recovery cannot cross the upgrade, so start a fresh base backup the moment it finishes.

For near-zero downtime, build a new 18 cluster and replicate into it: bootstrap it with `bootstrap.initdb.import` and
`schemaOnly: true`, add a `Subscription` resource, copy sequences with `kubectl cnpg subscription sync-sequences` at
cutover, then switch the application. `bootstrap.initdb.import` on its own is one `pg_dump -Fd` plus `pg_restore`
from a snapshot of the source: anything written after that snapshot stays behind, so use it alone only for a move
that can stop writes.

## Verify a Cluster before and after applying it

The first command checks a manifest against the live API without creating anything; the others prove the running
cluster. They were not run for this skill, which had no Kubernetes cluster.

```bash
kubectl apply --dry-run=server -f pg-main.yaml
kubectl cnpg status pg-main                       # instances, replication, WAL archiving, last backup
kubectl get clusters.postgresql.cnpg.io pg-main -o jsonpath='{.status.phase}{"\n"}'   # Cluster in healthy state
kubectl get backups                               # each Backup with its phase
kubectl cnpg psql pg-main -- -c "select pg_is_in_recovery(), now() - pg_last_xact_replay_timestamp() AS replay_lag"
```

Then run the drill that matters: restore into a new cluster, as in the point-in-time section, and read a known row.
A backup that was never restored proves nothing.

## Gotchas

These are the failures seen most often with Postgres on Kubernetes, each with its cause and fix.

1. **The operator manifest fails to apply.** Use `kubectl apply --server-side`, as the installation docs do.
2. **Two instances landed on one node and both died with it.** `podAntiAffinityType` was `preferred`; set
   `required` and provide enough nodes.
3. **The scheduled backup runs at the wrong time or never.** `ScheduledBackup.schedule` has six fields with seconds
   first; `0 2 * * *` is not "02:00 daily".
4. **A restored cluster hangs in `Setting up primary` with `Expected empty archive`.** It would archive into a
   `serverName` that already holds WAL; give it its own `serverName` or `ObjectStore` path.
5. **`ALTER SYSTEM` fails.** CNPG disables it by default; put parameters in `spec.postgresql.parameters`.
6. **The volume cannot grow.** The storage class lacks `allowVolumeExpansion`; sizes never shrink.
7. **A rollout was rejected with `primaryUpdateMethod: switchover`.** Image and parameters changed together; apply
   them one after the other.
8. **Pods stay Pending after a node failure.** `required` anti-affinity with no spare node; add capacity or accept
   fewer instances temporarily.
9. **The archive holds WAL and backups from two majors after an upgrade.** `serverName` stayed the same.
   Change it together with `imageName`, then take a new base backup.
10. **Rows are missing after a move with `bootstrap.initdb.import`.** They arrived after the `pg_dump` snapshot. Stop
    writes first, or replicate with a `Subscription`.

## Anti-patterns for Postgres on Kubernetes

Each of these looks fine until the first failover or restore.

| Do not | Do instead |
|---|---|
| Write your own StatefulSet for Postgres | Run an operator; failover, replica rebuilds and upgrades are its job |
| Pin `latest` or a major tag such as `18` | Pin a full tag or digest, so a pod restart cannot change the version |
| Keep backups only in volume snapshots on the same storage system | Archive WAL and base backups to object storage in another failure domain |
| Reuse one `serverName` across a restore or a major upgrade | Give each restored cluster and each major its own `serverName` |
| Run migrations through the transaction-mode Pooler | Connect migrations and listeners directly to `-rw` |
| Change settings with `ALTER SYSTEM` in a pod | Put them in `spec.postgresql.parameters`, so the manifest stays the truth |

## Checklist

Check these points before you call a Kubernetes Postgres cluster production-ready.

- [ ] CNPG 1.30.x on a supported Kubernetes (1.34 to 1.36), installed server-side.
- [ ] Image pinned to a `standard` or `minimal` tag or digest, not the deprecated `system` default.
- [ ] Three instances with `required` anti-affinity across nodes or zones; PDB enabled.
- [ ] Fast storage class with volume expansion; separate `walStorage`.
- [ ] Barman Cloud plugin archiving WAL, a `ScheduledBackup` with a six-field schedule, a retention policy, and a
      restore drill into a new cluster that passed.
- [ ] Applications use the `-rw` service or a Pooler; migrations use a direct connection.
- [ ] Metrics scraped from port 9187 with your own `PodMonitor`; alerts on archiving and replication lag.

## See also

Related skills in this library, each one works on its own:

- `postgres-replication-ha`: streaming replication, slots and synchronous commit.
- `postgres-connection-pooling`: PgBouncer settings behind the Pooler.
- `postgres-backup-restore`: backup strategy and restore drills.
- `postgres-zero-downtime-upgrades`: logical replication cutovers.
- `postgres-extensions-install`: installing extensions in general.
- `postgres-docker`: single containers for development.
- `postgres-patroni-ha`: high availability on VMs and bare metal.

## Sources

- CloudNativePG 1.30.1 docs (`docs/src` at tag v1.30.1): `cloudnative-pg.v1` API reference, installation_upgrade,
  backup, recovery, failover, rolling_update, connection_pooling, monitoring, storage, scheduling,
  service_management, applications, imagevolume_extensions, postgres_upgrades, database_import,
  logical_replication, kubectl-plugin, supported_releases, faq;
  `pkg/versions/versions.go` (default image); cloudnative-pg/postgres-containers README (image flavours).
- Barman Cloud plugin v0.15.1 docs: usage, installation, retention, object stores.
- GitHub releases and tags (October 2026): cloudnative-pg 1.30.1, plugin-barman-cloud 0.15.1,
  CrunchyData/postgres-operator v6.0.3 (CRD versions) with the PGO 6.0.x release notes on access.crunchydata.com,
  zalando/postgres-operator 2.0.3 (README, minimal manifest, licence).
- kubernetes.io: volumes (local volumes and `WaitForFirstConsumer`).
- ghcr.io registry: tags `cloudnative-pg/postgresql:18.6-standard-trixie`, `cloudnative-pg/pgvector:0.8.7-18-trixie`.
- Manifests in the reference were validated against the CRD schemas shipped in `cnpg-1.30.1.yaml` and the plugin's
  manifest; they were not applied to a cluster.
