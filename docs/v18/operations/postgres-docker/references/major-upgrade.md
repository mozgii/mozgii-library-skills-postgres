---
title: Upgrading a PostgreSQL container to a new major version
author: MOZGII, Inc.
lang: en
---

# Upgrading a PostgreSQL container to a new major version

This reference moves a database that runs in the official `postgres` image from one major version to the next
(17 to 18 in the examples). Changing the image tag alone never upgrades the data: an 18 container refuses a 17 data
directory. Every command here ran with Docker 29, `postgres:17.11` and `postgres:18.6`.

## Contents

The sections of this reference:

- Choose dump and restore or pg_upgrade
- Dump and restore between two containers
- pg_upgrade on the volume with tianon/postgres-upgrade
- The checksum mismatch from 17 to 18
- After the upgrade: pg_hba.conf, settings, statistics

## Choose dump and restore or pg_upgrade

Both methods need the old and the new server binaries; they differ in downtime and in what they carry over.

| Method | Downtime | Carries over | Use when |
|---|---|---|---|
| `pg_dumpall` piped into the new container | the whole dump and restore | databases, roles, grants; not `postgresql.conf` or `pg_hba.conf` | databases up to tens of GB, or a change of image base (bookworm to trixie, Debian to Alpine) |
| `pg_upgrade --link` on the volume | minutes, independent of size | everything in the catalogs and data files | large databases on the same image base |
| logical replication into a new container | seconds at the switch | data; schema is copied first | when downtime must be near zero (`postgres-replication-ha`) |

Take a backup that leaves the host before either one: `pg_upgrade --link` changes the old cluster so it can no longer
be started once the new one has run.

## Dump and restore between two containers

Dump and restore streams the old server's SQL into a new 18 container; it also rebuilds every index under the new
image's collation library, which is the safe path when the image base changes. These commands keep the old
container running until the new one is checked:

```bash
docker run -d --name pg18 -e POSTGRES_PASSWORD_FILE=/run/secrets/pg_password \
  -v "$PWD/pg_password.txt:/run/secrets/pg_password:ro" -v pgdata18:/var/lib/postgresql postgres:18.6-trixie
# wait for: docker exec pg18 pg_isready -h 127.0.0.1
docker exec pg17 pg_dumpall -U postgres | docker exec -i pg18 psql -X -U postgres -d postgres -q
docker exec pg18 vacuumdb -U postgres --all --analyze-in-stages
```

The one expected error is `role "postgres" already exists`; any other error needs a look before you switch. Stop
writes to the old container first (stop the application), or rows written during the dump are lost. Copy any
`pg_hba.conf` lines and server settings you added by hand to the new container's configuration.

## pg_upgrade on the volume with tianon/postgres-upgrade

`pg_upgrade` needs both majors' binaries in one place; the community image `tianon/postgres-upgrade:17-to-18`
carries both. With the 18 layout (one volume at `/var/lib/postgresql`, data in `<major>/docker`), `--link` works
because both data directories sit on the same mount.

This sequence upgraded a 17 volume in place. It assumes the 17 container ran with
`-e PGDATA=/var/lib/postgresql/17/docker -v pgdata:/var/lib/postgresql`; a 17 volume mounted at
`/var/lib/postgresql/data` must first be moved into a `17/docker` subdirectory.

```bash
docker stop -t 120 pg17 && docker rm pg17                     # clean shutdown first
docker run --rm -v pgdata:/var/lib/postgresql \
  -e PGDATAOLD=/var/lib/postgresql/17/docker -e PGDATANEW=/var/lib/postgresql/18/docker \
  -e POSTGRES_INITDB_ARGS=--no-data-checksums \
  tianon/postgres-upgrade:17-to-18 --link
docker run -d --name pg18 -e POSTGRES_PASSWORD_FILE=/run/secrets/pg_password \
  -v "$PWD/pg_password.txt:/run/secrets/pg_password:ro" -v pgdata:/var/lib/postgresql postgres:18.6-trixie
```

`pg_upgrade` ends with "Upgrade Complete" and the commands to rebuild statistics, and leaves
`delete_old_cluster.sh` in the volume. Keep the old directory until the new server has run and a backup of it
exists. The image's README calls itself a proof of concept: read it and adapt the paths rather than run it blind.

## The checksum mismatch from 17 to 18

PostgreSQL 18's `initdb` enables data checksums by default, and a 17 cluster created by the image has none, so the
first attempt failed:

```text
Checking cluster versions                                     ok

old cluster does not use data checksums but the new one does
Failure, exiting
```

Two fixes: create the new cluster without checksums (`POSTGRES_INITDB_ARGS=--no-data-checksums`, as above), or turn
checksums on in the stopped 17 cluster with `pg_checksums --enable -D /var/lib/postgresql/17/docker` first (it
rewrites every data file, so it takes time on large clusters). Remove the half-created `18/docker` directory before
retrying.

## After the upgrade: pg_hba.conf, settings, statistics

`pg_upgrade` does not copy configuration files. The new cluster's `pg_hba.conf` came from a fresh `initdb` and
lacked the image's `host all all all scram-sha-256` line, so other containers were refused:

```text
FATAL:  no pg_hba.conf entry for host "192.168.158.3", user "postgres", database "postgres", no encryption
```

Fix it in the volume and reload:

```bash
docker exec pg18 sh -c 'echo "host all all all scram-sha-256" >> /var/lib/postgresql/18/docker/pg_hba.conf'
docker exec -u postgres pg18 pg_ctl reload -D /var/lib/postgresql/18/docker
docker exec pg18 vacuumdb -U postgres --all --analyze-in-stages --missing-stats-only
```

Then carry over any `postgresql.conf` or `postgresql.auto.conf` settings from `17/docker`, run
`ALTER EXTENSION ... UPDATE` in each database for extensions whose packages changed, and take a new full backup: a
17 physical backup cannot restore into 18.
