---
name: postgres-fdw-federation
description: 'Queries other databases and files from PostgreSQL 18 with foreign data wrappers: postgres_fdw servers, user mappings and IMPORT FOREIGN SCHEMA, pushdown checked with EXPLAIN VERBOSE, fetch_size, batch_size, use_remote_estimate, async_capable and parallel commit, SCRAM pass-through instead of stored passwords, dblink for remote commands, file_fdw with on_error and reject_limit, mysql_fdw, oracle_fdw, tds_fdw and DuckDB or Parquet options, and the performance and security traps. Use when joining tables across databases or servers, reading a remote Postgres, MySQL, Oracle or SQL Server table from SQL, a foreign table query is slow, "password or GSSAPI delegated credentials required" appears, or when choosing between FDW, dblink, replication and ETL.'
metadata:
  tags:
  - postgres
  - fdw
  - postgres-fdw
  - dblink
  - file-fdw
  - federation
  - foreign-tables
  - scram-passthrough
---

# PostgreSQL foreign data wrappers and federation

A foreign data wrapper (FDW) makes a table in another database, server or file queryable as a local foreign table.
Use `postgres_fdw` to read and occasionally write another PostgreSQL database; check every important query with
`EXPLAIN (VERBOSE)` to see what is sent remotely, because a query that pulls whole tables across the network is
the usual failure. Federation is for occasional cross-database queries and migrations; for hot paths, copy the
data (logical replication in `postgres-replication-ha`, CDC in `postgres-cdc-logical-decoding`, loads in
`postgres-bulk-load-etl`). Never store a superuser's password in a user mapping. A read-only inventory of servers,
user mappings with their secrets masked, foreign tables with their statistics, and open connections:
[scripts/fdw-check.sql](scripts/fdw-check.sql). Pushdown is read per query with `EXPLAIN (VERBOSE)`.

## Step 0: see the wrappers and foreign objects that exist

Read what the server has before adding a wrapper, and which versions the remote side runs, because pushdown depends
on what the remote understands.

```sql
SELECT version();
SELECT name, default_version, installed_version FROM pg_available_extensions
WHERE name IN ('postgres_fdw', 'dblink', 'file_fdw', 'mysql_fdw', 'oracle_fdw', 'tds_fdw');
SELECT s.srvname, w.fdwname FROM pg_foreign_server s JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw;
SELECT foreign_table_schema, foreign_table_name, foreign_server_name FROM information_schema.foreign_tables;
```

## Choose postgres_fdw, dblink, file_fdw or another wrapper

The choice of wrapper follows from the source and from whether you need a table or a command.

| Tool | Source | Use for | Writes |
|---|---|---|---|
| `postgres_fdw` (contrib) | PostgreSQL 8.3 and later | joins, reports, migrations across databases | `INSERT`, `UPDATE`, `DELETE`, `COPY`, `TRUNCATE` |
| `dblink` (contrib) | PostgreSQL | one remote command: `VACUUM`, DDL, a function call | any statement |
| `file_fdw` (contrib) | files or programs on the database server | CSV and text logs read in place | no |
| `mysql_fdw` 2.9.3 | MySQL, MariaDB | reads with WHERE, column and join pushdown | yes |
| `oracle_fdw` 2.9.0 | Oracle Database | migration and reporting | yes |
| `tds_fdw` 2.0.5 | SQL Server, Sybase | reads; no join pushdown or writes | no |
| `pg_duckdb` 1.1, `pg_parquet` | Parquet, CSV, Iceberg on S3, GCS, Azure | analytics on lake files | `COPY TO` Parquet |

All of these except the contrib modules are separate builds per PostgreSQL major version: apt packages are named
`postgresql-18-mysql-fdw`, `postgresql-18-oracle-fdw` and `postgresql-18-tds-fdw`; oracle_fdw also needs an
Oracle client installation on the database server. On macOS and Windows, check each project's install notes and
expect to build from source.

## Setting up postgres_fdw: server, user mapping, foreign schema

`postgres_fdw` needs three objects: a server with the connection options, a user mapping with the remote
credentials, and foreign tables, usually imported in bulk. Create a dedicated, read-only role on the remote side.

```sql
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SERVER billing_srv FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'billing-db.internal', port '5432', dbname 'billing', sslmode 'verify-full',
           fetch_size '10000', use_remote_estimate 'true', async_capable 'true',
           parallel_commit 'true', parallel_abort 'true', application_name 'reporting_fdw');
CREATE USER MAPPING FOR reporting_app SERVER billing_srv
  OPTIONS (user 'fdw_reader', password 'change-me');
CREATE USER MAPPING FOR CURRENT_USER SERVER billing_srv          -- the admin who runs the import
  OPTIONS (user 'fdw_reader', password 'change-me');
CREATE SCHEMA billing;
IMPORT FOREIGN SCHEMA app LIMIT TO (customers, invoices) FROM SERVER billing_srv INTO billing;
GRANT USAGE ON SCHEMA billing TO reporting_app;
GRANT SELECT ON ALL TABLES IN SCHEMA billing TO reporting_app;
GRANT USAGE ON FOREIGN SERVER billing_srv TO reporting_app;   -- for dblink and CREATE FOREIGN TABLE; SELECT works without it
```

- Server options are libpq connection options plus FDW options; `user`, `password` and `sslpassword` belong in the
  user mapping. Every role that queries or runs `IMPORT FOREIGN SCHEMA` needs its own mapping (or one `FOR
  PUBLIC`), else `user mapping not found for user ...`.
- `IMPORT FOREIGN SCHEMA` copies column names, types, `NOT NULL` and generated expressions (`import_generated`,
  default true); defaults are skipped (`import_default`, default false) and other constraints are never imported.
- Partitions are imported only when named in `LIMIT TO`; import the partitioned parent.
- PostgreSQL 18 adds `CREATE FOREIGN TABLE name (LIKE local_table) SERVER ...` to copy a local definition.

## postgres_fdw options that matter

These options decide speed and behaviour; most can be set on the server and overridden per foreign table.

| Option | Default | Effect |
|---|---|---|
| `fetch_size` | 100 | rows per fetch; raise to thousands for scans |
| `batch_size` | 1 | rows per remote `INSERT`; also applies to `COPY` into a foreign table (capped at 1,000) |
| `use_remote_estimate` | false | runs remote `EXPLAIN` for costs; better join plans, more round trips |
| `async_capable` | false | lets an `Append` over several foreign tables scan them concurrently |
| `parallel_commit`, `parallel_abort` | false | commits or aborts several remote transactions at once (server only) |
| `keep_connections` | on | keeps the connection for the session; off closes it after each transaction |
| `extensions` | none | extensions whose immutable functions may be sent remotely |
| `fdw_startup_cost`, `fdw_tuple_cost` | 100, 0.2 | planner cost of remote access |
| `updatable`, `truncatable` | true | refuse writes locally without asking the remote |

Remote sessions run with `search_path = pg_catalog`, `TimeZone = UTC`, `DateStyle = ISO`; functions behind a
remote view that rely on `search_path` must schema-qualify their names.

## Checking pushdown with EXPLAIN VERBOSE

Pushdown means the remote server does the filtering, joining, aggregation, sorting and limiting, and only the
result travels. `EXPLAIN (VERBOSE)` shows the exact remote query in `Remote SQL`.

```sql
EXPLAIN (VERBOSE, COSTS OFF)
SELECT c.country, sum(i.amount_cents)
FROM billing.invoices i JOIN billing.customers c ON c.id = i.customer_id
WHERE i.issued_on >= date '2026-10-01'
GROUP BY c.country;
```

On 18.6 the whole query became one remote statement: `Relations: Aggregate on ((billing.invoices i) INNER JOIN
(billing.customers c))`. What stops pushdown:

- A function that is not built-in or immutable, or belongs to an extension not listed in `extensions`: a PL/pgSQL
  filter showed `Filter:` locally with `Remote SQL: SELECT amount_cents FROM app.invoices` (every row fetched). A
  simple SQL-language function was inlined and pushed.
- A join between foreign tables on different servers or with different user mappings, or with a local table.
- Mismatched collations or types between the foreign table and the remote column.

## Joining local rows to a foreign table

A join between a local table and a foreign table cannot be pushed down: the planner either fetches the whole remote
table or sends one remote query per local row. Pass the local keys as an array instead, which becomes one remote
query with `= ANY($1)`.

```sql
CREATE TABLE vip (customer_id bigint PRIMARY KEY);
INSERT INTO vip SELECT g FROM generate_series(1, 1000, 2) g;
ANALYZE vip;

SELECT sum(i.amount_cents)
FROM billing.invoices i
WHERE i.customer_id = ANY (ARRAY(SELECT customer_id FROM vip));
```

On 200,000 remote rows the plain join fetched all of them and took 58 ms; the array form pushed the filter and the
aggregate and took 11 ms. The gap grows with table size and network latency.

## Writes, transactions and batch inserts through postgres_fdw

Writes through `postgres_fdw` run in a remote transaction tied to the local one, at `REPEATABLE READ` (or
`SERIALIZABLE` when the local one is). The remote transaction is not prepared for two-phase commit, so a failure
between the commits of two servers can leave one committed and the other not.

```sql
ALTER FOREIGN TABLE billing.events OPTIONS (ADD batch_size '1000');
INSERT INTO billing.events SELECT g, 'x' FROM generate_series(1, 20000) g;
```

- With the default `batch_size` of 1, 20,000 rows took 255 ms over a local socket; with 1000 they took 14 ms. Over a
  real network the difference is far larger.
- `INSERT ... ON CONFLICT DO UPDATE` is not supported on foreign tables; `ON CONFLICT DO NOTHING` works without a
  conflict target. Stage rows remotely and upsert there (`dblink_exec`) instead.
- Long local transactions keep a remote `REPEATABLE READ` snapshot open, which holds back vacuum on the remote.

## Async scans of foreign partitions

A partitioned table whose partitions are foreign tables on different servers is a simple sharding layer. With
`async_capable` the `Append` scans all servers at once, and partitionwise aggregation sends the aggregate to each.

```sql
CREATE TABLE all_orders (id bigint NOT NULL, region text NOT NULL, total numeric NOT NULL)
  PARTITION BY LIST (region);
CREATE FOREIGN TABLE all_orders_eu PARTITION OF all_orders FOR VALUES IN ('eu')
  SERVER shard_eu OPTIONS (schema_name 'public', table_name 'orders');
CREATE FOREIGN TABLE all_orders_us PARTITION OF all_orders FOR VALUES IN ('us')
  SERVER shard_us OPTIONS (schema_name 'public', table_name 'orders');
SET enable_partitionwise_aggregate = on;
EXPLAIN (COSTS OFF) SELECT region, count(*), sum(total) FROM all_orders GROUP BY region;
```

The plan shows one `Async Foreign Scan` per server with `Relations: Aggregate on ...`. Rows routed to a foreign
partition are inserted remotely; unique constraints across shards are not enforced. For real sharding see
`postgres-citus-sharding`.

## Security of user mappings and SCRAM pass-through

A user mapping stores remote credentials in the catalog, and the mapped user can read its own mapping's password
in `pg_user_mappings` (seen on 18.6). Non-superusers must authenticate to the remote with a password, delegated
GSSAPI credentials or SCRAM pass-through; otherwise queries fail with `password or GSSAPI delegated credentials
required`, and a remote that does not ask for a password (`trust`) is refused too.

```sql
CREATE SERVER billing_scram FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'billing-db.internal', dbname 'billing', sslmode 'verify-full', use_scram_passthrough 'true');
CREATE USER MAPPING FOR scram_user SERVER billing_scram OPTIONS (user 'scram_user');
```

SCRAM pass-through (PostgreSQL 18) stores no password: it reuses the client's SCRAM login. It needs the client
session itself to log in with `scram-sha-256`, the remote to require `scram-sha-256`, and the same SCRAM secret for
the role on both servers (same salt and iterations; copy the `rolpassword` hash, do not just reuse the password).
Tested on 18.6: the mapping held only `{user=scram_user}` and the foreign query worked.

- Never map to a remote superuser; grant the remote role `SELECT` (and writes only where needed).
- `password_required 'false'` and `sslcert`/`sslkey` in a mapping can be set only by a superuser; never set
  `password_required 'false'` for `PUBLIC`.
- Use `sslmode 'verify-full'` in the server options; the remote `pg_hba.conf` should accept only the FDW host.

## dblink for remote commands

`dblink` runs any SQL text on another PostgreSQL server and returns rows as a record set, which suits commands a
foreign table cannot express. It accepts a connection string or the name of a `postgres_fdw` server, so credentials
stay in the user mapping.

```sql
CREATE EXTENSION IF NOT EXISTS dblink;
SELECT * FROM dblink('billing_srv', 'SELECT count(*) FROM app.customers') AS t(n bigint);
SELECT dblink_exec('billing_srv', 'VACUUM (ANALYZE) app.events');
```

Results need a column definition list (`AS t(n bigint)`). For queries, prefer `postgres_fdw`: it plans, pushes down
and handles transactions; dblink is plain text in and rows out.

## file_fdw for files on the database server

`file_fdw` reads a file, or a program's output, on the database server's file system as a table. PostgreSQL 18 adds
`on_error`, `reject_limit` and `log_verbosity`, the same options as `COPY`.

```sql
CREATE EXTENSION IF NOT EXISTS file_fdw;
CREATE SERVER files FOREIGN DATA WRAPPER file_fdw;
CREATE FOREIGN TABLE ext_scores (id int, name text, score int) SERVER files
  OPTIONS (filename '/srv/import/scores.csv', format 'csv', header 'true',
           on_error 'ignore', reject_limit '10', log_verbosity 'verbose');
SELECT * FROM ext_scores;
```

- Paths are on the server, read by the server's OS user. Creating a table with `filename` needs superuser or
  `pg_read_server_files`; `program` needs `pg_execute_server_program`.
- On Windows use forward slashes (`C:/import/scores.csv`); in a container the path is inside the container.
- `on_error 'ignore'` skips rows with type conversion errors only, with a `NOTICE` per row at `verbose`.

## Worked example: "report invoice totals from the billing database for our VIP customers"

The VIP list is local and invoices live in another database, imported as `billing_remote.invoices`. Read the plan before
the report ships. On 18.6, against a second database with 100,000 invoices:

```sql
EXPLAIN (VERBOSE, COSTS OFF)
SELECT v.id, sum(i.cents) FROM app.vip v JOIN billing_remote.invoices i ON i.customer_id = v.id GROUP BY 1;
```

The plan shows a `Nested Loop` over a `Foreign Scan` with `Remote SQL: SELECT customer_id, cents FROM billing.invoices
WHERE (($1::bigint = customer_id))`: one indexed lookup per VIP, with the `sum` run locally. A single customer does
better, because `WHERE customer_id = 7` pushes the whole aggregate down: `Remote SQL: SELECT customer_id, sum(cents) FROM
billing.invoices WHERE ((customer_id = 7)) GROUP BY 1`. If `Remote SQL` lacks your `WHERE`, every remote row crosses the
network, so fix that first.

## Verify pushdown, security and speed of a foreign table

Prove each important query from the local side, then from the remote side, before calling it done.

```sql
EXPLAIN (VERBOSE, COSTS OFF) SELECT count(*) FROM billing.invoices WHERE issued_on >= date '2026-10-01';
-- pass: Remote SQL holds the WHERE and the count; fail: a local Filter or Aggregate above Foreign Scan
SET ROLE reporting_app;
SELECT count(*) FROM billing.customers;      -- pass: a number; fail: user mapping not found, or permission denied
RESET ROLE;
```

Run [scripts/fdw-check.sql](scripts/fdw-check.sql) to confirm no password shows in plain text and each foreign table has
a `last_analyze`. On the remote, `pg_stat_activity` shows `application_name = 'reporting_fdw'` with the expected user.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Gotchas

These are the failures seen most often with foreign tables, each with its cause and fix.

1. **A foreign table query reads the whole remote table.** A local function, a local join or a type mismatch kept
   the filter local. Read `Remote SQL` in `EXPLAIN (VERBOSE)`, pass keys as an array, list extensions.
2. **`password or GSSAPI delegated credentials required`.** A non-superuser mapping without a password, or a remote
   on `trust`. Add a password, use SCRAM pass-through, and require `scram-sha-256` remotely.
3. **`function ... does not exist` on the remote.** A built-in function newer than the remote's version was pushed
   down. Wrap the foreign table in a subquery with `OFFSET 0` and apply the function outside.
4. **Bulk inserts into a foreign table are slow.** `batch_size` is 1. Set it to 1000.
5. **Wrong results with text comparisons.** Local and remote collations differ (`import_collate`, different OS).
   Declare columns with the remote's collation and compare on one side only.
6. **The remote server runs out of connections.** Each local session opens one connection per user mapping and
   keeps it. Set `keep_connections 'off'` for occasional use, or pool on the remote side.
7. **Estimates are wildly wrong.** No local statistics. `ANALYZE` the foreign table, or enable
   `use_remote_estimate`.

## Checklist

Check these points before you call a federation setup done.

- [ ] The remote role is dedicated and least-privilege; no mapping uses a superuser.
- [ ] Credentials use SCRAM pass-through, or a password only the mapped role can see; TLS is `verify-full`.
- [ ] Every important query's `Remote SQL` shows its filters, joins and aggregates pushed down.
- [ ] `fetch_size` is raised for scans and `batch_size` for inserts.
- [ ] Local keys go to the remote as arrays, not joins.
- [ ] Cross-server writes accept the lack of two-phase commit, or are made idempotent.
- [ ] Foreign tables have local statistics (`ANALYZE`) or `use_remote_estimate`.

## Anti-patterns with foreign data wrappers

| Do not | Do this instead |
|---|---|
| put federation on a hot request path | copy the data with logical replication or CDC |
| join a local table to a foreign one row by row | pass the keys as an array with `= ANY` |
| map to a remote superuser | a dedicated role with `SELECT` on what it reads |
| set `password_required 'false'` for `PUBLIC` | SCRAM pass-through, or a password in a per-role mapping |
| use `ON CONFLICT DO UPDATE` on a foreign table | stage remotely and upsert there through `dblink_exec` |
| trust a query without reading `Remote SQL` | check `EXPLAIN (VERBOSE)` on every important query |

## See also

- `postgres-replication-ha`: logical replication between PostgreSQL servers.
- `postgres-cdc-logical-decoding`: streaming changes to other systems.
- `postgres-bulk-load-etl`: `COPY`, staging tables and pgloader.
- `postgres-citus-sharding`: real sharding.
- `postgres-security-roles`: roles and grants on both sides.
- `postgres-query-performance`: reading plans.

## Sources

- https://www.postgresql.org/docs/18/postgres-fdw.html
- https://www.postgresql.org/docs/18/dblink.html
- https://www.postgresql.org/docs/18/file-fdw.html
- https://www.postgresql.org/docs/18/sql-createforeignserver.html
- https://www.postgresql.org/docs/18/sql-importforeignschema.html
- https://www.postgresql.org/docs/18/release-18.html (SCRAM pass-through, file_fdw options, CREATE FOREIGN TABLE LIKE)
- https://github.com/EnterpriseDB/mysql_fdw (README, release REL-2_9_3)
- https://github.com/laurenz/oracle_fdw (README, release ORACLE_FDW_2_9_0)
- https://github.com/tds-fdw/tds_fdw (README)
- https://github.com/duckdb/pg_duckdb (README, release v1.1.1)
- https://github.com/CrunchyData/pg_parquet (README)
- https://apt.postgresql.org (PostgreSQL 18 package list)
