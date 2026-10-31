---
title: psycopg_pool connection pools in depth
author: MOZGII, Inc.
lang: en
---

# psycopg_pool connection pools in depth

This reference covers psycopg_pool 3.3: every `ConnectionPool` parameter and its default, health checks and broken
connections, reconnecting after an outage, statistics, resizing and draining, `NullConnectionPool`, and sharing the
pool with SQLAlchemy. Every behaviour below was run against PostgreSQL 18.6 with psycopg-pool 3.3.3.

## ConnectionPool parameters and defaults

`ConnectionPool` (and `AsyncConnectionPool`, with the same parameters) keeps connections open and lends one per
`with pool.connection()` block; the block commits on success, rolls back on an exception and returns the connection.

| Parameter | Default | Meaning |
|---|---|---|
| `min_size` | 4 | connections kept open; created in the background when the pool opens |
| `max_size` | `None` (same as `min_size`) | ceiling; above `min_size` the pool grows on demand |
| `timeout` | 30.0 s | how long `connection()` waits, then `PoolTimeout` |
| `max_waiting` | 0 (no limit) | queued requests before `TooManyRequests` |
| `max_lifetime` | 3600 s | a connection is replaced after this age |
| `max_idle` | 600 s | a connection above `min_size` idle this long is closed |
| `reconnect_timeout` | 300 s | retry with backoff this long, then call `reconnect_failed` |
| `check` | `None` | callback run at every `connection()` before lending |
| `configure` | `None` | callback run once on each new connection |
| `reset` | `None` | callback run when a connection comes back, in idle state |
| `kwargs` | `None` | extra `connect()` arguments, such as `prepare_threshold` or `autocommit` |
| `close_returns` | `False` | `conn.close()` returns the connection to the pool (3.3) |
| `num_workers` | 3 | background workers that open connections |

`conninfo` and `kwargs` may be callables (3.3), so a pool can pick up a rotated password or a new host each time it
opens a connection.

## A production ConnectionPool

This pool sets a session timeout on each new connection, checks connections before lending them, recycles them every
30 minutes, and fails at startup if the database cannot be reached:

```python
import os
import psycopg
from psycopg_pool import ConnectionPool

def configure(conn: psycopg.Connection) -> None:
    conn.execute("SET statement_timeout = '30s'")
    conn.commit()                       # close the transaction before leaving configure

pool = ConnectionPool(
    os.environ["DATABASE_URL"],
    min_size=2, max_size=10, timeout=10, max_idle=300, max_lifetime=1800,
    check=ConnectionPool.check_connection, configure=configure,
    kwargs={"application_name": "billing-worker"}, name="billing", open=True,
)
pool.wait(timeout=10)                   # raises PoolTimeout and closes the pool if not ready
with pool.connection() as conn:
    conn.execute("UPDATE app.jobs SET done_at = now() WHERE id = %s", (job_id,))
pool.close()                            # at shutdown
```

A pool that is never closed keeps its worker threads alive; at interpreter exit it prints "couldn't stop thread
'billing-worker-0' within 5.0 seconds". Close it, or use it as a context manager.

## Pool health checks and broken connections

A pool does not test idle connections by itself: a server restart, a failover or `idle_session_timeout` leaves dead
connections, and the next caller gets one. In a test here, `pg_terminate_backend` on a pooled connection made the
next `pool.connection()` fail with `AdminShutdown` without a check, and succeed with
`check=ConnectionPool.check_connection`, which found the dead connection and served a new one.

- The check costs a round trip per borrow; leave it out only where a failed request is retried anyway.
- `pool.check()` tests every idle connection at once; call it from a timer when the server sets
  `idle_session_timeout`.
- `max_lifetime` below the server's or the load balancer's idle cut-off keeps connections from aging out under you.

## Reconnecting when the database is down

When a connection attempt fails, the pool retries in the background with exponential backoff until
`reconnect_timeout`, then calls `reconnect_failed(pool)` and keeps trying. Use the callback to alert, or to exit so
the supervisor (systemd, Kubernetes, a Windows service) restarts the process.

```python
import sys

def give_up(pool: ConnectionPool) -> None:
    log.critical("database unreachable for %s s", pool.reconnect_timeout)
    sys.exit(3)

pool = ConnectionPool(os.environ["DATABASE_URL"], min_size=2, reconnect_timeout=120, reconnect_failed=give_up)
```

Callers waiting meanwhile get `PoolTimeout: couldn't get a connection after 10.00 sec` when their `timeout` passes.

## Pool statistics, resize and drain

`pool.get_stats()` returns counters for monitoring; `pop_stats()` returns them and resets them. The keys include
`pool_size`, `pool_available`, `requests_waiting`, `requests_num`, `requests_queued`, `requests_wait_ms`,
`requests_errors`, `usage_ms`, `connections_num`, `connections_ms`, and, when they happened, `connections_errors`,
`connections_lost` and `returns_bad`.

```python
stats = pool.pop_stats()
metrics.gauge("db.pool.waiting", stats["requests_waiting"])
metrics.gauge("db.pool.wait_ms", stats.get("requests_wait_ms", 0))
pool.resize(4, 20)       # change min and max at run time
pool.drain()             # replace every connection, e.g. after a failover or new adapters
```

A steady `requests_waiting` above zero means the pool is too small or connections are held too long; raising
`max_size` past what the server can run makes it worse (`postgres-connection-pooling`).

## NullConnectionPool for poolers and short jobs

`NullConnectionPool` has the same API but keeps no idle connections: each `connection()` opens one and closes it at
the end, unless a waiting client takes it. `max_size` still caps concurrent connections. Use it in front of PgBouncer
(which already pools), in CLI tools and in serverless functions.

```python
from psycopg_pool import NullConnectionPool

with NullConnectionPool(os.environ["DATABASE_URL"], max_size=2) as pool:
    with pool.connection() as conn:
        conn.execute("SELECT 1")
```

## Sharing a psycopg pool with SQLAlchemy

SQLAlchemy can take its connections from a psycopg pool when the pool returns connections on `close()`
(`close_returns=True`, psycopg-pool 3.3) and SQLAlchemy keeps no pool of its own (`NullPool`). This lets one pool
serve both raw psycopg code and the ORM.

```python
import psycopg_pool
from sqlalchemy import create_engine
from sqlalchemy.pool import NullPool

pgpool = psycopg_pool.ConnectionPool(os.environ["DATABASE_URL"], close_returns=True, open=True)
engine = create_engine("postgresql+psycopg://", poolclass=NullPool, creator=pgpool.getconn)
```

The async form passes `async_creator=pgpool.getconn` to `create_async_engine`.

## Sources

- https://www.psycopg.org/psycopg3/docs/advanced/pool.html
- https://www.psycopg.org/psycopg3/docs/api/pool.html
- https://www.psycopg.org/psycopg3/docs/news_pool.html
- https://www.postgresql.org/docs/18/runtime-config-client.html
