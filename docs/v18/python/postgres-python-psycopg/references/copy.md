---
title: COPY from Python with psycopg 3
author: MOZGII, Inc.
lang: en
---

# COPY from Python with psycopg 3

This reference covers PostgreSQL `COPY` through psycopg 3: loading Python rows with `write_row`, loading a CSV file in
blocks, exporting a query to a file, binary COPY, streaming a table between two databases, and async COPY. Every
example ran against PostgreSQL 18.6 with psycopg 3.3.6. SQL-side bulk load design (staging tables, indexes,
`unnest`) is in `postgres-sql-patterns`.

## How fast COPY is compared with executemany

COPY sends rows as one stream instead of one statement per row. Loading 100,000 rows of `(int, timestamptz, float8)`
over a local Unix socket measured:

| Method | Time |
|---|---|
| `cur.executemany("INSERT ... VALUES (%s, %s, %s)", rows)` | 4.4 s |
| `copy.write_row(row)`, text format | 1.2 s |
| `copy.write_row(row)`, binary format with `set_types` | 0.7 s |
| `copy.write(block)` from a CSV file, 1 MiB blocks | 0.3 s |

Over a network the gap grows, because `executemany` still waits on the server per batch. Use `executemany` for
hundreds of rows, COPY above that.

## Loading Python rows with copy.write_row

`write_row` adapts each value the way query parameters are adapted (`Jsonb`, `Decimal`, aware `datetime`, lists for
arrays). Name the columns, and give no `FORMAT`, `DELIMITER` or `NULL` options: `write_row` writes its own format.

```python
import psycopg
from psycopg.types.json import Jsonb

with psycopg.connect(os.environ["DATABASE_URL"]) as conn, conn.cursor() as cur:
    with cur.copy("COPY app.readings (sensor_id, at, value, meta) FROM STDIN") as copy:
        for r in readings:
            copy.write_row((r.sensor_id, r.at, r.value, Jsonb(r.meta)))
# the with block commits; an exception inside the copy block discards every row sent
```

Binary format is faster but the server applies no casts, so the Python types must match the columns exactly; declare
them with `set_types`:

```python
with cur.copy("COPY app.r (sensor_id, at, value) FROM STDIN (FORMAT BINARY)") as copy:
    copy.set_types(["int4", "timestamptz", "float8"])
    for r in rows:
        copy.write_row(r)
```

Without `set_types`, a Python `float` sent into a `numeric` column fails with `ProtocolViolation: insufficient data
left in message`.

## Loading a CSV file in blocks with copy.write

When data is already in COPY's format (a CSV export, an earlier `COPY TO`), pass raw blocks to `copy.write` and let
the server parse them. Any COPY option works here.

```python
with open("readings.csv", "rb") as f, cur.copy(
    "COPY app.r (sensor_id, at, value) FROM STDIN (FORMAT csv, HEADER true)"
) as copy:
    while data := f.read(1 << 20):
        copy.write(data)
```

This reads the file on the client, so it works with a remote server and needs no superuser or `pg_read_server_files`
role, unlike `COPY ... FROM '/path'`. On Windows, open the file in binary mode as shown, so line endings pass through
unchanged; the server accepts `\r\n` in CSV.

## Exporting a query to a file with COPY TO STDOUT

`COPY (query) TO STDOUT` streams the result in blocks, so memory stays flat whatever the size. Parameters work in the
query, and `psycopg.sql` composes table names.

```python
from psycopg import sql

query = sql.SQL("COPY (SELECT * FROM {} WHERE sensor_id = %s) TO STDOUT (FORMAT csv, HEADER true)").format(
    sql.Identifier("app", "r"))
with open("sensor7.csv", "wb") as f, cur.copy(query, (7,)) as copy:
    for block in copy:
        f.write(block)
```

## Reading COPY rows as Python values

`copy.rows()` yields rows from `COPY TO`; the server sends no types, so without `set_types` every value is a string.

```python
with cur.copy("COPY (SELECT sensor_id, at, value FROM app.readings) TO STDOUT") as copy:
    copy.set_types(["int4", "timestamptz", "float8"])
    for sensor_id, at, value in copy.rows():
        handle(sensor_id, at, value)
```

For most reads, a server-side cursor is simpler and keeps the types; use `rows()` when the read is huge and fixed in
shape.

## Streaming a table between two databases

Two connections and binary COPY copy a table without parsing a single row: the source's blocks go straight into the
target.

```python
with psycopg.connect(SRC_URL) as src, psycopg.connect(DST_URL) as dst:
    with src.cursor().copy("COPY app.readings TO STDOUT (FORMAT BINARY)") as cin:
        with dst.cursor().copy("COPY app.readings FROM STDIN (FORMAT BINARY)") as cout:
            for block in cin:
                cout.write(block)
```

Binary format needs the same column types on both sides. Across major versions, or when columns differ, use text
format.

## Async COPY with AsyncCursor

The async cursor has the same COPY API with `await` on each write.

```python
async with await psycopg.AsyncConnection.connect(os.environ["DATABASE_URL"]) as aconn:
    async with aconn.cursor() as cur:
        async with cur.copy("COPY app.r (sensor_id, at, value) FROM STDIN") as copy:
            for r in rows:
                await copy.write_row(r)
```

## COPY gotchas

These COPY problems come up most often, each with its cause and fix.

1. **`invalid input syntax for type integer: "1<TAB>x"` from a COPY with `write_row`.** `write_row` writes
   tab-separated text, and the statement said `FORMAT csv`. Drop the options, or write raw CSV with `copy.write`.
2. **`ProtocolViolation: insufficient data left in message`.** Binary COPY with mismatched types. Call
   `set_types`.
3. **The load is all or nothing.** COPY runs in one transaction. Load in batches of a few hundred thousand rows when
   a partial load is acceptable, or into a staging table first.
4. **`permission denied to COPY to a file` (or from a file).** The SQL named a server path, which needs
   `pg_write_server_files` (or `pg_read_server_files`). Use `TO STDOUT` or `FROM STDIN` from Python.

## Sources

- https://www.psycopg.org/psycopg3/docs/basic/copy.html
- https://www.psycopg.org/psycopg3/docs/api/copy.html
- https://www.postgresql.org/docs/18/sql-copy.html
