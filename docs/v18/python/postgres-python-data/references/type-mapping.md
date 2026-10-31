---
title: PostgreSQL type mapping into pandas, Polars, Arrow and DuckDB
author: MOZGII, Inc.
lang: en
---

# PostgreSQL type mapping into pandas, Polars, Arrow and DuckDB

This reference lists what each PostgreSQL type becomes on each Python read path, as observed with pandas 3.1.0,
Polars 2.1.0, PyArrow 26.0.0, adbc-driver-postgresql 1.13.0, connectorx 0.4.6, DuckDB 2.0.0, SQLAlchemy 2.1.6 and
psycopg 3.3.6 against PostgreSQL 18.6. Check the columns of every new pipeline against it; wrong types are silent.

## Paths compared

Five read paths were run on the same tables:

| Short name | Call |
|---|---|
| pandas-SA | `pd.read_sql(text(q), sqlalchemy_engine)` with `postgresql+psycopg` |
| pandas-ADBC | `pd.read_sql(q, adbc_conn)` |
| pandas-ADBC-Arrow | `pd.read_sql(q, adbc_conn, dtype_backend="pyarrow")` |
| Polars-cx / Polars-ADBC | `pl.read_database_uri(q, uri, engine="connectorx" or "adbc")` |
| DuckDB | `ATTACH ... (TYPE postgres)` then `DESCRIBE` |

## Numbers: integers, numeric and NULLs

Integer columns keep their width on Arrow paths; NumPy-backed pandas turns a column with any `NULL` into `float64`.
`numeric` is the column most often damaged.

| PostgreSQL | pandas-SA | pandas-ADBC | pandas-ADBC-Arrow | Polars-cx | Polars-ADBC | DuckDB |
|---|---|---|---|---|---|---|
| `bigint` | `int64` | `int64` | `int64[pyarrow]` | `Int64` | `Int64` | `BIGINT` |
| `int` with NULLs | `float64` | `float64` | `int32[pyarrow]` | `Int32` | `Int32` | `INTEGER` |
| `int`, all NULL | `object` | `float64` | `int32[pyarrow]` | `Int32` | not tested | `INTEGER` |
| `numeric(12,2)` | `float64` | `object` (strings `'0.29'`) | opaque string extension | `Decimal(38, 10)` | opaque string extension | `DECIMAL(12,2)` |
| `numeric` (no precision) | `float64` | `object` | opaque string extension | `Decimal(38, 10)` | opaque string extension | `DOUBLE` |

For money, read through connectorx or DuckDB, or aggregate in SQL and read the totals. Casting in the query
(`amount::float8`) is fine for statistics, never for accounting.

## Time: timestamptz, timestamp, date and interval

Time zones depend on the path and on the session `TimeZone`; the same data read through pandas-SA with
`dtype_backend="pyarrow"` came back in `America/New_York` (the server's zone) while the NumPy path gave UTC.

| PostgreSQL | pandas-SA | pandas-ADBC | pandas-ADBC-Arrow | Polars-cx | Polars-ADBC | DuckDB |
|---|---|---|---|---|---|---|
| `timestamptz` | `datetime64[us, UTC]` | `datetime64[us, UTC]` | `timestamp[us, tz=UTC]` | `Datetime(us, UTC)` | `Datetime(us, UTC)` | `TIMESTAMP WITH TIME ZONE` |
| `timestamp` | `datetime64[us]` | `datetime64[us]` | `timestamp[us]` | `Datetime(us)` | not tested | `TIMESTAMP` |
| `date` | `object` (`datetime.date`) | `object` | `date32[day]` | `Date` | `Date` | `DATE` |
| `interval` | `timedelta64[us]` | `object` | `month_day_nano_interval` | panic: not implemented | panic | `INTERVAL` |

Both Polars engines abort on an `interval` column with a Rust `PanicException`, which `except Exception` does not
catch. Cast it in SQL: `extract(epoch FROM iv) AS iv_seconds` or `iv::text`. Connect with
`options=-c TimeZone=UTC` (psycopg, SQLAlchemy) so every path agrees.

## Text, JSON, UUID, arrays and bytes

pandas 3 stores text in its string dtype; JSON handling differs per path.

| PostgreSQL | pandas-SA | pandas-ADBC | pandas-ADBC-Arrow | Polars-cx | Polars-ADBC | DuckDB |
|---|---|---|---|---|---|---|
| `text` with NULLs | `StringDtype` (NaN) | `str` | `string[pyarrow]` | `String` | `String` | `VARCHAR` |
| `jsonb` | `object` (dicts) | `object` (JSON text) | `arrow.json` extension | `String` | `arrow.json` extension | `VARCHAR` |
| `uuid` | `object` (`uuid.UUID`) | `object` | `arrow.uuid` extension | `String` | not tested | `UUID` |
| `boolean` | `bool` | `bool` | `bool[pyarrow]` | `Boolean` | not tested | `BOOLEAN` |
| `int[]` | `object` (lists) | `object` | `list<int32>` | `List(Int32)` | not tested | `INTEGER[]` |
| `bytea` | `object` (bytes) | `object` | `binary` | `Binary` | not tested | `BLOB` |

Do not read through pandas-SA with `dtype_backend="pyarrow"`: it turned `jsonb` into Python `repr` strings
(`"{'k': 1}"`, not JSON) and `date` into strings. Flatten JSON in SQL (`meta->>'k' AS k`) when only a few keys are
needed.

## Writing types back with to_sql and ADBC ingest

When pandas or Polars create the table, they choose types from the dataframe: an integer column with NaN became
`double precision`, `float64` became `double precision`, strings became `text`, and timezone-aware datetimes became
`timestamp with time zone`. No primary key, index or constraint is created. Create the table in SQL (or a migration)
with the real types and append into it.

## Sources

- https://pandas.pydata.org/docs/user_guide/io.html
- https://arrow.apache.org/adbc/current/driver/postgresql.html
- https://docs.pola.rs/api/python/stable/reference/api/polars.read_database_uri.html
- https://duckdb.org/docs/2.0/core_extensions/postgres/overview.html
- https://www.postgresql.org/docs/18/datatype.html
