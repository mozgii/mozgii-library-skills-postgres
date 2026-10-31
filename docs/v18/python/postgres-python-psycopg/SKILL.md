---
name: postgres-python-psycopg
description: 'Uses psycopg 3 in depth, starting from a copy-paste uv quickstart: safe conninfo, psycopg_pool sizing and health checks, async pools, row factories, server-side cursors, pipeline mode, COPY, type adapters (Jsonb, UUID, numeric, ranges, enums), prepared statements behind PgBouncer, LISTEN/NOTIFY, SQLSTATE errors, cancellation and timeouts, psycopg.sql, and the binary, c and pure Python packages. Use when writing or debugging psycopg code, a pool hands out broken connections, "prepared statement does not exist" appears, or COPY from Python is slow.'
metadata:
  tags:
  - postgres
  - python
  - psycopg
  - psycopg-pool
  - copy
  - pipeline
  - listen-notify
  - asyncio
---

# PostgreSQL with psycopg 3

psycopg 3 is the default Python driver for PostgreSQL: start every project on `psycopg[binary,pool]`, open one
`ConnectionPool` per process, pass every value as a parameter, and load bulk data with `COPY`. The choice between
psycopg, asyncpg and an ORM is made in `postgres-python`; this skill goes deep on psycopg itself. Depth lives in references:
[references/adaptation.md](references/adaptation.md) (types and custom adapters),
[references/copy.md](references/copy.md) (COPY in and out, measured speeds) and
[references/async-notify-errors.md](references/async-notify-errors.md) (FastAPI, Windows event loop, LISTEN/NOTIFY,
SQLSTATE classes, retries, cancellation).

## Quickstart: psycopg 3 in a uv project

This quickstart creates a uv project, adds psycopg with its bundled libpq and the pool, and runs one query. It works
the same on macOS, Linux and Windows (on Windows, set the variable with `$env:DATABASE_URL = "..."` in PowerShell).

```bash
uv init pgdemo && cd pgdemo
uv add "psycopg[binary,pool]"
export DATABASE_URL="postgresql://app@localhost:5432/app"   # password from ~/.pgpass or PGPASSWORD, not the code
```

The program below connects, runs one parameterized query and closes; leaving the `with` block commits (or rolls back
on an exception) and closes the connection.

```python
# main.py
import os

import psycopg

with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
    row = conn.execute("SELECT version(), current_user, %s::int + 1", (41,)).fetchone()
    print(row)
```

Run it with `uv run main.py`. A Unix socket works too: `postgresql:///app?host=/var/run/postgresql&port=5432`.

## Step 0: read the installed psycopg and libpq versions

psycopg features depend on the package and on the libpq it links.

```bash
uv run python -c "import psycopg, psycopg_pool; print(psycopg.__version__, psycopg_pool.__version__, psycopg.pq.__impl__, psycopg.pq.version())"
```

Current versions (October 2026): psycopg 3.3.6 (Python 3.10 or later), psycopg-pool 3.3.3. The output
`binary 180006` means the bundled C module and libpq 18.6.

## Choosing the psycopg package: binary, c or pure Python

The psycopg package comes in three builds that differ in speed and in which libpq they use.

| Install | Speed | libpq | Use for |
|---|---|---|---|
| `psycopg[binary]` | fast (C) | bundled in the wheel | development, containers, Windows, most production |
| `psycopg[c]` | fast (C) | the system's, built locally (needs a compiler, `libpq-dev`, `pg_config` on PATH) | Linux servers that patch libpq and OpenSSL with the OS |
| `psycopg` | slow (pure Python) | the system's, loaded at run time | PyPy, platforms without wheels |

macOS arm64 binary wheels need macOS 14 or later. On Linux, `[c]` needs `python3-dev` and `libpq-dev` (Debian,
Ubuntu) or `python3-devel` and `libpq-devel` (RHEL). On Windows use `[binary]`. `psycopg.pq.__impl__` prints
`binary`, `c` or `python`, so a deploy can assert the build it expects.

## Connection strings and safe conninfo

A connection string is a URL (`postgresql://user@host:port/db?sslmode=verify-full`) or a libpq key/value string.
Build it with `make_conninfo`, which quotes values: a password with a space or a quote breaks a hand-joined string.

```python
from psycopg.conninfo import make_conninfo

dsn = make_conninfo(os.environ["DATABASE_URL"], application_name="billing-worker", connect_timeout=5)
print(make_conninfo("", host="db.internal", dbname="app", user="app", password="p@ss word'x"))
# host=db.internal dbname=app user=app password='p@ss word\'x'
```

Fields left out of the string come from `PG*` environment variables and `~/.pgpass` (`postgres-python` shows how to
ignore them). Set `application_name` on every service, so `pg_stat_activity` shows who holds connections.

## psycopg_pool ConnectionPool settings and sizing

`ConnectionPool` keeps connections open and lends one per `with pool.connection()` block, which commits on success,
rolls back on an exception and returns the connection. Defaults: `min_size=4`, `max_size` equal to `min_size`,
`timeout=30` s to wait for a connection, `max_idle=600` s, `max_lifetime=3600` s, `reconnect_timeout=300` s, and no
`check`. A pool does not test idle connections: after a restart or failover the next caller gets a dead one
(`AdminShutdown`) unless `check=ConnectionPool.check_connection` is set.

```python
from psycopg_pool import ConnectionPool

def configure(conn: psycopg.Connection) -> None:
    conn.execute("SET statement_timeout = '30s'")
    conn.commit()                               # leave the new connection idle

pool = ConnectionPool(
    os.environ["DATABASE_URL"],
    min_size=2, max_size=10, timeout=10, max_idle=300, max_lifetime=1800,
    check=ConnectionPool.check_connection, configure=configure,
    kwargs={"application_name": "billing-worker"}, open=True,
)
pool.wait(timeout=10)                           # fail fast at startup if the database is unreachable
with pool.connection() as conn:
    conn.execute("UPDATE app.jobs SET done_at = now() WHERE id = %s", (job_id,))
pool.close()                                    # at shutdown, or use the pool as a context manager
```

Size the sum of all pools against `max_connections` (`postgres-connection-pooling`). Every parameter, reconnecting
with `reconnect_failed`, `get_stats()`, `resize()`, `drain()`, `NullConnectionPool` and sharing the pool with
SQLAlchemy are in [references/pool.md](references/pool.md).

## Async psycopg with AsyncConnectionPool

`AsyncConnectionPool` takes the same parameters as `ConnectionPool`; create it with `open=False` and `await
pool.open()` inside the running event loop (a FastAPI lifespan), because opening an async pool in its constructor is
deprecated. A connection runs one query at a time, so never share one `AsyncConnection` between concurrent tasks.

```python
from psycopg_pool import AsyncConnectionPool

pool = AsyncConnectionPool(os.environ["DATABASE_URL"], min_size=2, max_size=10, open=False,
                           check=AsyncConnectionPool.check_connection)
await pool.open()                               # at startup; await pool.close() at shutdown
async with pool.connection() as conn:
    cur = await conn.execute("SELECT id, status FROM app.orders WHERE id = %s", (order_id,))
    order = await cur.fetchone()
```

On Windows, psycopg async refuses the default `ProactorEventLoop`: run `asyncio.run(main(),
loop_factory=asyncio.SelectorEventLoop)` (Python 3.12 and later).

## Row factories: dict_row, class_row, scalar_row

A row factory decides what each row is: tuples by default, `dict_row` for dicts, `class_row(Cls)` for dataclasses or
pydantic models, `namedtuple_row`, and `scalar_row` for the first column alone. Set it per cursor or per connection.

```python
from dataclasses import dataclass
from psycopg.rows import class_row, dict_row, scalar_row

@dataclass
class Customer:
    id: int
    email: str

with pool.connection() as conn:
    with conn.cursor(row_factory=class_row(Customer)) as cur:
        customers = cur.execute("SELECT id, email FROM app.customers").fetchall()   # list[Customer]
    with conn.cursor(row_factory=scalar_row) as cur:
        total = cur.execute("SELECT count(*) FROM app.customers").fetchone()          # int, not (int,)
```

`class_row` maps columns by name: an alias that matches no field raises `TypeError`.

## Server-side cursors for large results

A server-side (named) cursor keeps the result on the server and fetches `itersize` rows per round trip (default 100),
so a 50-million-row export uses constant memory. A plain cursor loads the whole result into Python first.

```python
with pool.connection() as conn:
    with conn.cursor(name="export_customers", row_factory=dict_row) as cur:
        cur.itersize = 5000
        cur.execute("SELECT id, email FROM app.customers ORDER BY id")
        for row in cur:
            write_out(row)
```

A named cursor lives in a transaction: on an autocommit connection `DECLARE` fails with `NoActiveSqlTransaction`
unless the cursor is created with `withhold=True`. Behind a transaction-mode pooler keep the whole read in one
transaction.

## executemany and pipeline mode

`executemany()` sends all parameter sets in pipeline mode (psycopg 3.1 and later), so it needs no extra setup; pass
`returning=True` and walk the results with `cur.nextset()` to collect `RETURNING` rows. `conn.pipeline()` sends
different statements without waiting for each answer, which pays off over a network with latency; one failing
statement aborts the rest of the batch.

```python
with pool.connection() as conn:
    with conn.pipeline():
        counted = conn.execute("SELECT count(*) FROM app.customers")
        updated = conn.execute("UPDATE app.customers SET balance = balance + 1 WHERE id <= %s", (10,))
    print(counted.fetchone(), updated.rowcount)
```

## COPY from Python with copy.write_row

`cursor.copy()` runs `COPY ... FROM STDIN` or `TO STDOUT`; `write_row` adapts Python values the same way parameters
are adapted. Name the columns and give no `FORMAT csv` or `DELIMITER` options when using `write_row`.

```python
from psycopg.types.json import Jsonb

with pool.connection() as conn, conn.cursor() as cur:
    with cur.copy("COPY app.readings (sensor_id, at, value, meta) FROM STDIN") as copy:
        for r in readings:
            copy.write_row((r.sensor_id, r.at, r.value, Jsonb(r.meta)))
```

100,000 rows took 4.4 s with `executemany`, 1.2 s with `write_row`, 0.7 s with binary `write_row` and 0.3 s from a
CSV file in blocks. Loading files, exports to CSV, binary COPY and streaming a table between two databases are in
[references/copy.md](references/copy.md).

## Prepared statements, prepare_threshold and PgBouncer

psycopg prepares a query on the server automatically after it ran `prepare_threshold` times on one connection
(default 5) and keeps at most `prepared_max` (default 100). `execute(..., prepare=True)` prepares at once;
`prepare=False` never.

| Setup | Setting |
|---|---|
| Direct connection, or PgBouncer in session mode | defaults |
| PgBouncer 1.22 or later, transaction mode, `max_prepared_statements` > 0, client libpq 17 or later | defaults (psycopg 3.2 and later) |
| Same, client libpq older than 17 | `conn.prepared_max = None` (no deallocation) |
| Any other transaction pooler | `psycopg.connect(url, prepare_threshold=None)` or pool `kwargs={"prepare_threshold": None}` |

`psycopg.capabilities.has_send_close_prepared()` tells whether the client libpq is new enough.

## LISTEN/NOTIFY with conn.notifies()

`LISTEN` needs its own connection in autocommit mode, outside the pool and never through a transaction pooler;
`conn.notifies(timeout=60)` yields each message and ends 60 s from the call, however many came. Send with `SELECT pg_notify('jobs', %s)`, because `NOTIFY jobs, %s`
cannot take a parameter. Messages sent while the listener reconnects are lost, so re-read the table after a
reconnect. The listener loop and its async form are in
[references/async-notify-errors.md](references/async-notify-errors.md).

## psycopg errors and SQLSTATE classes

Every server error raises a class from `psycopg.errors` named after its SQLSTATE (`UniqueViolation` for `23505`,
`SerializationFailure` for `40001`, `DeadlockDetected` for `40P01`, `QueryCanceled` for `57014`), under the DB-API
classes such as `IntegrityError`. Catch the narrow class, read `e.sqlstate` and `e.diag.constraint_name`, and call
`conn.rollback()` before the next statement.

```python
from psycopg import errors

try:
    conn.execute("INSERT INTO app.customers (email) VALUES (%s)", (email,))
except errors.UniqueViolation as e:
    conn.rollback()
    raise EmailTaken(e.diag.constraint_name) from e
```

The code table and a tested retry helper for serializable transactions are in
[references/async-notify-errors.md](references/async-notify-errors.md).

## Cancellation and timeouts from Python

A server-side `statement_timeout` is the most reliable limit: connect with `options="-c statement_timeout=30s"` and
`connect_timeout=5`. A timed-out statement raises `QueryCanceled`. From another thread, `conn.cancel_safe()` (3.2 and
later) cancels the running query; in async code, cancelling the task (`asyncio.timeout(2)`) cancels the query on the
server and the pooled connection stays usable.

## Dynamic SQL: psycopg.sql and template strings

Parameters stand only for values. Table names, column names and statements without parameter support (`SET`,
`NOTIFY`, DDL) are composed with `psycopg.sql`, which quotes identifiers and literals.

```python
from psycopg import sql

q = sql.SQL("SELECT {cols} FROM {tbl} WHERE {col} = %s").format(
    cols=sql.SQL(", ").join(map(sql.Identifier, ["id", "status"])),
    tbl=sql.Identifier("app", "orders"), col=sql.Identifier(sort_col))
conn.execute(q, ("paid",))
conn.execute(sql.SQL("SET statement_timeout = {}").format(sql.Literal("5s")))
```

On Python 3.14, psycopg 3.3 also takes template strings: `conn.execute(t"SELECT id FROM app.customers WHERE email =
{email}")` sends `$1` with the value apart; `{col:i}` is an identifier and `{payload:l}` a literal.

## Verify a psycopg pool and build

This prints the build and what the pool holds. It ran on psycopg 3.3.6 and PostgreSQL 18.6 against the pool above.

```python
with pool.connection() as conn:
    print(conn.execute("SELECT current_setting('application_name')").fetchone())
stats = pool.get_stats()
print(psycopg.pq.__impl__, stats["pool_min"], stats["pool_max"], stats["pool_size"], stats["pool_available"])
```

`__impl__` must be the build you meant to deploy, and `pool_size` must sit between `pool_min` and `pool_max`. Then
restart Postgres under a test: with `check` set, the next `pool.connection()` must hand out a live connection.

## Gotchas

These are the psycopg failures seen most often, each with its cause and fix.

1. **The first query after a database restart fails with `AdminShutdown` or "server closed the connection".** The
   pool lent a dead connection. Add `check=ConnectionPool.check_connection`.
2. **`prepared statement "_pg3_0" does not exist`.** A transaction pooler moved the session. Use PgBouncer 1.22+
   with libpq 17, or `prepare_threshold=None`.
3. **`SET statement_timeout = %s` raises a syntax error (`42601`).** Server-side binding has no parameters in `SET`.
   Use `set_config('statement_timeout', %s, false)` or `sql.Literal`.
4. **"couldn't stop thread ... within 5.0 seconds" at exit.** The pool was never closed. Call `pool.close()` or use
   it as a context manager.
5. **`DECLARE CURSOR can only be used in transaction blocks`.** A named cursor on an autocommit connection. Use a
   transaction or `withhold=True`.
6. **Timestamps come back in an unexpected zone.** `timestamptz` loads in the session `TimeZone`. Set `TimeZone=UTC`
   in `options` or convert at the boundary.

## Anti-patterns with psycopg

These come mostly from psycopg2 habits.

| Do not | Do instead |
|---|---|
| Open a `ConnectionPool` without `check` | Pass `check=ConnectionPool.check_connection` |
| Share one connection between threads or tasks | Take one per block from the pool |
| Format values into `SET statement_timeout = %s` | Use `set_config(...)` or `sql.Literal` |
| Fetch a big result with a plain cursor | Use a named cursor or `COPY TO` |
| Insert rows one by one in a loop | Use `COPY` or `executemany` |
| Run `LISTEN` on a pooled connection | Use its own autocommit connection |

## Checklist

Check these points before you call psycopg code done.

- [ ] `psycopg[binary,pool]` (or `[c]` on Linux servers) pinned in `pyproject.toml`; `psycopg.pq.__impl__` checked.
- [ ] One pool per process with `check`, sized against `max_connections`, closed at shutdown.
- [ ] Every value is a parameter; identifiers go through `psycopg.sql`.
- [ ] Bulk writes use `COPY` or `executemany`; big reads use a named cursor or `COPY TO`.
- [ ] Prepared statement settings match the pooler.
- [ ] `statement_timeout` and `connect_timeout` set; `QueryCanceled` handled.
- [ ] `LISTEN` runs on its own autocommit connection, not a pooled one.

## See also

Related skills in this library, each one works on its own:

- `postgres-python`: choosing a driver and scrubbing `PG*`.
- `postgres-python-asyncpg`: the alternative async driver.
- `postgres-python-sqlalchemy`: psycopg under SQLAlchemy.
- `postgres-python-data`: dataframes over psycopg.
- `postgres-connection-pooling`: sizing and PgBouncer.
- `postgres-libpq-protocol`: what libpq does underneath.

## Sources

- https://www.psycopg.org/psycopg3/docs/basic/install.html
- https://www.psycopg.org/psycopg3/docs/advanced/pool.html
- https://www.psycopg.org/psycopg3/docs/advanced/prepare.html
- https://www.psycopg.org/psycopg3/docs/advanced/pipeline.html
- https://www.psycopg.org/psycopg3/docs/advanced/cursors.html
- https://www.psycopg.org/psycopg3/docs/basic/tstrings.html
- https://www.psycopg.org/psycopg3/docs/news.html
