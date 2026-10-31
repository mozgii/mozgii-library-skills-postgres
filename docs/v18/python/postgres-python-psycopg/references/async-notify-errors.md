---
title: psycopg 3 async code, LISTEN/NOTIFY, errors, timeouts and cancellation
author: MOZGII, Inc.
lang: en
---

# psycopg 3 async code, LISTEN/NOTIFY, errors, timeouts and cancellation

This reference covers psycopg 3 in `asyncio` services (FastAPI, aiohttp), listening for `NOTIFY` messages, the error
classes and SQLSTATE codes, retry loops, statement timeouts and cancelling a running query. Every example ran against
PostgreSQL 18.6 with psycopg 3.3.6 and psycopg-pool 3.3.3.

## AsyncConnectionPool in a FastAPI service

`AsyncConnectionPool` takes the same parameters as `ConnectionPool`; open it inside the running event loop, because
opening an async pool in its constructor is deprecated. This FastAPI lifespan opens it at startup and closes it at
shutdown:

```python
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI
from psycopg_pool import AsyncConnectionPool

pool = AsyncConnectionPool(os.environ["DATABASE_URL"], min_size=2, max_size=10, open=False,
                           check=AsyncConnectionPool.check_connection)

@asynccontextmanager
async def lifespan(app: FastAPI):
    await pool.open()
    yield
    await pool.close()

app = FastAPI(lifespan=lifespan)

@app.get("/orders/{order_id}")
async def get_order(order_id: int):
    async with pool.connection() as conn:
        cur = await conn.execute("SELECT id, status FROM app.orders WHERE id = %s", (order_id,))
        return await cur.fetchone()
```

Each `async with pool.connection()` holds a connection only for its block; eight concurrent 100 ms queries on a pool
of four finished in about 0.2 s. Never share one `AsyncConnection` between concurrent tasks: a connection runs one
query at a time.

## Async psycopg on Windows needs a selector event loop

psycopg async refuses Windows' default `ProactorEventLoop` with `InterfaceError: Psycopg cannot use the
'ProactorEventLoop' to run in async mode`. Start the program on a selector loop:

```python
import asyncio
asyncio.run(main(), loop_factory=asyncio.SelectorEventLoop)       # Python 3.12 and later
```

On Python 3.11, call `asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())` before
`asyncio.run`. A server that creates its own loop (Uvicorn, Hypercorn) must be checked on Windows for which loop it
runs. macOS and Linux need nothing.

## LISTEN/NOTIFY with conn.notifies()

`LISTEN` needs a dedicated connection in autocommit mode, outside the pool and never through a transaction pooler.
`notifies()` yields each notification and accepts `timeout` and `stop_after` (a count). The timeout is a total deadline
in seconds from the call, not an idle limit: with a message every 0.5 s, `timeout=2.0` still ended at 2.0 s.

```python
import psycopg

with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as conn:
    conn.execute("LISTEN jobs")
    for n in conn.notifies(timeout=60):            # ends 60 s from here, however many messages came
        print(n.channel, n.payload, n.pid)
        if n.payload == "stop":
            break
```

The sender passes the payload as a parameter through `pg_notify`, because `NOTIFY jobs, %s` cannot take one:

```python
with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as conn:
    conn.execute("SELECT pg_notify('jobs', %s)", ("job-1",))
```

- A notification is sent at commit; one sent in a rolled-back transaction never arrives.
- Messages sent while the listener is disconnected are lost: after each reconnect, re-read the table the
  notifications describe.
- The async form is `async for n in aconn.notifies(timeout=60)`; `conn.add_notify_handler(callback)` is the callback
  alternative.
- Queue design around `NOTIFY` and `SKIP LOCKED` is in `postgres-transactions-locking`.

## psycopg error classes and SQLSTATE codes

Every server error raises a class from `psycopg.errors` named after its SQLSTATE, under the DB-API classes
(`IntegrityError`, `OperationalError`, `ProgrammingError`, `DataError`). Catch the narrow class and read `e.sqlstate`
and `e.diag`.

```python
from psycopg import errors

try:
    conn.execute("INSERT INTO app.customers (email) VALUES (%s)", (email,))
except errors.UniqueViolation as e:              # 23505, an IntegrityError
    conn.rollback()
    print(e.sqlstate, e.diag.constraint_name)    # 23505 customers_email_key
```

| SQLSTATE | Class | Action |
|---|---|---|
| `40001` | `SerializationFailure` | retry the whole transaction |
| `40P01` | `DeadlockDetected` | retry the whole transaction |
| `57014` | `QueryCanceled` | statement timeout or cancel: do not retry blindly |
| `57P01` | `AdminShutdown` | connection killed: get a new one, retry if idempotent |
| `23505` | `UniqueViolation` | report a duplicate to the caller |
| `23503` | `ForeignKeyViolation` | report a missing parent to the caller |
| `23001` | `RestrictViolation` | PG 18+: `ON DELETE RESTRICT` blocked a parent delete, report that children still exist |
| `42601` | `SyntaxError` | a bug: fix the SQL |
| `25P02` | `InFailedSqlTransaction` | an earlier statement failed: roll back first |

`errors.lookup("40P01")` returns the class for a code, which helps when the code comes from a log.

## Retrying serializable transactions from Python

A retry wraps the whole transaction, never one statement, with jittered backoff and a cap. This helper ran a write
skew race (two doctors leaving call at once under `SERIALIZABLE`): one transaction committed, the other failed with
`40001`, retried, saw one doctor left and stayed.

```python
import random, time
from collections.abc import Callable
from typing import TypeVar
import psycopg
from psycopg import errors
from psycopg_pool import ConnectionPool

T = TypeVar("T")
RETRYABLE = (errors.SerializationFailure, errors.DeadlockDetected)

def run_in_transaction(pool: ConnectionPool, work: Callable[[psycopg.Connection], T], attempts: int = 5) -> T:
    for attempt in range(1, attempts + 1):
        try:
            with pool.connection() as conn, conn.transaction():
                # this transaction only: conn.isolation_level would stay set for the pool's next borrower
                conn.execute("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
                return work(conn)
        except RETRYABLE:
            if attempt == attempts:
                raise
            time.sleep(random.uniform(0, 0.05 * 2 ** attempt))
    raise AssertionError("unreachable")
```

`work` must not have side effects outside the database (emails, HTTP calls), because it may run more than once.

## Statement timeouts and cancelling a query

A server-side timeout is the most reliable limit, because it holds even when the client hangs. Set it on the
connection, per role, or per transaction.

```python
with psycopg.connect(os.environ["DATABASE_URL"], options="-c statement_timeout=30s", connect_timeout=5) as conn:
    try:
        conn.execute("SELECT slow_report()")
    except errors.QueryCanceled:              # "canceling statement due to statement timeout"
        conn.rollback()
```

To stop a query from another thread, call `conn.cancel_safe()` (psycopg 3.2 and later); the running `execute` raises
`QueryCanceled` with "canceling statement due to user request". In async code, cancelling the task cancels the query
on the server, and the pooled connection stays usable:

```python
import asyncio

async with pool.connection() as conn:
    try:
        async with asyncio.timeout(2):
            await conn.execute("SELECT slow_report()")
    except TimeoutError:
        log.warning("report cancelled after 2 s")
```

- `connect_timeout` bounds connection setup; the pool's `timeout` bounds the wait for a free connection.
- After any error inside a transaction, call `rollback()` before the next statement, or psycopg raises
  `InFailedSqlTransaction`.
- psycopg 3.3.6 stops waiting on an unresponsive server after an interrupt (Ctrl-C, `SystemExit`) when the client
  libpq is 17 or newer.
- Timeouts per role (`lock_timeout`, `idle_in_transaction_session_timeout`) are in `postgres-transactions-locking`.

## Sources

- https://www.psycopg.org/psycopg3/docs/advanced/async.html
- https://www.psycopg.org/psycopg3/docs/advanced/pool.html
- https://www.psycopg.org/psycopg3/docs/api/errors.html
- https://www.psycopg.org/psycopg3/docs/basic/transactions.html
- https://www.psycopg.org/psycopg3/docs/news.html
- https://www.postgresql.org/docs/18/errcodes-appendix.html
- https://www.postgresql.org/docs/18/sql-notify.html
- https://docs.python.org/3/library/asyncio-runner.html
