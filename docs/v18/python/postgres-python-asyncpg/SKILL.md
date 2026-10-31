---
name: postgres-python-asyncpg
description: 'Uses asyncpg in depth, from a copy-paste uv quickstart: connect and create_pool (min_size, init_size, max_inactive_connection_lifetime), Record rows, $n parameters and ANY arrays, prepared statements and the statement cache trap behind PgBouncer, transactions and savepoints, cursors, copy_records_to_table and copy_from_query, JSON and JSONB codecs with set_type_codec, LISTEN listeners, timeouts, exception classes and SQLSTATE, measured speed against psycopg 3, and when to choose asyncpg. Use when writing asyncpg code, "prepared statement __asyncpg_stmt does not exist" appears, JSONB comes back as a string, IN $1 fails, or when choosing between asyncpg and psycopg.'
metadata:
  tags:
  - postgres
  - python
  - asyncpg
  - asyncio
  - connection-pool
  - copy
  - pgbouncer
  - prepared-statements
---

# PostgreSQL with asyncpg

asyncpg is an `asyncio`-only PostgreSQL driver that speaks the protocol itself (no libpq) and returns `Record`
objects: create one pool at startup, use `$1` placeholders, register JSON codecs in the pool's `init`, and turn the
statement cache off behind a transaction pooler. The choice between asyncpg, psycopg 3 and an ORM is made in
`postgres-python`; psycopg in depth is `postgres-python-psycopg`.

## Quickstart: asyncpg in a uv project

This quickstart creates a uv project, adds asyncpg (wheels for macOS, Linux and Windows, no system libraries) and
runs one query.

```bash
uv init ingest && cd ingest
uv add asyncpg
export DATABASE_URL="postgresql://app@localhost:5432/app"     # PowerShell: $env:DATABASE_URL = "..."
```

The program connects, runs a query with a `$1` parameter and closes the connection.

```python
# main.py
import asyncio
import os

import asyncpg

async def main() -> None:
    conn = await asyncpg.connect(os.environ["DATABASE_URL"])
    try:
        row = await conn.fetchrow("SELECT version(), current_user, $1::int + 1 AS n", 41)
        print(row["n"], row)
    finally:
        await conn.close()

asyncio.run(main())
```

Run it with `uv run main.py`. A Unix socket works as `postgresql://app@/app?host=/var/run/postgresql`.

## Step 0: read the installed asyncpg version

asyncpg's pool semantics changed in 0.32, so read the version before tuning a pool.

```bash
uv run python -c "import asyncpg; print(asyncpg.__version__)"
```

Current version (October 2026): asyncpg 0.32.0 (Python 3.9 or later; adds Python 3.15 and PostgreSQL 19 support).

## When to choose asyncpg over psycopg 3

asyncpg fits code that is `async def` end to end and wants the shortest path from the wire to Python values. psycopg 3
fits everything else and is the default.

| Need | asyncpg | psycopg 3 |
|---|---|---|
| Sync code, scripts, Django | no (async only) | yes |
| Placeholders | `$1, $2` (server syntax) | `%s`, `%(name)s` |
| JSON and JSONB decoding | strings until a codec is set | `dict` by default |
| `timestamptz` zone | always UTC | the session `TimeZone` |
| libpq features (`.pg_service.conf`, all `sslmode` values) | reimplemented, partial | all |
| PgBouncer transaction mode | `statement_cache_size=0` | works with PgBouncer 1.22+ and libpq 17 |
| SQLAlchemy | `postgresql+asyncpg://` | `postgresql+psycopg://` |

Measured here on a Unix socket (200,000 rows of int, timestamptz, float8, text; three runs each), the two drivers
landed in the same range: fetching all rows took 0.11 to 0.12 s with asyncpg, 0.14 to 0.16 s with psycopg async and
0.11 to 0.31 s with sync psycopg; COPY of the rows 0.22 to 0.41 s with asyncpg and 0.09 to 0.52 s with psycopg.
Speed alone rarely decides; measure your own workload over the real network.

## Connection pool with create_pool

`asyncpg.create_pool` opens connections, lends one per `async with pool.acquire()`, and resets it on release
(`RESET ALL`, `UNLISTEN *`, `CLOSE ALL`, advisory locks released, an open transaction rolled back). Defaults in
0.32: `min_size=10`, `max_size=10`, `max_queries=50000` (a connection is replaced after that many queries),
`max_inactive_connection_lifetime=300` s, and `init_size` equal to `min_size`.

```python
import json
import asyncpg

async def init(conn: asyncpg.Connection) -> None:
    await conn.set_type_codec("jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog")
    await conn.set_type_codec("json", encoder=json.dumps, decoder=json.loads, schema="pg_catalog")

pool = await asyncpg.create_pool(
    os.environ["DATABASE_URL"],
    min_size=2, max_size=10, max_inactive_connection_lifetime=300,
    command_timeout=30,                                   # default per-call timeout, seconds
    init=init,                                            # runs once per new connection
    server_settings={"application_name": "ingest", "statement_timeout": "30s"},
)
async with pool.acquire() as conn:
    await conn.execute("UPDATE app.jobs SET done_at = now() WHERE id = $1", job_id)
await pool.close()                                        # at shutdown
```

- In 0.32, `min_size` is a floor the pool keeps and refills; `init_size` sets how many open at startup. The old
  "drain to zero" behaviour is `init_size=N, min_size=0`.
- `pool.acquire(timeout=5)` bounds the wait for a free connection and raises `TimeoutError`.
- `pool.fetch()`, `pool.fetchrow()`, `pool.fetchval()` and `pool.execute()` acquire and release for one call.
- A `SET` made on a pooled connection is undone at release; put session settings in `server_settings` or `init`.

## Records, $n parameters and arrays

A `Record` is a read-only row: index it by name or position, turn it into a dict with `dict(record)`, and use
`record.get(name, default)`. Parameters are positional `$1`, `$2`, sent with their PostgreSQL types; Python lists are
arrays, so a list filter is `= any($1::bigint[])`, never `IN $1`.

```python
row = await conn.fetchrow(
    "INSERT INTO app.events (kind, body, amount, tags) VALUES ($1, $2, $3, $4) RETURNING *",
    "signup", {"plan": "pro"}, decimal.Decimal("9.90"), ["a", "b"])
print(row["id"], dict(row))
rows = await conn.fetch("SELECT id FROM app.events WHERE id = any($1::bigint[])", [1, 2])
total = await conn.fetchval("SELECT count(*) FROM app.events")
await conn.executemany("INSERT INTO app.events (kind, amount) VALUES ($1, $2)", [("k", decimal.Decimal(1))])
```

`WHERE id IN $1` fails with `PostgresSyntaxError: syntax error at or near "$1"`. For dot access, pass a subclass of
`asyncpg.Record` with `__getattr__` as `record_class=` to `connect` or `create_pool`.

## Prepared statements and the PgBouncer statement cache trap

asyncpg prepares every query and keeps up to `statement_cache_size` (default 100) per connection, named
`__asyncpg_stmt_<n>__`. Through PgBouncer in transaction or statement mode, the next query may land on another server
connection that lacks the statement. The failure looks like this (reproduced here with `DEALLOCATE ALL`):

```text
InvalidSQLStatementNameError: prepared statement "__asyncpg_stmt_3__" does not exist
HINT: NOTE: pgbouncer with pool_mode set to "transaction" or "statement" does not support prepared statements properly.
```

| Setup | Setting |
|---|---|
| Direct connection, or PgBouncer session mode | defaults |
| PgBouncer transaction mode, Supabase or Neon pooled ports, other transaction poolers | `statement_cache_size=0` in `connect` or `create_pool`; no `conn.prepare()` |
| SQLAlchemy asyncpg dialect behind a transaction pooler | `?prepared_statement_cache_size=0` in the URL plus `connect_args={"statement_cache_size": 0}`, `poolclass=NullPool` |

With `statement_cache_size=0`, five runs of a query left no rows in `pg_prepared_statements`. If PgBouncer is there
only to save connection setup, use asyncpg's own pool instead.

## Stale statements after schema changes

A cached statement plan breaks when DDL changes the table it reads. Outside a transaction asyncpg re-prepares and
retries by itself; inside a transaction it cannot, and raises `InvalidCachedStatementError: cached statement plan is
invalid due to a database schema or configuration change`. Retry the whole transaction on that error after a
migration, or call `await conn.reload_schema_state()` on each pooled connection after DDL that changes types.

## Transactions and savepoints

`conn.transaction()` opens a transaction that commits when the block ends and rolls back on an exception; a nested
`transaction()` is a savepoint. Isolation is a parameter.

```python
async with conn.transaction(isolation="serializable"):
    await conn.execute("UPDATE app.accounts SET balance = balance - $1 WHERE id = $2", amount, src)
    try:
        async with conn.transaction():                     # SAVEPOINT
            await conn.execute("INSERT INTO app.audit (note) VALUES ($1)", note)
    except asyncpg.UniqueViolationError:
        pass                                               # only the savepoint rolled back
```

Retry serializable transactions as a whole on `SerializationError` (`40001`) and `DeadlockDetectedError`
(`40P01`). A cursor (`conn.cursor(query, prefetch=500)`) streams a large result but only inside a transaction;
outside one it raises `NoActiveSQLTransactionError: cursor cannot be created outside of a transaction`.

## COPY with copy_records_to_table and copy_from_query

COPY is asyncpg's bulk path: `copy_records_to_table` sends Python tuples in binary format, from a list or an async
iterable; 50,000 rows took 0.12 s here.

```python
rows = [("bulk", datetime.datetime.now(datetime.UTC), decimal.Decimal("1.00")) for _ in range(50_000)]
status = await conn.copy_records_to_table("events", schema_name="app", columns=["kind", "at", "amount"],
                                          records=rows)            # 'COPY 50000'
```

`copy_from_query` writes a query result to a file or file-like object in any COPY format, with parameters;
`copy_to_table` loads a file:

```python
with open("events.csv", "wb") as f:
    await conn.copy_from_query("SELECT id, kind FROM app.events WHERE id < $1", 1000,
                               output=f, format="csv", header=True)
with open("more.csv", "rb") as f:
    await conn.copy_to_table("events", schema_name="app", source=f, columns=["kind", "amount"],
                             format="csv", header=True)
```

Values must match the column types exactly, because binary COPY applies no casts (a `float` for `numeric` fails).

## JSON, JSONB and custom type codecs

asyncpg returns `json` and `jsonb` as `str` and expects `str` on input until a codec is set. Register codecs on every
connection through the pool's `init` (shown in the pool section); `schema="pg_catalog"` is required for built-in
types. `set_type_codec` also maps custom types, for example a composite with `format="tuple"`; enums arrive as `str`.
Other defaults: `numeric` is `Decimal`, `uuid` is `uuid.UUID`, `timestamptz` is an aware `datetime` in UTC, arrays are
lists.

## LISTEN and NOTIFY with add_listener

`add_listener(channel, callback)` runs `LISTEN` and calls `callback(connection, pid, channel, payload)` for each
notification. Keep the listening connection outside the pool: the pool's reset runs `UNLISTEN *` on release.

```python
def on_job(conn, pid, channel, payload):
    queue.put_nowait(payload)

listener = await asyncpg.connect(os.environ["DATABASE_URL"])
await listener.add_listener("jobs", on_job)
# elsewhere: await pool.execute("SELECT pg_notify('jobs', $1)", "job-1")
```

`add_termination_listener` reports a lost connection; reconnect and re-read the table, because notifications sent
meanwhile are gone.

## Timeouts and cancellation

asyncpg has three limits: `timeout` on `connect` (connection setup, default 60 s), `command_timeout` as the default
for each call, and `timeout=` on a single call. A client timeout raises `TimeoutError`, cancels the query on the
server, and leaves the connection usable. A server `statement_timeout` raises `QueryCanceledError` (`57014`).

```python
try:
    await conn.execute("SELECT slow_report()", timeout=2)
except TimeoutError:
    log.warning("report cancelled after 2 s")
```

## asyncpg exceptions and SQLSTATE

Server errors are subclasses of `asyncpg.PostgresError` named after the condition, with `sqlstate` and fields such
as `constraint_name`, `table_name`, `detail`.

| SQLSTATE | asyncpg class | Action |
|---|---|---|
| `23505` | `UniqueViolationError` | report a duplicate |
| `23503` | `ForeignKeyViolationError` | report a missing parent |
| `40001` | `SerializationError` | retry the transaction |
| `40P01` | `DeadlockDetectedError` | retry the transaction |
| `57014` | `QueryCanceledError` | timeout or cancel |
| `0A000` | `InvalidCachedStatementError` (a `FeatureNotSupportedError`) | retry after DDL |

Client-side problems (a wrong argument count, a released connection, a closed pool) raise
`asyncpg.InterfaceError`.

## Verify asyncpg settings on a live pool

This small check prints what the pool really does. It ran on asyncpg 0.32.0 and PostgreSQL 18.6, inside `main()` of a
script with the pool from above and `statement_cache_size=0`.

```python
async with pool.acquire() as conn:
    print(await conn.fetchval("SELECT count(*) FROM pg_prepared_statements"))     # 0 with statement_cache_size=0
    print(await conn.fetchval("SELECT jsonb_build_object('a', 1)"))               # {'a': 1}, a dict once the codec is set
print(pool.get_size(), pool.get_idle_size(), pool.get_max_size())
```

Behind PgBouncer, run a query in a loop across more connections than the pool holds: no `__asyncpg_stmt_` error may
appear. Restart Postgres once and check that a termination listener reconnects.

## Gotchas

These are the asyncpg failures seen most often, each with its cause and fix.

1. **`prepared statement "__asyncpg_stmt_N__" does not exist` or `already exists`.** A transaction pooler.
   Set `statement_cache_size=0`.
2. **JSONB values arrive as strings.** No codec. Register `set_type_codec("jsonb", ..., schema="pg_catalog")` in
   the pool's `init`.
3. **`syntax error at or near "$1"` with `IN $1`.** Use `= any($1::type[])`.
4. **A pool opens 10 connections per process.** `min_size` defaults to 10. Set it to the steady load.
5. **Listeners stop after a connection goes back to the pool.** The reset runs `UNLISTEN *`. Use a dedicated
   connection.
6. **`InvalidCachedStatementError` right after a deploy.** A migration changed a table under cached plans. Retry
   the transaction.
7. **`IndeterminateDatatypeError: could not determine data type of parameter $1`.** The server cannot infer the
   type (`$1 IS NULL`, `concat($1, ...)`). Cast the placeholder (`$1::text`).

## Anti-patterns with asyncpg

Each of these comes from treating asyncpg like a libpq driver.

| Do not | Do instead |
|---|---|
| Build `IN (...)` lists with string formatting | Pass a list to `= any($1::bigint[])` |
| Leave the statement cache on behind a transaction pooler | Set `statement_cache_size=0` |
| Issue `SET` on a pooled connection and expect it to stay | Use `server_settings` or `init`; the pool resets on release |
| Call `add_listener` on a pooled connection | Listen on a dedicated connection; the reset runs `UNLISTEN *` |
| Share one connection between tasks | Acquire one per task from the pool |
| Pass a `float` to a `numeric` column in binary COPY | Pass `Decimal`: binary COPY applies no casts |

## Checklist

Check these points before you call asyncpg code done.

- [ ] One pool per process, created at startup with explicit `min_size` and `max_size`, closed at shutdown.
- [ ] JSON and JSONB codecs set in `init`; session settings in `server_settings`.
- [ ] `statement_cache_size=0` wherever a transaction pooler sits in between.
- [ ] Lists filtered with `= any($1::type[])`; ambiguous parameters cast.
- [ ] Bulk loads use `copy_records_to_table`; big reads a cursor in a transaction or `copy_from_query`.
- [ ] `command_timeout` or per-call `timeout` set; serialization and deadlock errors retried.
- [ ] Listeners on a dedicated connection with a termination listener.

## See also

Related skills in this library, each one works on its own:

- `postgres-python`: choosing asyncpg, psycopg or an ORM.
- `postgres-python-psycopg`: the default driver in depth.
- `postgres-python-sqlalchemy`: the asyncpg dialect.
- `postgres-connection-pooling`: transaction pooling and prepared statements.
- `postgres-transactions-locking`: retries and isolation.

## Sources

- https://magicstack.github.io/asyncpg/current/api/index.html
- https://magicstack.github.io/asyncpg/current/usage.html
- https://magicstack.github.io/asyncpg/current/faq.html
- https://magicstack.github.io/asyncpg/current/installation.html
- https://github.com/MagicStack/asyncpg/releases/tag/v0.32.0
- https://docs.sqlalchemy.org/en/21/dialects/postgresql.html
- https://www.postgresql.org/docs/18/errcodes-appendix.html
