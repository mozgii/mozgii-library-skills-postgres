---
title: Testing Python code against PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Testing Python code against PostgreSQL

This reference sets up pytest so tests run against a real PostgreSQL, isolated from each other and never touching a
shared or production database.

## A real Postgres per test session

Tests against SQLite or mocks miss PostgreSQL behaviour (constraints, `ON CONFLICT`, JSONB, locking). Start a real
server once per test session.

```python
# tests/conftest.py
import pytest
from testcontainers.community.postgres import PostgresContainer

@pytest.fixture(scope="session")
def database_url():
    with PostgresContainer("postgres:18", driver=None) as pg:      # driver=None: plain postgresql:// URL
        yield pg.get_connection_url()
```

Without Docker, `pytest-postgresql` starts a server from the local binaries (`postgresql_proc` fixture), or point
`DATABASE_URL` at a dedicated `*_test` database in CI.

## Run the real migrations once

Build the schema with the same migrations production uses, so the tests exercise them too.

```python
import os
import subprocess

@pytest.fixture(scope="session")
def migrated(database_url):
    subprocess.run(["alembic", "upgrade", "head"], check=True,
                   env={**os.environ, "DATABASE_URL": database_url})
    return database_url
```

## One transaction per test, rolled back

Each test runs inside a transaction that is rolled back at the end, so tests leave no rows and do not depend on
order.

```python
import psycopg

@pytest.fixture
def conn(migrated):
    with psycopg.connect(migrated) as c:
        c.autocommit = False
        yield c
        c.rollback()

def test_upsert_keeps_one_row(conn):
    for _ in range(2):
        conn.execute("INSERT INTO app.customers (email) VALUES (%s) ON CONFLICT (email) DO NOTHING", ("a@acme.example",))
    assert conn.execute("SELECT count(*) FROM app.customers").fetchone()[0] == 1
```

Code under test that commits by itself breaks this pattern. Pass the test's connection into the code, or with
SQLAlchemy bind the session to an outer transaction with `join_transaction_mode="create_savepoint"`.

## Template databases for fast fresh databases

When tests need a clean database each (parallel workers, code that commits), clone a migrated template: copying a
template is much faster than running migrations again.

```sql
CREATE DATABASE app_template;           -- run migrations into it once, then:
CREATE DATABASE test_worker_1 TEMPLATE app_template;
DROP DATABASE test_worker_1 WITH (FORCE);
```

PG 18 can clone with `STRATEGY = FILE_COPY` and `file_copy_method = clone` for near-instant copies on filesystems
that support it.

## Testing gotchas

These database test problems come up most often, each with its cause and fix.

1. **Tests pass alone and fail together.** Some test committed rows. Find the commit, or give that test its own
   database.
2. **pytest-asyncio and async drivers.** Use one event loop for the session-scoped pool and the tests, or the pool
   is attached to a different loop.
3. **Tests read `DATABASE_URL` from the developer's shell.** Set it inside the fixture; never fall back to a default
   that could point at a real database.
