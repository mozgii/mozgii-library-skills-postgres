---
name: postgres-connection-pooling
description: 'Sizes and pools PostgreSQL connections: why each connection is a process, max_connections and application pool sizing, PgBouncer session and transaction modes, what breaks in transaction mode, prepared statements through a pooler, serverless and edge poolers (Supavisor, Neon, RDS Proxy, Hyperdrive) and timeouts. Use for "sorry, too many clients already", "prepared statement does not exist", pool timeouts, adding PgBouncer, or deploying to serverless.'
metadata:
  tags:
  - postgres
  - connection-pooling
  - pgbouncer
  - max_connections
  - serverless
  - prepared-statements
  - supavisor
---

# PostgreSQL connection pooling

Each PostgreSQL connection is a separate server process with its own memory, so thousands of connections cost RAM,
CPU for snapshots, and lock contention even when idle. A small number of busy connections serves more traffic than a
large number of idle ones. PgBouncer settings: [references/pgbouncer-config.md](references/pgbouncer-config.md).

## Step 0: see what holds connections now

Start from where connections go before changing any limit.

```sql
SHOW max_connections;
SELECT usename, application_name, state, count(*)
FROM pg_stat_activity WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3 ORDER BY count(*) DESC;
```

Many `idle` connections mean oversized application pools; many `idle in transaction` mean code that holds
transactions open; many `active` waiting on locks mean contention, not a pool problem.

## Sizing max_connections and application pools

Size the database for the work it can do in parallel, not for the number of clients.

- The useful number of active connections is roughly 2 to 4 times the CPU cores of the database server. Past that,
  throughput falls while latency grows.
- `max_connections` default is 100. Raise it to a few hundred at most; reserve `superuser_reserved_connections` (3)
  and `reserved_connections` (PG 16+) for admin access.
- The sum of every application instance's pool `max` must fit under `max_connections` minus reserved slots minus
  migrations, monitoring and replicas. Ten instances with `max: 20` already need 200.
- When the sum does not fit (many instances, autoscaling, serverless), put a pooler in front.

## Application-side pools

Every long-running service should hold one pool per process, created at startup, with explicit limits.

| Driver | Pool |
|---|---|
| node-postgres | `new pg.Pool({ max: 10, idleTimeoutMillis: 30000, connectionTimeoutMillis: 5000 })` |
| postgres.js | `postgres(url, { max: 10, idle_timeout: 30 })` |
| psycopg 3 | `psycopg_pool.ConnectionPool(conninfo, min_size=1, max_size=10)` |
| asyncpg | `await asyncpg.create_pool(dsn, min_size=1, max_size=10)` |
| SQLAlchemy | `create_engine(url, pool_size=5, max_overflow=5, pool_pre_ping=True)` |
| Go pgx | `pgxpool.ParseConfig` with `MaxConns = 10` |
| Java | HikariCP `maximumPoolSize=10` |

Always release connections (`finally`, `with`, `defer`). A leaked connection looks like a pool that is too small.

## External poolers and their modes

A pooler such as PgBouncer accepts many client connections and shares a few server connections among them. The pool
mode decides when a server connection is returned.

| Mode | Server connection returned | Session features | Use for |
|---|---|---|---|
| `session` | when the client disconnects | all work | long-lived apps that need session state; little multiplexing |
| `transaction` | at each `COMMIT`/`ROLLBACK` | many break (table below) | web apps, serverless, many short clients |
| `statement` | after each statement | no multi-statement transactions | rare |

Poolers: PgBouncer (the standard, single-threaded, very light), PgCat and PgDog (multi-threaded, with load balancing
and sharding), Supavisor (Supabase), RDS Proxy (AWS), Hyperdrive (Cloudflare Workers).

## What breaks in transaction pooling mode

In transaction mode two consecutive transactions from one client may run on different server connections, so any
state kept in a session is lost or leaks to another client.

| Feature | Works in transaction mode? | Instead |
|---|---|---|
| `SET` / `RESET` (session) | no | `SET LOCAL` inside the transaction, or role/database defaults (`ALTER ROLE ... SET`) |
| `LISTEN` | no | a direct connection for listeners |
| Session advisory locks | no | `pg_advisory_xact_lock` |
| `WITH HOLD` cursors | no | keyset pagination |
| SQL `PREPARE` / `EXECUTE` | no | protocol-level prepared statements (below) |
| Temp tables (`ON COMMIT PRESERVE ROWS`) | no | `ON COMMIT DROP`, or a real table |
| Protocol-level prepared statements | yes, PgBouncer 1.21+ with `max_prepared_statements` > 0 | |

## Prepared statements through a pooler

Drivers prepare statements on a server connection; a transaction pooler may send the next execution to a different
connection, which fails with `prepared statement "s1" does not exist`. PgBouncer 1.21 and later track protocol-level
prepared statements when `max_prepared_statements` is above zero (default 200). For older poolers, or poolers
without this support, turn prepared statements off in the driver:

| Driver | Setting |
|---|---|
| postgres.js | `postgres(url, { prepare: false })` |
| psycopg 3 | `psycopg.connect(conninfo, prepare_threshold=None)` |
| asyncpg | `asyncpg.connect(dsn, statement_cache_size=0)` |
| JDBC | `prepareThreshold=0` in the URL |
| pgx | `default_query_exec_mode=exec` (or `simple_protocol`) in the connection string |
| Prisma | `?pgbouncer=true` on the URL for older PgBouncer |

Check your pooler's documentation, because the answers differ. Supabase says its shared pooler (Supavisor) does not
support prepared statements in transaction mode: turn them off there, or use session mode on port 5432. Its dedicated
pooler supports them on PgBouncer 1.21 or later. Hyperdrive supports named prepared statements. AWS lists the SQL
commands `PREPARE`, `EXECUTE` and `DEALLOCATE` as pinning an RDS Proxy session to its server connection.

## Serverless and edge functions

Serverless functions create connections per instance and scale to hundreds of instances, so they need a pooler in
transaction mode, or an HTTP or WebSocket driver.

- Supabase: use the pooler connection string in transaction mode (port 6543) for serverless, the direct or session
  string (port 5432) for migrations and long-lived servers.
- Neon: the pooled host has `-pooler` in its name; `@neondatabase/serverless` speaks HTTP or WebSocket for edge
  runtimes.
- AWS Lambda: RDS Proxy, and create the client outside the handler so warm invocations reuse it.
- Cloudflare Workers: Hyperdrive, with a client created per request.
- Keep a direct URL for migrations, `LISTEN`, and session-level work.

## Timeouts and dead connections

Timeouts close connections that would otherwise sit forever on a dead client or a stuck transaction.

```sql
ALTER ROLE app_rw SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE app_rw SET statement_timeout = '30s';
ALTER SYSTEM SET idle_session_timeout = '0';          -- leave 0 behind a pooler: the pooler manages idle connections
ALTER SYSTEM SET tcp_keepalives_idle = 60;            -- detect dead peers on long-lived connections
SELECT pg_reload_conf();
```

Set a connect timeout and a query timeout in the application pool too, so a saturated pool fails fast instead of
queueing requests forever.

## Worked example: "too many clients after we scaled to 30 pods"

The server has 8 cores and `max_connections = 200`; each of 30 pods runs a pool with `max: 10`, so the app alone
can open 300 connections, and autoscaling makes it worse. The Step 0 query shows 190 connections, 170 of them `idle`.

1. Work out the budget: about 2 to 4 per core, so 16 to 32 busy connections do the real work.
2. Put PgBouncer in transaction mode in front (or the provider's pooler): `default_pool_size = 20`,
   `max_client_conn = 2000`, `max_prepared_statements = 200`.
3. Point the pods at PgBouncer and keep `max: 10` per pod: clients wait in PgBouncer, not in Postgres.
4. Keep a direct URL for migrations and `LISTEN`, and check the code for session `SET` (use `SET LOCAL`).
5. Verify: `SHOW POOLS;` in the PgBouncer admin console shows `cl_waiting` near 0 under load, and
   `pg_stat_activity` holds about 20 app connections.

## Verify pool limits and pooler behaviour

Prove the pooler carries the load and the budget holds, with the application under normal traffic.

```sql
-- on PostgreSQL: the app total stays near default_pool_size, not the sum of the pods
SELECT application_name, state, count(*) FROM pg_stat_activity
WHERE backend_type = 'client backend' GROUP BY 1, 2 ORDER BY 3 DESC;
```

```bash
psql -h pgbouncer.internal -p 6432 -U pgbouncer_admin pgbouncer -c 'SHOW POOLS;'   # cl_waiting near 0
```

Run one test that runs `SET` through the pooler and reads it back from a second client: a value that shows up there
is session state leaking between clients. Then restart PgBouncer and confirm the application reconnects without a
deploy.

## Checklist

Check these points before you call connection pooling done.

- [ ] One pool per process, created at startup, with explicit `max`, idle and connect timeouts.
- [ ] Sum of all pool maxima fits under `max_connections` with room for admin, migrations and replicas.
- [ ] Serverless and autoscaled apps go through a transaction-mode pooler.
- [ ] Code behind a transaction pooler uses no session state (`SET`, `LISTEN`, session advisory locks, SQL `PREPARE`).
- [ ] Prepared statements are supported by the pooler or turned off in the driver.
- [ ] Migrations and listeners use a direct connection.
- [ ] `idle_in_transaction_session_timeout` is set for app roles.

## Gotchas

These are the failures seen most often with connection pooling, each with its cause and fix.

1. **`FATAL: sorry, too many clients already`.** Pools across instances exceed `max_connections`. Lower pool sizes
   or add a pooler; raising `max_connections` alone moves the problem into memory.
2. **`prepared statement "s0" does not exist` or `already exists`.** A transaction pooler without prepared statement
   support. Upgrade PgBouncer and set `max_prepared_statements`, or disable prepares in the driver.
3. **Settings leak between requests.** A session `SET` through a transaction pooler stayed on a shared server
   connection. Use `SET LOCAL`.
4. **Pool exhaustion under load with low database CPU.** Connections are leaked or held during network calls.
   Release them in `finally`, and do slow work outside transactions.
5. **Every serverless cold start opens a new connection.** Create the client outside the handler (Lambda) or use a
   pooler or HTTP driver; on Workers, use Hyperdrive.
6. **`LISTEN` stops receiving notifications.** The listener runs through a transaction pooler. Listen on a direct
   connection.

## Anti-patterns in connection pooling

| Do not | Do this instead |
|---|---|
| raise `max_connections` to fix `too many clients` | shrink pools, or put a pooler in front |
| size pools per instance without adding them up | budget the sum against `max_connections` |
| use session `SET`, `LISTEN` or `pg_advisory_lock` through a transaction pooler | `SET LOCAL`, a direct connection, `pg_advisory_xact_lock` |
| run migrations through the pooler | a direct URL with its own role |
| open a connection per serverless invocation | a pooler in transaction mode, or Hyperdrive on Workers |
| add `; comments` after values in `pgbouncer.ini` | comments on their own lines |

## See also

- `postgres-app-drivers`: pools and timeouts per language.
- `postgres-cloudflare-hyperdrive`: Workers through Hyperdrive.
- `postgres-operations`: `max_connections` and server memory.
- `postgres-monitoring-observability`: alerts on connections and pool waits.
- `postgres-internals-architecture`: why a connection is a process.
- `postgres-patroni-ha`: pools in front of a failover.

## Sources

- https://www.pgbouncer.org/config.html and https://www.pgbouncer.org/features.html
- https://www.postgresql.org/docs/18/runtime-config-connection.html
- https://www.postgresql.org/docs/18/sql-prepare.html
