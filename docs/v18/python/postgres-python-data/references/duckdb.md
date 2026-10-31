---
title: DuckDB with PostgreSQL from Python
author: MOZGII, Inc.
lang: en
---

# DuckDB with PostgreSQL from Python

This reference covers DuckDB 2.0's `postgres` extension from Python: installing it into a chosen folder, attaching
with a connection string or a secret, read-only attaches, analytical queries over live tables, `postgres_query` and
`postgres_execute`, writing results back, exporting to partitioned Parquet, and the settings that control scans.
Every example ran with DuckDB 2.0.0 against PostgreSQL 18.6.

## Installing the DuckDB postgres extension

`uv add duckdb` installs DuckDB; the `postgres` extension is downloaded from DuckDB's extension repository on first
`INSTALL` (or autoloaded on first use) into `~/.duckdb/extensions/<version>/<platform>/` by default. Set
`extension_directories` first when the home folder is read-only, in containers, or when extensions must live with the
project; the singular `extension_directory` is deprecated in DuckDB 2.0.

```python
import duckdb

con = duckdb.connect()                                      # in-memory DuckDB
con.execute("SET extension_directories = ['.duckdb_extensions']")
con.execute("INSTALL postgres")
con.execute("LOAD postgres")
```

DuckDB ships wheels for macOS, Linux (glibc, x86-64 and arm64) and Windows (x64 and arm64). An air-gapped server
needs the extension file copied in advance.

## Attaching PostgreSQL with ATTACH

`ATTACH` takes a libpq connection string or a `postgresql://` URI and makes every schema visible as
`<alias>.<schema>.<table>`. `READ_ONLY` refuses writes; `SCHEMA 'app'` attaches one schema; the scan transactions use
`REPEATABLE READ` unless `ISOLATION_LEVEL` says otherwise.

```python
con.execute("ATTACH 'host=db.internal port=5432 dbname=app user=analyst' AS pg (TYPE postgres, READ_ONLY)")
con.sql("DESCRIBE pg.app.sales").fetchall()          # numeric(12,2) appears as DECIMAL(12,2)
```

A write on a read-only attach fails with `Cannot execute statement of type "INSERT" on database "ro" which is attached
in read-only mode!`. DuckDB's docs warn that a connection error may print the whole connection string, so keep
passwords out of it.

## Keeping credentials in a DuckDB secret

A postgres secret holds host, port, database, user and password; `ATTACH ''` with `SECRET <name>` uses it, and a
non-empty connection string overrides single fields. Fill the password from the environment, not from code.

```python
pw = os.environ["PGPASSWORD_ANALYST"].replace("'", "''")
con.execute(f"CREATE SECRET pg_app (TYPE postgres, HOST 'db.internal', PORT 5432, DATABASE app, "
            f"USER 'analyst', PASSWORD '{pw}')")
con.execute("ATTACH '' AS pg (TYPE postgres, SECRET pg_app, SCHEMA 'app')")
```

Secrets are temporary by default; `CREATE PERSISTENT SECRET` stores them on disk in DuckDB's secret folder, which then
needs the same protection as a `.pgpass` file. The standard `PGHOST`, `PGUSER`, `PGPASSWORD` and `PGDATABASE`
variables also work with `ATTACH ''`.

## Querying live tables and pushdown

Queries against `pg.<schema>.<table>` read the table with binary `COPY`, split into parallel tasks by page ranges
(`ctid`), and push simple filters and projections down. `EXPLAIN` shows what reached Postgres:

```python
print(con.sql("EXPLAIN SELECT id FROM pg.app.sales WHERE id = 5").fetchall()[0][1])
# Postgres Scan / Table: sales / Projections: id / Filters: id = 5
```

Aggregations, window functions and joins run in DuckDB after the rows arrive. Every query re-reads the table, so
copy a table into DuckDB (`CREATE TABLE local_sales AS FROM pg.app.sales`) when you query it many times.

## postgres_query and postgres_execute

`postgres_query(attached_db, sql)` runs a read query inside Postgres and returns its result, for SQL DuckDB does not
speak (Postgres functions, `jsonb` operators, extensions). `postgres_execute(attached_db, sql)` runs any statement,
DDL included, on a read-write attach.

```python
con.sql("SELECT * FROM postgres_query('pg', 'SELECT pg_typeof(total)::text AS t FROM app.daily LIMIT 1')")
con.execute("CALL postgres_execute('pg', 'CREATE TABLE IF NOT EXISTS app.daily (day date PRIMARY KEY, total numeric(14,2))')")
```

Quote single quotes inside the SQL string by doubling them. After DDL from another client, `CALL
postgres_clear_cache()` refreshes DuckDB's cached schema (DuckDB also checks for changes automatically on PostgreSQL).

## Writing results back to PostgreSQL

On a read-write attach, `INSERT`, `CREATE TABLE ... AS`, `UPDATE` and `DELETE` run against Postgres. This rebuilds a
daily summary from the live table:

```python
con.execute("ATTACH '' AS pg (TYPE postgres, SECRET pg_app)")
con.execute("DELETE FROM pg.app.daily")
con.execute("INSERT INTO pg.app.daily SELECT day, sum(amount) FROM pg.app.sales GROUP BY day")   # 365 rows
con.execute("CREATE OR REPLACE TABLE pg.app.store_totals AS "
            "SELECT store_id, sum(amount) AS total FROM read_parquet('sales.parquet') GROUP BY store_id")
```

Tables DuckDB creates get DuckDB's idea of the types and no indexes or constraints; for tables an application owns,
create them in Postgres first (or through `postgres_execute`) and insert into them.

## Exporting PostgreSQL to Parquet

`COPY (query) TO 'file' (FORMAT parquet)` writes a Parquet file; `PARTITION_BY` writes a Hive-style folder tree
that later reads can prune.

```python
con.execute("COPY (SELECT * FROM pg.app.sales) TO 'sales.parquet' (FORMAT parquet, COMPRESSION zstd)")
con.execute("COPY (SELECT *, month(day) AS m FROM pg.app.sales) TO 'by_month' "
            "(FORMAT parquet, PARTITION_BY (m), OVERWRITE_OR_IGNORE)")
con.sql("SELECT m, count(*) FROM read_parquet('by_month/*/*.parquet', hive_partitioning = true) GROUP BY m")
```

The one-million-row table (113 MB in Postgres) became a 4.8 MB file, and the partitioned export 12 folders `m=1` to
`m=12`. Results convert to pandas with `.df()`, to Polars with `.pl()` (`DECIMAL(12,2)` stayed
`Decimal(precision=12, scale=2)`), and to Arrow with `.arrow()`.

## DuckDB postgres extension settings

These settings tune scans; defaults were read from the running DuckDB 2.0.0 with `current_setting()`.

| Setting | Default | Effect |
|---|---|---|
| `pg_use_binary_copy` | `true` | read with binary `COPY` |
| `pg_enable_filter_pushdown` | `true` | send `WHERE` filters to Postgres |
| `pg_pages_per_task` | `1000` | pages per parallel scan task |
| `pg_use_ctid_scan` | `true` | split scans by `ctid` ranges |
| `pg_statement_timeout_millis` | `NULL` | `statement_timeout` on scan connections |
| `pg_numeric_as_varchar` | `false` | read unconstrained `numeric` as text instead of `DOUBLE` |

Parallel scans open several connections at once; on a busy server, lower DuckDB's `threads` or point it at a replica.

## Sources

- https://duckdb.org/docs/2.0/core_extensions/postgres/overview.html
- https://duckdb.org/docs/2.0/core_extensions/postgres/functions.html
- https://duckdb.org/docs/2.0/core_extensions/postgres/secrets.html
- https://duckdb.org/docs/2.0/core_extensions/postgres/connection_pool.html
- https://duckdb.org/docs/2.0/extensions/installing_extensions.html
- https://pypi.org/project/duckdb/
