# PostgreSQL skills

A library of Claude skills for PostgreSQL 18, for developers and DBAs who build on Postgres and want an agent that
gets schema design, queries, indexes, migrations, backups, replication, pooling, security, search, geospatial data,
operations, incidents and drivers right. Each skill is a standalone `SKILL.md` folder: take one, several or all.

Versions in the text were checked in October 2026: PostgreSQL 18.6 (19 in release candidate), pgvector 0.8.7,
PostGIS 3.7.0, psycopg 3.3.6, asyncpg 0.32.0, SQLAlchemy 2.1.6,
Alembic 1.20.1, node-postgres 8.23.1, postgres.js 4.0.0, Prisma 7.10.1, drizzle-orm 0.45.4 (1.0.0-rc.5), drizzle-kit 0.31.11,
Kysely 0.29.7, pgx 5.11.0, PgJDBC 42.7.14, Npgsql 10.0.3, SQLx 0.9.0, PgBouncer 1.26.1, pgBackRest 2.60.0,
Next.js 16.4. SQL in the skills added or changed in this version was run against PostgreSQL 18.6 with pgvector 0.8.6
and PostGIS 3.7.0.

## Use these skills

Each folder under `docs/v18/<group>/` is one skill that works on its own; none needs another skill or any tool to be
installed.

- **Claude Code, for you:** copy a skill folder into `~/.claude/skills/`, for example
  `cp -r docs/v18/performance/postgres-indexing ~/.claude/skills/`.
- **Claude Code, for one project:** copy it into the project's `.claude/skills/` and commit it, so everyone on the
  project gets it.
- **claude.ai and Claude Desktop:** zip the skill folder (the zip holds one folder named like the skill, with
  `SKILL.md` inside) and upload it in the Skills section of your claude.ai settings.
- **Claude API:** upload the folder through the Skills API.

The front matter uses only portable keys (`name`, `description`, `metadata.tags`), so the same folder works on every
surface. Claude loads a skill when a request matches its description; you can also call one by name, such as
`/postgres-troubleshooting`.

## Skills

Each skill lives in `docs/v18/<group>/<name>/SKILL.md`, with `references/` for detail opened only when needed and
`scripts/` for runnable SQL and shell.

| Skill | Use it for |
|---|---|
| **`clients`** | |
| `postgres-app-drivers` | Node.js, Go, Java, .NET and Rust drivers and ORMs, including Prisma 7 |
| `postgres-drizzle` | Drizzle ORM schema, queries and safe drizzle-kit migrations, with Next.js and Workers notes |
| `postgres-cloudflare-hyperdrive` | Cloudflare Workers to Postgres through Hyperdrive, caching and local development |
| `postgres-libpq-protocol` | connection strings, service files, .pgpass, PG* variables, the wire protocol, pipeline, COPY |
| `postgres-node-typescript` | node-postgres, postgres.js, Kysely and Prisma 7, with Bun and Deno notes |
| `postgres-go-pgx` | pgx v5, pgxpool, CopyFrom, sqlc, goose and golang-migrate |
| `postgres-java-jdbc` | PgJDBC, HikariCP, Spring Boot 4, Hibernate 7, Flyway and Liquibase |
| `postgres-dotnet-npgsql` | Npgsql 10, EF Core 10, Dapper, NativeAOT |
| `postgres-rust-sqlx` | SQLx with compile-time checks, tokio-postgres, Diesel |
| `postgres-php-laravel` | PDO pgsql, Laravel 13, Doctrine |
| `postgres-ruby-rails` | the pg gem, Active Record 8.1, strong_migrations, Solid Queue |
| **`extensions`** | |
| `postgres-vector-search` | pgvector embeddings, HNSW, filtered search, quantization, recall, hybrid search |
| `postgres-postgis` | geospatial data: radius and nearest search, point in polygon, GeoJSON, vector tiles |
| `postgres-extensions-install` | getting extensions onto a server: packages, PGXS, preload libraries, trusted extensions, upgrades |
| `postgres-citus-sharding` | Citus distributed and reference tables, distribution column, colocation, rebalancing |
| `postgres-timeseries` | time series on plain Postgres and on TimescaleDB: partitions, BRIN, rollups, retention |
| `postgres-fdw-federation` | postgres_fdw pushdown and batching, dblink, file_fdw, other foreign data wrappers |
| `postgres-extension-development` | writing extensions in SQL, C with PGXS and Rust with pgrx; tests with pg_regress |
| **`operations`** | |
| `postgres-troubleshooting` | something is wrong right now: slow, CPU 100%, too many clients, locks, disk full, wraparound, won't start |
| `postgres-backup-restore` | pg_dump and pg_restore, WAL archiving, point-in-time recovery, pgBackRest, restore drills |
| `postgres-replication-ha` | streaming replicas, slots, synchronous commit, lag, failover, logical replication |
| `postgres-operations` | autovacuum, bloat, wraparound, WAL, configuration, upgrades, managed services |
| `postgres-local-cluster` | one private cluster per desktop app or project: setup, backups, drills, upgrades, bundling |
| `postgres-install` | installing PostgreSQL 18 on macOS, Linux (PGDG apt and dnf) and Windows, initdb choices, side-by-side majors |
| `postgres-docker` | the official image, the PGDATA change in 18, init scripts, health checks, compose, backups, major upgrades |
| `postgres-kubernetes` | CloudNativePG clusters, object-store backups and PITR, failover, poolers; PGO and Zalando compared |
| `postgres-patroni-ha` | Patroni with etcd and HAProxy: configuration, switchover, failover, rewind, drills |
| `postgres-zero-downtime-upgrades` | pg_upgrade clone, link and swap, blue-green upgrades with logical replication, rollback |
| `postgres-monitoring-observability` | what to alert on, postgres_exporter and Prometheus rules, log settings, pgBadger |
| `postgres-psql-cli` | psql at a pro level, scripting, pg_dump, pg_restore and pg_basebackup flags that matter |
| `postgres-cdc-logical-decoding` | change data capture: slots, publications, pgoutput and wal2json, Debezium, failover slots |
| `postgres-pg18-features` | what PostgreSQL 18 changes and the incompatibilities to check before upgrading |
| **`performance`** | |
| `postgres-indexing` | which index to build, column order, partial, expression, covering, GIN, BRIN, concurrent builds |
| `postgres-query-performance` | slow queries: pg_stat_statements, EXPLAIN ANALYZE, statistics, generic plans, work_mem |
| `postgres-connection-pooling` | pool sizing, PgBouncer modes, prepared statements, serverless poolers |
| `postgres-os-kernel-tuning` | huge pages, THP, sysctl, filesystems, io_uring, sizing CPU, RAM and disks |
| `postgres-partitioning` | partition keys, pruning, ATTACH and DETACH CONCURRENTLY, pg_partman 5, moving a live table |
| `postgres-vacuum-bloat` | autovacuum per table, wraparound, measuring bloat, HOT and fillfactor, pg_repack, pg_squeeze |
| `postgres-bulk-load-etl` | fast loads with COPY, ON_ERROR, staging tables, upserts at scale, pgloader |
| `postgres-internals-architecture` | processes, shared memory, WAL, checkpoints, crash recovery, the data directory |
| `postgres-internals-mvcc-storage` | pages, tuples, xmin and xmax, HOT, TOAST, visibility and free space maps |
| `postgres-internals-planner` | statistics, cost model, selectivity, join methods and order, generic plans |
| **`python`** | |
| `postgres-python` | psycopg 3, asyncpg, SQLAlchemy 2.1, Alembic, pytest against a real Postgres |
| `postgres-python-psycopg` | psycopg 3 in depth: pools, async, pipeline, COPY, type adapters, LISTEN, errors |
| `postgres-python-sqlalchemy` | SQLAlchemy 2.1 ORM and Core on Postgres, async sessions, Alembic in depth |
| `postgres-python-asyncpg` | asyncpg pools, statement cache with PgBouncer, codecs, COPY, listeners |
| `postgres-python-django` | Django on Postgres: pooling, contrib.postgres, migrations on big tables, SKIP LOCKED |
| `postgres-python-data` | pandas, Polars, ADBC and DuckDB with Postgres: fast reads and writes, type mapping |
| **`security`** | |
| `postgres-security-roles` | least-privilege roles, default privileges, pg_hba, scram, TLS, row-level security |
| `postgres-encryption-tls` | TLS and verify-full, client certificates, SCRAM channel binding, pgcrypto, encryption at rest |
| `postgres-auditing-compliance` | pgaudit, DDL logs, erasure across backups, retention, masking, audit evidence |
| **`sql`** | |
| `postgres-schema-exploration` | reading an unfamiliar database safely and writing a first correct query against it |
| `postgres-schema-design` | tables, types, keys, constraints, multi-tenant layouts, JSONB, generated columns, partitioning |
| `postgres-sql-patterns` | upserts, MERGE, keyset pagination, bulk loads, N+1 fixes, NULL traps, materialized views, reports |
| `postgres-schema-migrations` | zero-downtime DDL in any migration tool: lock_timeout, NOT VALID, expand and contract, backfills |
| `postgres-transactions-locking` | isolation, retries, lost updates, SKIP LOCKED queues, outbox, advisory locks, deadlocks |
| `postgres-functions-triggers` | SQL and PL/pgSQL functions, procedures, triggers for updated_at and audit, event triggers |
| `postgres-full-text-search` | tsvector search boxes, ranking, highlighting, unaccent, typo-tolerant search with pg_trgm |
| `postgres-multitenancy` | row-level security per tenant, schema or database per tenant, per-tenant export and deletion |
| `postgres-queues-jobs` | job queues with SKIP LOCKED, leases, retries, dead letters, outbox, pgmq, pg_cron |
| `postgres-constraints-integrity` | exclusion, deferrable, NOT VALID and NOT ENFORCED constraints, temporal keys, domains |
| `postgres-testing-ci` | pgTAP, template databases, Testcontainers, ephemeral clusters, migration checks, pgbench |
| `postgres-sql-fundamentals` | how a SELECT is evaluated, every join, NULL logic, casts, set operations, DML semantics |
| `postgres-sql-json` | jsonb operators, jsonpath, SQL/JSON functions and JSON_TABLE, indexing JSON |
| `postgres-sql-dates-times` | timestamptz, time zones and DST, intervals, date_bin, calendars, ranges |

## Layout

- `docs/v18/<group>/<skill>/SKILL.md`: front matter `name` (equal to the folder name), `description`, `metadata.tags`.
- `docs/v18/<group>/<skill>/references/*.md`: detail the skill links to, one level deep; front matter `title`,
  `author`, `lang`.
- `docs/v18/<group>/<skill>/scripts/`: read-only SQL reports and a restore drill to run with `psql -f` or `bash`.
- `library.json`: name `postgres`, title, version, the self-test minimum.
- `questions.json`: the self-test; each question names a phrase its answering passage holds and the file it is in.
- `versions.json`: every package the skills name, with the version checked and the date.
- `sources.json` and `NOTICE`: what was read as context, at which commit and under which licence.
- `dist/` holds build output and is not in git.

## What changed

The last round before the first public release added a Step 0, a Verify section, anti-patterns and See also to the
skills, and put into `SKILL.md` what a reader needs when only the text is installed: restore drills, test CA commands,
audit queries. Corrections from running each one: comments after a value break `pgbouncer.ini` and
`pgbackrest.conf`; PgBouncer's `auth_user` needs a plain-text password when the server requires SCRAM;
`pg_restore --clean -t` loses keys, indexes and triggers; `COPY FROM` is pgaudit's `WRITE` class; `import
'server-only'` in a Drizzle schema breaks `drizzle-kit`; a `regconfig` column blocks `pg_upgrade`.

Before the first public release, the skills were compared with the agent skills that Supabase and Tiger Data publish
and with the PostgreSQL 18.6 documentation. New material: retrying a migration after `lock_timeout`, idempotent
migrations, preflight queries and rehearsal, the policies each command needs under row-level security, partition,
inheritance, foreign table and extension queries for exploring a database, BM25 and DiskANN extensions for hybrid
search, converting a table to a hypertable, TimescaleDB Toolkit analytics, and the upgrade to postgres.js 4.
Corrections: plain `REINDEX` takes `SHARE` on the table, not `ACCESS EXCLUSIVE`; `ATTACH PARTITION` also locks the
attached table and the default partition; the binary quantization example returned at most 40 candidates until
`hnsw.ef_search` covered its `LIMIT`; the tenant setting needs `nullif` on a pooled connection; `contype` includes
`n` on PostgreSQL 18. Each was run on PostgreSQL 18.6, on TimescaleDB 2.31 in a container, or read in the official
documentation.

Version 1.2 added 43 skills, for 65 in all: installing and deploying every part (packages per OS, extensions,
Docker, Kubernetes, the host), high availability and scale (Patroni, Citus, multi-tenancy, partitioning, upgrades
without downtime), production operations (vacuum, monitoring, psql, TLS, auditing), data patterns (time series,
queues, change data capture, foreign data, bulk loads), building tools (constraints, libpq and the wire protocol,
extension development, testing, PostgreSQL 18 changes), five Python skills that start from a working quickstart,
one deep skill each for Node.js and TypeScript, Go, Java, .NET, Rust, PHP and Ruby, and six skills on SQL itself and
how PostgreSQL works inside. Every SQL example in them ran on PostgreSQL 18.6; extensions, other languages and
cluster tools ran in containers, and each skill says what was checked against documentation only. Each new skill
ends with the official pages it was checked against.

Version 1.1 added four skills, merged two, renamed one and deepened the rest:

- New: `postgres-troubleshooting` (symptom-first incident guide), `postgres-schema-exploration` (catalog-first
  exploration of an unknown database), `postgres-functions-triggers` (functions, procedures, triggers, audit
  history), `postgres-postgis` (geospatial).
- Merged: `drizzle-migrations` and `drizzle-orm-nextjs` became `postgres-drizzle`, with the Next.js and Workers rules
  and the migration detail in references, so Drizzle users outside Next.js find it too.
- Renamed: `cloudflare-hyperdrive-postgres` to `postgres-cloudflare-hyperdrive`, so every skill name starts with
  `postgres-`.
- Deepened: multi-tenant schemas, PostgreSQL 18 `RETURNING old` for upserts, materialized views and a reporting
  reference, the transactional outbox, keeping embeddings in sync, managed-service differences, and a worked example
  in every skill. Descriptions were rewritten in the words people use when they ask.

Five skills of version 1.0 came from an earlier internal collection and were rewritten for general use, with
neutral example names (`app`, `acme`). Fixes made on the way, each checked against the docs or by running it:
Drizzle's migrator runs all pending files in one transaction, so `CREATE INDEX CONCURRENTLY` needs its own step;
`ADD COLUMN ... DEFAULT now()` does not rewrite a table; Hyperdrive's documented pattern is a `Client` per request;
Next.js 16's `revalidateTag` takes a second profile argument.

## Sources

Every text, example and script in this library is the own work of MOZGII, Inc. The sources below were read as
context: they showed what the skills should cover and which facts are true. Each fact was checked against the
official documentation or by running it. No wording, example or code was copied from any of them, whatever its
licence, so no third-party notice applies. They are listed as thanks and as a map for the next upgrade.

The PostgreSQL project publishes no agent skills of its own: its GitHub organization (`postgres`, six repositories)
holds no `SKILL.md`, and a web search found none on postgresql.org, checked on 30 October 2026. The closest official
material is its documentation, which is the authority on facts here. Supabase and Tiger Data are companies built on
Postgres, so their collections are good open work and not the project's own.

These were read at the exact commit `sources.json` records.

| Source | Publisher | Licence | What it informed |
|---|---|---|---|
| [agent-skills](https://github.com/supabase/agent-skills) | Supabase | MIT | which migration, row-level security and connection topics to cover; Supabase's security traps |
| [pg-aiguide](https://github.com/timescale/pg-aiguide) | Timescale, Inc., d/b/a Tiger Data | Apache-2.0 | migration safety topics, schema exploration, vector and hybrid search, moving tables to hypertables, Toolkit analytics |
| [PostgreSQL 18.6 documentation source](https://github.com/postgres/postgres/tree/REL_18_6/doc/src/sgml) | The PostgreSQL Global Development Group | PostgreSQL Licence | policies per command, lock levels, `DROP COLUMN`, catalog values |
| [pgvector](https://github.com/pgvector/pgvector) 0.8.7 README and CHANGELOG | pgvector contributors | PostgreSQL Licence | scan limits, iterative scan memory, zero vectors |
| [pg_textsearch](https://github.com/timescale/pg_textsearch) 1.5.1 README | Tiger Data | PostgreSQL Licence | BM25 index and operator |
| [pgvectorscale](https://github.com/timescale/pgvectorscale) 0.9.1 README | Tiger Data | PostgreSQL Licence | `diskann` index and label filters |
| [postgres.js](https://github.com/porsager/postgres) 4.0.0 README and release notes | Rasmus Porsager and contributors | Unlicense | the upgrade from version 3 |
| [PostGIS](https://github.com/postgis/postgis) 3.7.0 NEWS | The PostGIS project | GPL-2.0-or-later; facts only | release status and breaking changes |
| [Supabase docs](https://github.com/supabase/supabase/tree/master/apps/docs/content/guides): row-level security, securing your API | Supabase | Apache-2.0 | roles, grants and policies on Supabase |
| [PgBouncer](https://github.com/pgbouncer/pgbouncer) `doc/config.md`, `NEWS.md`, `lib/usual/cfparser.c` | The PgBouncer project | ISC | configuration file syntax, `auth_user` and SCRAM limits, CVE fixes |
| [pgBackRest](https://github.com/pgbackrest/pgbackrest) `src/common/ini.c` | pgBackRest contributors | MIT | configuration file syntax |
| [CloudNativePG](https://github.com/cloudnative-pg/cloudnative-pg/tree/v1.30.1/docs/src) 1.30.1 documentation | The CloudNativePG Contributors | Apache-2.0 | the `Cluster` manifest, Barman Cloud plugin backups, recovery and `initdb.import` |
| [plugin-barman-cloud](https://github.com/cloudnative-pg/plugin-barman-cloud) 0.15.1 docs | The CloudNativePG Contributors | Apache-2.0 | installing the plugin and its needs, `ObjectStore`, retention |
| [Crunchy PGO](https://github.com/CrunchyData/postgres-operator) 6.0.3 README and CRDs | Crunchy Data Solutions, Inc. | Apache-2.0 (operator) | the operator comparison: resource versions, Patroni, pgBackRest |
| [Zalando postgres-operator](https://github.com/zalando/postgres-operator) 2.0.3 README and manifests | Zalando SE | MIT | the operator comparison: Spilo, WAL-G |
| [postgres-containers](https://github.com/cloudnative-pg/postgres-containers) README | The CloudNativePG Contributors | Apache-2.0 | image flavours |
| [create_hypertable reference](https://www.tigerdata.com/docs/reference/timescaledb/hypertables/create_hypertable) (web page) | Tiger Data | not stated; facts only | `migrate_data` and `by_range`; foreign key limits were measured instead |
| [Cloudflare Hyperdrive docs](https://developers.cloudflare.com/hyperdrive/) (web pages) | Cloudflare, Inc. | CC-BY-4.0 (docs); facts only | local development, caching, limits, pooling mode, driver support |
| [OpenNext database how-to](https://opennext.js.org/cloudflare/howtos/db) (web page) | OpenNext | not stated; facts only | a per-request `Pool` with `maxUses: 1` |
| [Npgsql basic types](https://www.npgsql.org/doc/types/basic.html) (web page) | The Npgsql project | PostgreSQL Licence | `numeric` mappings |
| [PostGIS 3.7.0 release page](https://postgis.net/2026/10/PostGIS-3.7.0/) (web page) | The PostGIS project | CC BY-SA 3.0 (site); facts only | supported PostgreSQL versions, packaging changes |
| [PostgreSQL versioning policy](https://www.postgresql.org/support/versioning/) (web page) | The PostgreSQL Global Development Group | PostgreSQL Licence | supported versions and end-of-life dates |

Most skills also end with a Sources section naming the official pages they were checked against.

Version numbers came from the npm registry, PyPI, crates.io, Maven Central, NuGet, RubyGems, GitHub release tags and
project pages on 30 and 31 October 2026; `versions.json` lists them.
