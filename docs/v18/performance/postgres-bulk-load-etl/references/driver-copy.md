---
title: COPY from application drivers
author: MOZGII, Inc.
lang: en
---

# COPY from application drivers

This reference shows the COPY call of each mainstream PostgreSQL driver, so an application streams rows instead of
sending batched `INSERT` statements. The API names and shapes were checked against each driver's documentation in
October 2026; the snippets were not run here, so adapt types and error handling to your code.

## Contents

The sections of this reference on driver COPY APIs:

1. Python: psycopg 3 and asyncpg
2. Node.js: node-postgres with pg-copy-streams
3. Go: pgx v5 CopyFrom
4. Java: PgJDBC CopyManager
5. .NET: Npgsql binary import
6. Text, CSV or binary from a driver

## Python: psycopg 3 and asyncpg

psycopg 3 opens a COPY with `cursor.copy()` used as a context manager; `write_row()` adapts Python values the same
way as query parameters. Leaving the block finishes the COPY; an exception inside it aborts the operation.

```python
with conn.cursor() as cur:
    with cur.copy("COPY app.readings (device_id, ts, value) FROM STDIN") as copy:
        for device_id, ts, value in rows:
            copy.write_row((device_id, ts, value))
conn.commit()
```

asyncpg has `copy_records_to_table()` for an iterable of tuples, and `copy_to_table()` for a file or stream.

```python
await conn.copy_records_to_table(
    "readings", schema_name="app", records=rows, columns=["device_id", "ts", "value"])
```

More on both drivers: `postgres-python`.

## Node.js: node-postgres with pg-copy-streams

pg-copy-streams 7.0.0 turns `COPY ... FROM STDIN` into a writable stream on a node-postgres client. Use a dedicated
client from the pool and release it after the stream finishes.

```js
import { pipeline } from 'node:stream/promises'
import fs from 'node:fs'
import { from as copyFrom } from 'pg-copy-streams'

const client = await pool.connect()
try {
  const ingest = client.query(copyFrom("COPY app.readings FROM STDIN WITH (FORMAT csv, HEADER true)"))
  await pipeline(fs.createReadStream('readings.csv'), ingest)
} finally {
  client.release()
}
```

## Go: pgx v5 CopyFrom

pgx sends rows with the binary COPY protocol through `Conn.CopyFrom`, which takes a table identifier, the column
names and a `CopyFromSource`. `pgx.CopyFromRows` wraps `[][]any`; `pgx.CopyFromSlice` reads a typed slice.

```go
n, err := conn.CopyFrom(ctx,
    pgx.Identifier{"app", "readings"},
    []string{"device_id", "ts", "value"},
    pgx.CopyFromRows(rows))
```

Because the format is binary, Go values must match the column types (`int32` for `int`, `time.Time` for
`timestamptz`).

## Java: PgJDBC CopyManager

PgJDBC exposes COPY through `org.postgresql.copy.CopyManager`, obtained from the driver connection. `copyIn` reads
from a `Reader` or `InputStream` and returns the row count.

```java
CopyManager copy = new CopyManager(conn.unwrap(BaseConnection.class));
long rows = copy.copyIn("COPY app.readings FROM STDIN WITH (FORMAT csv, HEADER true)",
                        new FileReader("readings.csv"));
```

When the connection comes from a pool (HikariCP), `unwrap` reaches the underlying PgJDBC connection.

## .NET: Npgsql binary import

Npgsql writes binary COPY rows with `BeginBinaryImport`: start each row, write each field with its type, then call
`Complete()`. Disposing the importer without `Complete()` rolls the COPY back.

```csharp
using (var writer = conn.BeginBinaryImport(
    "COPY app.readings (device_id, ts, value) FROM STDIN (FORMAT BINARY)"))
{
    foreach (var r in rows)
    {
        writer.StartRow();
        writer.Write(r.DeviceId, NpgsqlDbType.Integer);
        writer.Write(r.Ts, NpgsqlDbType.TimestampTz);
        writer.Write(r.Value, NpgsqlDbType.Double);
    }
    writer.Complete();
}
```

Npgsql's documentation recommends the `Write` overload with an `NpgsqlDbType`, since a wrong type can corrupt data
silently in binary mode.

## Text, CSV or binary from a driver

The COPY format sent by a driver changes speed and strictness. Binary was twice as fast as CSV in the skill's
measurement, but it rejects any type mismatch, and the COPY page warns that a binary file may not load on another CPU
architecture or another PostgreSQL version.

| Format | Strength | Risk |
|---|---|---|
| `text` (default) | simple; `\N` is NULL, tab separated | escaping of tabs, newlines and backslashes |
| `csv` | files from other tools; quoting rules | empty string versus NULL needs `FORCE_NULL` or `FORCE_NOT_NULL` |
| `binary` | fastest; no parsing | types must match exactly |

## Sources

- https://www.psycopg.org/psycopg3/docs/basic/copy.html
- https://magicstack.github.io/asyncpg/current/api/index.html
- https://github.com/brianc/node-pg-copy-streams (README, npm 7.0.0)
- https://pkg.go.dev/github.com/jackc/pgx/v5
- https://jdbc.postgresql.org/documentation/publicapi/org/postgresql/copy/CopyManager.html
- https://www.npgsql.org/doc/copy.html
- https://www.postgresql.org/docs/18/sql-copy.html (File Formats)
