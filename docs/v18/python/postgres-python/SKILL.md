---
name: postgres-python
description: 'Connects Python code to PostgreSQL safely with the smallest stack that fits: psycopg 3 with psycopg_pool by default, asyncpg for raw async throughput, SQLAlchemy 2.1 and Alembic when an ORM pays off, parameterized queries, typed rows, transactions, COPY, connections immune to PG* environment variables and .pgpass, and pytest fixtures that roll back. Use whenever Python code connects to, queries, migrates or tests Postgres, or when choosing between psycopg2, psycopg 3, asyncpg and SQLAlchemy.'
metadata:
  tags:
  - postgres
  - python
  - psycopg
  - asyncpg
  - sqlalchemy
  - alembic
  - connection-pool
  - pytest
---

# PostgreSQL from Python

Default to plain psycopg 3 with parameterized SQL and a pool; add an ORM only when the project's relational
complexity asks for it. ORM and migrations detail: [references/sqlalchemy-alembic.md](references/sqlalchemy-alembic.md).
Tests: [references/testing.md](references/testing.md).

## Step 0: read installed versions

APIs differ between majors (SQLAlchemy 2.1 needs Python 3.11 and an explicit asyncio extra), so read them first.

```bash
uv pip list 2>/dev/null | grep -iE 'psycopg|asyncpg|sqlalchemy|alembic|pgvector' || pip list | grep -iE 'psycopg|asyncpg|sqlalchemy|alembic'
python -c "import psycopg; print(psycopg.__version__, psycopg.pq.version())"   # driver and libpq versions
```

Current versions (October 2026): psycopg 3.3.6, psycopg-pool 3.3.3, asyncpg 0.32.0, SQLAlchemy 2.1.6,
Alembic 1.20.1, pgvector (Python) 0.5.1.

## Choosing the driver

Choose by how the calling code runs, not by fashion.

| Situation | Use | Install |
|---|---|---|
| Default: sync code, scripts, CLIs, workers, Django | psycopg 3 + `psycopg_pool` | `uv add "psycopg[binary,pool]"` |
| `async def` end to end (FastAPI, aiohttp) | psycopg 3 async, or asyncpg when raw throughput matters most | `uv add "psycopg[binary,pool]"` or `uv add asyncpg` |
| Many related tables, shared query logic, an ORM team | SQLAlchemy 2.1 on psycopg or asyncpg | `uv add "sqlalchemy[asyncio]" "psycopg[binary]"` |

- `psycopg[binary]` bundles libpq; for production on Linux you can build against the system libpq with `psycopg[c]`.
- psycopg2 is in maintenance; start new code on psycopg 3.
- Django 6 uses psycopg 3 when installed (`ENGINE: django.db.backends.postgresql`).

## Connection and pooling with psycopg_pool

One pool per process, created at startup, reused for every query. Read the connection string from the environment.

```python
import os
from psycopg_pool import ConnectionPool

pool = ConnectionPool(
    os.environ["DATABASE_URL"],          # postgresql://app_api@db.example:5432/app?sslmode=verify-full
    min_size=1, max_size=10,
    kwargs={"application_name": "app-worker", "options": "-c statement_timeout=30s"},
    open=True,
)

with pool.connection() as conn:           # commits on success, rolls back on exception, returns to the pool
    conn.execute("UPDATE app.jobs SET done_at = now() WHERE id = %s", (job_id,))
```

Async version:

```python
from psycopg_pool import AsyncConnectionPool

pool = AsyncConnectionPool(os.environ["DATABASE_URL"], min_size=1, max_size=10, open=False)
await pool.open()                         # at application startup; await pool.close() at shutdown
async with pool.connection() as conn:
    cur = await conn.execute("SELECT id FROM app.jobs WHERE done_at IS NULL LIMIT 10")
    rows = await cur.fetchall()
```

## Parameterized queries, always

Parameters are passed separately from the SQL text, so input can never change the query. Never build SQL with
f-strings or `%` formatting.

```python
# WRONG: SQL injection
cur.execute(f"SELECT * FROM app.customers WHERE email = '{email}'")
# RIGHT: psycopg sends the value as a parameter
cur.execute("SELECT * FROM app.customers WHERE email = %s", (email,))
cur.execute("SELECT * FROM app.customers WHERE id = ANY(%s)", (ids,))        # a Python list becomes an array
```

Identifiers (table or column names chosen at run time) go through `psycopg.sql`:

```python
from psycopg import sql
query = sql.SQL("SELECT {col} FROM app.customers ORDER BY {col}").format(col=sql.Identifier(column))
```

psycopg 3.3 also accepts Python 3.14 template strings (`t"... {email}"`), which it turns into parameters.

## Row factories and TypedDict results

Row factories return dicts or dataclasses instead of tuples; narrow them into a `TypedDict` at the function
boundary so type checkers know the shape.

```python
from typing import TypedDict
import psycopg
from psycopg.rows import class_row, dict_row
from dataclasses import dataclass

class CustomerRow(TypedDict):
    id: int
    email: str

def get_customer(conn: psycopg.Connection, email: str) -> CustomerRow | None:
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute("SELECT id, email FROM app.customers WHERE email = %s", (email,))
        row = cur.fetchone()
    return CustomerRow(id=row["id"], email=row["email"]) if row else None

@dataclass
class Customer:
    id: int
    email: str

with conn.cursor(row_factory=class_row(Customer)) as cur:      # typed rows without a cast
    customers = cur.execute("SELECT id, email FROM app.customers").fetchall()
```

## Transactions

psycopg opens a transaction on the first statement and commits when the `with pool.connection()` block ends. Use
`conn.transaction()` for an explicit block, nested blocks for savepoints.

```python
with pool.connection() as conn:
    with conn.transaction():
        conn.execute("UPDATE app.accounts SET balance = balance - %s WHERE id = %s", (amount, src))
        conn.execute("UPDATE app.accounts SET balance = balance + %s WHERE id = %s", (amount, dst))
        # an exception here rolls back both
```

Retry the whole block on `psycopg.errors.SerializationFailure` and `psycopg.errors.DeadlockDetected`.

## Bulk loading with COPY

`COPY` through `cursor.copy()` streams rows far faster than many `INSERT`s.

```python
with pool.connection() as conn, conn.cursor() as cur:
    with cur.copy("COPY app.readings (sensor_id, value) FROM STDIN") as copy:
        for sensor_id, value in readings:
            copy.write_row((sensor_id, value))
```

`cur.executemany()` in psycopg 3 uses pipeline mode and is also fast for thousands of rows.

## asyncpg essentials

asyncpg speaks the protocol directly and is very fast, but uses `$1` placeholders and its own API.

```python
import asyncpg

pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], min_size=1, max_size=10, command_timeout=30)
async with pool.acquire() as conn:
    async with conn.transaction():
        row = await conn.fetchrow("SELECT id, email FROM app.customers WHERE email = $1", email)
        await conn.copy_records_to_table("readings", schema_name="app", records=readings)
```

Behind a transaction pooler without prepared statement support, pass `statement_cache_size=0`.

## Connections immune to PG environment variables and .pgpass

libpq-based clients fill any connection field you leave out from `PG*` environment variables, and `PGOPTIONS` can
change session settings even when host, port, database and user are explicit. With no password given, libpq and
asyncpg also read `~/.pgpass`, where a `*:*:*:*:` line matches any server. For a process that must always reach one
specific database (an app with its own cluster, a CI job), remove `PG*` and name every field:

```python
import os
for key in [k for k in os.environ if k.startswith("PG")]:
    del os.environ[key]
from psycopg.conninfo import make_conninfo

dsn = make_conninfo(host=cfg.host, port=cfg.port, dbname=cfg.dbname, user=cfg.user,
                    passfile=cfg.passfile, sslmode="verify-full", application_name="app-worker")
```

## Local Postgres for development

Run a Postgres matching production's major for development and tests.

| Option | When |
|---|---|
| `docker run -d --name pg -e POSTGRES_PASSWORD=dev -p 5432:5432 postgres:18` | the project uses Docker; disposable |
| Postgres.app (macOS), the PGDG apt/yum packages (Linux), the EDB installer (Windows) | a native server |
| testcontainers or pytest-postgresql | a fresh server per test session |

For a desktop app or tool that owns its database, run a private cluster instead (`postgres-local-cluster`).

## Worked example: "move this FastAPI service from psycopg2 to psycopg 3"

The service opens a psycopg2 connection per request and builds some SQL with f-strings. The move:

1. `uv remove psycopg2-binary && uv add "psycopg[binary,pool]"`.
2. Open one `AsyncConnectionPool(..., open=False)` in the FastAPI lifespan: `await pool.open()` at startup,
   `await pool.close()` at shutdown. Each handler uses `async with pool.connection() as conn:`.
3. Replace every f-string query with `%s` parameters (`psycopg.sql.Identifier` for the one dynamic sort column).
4. psycopg 3 differences to check: `cursor.execute()` returns the cursor, so `conn.execute(...).fetchall()` chains;
   `with conn:` closes the connection at the end (psycopg2 only ended the transaction); server-side binding means
   `%s` cannot stand for a table name or appear in `SET statement_timeout = %s` (use `set_config('statement_timeout', %s, false)`).
5. Run the tests against a real Postgres; then watch `pg_stat_activity` under load: the connection count stays at the
   pool's `max_size` instead of one per request.

## Verify Python database code

Check the build, then the code, then the database's view of it. The grep must print nothing; the query ran on 18.6.

```bash
uv run python -c "import psycopg; print(psycopg.__version__, psycopg.pq.__impl__, psycopg.pq.version())"
grep -rnE 'execute\(\s*f["'"'"']' src/          # an f-string in execute() is an injection risk
uv run pytest -q
```

```sql
SELECT application_name, state, count(*) FROM pg_stat_activity
WHERE application_name = 'app-worker' GROUP BY 1, 2;     -- total at or under the pool's max_size
```

Run the process once with `PGOPTIONS='-c default_transaction_read_only=on'` in its environment when it must be immune:
a write must still succeed.

## Checklist

Check these points before you call Python database code done.

- [ ] Connection string from the environment; no credentials in code.
- [ ] One pool per process, opened at startup, closed at shutdown.
- [ ] Every value parameterized; identifiers through `psycopg.sql`.
- [ ] Rows narrowed to a `TypedDict` or dataclass at the boundary.
- [ ] Multi-statement writes in `conn.transaction()`; retries on serialization and deadlock errors.
- [ ] Bulk loads use `COPY` or `executemany`.
- [ ] Tests roll back or use a throwaway database; never a shared or production one.

## Gotchas

These are the failures seen most often with Python database code, each with its cause and fix.

1. **Queries hit another database, or every write fails as read-only.** `PG*` variables (`PGHOST`, `PGOPTIONS`)
   filled fields the conninfo left open. Name every field, or delete `PG*` before connecting.
2. **A wrong password still connects.** No password was given, so libpq used `~/.pgpass`. Pass the password or an
   explicit `passfile`.
3. **Changes vanish.** A connection made with `psycopg.connect()` (not the pool context) was closed without
   `commit()`; psycopg does not autocommit by default.
4. **`AsyncConnectionPool` warns about opening in the constructor.** Create it with `open=False` and `await
   pool.open()` inside the running event loop.
5. **`InFailedSqlTransaction: current transaction is aborted`.** An earlier statement failed in the same
   transaction; roll back (or use a savepoint) before running more.
6. **SQLAlchemy async fails with `greenlet` missing after upgrading to 2.1.** Install `sqlalchemy[asyncio]`.

## Anti-patterns in Python database code

These show up in nearly every first version of a service.

| Do not | Do instead |
|---|---|
| Open a connection per request | Create one pool per process at startup |
| Build SQL with f-strings or `%` | Pass values as parameters and identifiers through `psycopg.sql` |
| Start new code on psycopg2 | Start on psycopg 3; psycopg2 is in maintenance |
| Add an ORM before the project needs one | Start with plain psycopg and add SQLAlchemy when relations demand it |
| Keep credentials in code or a repository | Read the connection string from the environment |
| Test against SQLite or a shared database | Test on a throwaway Postgres of the same major |

## See also

Related skills in this library, each one works on its own:

- `postgres-python-psycopg`: psycopg 3 in depth.
- `postgres-python-asyncpg`: asyncpg in depth.
- `postgres-python-sqlalchemy`: SQLAlchemy and Alembic in depth.
- `postgres-python-django`: Django on Postgres.
- `postgres-python-data`: pandas, Polars and DuckDB.
- `postgres-local-cluster`: a private cluster for a desktop app.
- `postgres-testing-ci`: test databases in CI.
