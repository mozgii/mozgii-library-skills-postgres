---
name: postgres-python-data
description: 'Moves data between PostgreSQL and Python dataframes fast and correctly, from a copy-paste uv quickstart: pandas read_sql and to_sql (SQLAlchemy or ADBC, method multi versus COPY), Polars read_database_uri with connectorx or ADBC and write_database, the ADBC PostgreSQL driver with Arrow tables and adbc_ingest, DuckDB''s postgres extension (ATTACH, postgres_query, export to Parquet), chunked reads of big tables, type mapping for numeric, timestamptz, dates, JSON and NULLs, Jupyter notebooks, and memory limits with measured numbers. Use when loading a Postgres table into pandas or Polars, writing a DataFrame to Postgres, read_sql is slow or runs out of memory, numbers or timezones come back wrong, or exporting Postgres to Parquet.'
metadata:
  tags:
  - postgres
  - python
  - pandas
  - polars
  - adbc
  - duckdb
  - arrow
  - etl
---

# PostgreSQL and Python dataframes

Arrow-based paths (ADBC, connectorx, DuckDB) read a Postgres table into a dataframe several times faster and with a
fraction of the memory of `pandas.read_sql` over SQLAlchemy, and they keep integer columns with `NULL`s as integers.
Write with `COPY` (ADBC ingest, or a psycopg `COPY` callable for `to_sql`), never row-by-row `INSERT`s. Driver choice
for application code is in `postgres-python`; COPY from plain psycopg is in `postgres-python-psycopg`. The full type
table: [references/type-mapping.md](references/type-mapping.md); DuckDB in depth:
[references/duckdb.md](references/duckdb.md).

## Quickstart: a Postgres query into pandas with uv

This quickstart reads a parameterized query into a pandas DataFrame through the ADBC driver, which ships wheels for
macOS, Linux (glibc) and Windows and needs no libpq.

```bash
uv init analysis && cd analysis
uv add pandas pyarrow adbc-driver-postgresql
export DATABASE_URL="postgresql://app@localhost:5432/app"     # PowerShell: $env:DATABASE_URL = "..."
```

The program opens a connection, runs the query with a `$1` parameter, converts the Arrow result to pandas with Arrow
types, and closes the connection when the block ends.

```python
# main.py
import os

import adbc_driver_postgresql.dbapi as pg
import pandas as pd

with pg.connect(os.environ["DATABASE_URL"]) as conn, conn.cursor() as cur:
    cur.execute("SELECT id, sold_at, store_id FROM app.sales WHERE store_id = $1 LIMIT 5", parameters=(7,))
    df = cur.fetch_arrow_table().to_pandas(types_mapper=pd.ArrowDtype)
print(df.dtypes)          # id int64[pyarrow], sold_at timestamp[us, tz=UTC][pyarrow], store_id int32[pyarrow]
```

Run it with `uv run main.py`. A Unix socket URL is `postgresql://app@localhost/app?host=/var/run/postgresql`.

## Step 0: read installed dataframe and driver versions

The dataframe libraries changed major versions in 2026, so read what is installed before copying an example.

```bash
uv run python -c "import importlib.metadata as m; print({p: m.version(p) for p in ['pandas','polars','pyarrow','adbc-driver-postgresql','connectorx','duckdb','sqlalchemy','psycopg']})"
```

Versions in October 2026: pandas 3.1.0, Polars 2.1.0, PyArrow 26.0.0, adbc-driver-postgresql 1.13.0, connectorx
0.4.6, DuckDB 2.0.0, SQLAlchemy 2.1.6, psycopg 3.3.6.

## Choosing a read path: SQLAlchemy, ADBC, connectorx or DuckDB

The read path decides speed, memory and types. Measured here reading one million rows of eight columns (`bigint`,
`timestamptz`, `int` with NULLs, `numeric(12,2)`, `int`, `text`, `jsonb`, `date`; 113 MB on disk) over a Unix
socket, each in a fresh process on a busy machine, so compare the ratios rather than the seconds:

| Path | Time | Peak memory | Integers with NULL | `numeric` |
|---|---|---|---|---|
| `pd.read_sql(text(q), sqlalchemy_engine)` | 16.1 s | 1,137 MB | `float64` | `float64` (rounded) |
| `pd.read_sql(q, adbc_conn)` | 4.8 s | 298 MB | `float64` | `object` (strings) |
| `pl.read_database_uri(q, uri, engine="connectorx")` | 2.3 s | 273 MB | `Int32` | `Decimal(38, 10)` |
| `pl.read_database_uri(q, uri, engine="adbc")` | 0.9 s | 238 MB | `Int32` | opaque string extension |
| `pd.read_sql(..., chunksize=50_000)` over a streaming SQLAlchemy connection | 5.3 s | 227 MB | `float64` | `float64` |

- Analysis in pandas: ADBC, with `dtype_backend="pyarrow"` to keep integer and date types.
- Analysis in Polars: `read_database_uri` (connectorx by default, `engine="adbc"` for the fastest read).
- Aggregations over large tables, joins with files, export to Parquet: DuckDB's `postgres` extension.
- Existing SQLAlchemy code and small results: `pd.read_sql` is fine below about 100,000 rows.

## pandas.read_sql with SQLAlchemy

`pandas.read_sql` takes a SQLAlchemy engine or connection, a `text()` query and `params`; with the psycopg driver,
named parameters use `:name` in `text()`.

```python
import pandas as pd
from sqlalchemy import create_engine, text

engine = create_engine(os.environ["SA_URL"])        # postgresql+psycopg://app@db/app
df = pd.read_sql(text("SELECT * FROM app.sales WHERE store_id = :s"), engine, params={"s": 7})
```

`numeric` arrives as `float64` and integer columns containing `NULL` become `float64` with `NaN`. Do not combine this
path with `dtype_backend="pyarrow"`: in a test here it turned `date` into strings, `jsonb` into Python `repr` text
(`"{'k': 1}"`), and `timestamptz` into the session time zone instead of UTC.

## Chunked reads of big tables

`chunksize=` alone still loads the whole result into the driver first (peak 395 MB here for the million rows).
Combine it with a streaming (server-side) cursor, so memory stays near one chunk (227 MB):

```python
with engine.connect().execution_options(stream_results=True, max_row_buffer=50_000) as conn:
    for chunk in pd.read_sql(text("SELECT * FROM app.sales"), conn, chunksize=50_000):
        process(chunk)                                   # write out, aggregate, discard
```

With ADBC, `cur.fetch_record_batch()` returns a `RecordBatchReader` that yields Arrow batches; Polars has
`pl.read_database(query, conn, iter_batches=True, batch_size=200_000)`. For exports that must resume after a failure,
page by key instead (`WHERE id > :last ORDER BY id LIMIT 100000`), which also avoids a long-open transaction.

## ADBC driver for PostgreSQL

ADBC (Arrow Database Connectivity) is a DB-API driver that returns Arrow data directly; `adbc-driver-postgresql`
reads with binary `COPY` and writes with `COPY` through `adbc_ingest`. Parameters are `$1`, `$2`.

```python
import adbc_driver_postgresql.dbapi as pg
import pyarrow as pa

with pg.connect(os.environ["DATABASE_URL"]) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM app.sales WHERE sold_at >= $1", parameters=(start,))
        table = cur.fetch_arrow_table()                     # 1,000,000 rows: 58 MB of Arrow buffers
        data = pa.table({"id": pa.array(range(200_000), pa.int64()), "v": pa.array([0.1] * 200_000)})
        cur.adbc_ingest("adbc_in", data, mode="create", db_schema_name="app")   # also "append", "replace"
    conn.commit()                                          # ADBC connections do not autocommit
```

- `pd.read_sql(query, adbc_conn)` works, but `params=` raises `NotImplementedError: 'params' is not implemented for
  ADBC drivers`; run parameterized queries on the cursor as in the quickstart.
- `numeric` arrives as an opaque string type; cast in SQL (`amount::float8`) or convert after reading.
- Wheels exist for macOS, glibc Linux and Windows; not for Alpine (musl).

## Polars read_database_uri and write_database

Polars reads from a URI with connectorx (default) or ADBC, and from an existing connection with `read_database`.
connectorx can split a read into parallel queries on a numeric column.

```python
import polars as pl

uri = os.environ["DATABASE_URL"]
df = pl.read_database_uri("SELECT * FROM app.sales", uri)                       # connectorx
df = pl.read_database_uri("SELECT * FROM app.sales", uri, engine="adbc")
ids = pl.read_database_uri("SELECT id, amount FROM app.sales", uri,
                           partition_on="id", partition_num=4)               # 4 parallel range queries
rows = df.write_database("app.sales_out", connection=uri, if_table_exists="replace", engine="adbc")
```

`write_database` with `engine="adbc"` uses `adbc_ingest` (100,000 rows took 0.07 s); with `engine="sqlalchemy"` it
calls pandas `to_sql` and needs pandas installed. connectorx has wheels for macOS, glibc Linux and Windows x64 only.

## Writing DataFrames: to_sql, method multi and COPY

`DataFrame.to_sql` creates or appends to a table; the `method` decides the SQL. Writing 100,000 rows of seven columns
with SQLAlchemy and psycopg measured:

| `method` | SQL sent | Time |
|---|---|---|
| `None` (default) | one `INSERT` per row, sent with `executemany` | 0.95 s |
| `"multi"`, `chunksize=9_000` | multi-row `INSERT ... VALUES (...), (...)` | 5.91 s |
| a COPY callable (below) | `COPY ... FROM STDIN` | 0.17 s |
| `to_sql` on an ADBC connection (200,000 rows) | `COPY` through `adbc_ingest` | 0.19 s |

This callable streams the rows through psycopg's `COPY`; pass it as `method=psql_copy`:

```python
from psycopg import sql

def psql_copy(table, conn, keys, data_iter):
    dbapi_conn = conn.connection                     # the psycopg connection under SQLAlchemy
    columns = sql.SQL(", ").join(map(sql.Identifier, keys))
    name = sql.Identifier(*filter(None, (table.schema, table.name)))
    with dbapi_conn.cursor() as cur:
        with cur.copy(sql.SQL("COPY {} ({}) FROM STDIN").format(name, columns)) as copy:
            for row in data_iter:
                copy.write_row(row)

df.to_sql("sales_copy", engine, schema="app", if_exists="append", index=False, method=psql_copy)
```

- `method="multi"` with a large `chunksize` fails with `number of parameters must be between 0 and 65535`: keep
  `chunksize * columns` below 65,535, or better, use COPY.
- `to_sql` invents column types from pandas dtypes (`double precision` for an integer column with NaN). Create the
  table with real types and constraints first, then `if_exists="append"`.
- `if_exists="replace"` drops the table, with its indexes, grants and foreign keys.

## Type mapping between PostgreSQL and dataframes

The type mapping is where silent data errors come from. The cases to check on every new pipeline:

| PostgreSQL | Risk | Fix |
|---|---|---|
| `numeric` | rounded to `float64` (SQLAlchemy path) or a string (ADBC) | connectorx `Decimal`, DuckDB `DECIMAL`, or cast to `float8` on purpose |
| `int` with `NULL` | becomes `float64` with `NaN` in NumPy-backed pandas | `dtype_backend="pyarrow"` on ADBC, or Polars |
| `timestamptz` | zone depends on path and session `TimeZone` | read as UTC (`options=-c TimeZone=UTC`), convert for display |
| `timestamp` (no zone) | naive values, meaning lost | store `timestamptz` |
| `date` | Python `date` objects (`object` dtype) | Arrow backend gives `date32` |
| `jsonb` | dicts, strings or an Arrow JSON extension | parse explicitly, or flatten in SQL (`meta->>'k'`) |
| `interval` | both Polars engines abort with a Rust `PanicException` | cast in SQL: `extract(epoch FROM iv)` |

Every path above read NULL text as missing (`NaN` or null), never as the string `'None'`. More detail per path:
[references/type-mapping.md](references/type-mapping.md).

## DuckDB postgres extension: query, join and export to Parquet

DuckDB's `postgres` extension attaches a live Postgres database and runs DuckDB SQL against it, reading with binary
`COPY` in parallel and pushing filters down. It is the shortest way to aggregate a big table or export it to Parquet.

```python
import duckdb

con = duckdb.connect()
con.execute("INSTALL postgres")
con.execute("LOAD postgres")
con.execute("ATTACH 'host=db.internal dbname=app user=analyst' AS pg (TYPE postgres, READ_ONLY)")
top = con.sql("SELECT store_id, count(*) AS n, sum(amount) AS total FROM pg.app.sales "
              "GROUP BY store_id ORDER BY n DESC LIMIT 3").df()
con.execute("COPY (SELECT * FROM pg.app.sales) TO 'sales.parquet' (FORMAT parquet, COMPRESSION zstd)")
```

The 113 MB table became a 4.8 MB Parquet file; `numeric(12,2)` stayed `DECIMAL(12,2)`. Writing back, `postgres_query`,
secrets and settings are in [references/duckdb.md](references/duckdb.md).

## Postgres in Jupyter notebooks

A notebook keeps its kernel, connections and open transactions alive between cells, which Postgres sees as a
long-lived client. Create one engine or connection per notebook, set a `statement_timeout` and an
`application_name`, and explore with `LIMIT` or `TABLESAMPLE` before pulling whole tables.

```python
engine = create_engine(os.environ["SA_URL"], connect_args={
    "application_name": "notebook-ann", "options": "-c statement_timeout=60s -c TimeZone=UTC"})
```

- Read through `engine` (each call checks out and returns a connection), not one `engine.connect()` held across
  cells: a failed cell leaves that connection idle in a transaction, which holds back vacuum.
- Point notebooks at a replica or a reporting role, not the primary with write rights (`postgres-security-roles`).
- The JupySQL `%sql` magic (0.11.1, last released March 2025) fills `{{variable}}` by text templating, not as a bound
  parameter: never put user input there.
- Call `engine.dispose()` or restart the kernel when done, so connections close.

## Memory limits for dataframe loads

A DataFrame needs several times the table's size on disk: the one-million-row table (113 MB) peaked at 1.1 GB in
pandas over SQLAlchemy and about 240 to 300 MB through Arrow paths. Before loading, estimate with
`SELECT pg_size_pretty(pg_table_size('app.sales'))` and the row count, select only the needed columns, filter and
aggregate in SQL, and stream in chunks when the result is larger than a quarter of free RAM. For data larger than
memory, use DuckDB on Parquet or Polars' lazy API on Parquet files exported once.

## Verify a dataframe load against the source

A silent type error passes every other test, so compare the frame with the database. This ran on 18.6 with ADBC on
pandas 3.1; `df` is the frame the pipeline loaded.

```python
with pg.connect(os.environ["DATABASE_URL"]) as conn, conn.cursor() as cur:
    cur.execute("SELECT count(*), sum(amount)::float8, count(*) FILTER (WHERE store_id IS NULL) FROM app.sales")
    rows, total, null_stores = cur.fetchone()
assert len(df) == rows
assert abs(float(df["amount"].astype("float64").sum()) - total) < 0.01
assert int(df["store_id"].isna().sum()) == null_stores
print(df.dtypes)
```

Print `dtypes` on every new pipeline and read them against the type table above. Run the same check after a write,
with the two sides swapped.

## Gotchas

These are the dataframe failures seen most often with Postgres, each with its cause and fix.

1. **Money totals are off by cents.** `numeric` was read as `float64`. Read with connectorx or DuckDB, or keep
   decimals in SQL.
2. **An integer column turned into floats.** It has `NULL`s and pandas used NumPy types. Use the Arrow backend on
   ADBC, or Polars.
3. **`number of parameters must be between 0 and 65535`.** `to_sql(method="multi")` with too many rows per chunk.
   Use COPY.
4. **`NotImplementedError: 'params' is not implemented for ADBC drivers`.** Run the query on the ADBC cursor with
   `parameters=`.
5. **The kernel dies on `read_sql`.** The whole result was materialized. Stream with `stream_results` and
   `chunksize`, or use Arrow.
6. **Times are shifted by hours.** The session `TimeZone` differed between paths. Connect with `TimeZone=UTC`.
7. **A table lost its indexes and grants.** `to_sql(if_exists="replace")` dropped it. Create tables yourself and
   append.

## Anti-patterns in dataframe pipelines

These lose data quietly, or lose the kernel loudly.

| Do not | Do instead |
|---|---|
| Pull a whole table to aggregate it in pandas | Aggregate in SQL or DuckDB and fetch the result |
| Write with `to_sql(method="multi")` | Write with COPY: ADBC ingest or a COPY callable |
| Use `if_exists="replace"` on a real table | Create the table with real types and use `append` |
| Read money as `float64` | Keep decimals with connectorx or DuckDB, or sum in SQL |
| Hold one connection across notebook cells | Read through an engine, so a failed cell leaves no open transaction |
| Point a notebook at the primary with write rights | Use a replica or a read-only role |

## Checklist

Check these points before you call a dataframe pipeline done.

- [ ] Read path chosen by size: Arrow (ADBC, connectorx, DuckDB) for large reads.
- [ ] `numeric`, nullable integers, `timestamptz` and `jsonb` columns checked after the first load.
- [ ] Session in UTC; `statement_timeout` and `application_name` set.
- [ ] Big reads streamed or paged by key; only needed columns selected.
- [ ] Writes use COPY (ADBC ingest or a COPY callable) into a table created with real types.
- [ ] Notebook connections point at a replica or read-only role and are disposed of.

## See also

Related skills in this library, each one works on its own:

- `postgres-python`: driver choice for application code.
- `postgres-python-psycopg`: COPY from plain psycopg.
- `postgres-python-sqlalchemy`: engines and sessions.
- `postgres-bulk-load-etl`: staging tables and big loads.
- `postgres-sql-dates-times`: `timestamptz` and time zones.
- `postgres-security-roles`: reporting roles.

## Sources

- https://pandas.pydata.org/docs/reference/api/pandas.read_sql.html
- https://pandas.pydata.org/docs/reference/api/pandas.DataFrame.to_sql.html
- https://pandas.pydata.org/docs/user_guide/io.html
- https://docs.pola.rs/api/python/stable/reference/api/polars.read_database_uri.html
- https://docs.pola.rs/api/python/stable/reference/api/polars.DataFrame.write_database.html
- https://arrow.apache.org/adbc/current/driver/postgresql.html
- https://duckdb.org/docs/2.0/core_extensions/postgres/overview.html
- https://pypi.org/project/jupysql/
