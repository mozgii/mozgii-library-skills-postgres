---
name: postgres-docker
description: 'Runs PostgreSQL 18 in Docker correctly: the official postgres image variants and tags, the 18 change of PGDATA to /var/lib/postgresql/18/docker with the volume at /var/lib/postgresql, POSTGRES_* environment variables and _FILE secrets, docker-entrypoint-initdb.d scripts, pg_isready health checks, compose files for development and CI, custom images with extensions, shm_size, clean shutdown, non-root and read-only containers, backups from a container, io_uring under seccomp, and upgrading a containerised database to a new major. Use when someone runs Postgres with docker run or docker compose, the container ignores POSTGRES_PASSWORD, data disappears after docker compose down, init scripts do not run, or a postgres:17 volume will not start on postgres:18.'
metadata:
  tags:
  - postgres
  - docker
  - docker-compose
  - containers
  - healthcheck
  - pg-upgrade
  - ci
---

# PostgreSQL in Docker

Use the official `postgres` image, pin the full tag (`postgres:18.6-trixie`), mount one volume at
`/var/lib/postgresql`, pass the password through a `_FILE` secret, and gate dependants on a health check that uses
TCP. The image only initialises an empty data directory: every `POSTGRES_*` variable and every init script is
ignored once data exists. Every command below ran on Docker 29 with `postgres:18.6`. Moving a volume to a new major
is in [references/major-upgrade.md](references/major-upgrade.md); extensions in general are in
`postgres-extensions-install`.

## Step 0: read Docker, the image and the volume

The 18 images changed where data lives, so check the image and the mount before changing anything.

```bash
docker version --format '{{.Server.Version}}'; docker compose version
docker inspect --format '{{.Config.Image}} {{range .Mounts}}{{.Destination}} {{end}}' pg
docker exec pg psql -U postgres -Atc 'SELECT version()' -c 'SHOW data_directory'
docker run --rm -v pgdata:/d alpine sh -c 'ls /d /d/*/ 2>/dev/null | head; cat /d/*/docker/PG_VERSION 2>/dev/null'
```

## Image variants and tags

The official image comes in Debian (trixie, bookworm) and Alpine builds; tags move with every minor, so pin the full
version for anything you need to reproduce.

| Tag | Base | Notes |
|---|---|---|
| `18`, `18.6`, `18-trixie`, `18.6-trixie` | Debian 13 (glibc) | default; server and extensions from the PGDG apt repository; `postgres` uid 999 |
| `18-bookworm`, `18.6-bookworm` | Debian 12 | for hosts that must stay on the older glibc |
| `18-alpine`, `18.6-alpine`, `18.6-alpine3.24` | Alpine (musl) | smaller; only contrib extensions, others must be compiled; `postgres` uid 70 |

- Both 18 builds are configured `--with-icu`, `--with-liburing` and `--with-llvm`; the Debian build adds `--with-libnuma`.
- Prefer the builtin or ICU locale provider (`POSTGRES_INITDB_ARGS="--locale-provider=builtin --locale=C.UTF-8"`):
  libc collations change between glibc versions, so a volume moved from a bookworm to a trixie image (or to Alpine)
  can return different sort orders and needs its text indexes rebuilt.
- `postgres:18` without a minor pulls a new minor on the next `docker pull`; a minor update needs only a restart,
  but make it on purpose.

## PGDATA and the volume in 18 images

From 18 the image sets `PGDATA=/var/lib/postgresql/18/docker` and declares the volume at `/var/lib/postgresql`, the
same layout `pg_ctlcluster` uses, so a later `pg_upgrade --link` sees old and new data on one mount. Mount the
volume at `/var/lib/postgresql`:

```bash
docker run -d --name pg -e POSTGRES_PASSWORD_FILE=/run/secrets/pg_password \
  -v "$PWD/pg_password.txt:/run/secrets/pg_password:ro" \
  -v pgdata:/var/lib/postgresql -p 127.0.0.1:5432:5432 \
  --shm-size=256m --stop-timeout=60 postgres:18.6-trixie
```

A mount at the 17-era path `/var/lib/postgresql/data` stops an 18 container before `initdb`:

```text
Error: in 18+, these Docker images are configured to store database data in a
       format which is compatible with "pg_ctlcluster" (specifically, using
       major-version-specific directory names).
```

The same error appears when an 18 container finds a 17 cluster in the volume: the image will not start an old
major's data. Upgrade it first ([references/major-upgrade.md](references/major-upgrade.md)).

## Environment variables the image reads

The entrypoint reads these variables only when the data directory is empty; later changes to them do nothing.

| Variable | Default | Effect |
|---|---|---|
| `POSTGRES_PASSWORD` | required | superuser password; `initdb --pwfile` |
| `POSTGRES_USER` | `postgres` | superuser name, and a database of that name |
| `POSTGRES_DB` | value of `POSTGRES_USER` | name of the first database |
| `POSTGRES_INITDB_ARGS` | empty | extra `initdb` flags, space separated |
| `POSTGRES_INITDB_WALDIR` | empty | WAL in another directory (another volume) |
| `POSTGRES_HOST_AUTH_METHOD` | `scram-sha-256` | method of the appended `host all all all` line; never `trust` |
| `PGDATA` | `/var/lib/postgresql/18/docker` | data directory |

The generated `pg_hba.conf` trusts connections inside the container (socket, 127.0.0.1, ::1) and appends
`host all all all scram-sha-256` for everything else, so `docker exec pg psql -U postgres` needs no password and other
containers do.

## Secrets with _FILE variables

`POSTGRES_PASSWORD_FILE`, `POSTGRES_USER_FILE`, `POSTGRES_DB_FILE` and `POSTGRES_INITDB_ARGS_FILE` read the value
from a file, which keeps the password out of `docker inspect`; the entrypoint also unsets every `POSTGRES_*`
variable before it starts the server. Compose secrets mount at `/run/secrets/<name>`. The file must be readable by
the container's user; trailing newlines are dropped, and setting both `POSTGRES_PASSWORD` and
`POSTGRES_PASSWORD_FILE` is an error.

## Initialisation scripts in /docker-entrypoint-initdb.d

After `initdb`, the entrypoint runs files in `/docker-entrypoint-initdb.d` in sorted name order: `*.sql`,
`*.sql.gz`, `*.sql.xz`, `*.sql.zst` through `psql` as `POSTGRES_USER`, executable `*.sh` files, and non-executable
`*.sh` files sourced. This script creates an application role and database:

```sql
-- 01-app.sql
CREATE ROLE app LOGIN PASSWORD 'app-dev-only';
CREATE DATABASE app OWNER app;
```

- They run once, on an empty data directory, against a temporary server that listens only on the socket.
- A failing script stops the entrypoint; a restarted container then finds a half-initialised data directory and
  skips all scripts. Delete the volume and start again rather than repair it.
- Inside `*.sh` scripts call `psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"`.

## Health checks with pg_isready

`pg_isready` reports whether the server accepts connections. Point it at `127.0.0.1`: the temporary server used for
init scripts listens only on the Unix socket, so a socket check can report healthy before initialisation finishes,
while a TCP check waits for the real server.

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U postgres -d app -h 127.0.0.1"]
  interval: 5s
  timeout: 3s
  retries: 10
  start_period: 30s
```

## Compose file for development

This compose file was brought up with `docker compose up -d --wait`; the `migrate` service starts only after the
database is healthy.

```yaml
name: myapp
services:
  db:
    image: postgres:18.6-trixie
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/pg_password
      POSTGRES_INITDB_ARGS: "--locale-provider=builtin --locale=C.UTF-8"
    secrets: [pg_password]
    volumes:
      - pgdata:/var/lib/postgresql
      - ./initdb:/docker-entrypoint-initdb.d:ro
    ports: ["127.0.0.1:5432:5432"]
    shm_size: 256mb
    stop_grace_period: 60s
    command: ["postgres", "-c", "shared_buffers=256MB", "-c", "max_connections=50"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d app -h 127.0.0.1"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 30s
  migrate:
    image: postgres:18.6-trixie
    depends_on:
      db: {condition: service_healthy}
    environment: {PGHOST: db, PGUSER: app, PGPASSWORD: app-dev-only, PGDATABASE: app}
    command: ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-c", "CREATE TABLE IF NOT EXISTS hello (id int)"]
secrets:
  pg_password: {file: ./pg_password.txt}
volumes:
  pgdata:
```

Publish the port on `127.0.0.1` only: `"5432:5432"` listens on every host interface. `docker compose down` keeps the
named volume; `docker compose down -v` deletes the database.

## Compose file for CI

A CI database is thrown away after each run, so it can trade durability for speed: data on `tmpfs`, and
`fsync`, `synchronous_commit` and `full_page_writes` off. Never use these settings for data you keep.

```yaml
services:
  db:
    image: postgres:18.6-trixie
    environment: {POSTGRES_PASSWORD: ci, POSTGRES_DB: test}
    tmpfs: ["/var/lib/postgresql:size=1g"]
    shm_size: 256mb
    command: ["postgres", "-c", "fsync=off", "-c", "synchronous_commit=off", "-c", "full_page_writes=off"]
    ports: ["127.0.0.1:5432:5432"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d test -h 127.0.0.1"]
      interval: 2s
      timeout: 3s
      retries: 30
```

`docker compose up -d --wait` returns once the health check passes, so the next CI step can connect at once.

## Configuration, custom images and extensions

Settings go on the command line (`command: ["postgres", "-c", "name=value"]`) or in a mounted file with
`-c config_file=/etc/postgresql/postgresql.conf`; a custom file must set `listen_addresses = '*'` or other
containers cannot connect. Extensions need their files in the image: the Debian variants install PGDG packages
with `apt-get`. This image adds six extensions and preloads the ones that need it (built and run on 18.6):

```dockerfile
FROM postgres:18.6-trixie
RUN set -eux; apt-get update; \
    apt-get install -y --no-install-recommends postgresql-18-pgvector postgresql-18-cron \
      postgresql-18-partman postgresql-18-pgaudit postgresql-18-repack postgresql-18-postgis-3; \
    rm -rf /var/lib/apt/lists/*
COPY 10-extensions.sql /docker-entrypoint-initdb.d/
CMD ["postgres", "-c", "shared_preload_libraries=pg_stat_statements,pg_cron,pgaudit,pg_partman_bgw", \
     "-c", "cron.database_name=app", "-c", "pgaudit.log=ddl,role"]
```

Projects publish their own images too: `pgvector/pgvector:0.8.7-pg18-trixie`, `postgis/postgis:18-3.6`,
`timescale/timescaledb:latest-pg18` (Community edition, Alpine based, preloads `timescaledb`). On 31 October 2026 the
`postgis/postgis` repository had 3.7.0 only as release candidates, so `18-3.6` is still its stable tag; the
`postgresql-18-postgis-3` package in the Dockerfile above now installs 3.7.0 from PGDG.

## Shared memory, shutdown and resources

Docker gives a container 64 MB of `/dev/shm`; parallel queries and parallel index builds allocate dynamic shared
memory there and fail with `could not resize shared memory segment ... No space left on device` when it runs out.
Set `--shm-size` (`shm_size:` in compose) to at least 256 MB, and above `maintenance_work_mem` for parallel HNSW
builds.

The image's `STOPSIGNAL` is `SIGINT`, PostgreSQL's fast shutdown, but Docker sends `SIGKILL` after 10 seconds by
default and a killed server runs crash recovery on the next start. Give it time with `--stop-timeout=60` or
`stop_grace_period: 60s`. Limit memory with `--memory`; the server sizes nothing from the cgroup limit, so keep
`shared_buffers` plus `work_mem` times connections inside it.

## Running as non-root and read-only

The entrypoint starts as root only to fix ownership, then drops to `postgres`. To never run as root, start the
container as the image's `postgres` uid (999 on Debian, 70 on Alpine) with a volume that uid owns; a read-only root
filesystem works when the socket directory and `/tmp` are `tmpfs`:

```bash
docker run -d --name pg --user 999:999 --read-only \
  --tmpfs /var/run/postgresql --tmpfs /tmp \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/pg_password -v "$PWD/pg_password.txt:/run/secrets/pg_password:ro" \
  -v pgdata:/var/lib/postgresql postgres:18.6-trixie
```

An arbitrary uid that is not in `/etc/passwd` needs the image's `nss_wrapper` support or a bind-mounted
`/etc/passwd`, because `initdb` looks the user up.

## Backups from a container

`docker exec` runs `pg_dump` with the server's own version and streams the dump to the host, so no client install
is needed. These commands dump one database, the roles, and restore into another container:

```bash
docker exec pg pg_dump -U postgres -d app -Fc > app.dump
docker exec pg pg_dumpall -U postgres --globals-only > globals.sql
docker exec -i pg2 pg_restore -U postgres -d app --no-owner < app.dump
```

Use `docker exec` without `-t`: through a TTY the custom-format dump came out 44 bytes longer and `pg_restore`
rejected it (`input file does not appear to be a valid tar archive`). Physical backups and
point-in-time recovery (`pg_basebackup`, pgBackRest, WAL-G) work the same in a container with the archive on its own
volume or object storage (`postgres-backup-restore`).

## io_uring under Docker's seccomp profile

PostgreSQL 18 can use `io_method = io_uring` on Linux, and both 18 images are built with liburing. Docker's default
seccomp profile blocks the io_uring system calls, so the server fails at start:

```text
FATAL:  could not setup io_uring queue: Operation not permitted
HINT:  Check if io_uring is disabled via /proc/sys/kernel/io_uring_disabled.
```

Keep the default `io_method = worker` in containers. The same server started with `--security-opt
seccomp=unconfined` runs io_uring, but that removes a container security boundary; a custom profile that allows only
the three io_uring calls is the narrow way.

## Verify a containerised PostgreSQL

These commands prove the container is healthy, the data is on the volume and it survives a restart.

```bash
docker compose up -d --wait                                     # returns once the health check passes
docker inspect --format '{{.State.Health.Status}}' myapp-db-1   # healthy
docker compose exec db psql -U postgres -Atc 'SHOW data_directory'   # /var/lib/postgresql/18/docker
docker compose exec db psql -U postgres -c 'CREATE TABLE probe (id int)'
docker compose down && docker compose up -d --wait
docker compose exec db psql -U postgres -c 'DROP TABLE probe'   # the table survived down and up
docker compose exec db df -h /dev/shm                           # 256M, not 64M
```

From another machine, connect to the host's port: it must be refused when you publish on `127.0.0.1`.

## Gotchas

These are the container failures seen most often, each with its cause and fix.

1. **`POSTGRES_PASSWORD` changed but the old password still works.** The variables apply only on an empty data
   directory. Change it with `ALTER ROLE postgres PASSWORD ...`.
2. **Data gone after `docker compose down`.** The data was in an anonymous volume or on `tmpfs`, or `down -v` ran.
   Use a named volume at `/var/lib/postgresql`.
3. **Init scripts did not run.** The volume already held data, or an earlier script failed. Remove the volume and
   start again.
4. **The app connects before the database is ready.** Use `depends_on` with `condition: service_healthy` and a TCP
   `pg_isready` check.
5. **`could not resize shared memory segment`.** `/dev/shm` is 64 MB by default; set `shm_size`.
6. **Port 5432 is open to the network.** `-p 5432:5432` binds every interface; publish `127.0.0.1:5432:5432`.
7. **Sort order or index results differ after changing the image base.** libc collations changed with glibc. Use
   the builtin provider for new volumes; `REINDEX` text indexes on moved ones.
8. **The container was killed during shutdown.** The 10-second stop timeout ran out; raise it to 60 seconds or more.

## Checklist

Check these points before you call a containerised Postgres done.

- [ ] Image pinned to a full tag such as `postgres:18.6-trixie`.
- [ ] One named volume at `/var/lib/postgresql`, never `/var/lib/postgresql/data` on 18.
- [ ] Password from a `_FILE` secret; port published on `127.0.0.1` unless remote access is meant.
- [ ] Health check with `pg_isready -h 127.0.0.1`; dependants wait for `service_healthy`.
- [ ] `shm_size` of at least 256 MB and a stop timeout of 60 seconds or more.
- [ ] Locale provider chosen at first start (`POSTGRES_INITDB_ARGS`).
- [ ] A tested `pg_dump` (or physical) backup that leaves the host.

## Anti-patterns with PostgreSQL in Docker

| Do not | Do this instead |
|---|---|
| run the `latest` tag | a full tag such as `postgres:18.6-trixie` |
| mount at `/var/lib/postgresql/data` on 18 | mount the volume at `/var/lib/postgresql` |
| set `POSTGRES_HOST_AUTH_METHOD=trust` beyond a local lab | `scram-sha-256`, with a `_FILE` secret |
| publish `5432:5432` | `127.0.0.1:5432:5432` |
| run `docker exec -t` for a dump | no `-t`, or the dump is corrupted |
| keep `fsync=off` beyond a throwaway CI database | the defaults for any data you keep |

## See also

- `postgres-extensions-install`: extensions beyond the images.
- `postgres-backup-restore`: physical backups and restore drills.
- `postgres-kubernetes`: operators instead of plain containers.
- `postgres-zero-downtime-upgrades`: upgrades with less downtime.
- `postgres-operations`: server configuration.
- `postgres-testing-ci`: throwaway databases in CI.

## Sources

- Docker Official Image docs for `postgres` (docker-library/docs `postgres/content.md`), docker-library/postgres
  `18/trixie/Dockerfile` and `docker-entrypoint.sh`, docker-library/postgres pull request 1259 (PGDATA change),
  Docker Hub tag list for `library/postgres` (October 2026).
- docs.docker.com: seccomp security profiles (io_uring calls blocked, moby issue 46762).
- postgresql.org docs/18: `runtime-config-resource` (`io_method`), `app-pg-isready`, `server-shutdown`.
- pgvector README (Docker), Tiger Data install docs (TimescaleDB images).
- Run with Docker 29: every `docker run`, both compose files, the extension image, the 17-path error, non-root with
  `--read-only`, `pg_dump` and `pg_restore` between containers, io_uring with and without seccomp, and the 17 to 18
  upgrade in the reference.
