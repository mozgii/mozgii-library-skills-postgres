---
name: postgres-python-sqlalchemy
description: 'Uses SQLAlchemy 2.1 on PostgreSQL in depth, from a copy-paste uv quickstart: psycopg and asyncpg engine URLs, pool settings, typed models with Mapped, Core or ORM, sessions, async sessions, on_conflict_do_update upserts, JSONB, ARRAY, uuidv7, ranges, CTEs, window functions, eager loading against N+1, bulk writes, and Alembic in depth. Use when building or debugging SQLAlchemy on Postgres, MissingGreenlet or lazy loading errors appear, an upsert is needed, or Alembic autogenerate, heads or migrations go wrong.'
metadata:
  tags:
  - postgres
  - python
  - sqlalchemy
  - orm
  - alembic
  - asyncio
  - upsert
  - migrations
---

# PostgreSQL with SQLAlchemy 2.1

SQLAlchemy 2.1 runs on psycopg 3 by default: write typed models with `Mapped[...]`, open one engine per process, use a
`Session` per unit of work, load relationships explicitly, and treat every Alembic autogenerate output as a draft.
Whether an ORM pays off at all is decided in `postgres-python`; driver details are in `postgres-python-psycopg` and
`postgres-python-asyncpg`. Alembic in depth: [references/alembic.md](references/alembic.md).

## Quickstart: SQLAlchemy in a uv project

This quickstart creates a uv project with SQLAlchemy and psycopg and runs one query through an engine; it works the
same on macOS, Linux and Windows.

```bash
uv init shop && cd shop
uv add sqlalchemy "psycopg[binary]"              # add "sqlalchemy[asyncio]" for async code
export DATABASE_URL="postgresql+psycopg://app@localhost:5432/app"
```

The program opens an engine, runs a parameterized text query and disposes of the pool.

```python
# main.py
import os

from sqlalchemy import create_engine, text

engine = create_engine(os.environ["DATABASE_URL"])
with engine.connect() as conn:
    row = conn.execute(text("SELECT version(), current_user, :n + 1"), {"n": 41}).one()
    print(row)
engine.dispose()
```

Run it with `uv run main.py`; over a Unix socket the URL is `postgresql+psycopg://app@/app?host=/var/run/postgresql`.

## Step 0: read installed SQLAlchemy and Alembic versions

SQLAlchemy 2.1 changed defaults that 2.0 code relied on, so read the versions first.

```bash
uv run python -c "import sqlalchemy, alembic; print(sqlalchemy.__version__, alembic.__version__)"
```

Current versions (October 2026): SQLAlchemy 2.1.6 (Python 3.11 or later), Alembic 1.20.1. Changes
in 2.1 that matter on Postgres: `postgresql://` now means psycopg 3, `greenlet` comes only with the `asyncio` extra,
`Computed(...)` without `persisted=True` is a PostgreSQL 18 `VIRTUAL` column, named types such as `Enum` take the
`MetaData` schema, and `func.uuidv7(monotonic=True)` works in batched inserts.

## Engine URLs and drivers

The URL scheme picks the driver; name it explicitly so an upgrade never switches drivers silently.

| URL | Driver | Engine |
|---|---|---|
| `postgresql+psycopg://` | psycopg 3, sync | `create_engine` |
| `postgresql+psycopg://` | psycopg 3, async | `create_async_engine` |
| `postgresql+asyncpg://` | asyncpg | `create_async_engine` |
| `postgresql+psycopg2://` | psycopg2 (maintenance only) | `create_engine` |

Build a URL whose password has special characters with `sqlalchemy.URL.create(...)`.

## Engine pool settings

The engine keeps a `QueuePool`: defaults are `pool_size=5`, `max_overflow=10`, `pool_timeout=30`,
`pool_recycle=-1` (never) and `pool_pre_ping=False`. Set them for production:

```python
engine = create_engine(
    os.environ["DATABASE_URL"],
    pool_size=5, max_overflow=5, pool_timeout=10,
    pool_pre_ping=True,          # test each connection on checkout; survives restarts and failovers
    pool_recycle=1800,           # replace connections older than 30 min
    connect_args={"application_name": "shop-api", "options": "-c statement_timeout=30s"},
)
```

- One engine per process (each can open `pool_size + max_overflow`); after `fork()` (Gunicorn preload, multiprocessing) call `engine.dispose(close=False)` in
  the child.
- Behind PgBouncer in transaction mode use `poolclass=NullPool` and turn prepared statements off where the pooler
  cannot track them: `connect_args={"prepare_threshold": None}` for psycopg,
  `?prepared_statement_cache_size=0` in the URL plus `connect_args={"statement_cache_size": 0}` for asyncpg.

## Typed ORM models with Mapped and mapped_column

Declarative models with `Mapped[...]` give typed attributes and derive `NOT NULL` from `Optional`. Put the Postgres
types and the constraint naming convention on the base once.

```python
import datetime, decimal, uuid
from typing import Any
from sqlalchemy import BigInteger, Computed, DateTime, ForeignKey, Identity, MetaData, Numeric, String, Text, func, text
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, TSTZRANGE, Range
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from sqlalchemy.types import UUID

class Base(DeclarativeBase):
    metadata = MetaData(schema="shop", naming_convention={
        "ix": "ix_%(column_0_label)s", "uq": "uq_%(table_name)s_%(column_0_name)s",
        "ck": "ck_%(table_name)s_%(constraint_name)s", "pk": "pk_%(table_name)s",
        "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s"})
    type_annotation_map = {datetime.datetime: DateTime(timezone=True), dict[str, Any]: JSONB, list[str]: ARRAY(Text)}

class Customer(Base):
    __tablename__ = "customers"
    id: Mapped[uuid.UUID] = mapped_column(UUID, primary_key=True, server_default=func.uuidv7(monotonic=True))
    email: Mapped[str] = mapped_column(String(320), unique=True)
    prefs: Mapped[dict[str, Any]] = mapped_column(server_default=text("'{}'::jsonb"))
    tags: Mapped[list[str]] = mapped_column(server_default=text("'{}'"))
    created_at: Mapped[datetime.datetime] = mapped_column(server_default=func.now())
    orders: Mapped[list["Order"]] = relationship(back_populates="customer", lazy="raise")

class Order(Base):
    __tablename__ = "orders"
    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("shop.customers.id"), index=True)
    total: Mapped[decimal.Decimal] = mapped_column(Numeric(12, 2))
    total_cents: Mapped[int] = mapped_column(BigInteger, Computed("(total * 100)::bigint", persisted=True))
    during: Mapped[Range[datetime.datetime] | None] = mapped_column(TSTZRANGE)
    customer: Mapped[Customer] = relationship(back_populates="orders")
```

- Without the `type_annotation_map` entry, `Mapped[datetime.datetime]` becomes `timestamp without time zone`;
  Alembic autogenerate showed `sa.DateTime()` here until the map was added.
- `server_default` puts the default in the database, so raw SQL and other services get it; `default=` runs only in
  Python.

## Core or ORM

SQLAlchemy Core runs SQL expressions on a `Connection` and returns rows; the ORM maps rows to objects with identity
and change tracking in a `Session`. Both build the same `select`, `insert` and `update`. Use the ORM for business
logic that loads, changes and saves related objects; use Core for reports, bulk loads, ETL and set-based updates; use
`text()` with `:name` bind parameters for SQL the expression language cannot say.

## Sessions and the unit of work

A `Session` collects changes and writes them in one transaction at `flush()` or commit. `Session.begin()` commits on
success and rolls back on an exception.

```python
from sqlalchemy.orm import sessionmaker

SessionLocal = sessionmaker(engine, expire_on_commit=False)

with SessionLocal.begin() as session:
    customer = Customer(email="ann@acme.example", prefs={"theme": "dark"}, tags=["vip"])
    customer.orders = [Order(total=decimal.Decimal("10.00"))]
    session.add(customer)
    session.flush()                     # INSERTs run now; server defaults and RETURNING fill customer.id
```

- One session per request or job, never shared between threads or tasks.
- `expire_on_commit=False` keeps attributes readable after commit; otherwise async code raises on access.
- In 2.1 autoflush runs before every execution, `text()` included; wrap code that must not flush in
  `with session.no_autoflush:`.

## Async sessions with create_async_engine

The async engine wraps psycopg or asyncpg and needs `sqlalchemy[asyncio]` (greenlet). Lazy loading cannot run inside
`await`, so every relationship read is loaded in the query or through `awaitable_attrs`.

```python
from sqlalchemy.ext.asyncio import AsyncAttrs, async_sessionmaker, create_async_engine

engine = create_async_engine("postgresql+asyncpg://app@db.example/app", pool_size=5, pool_pre_ping=True)
SessionAsync = async_sessionmaker(engine, expire_on_commit=False)

async with SessionAsync() as session:
    customers = (await session.scalars(
        select(Customer).options(selectinload(Customer.orders)).limit(20))).all()
await engine.dispose()                                      # at shutdown
```

Reading an unloaded relationship in async code raises `MissingGreenlet: greenlet_spawn has not been called`. With
`AsyncAttrs` in the base classes, `await obj.awaitable_attrs.orders` loads one on demand (not for `lazy="raise"`).

## Eager loading to avoid N+1 queries

Loading a relationship per row in a loop runs one query per row (N+1). Choose the loader in the query:

| Loader | Queries | Use for |
|---|---|---|
| `selectinload(Customer.orders)` | 2 (parents, then `WHERE customer_id IN (...)`) | collections; the default choice |
| `joinedload(Order.customer)` | 1 (`LEFT OUTER JOIN`) | many-to-one; collections need `.unique()` on the result |
| `raiseload("*")` | 0 | forbid further loads in this query (`lazy="raise"` on the model does it everywhere) |

This query loads 50 customers and all their orders in two statements:

```python
custs = session.scalars(select(Customer).options(selectinload(Customer.orders)).limit(50)).all()
```

Counted with a `before_cursor_execute` listener, `joinedload` did the same in 1 statement.

## PostgreSQL upsert with on_conflict_do_update and RETURNING

The Postgres `insert` from `sqlalchemy.dialects.postgresql` adds `ON CONFLICT`; `excluded` is the row that failed to
insert. This upsert merges JSONB preferences, skips identical rows and returns the result:

```python
from sqlalchemy.dialects.postgresql import insert

stmt = insert(Customer).values(email="ann@acme.example", prefs={"theme": "light"})
stmt = stmt.on_conflict_do_update(
    index_elements=[Customer.email],
    set_={"prefs": Customer.prefs.op("||")(stmt.excluded.prefs)},
    where=Customer.prefs.is_distinct_from(stmt.excluded.prefs),
).returning(Customer.id, Customer.prefs)
row = session.execute(stmt).one()
```

`on_conflict_do_nothing()` skips duplicates; a `where` that filters every row makes `RETURNING` return nothing.

## JSONB, ARRAY and range operators

The Postgres types carry their operators as Python methods, compiled to the operators GIN and GiST indexes support:

```python
select(Customer.email, Customer.prefs["theme"].astext).where(Customer.prefs.contains({"theme": "light"}))  # @>
select(Customer.id).where(Customer.prefs.has_key("theme"))                                                # ?
select(func.count()).where(Customer.tags.contains(["eu"]))                                                # array @>
select(func.count()).where(Customer.tags.any_() == "vip")                                                 # = ANY
select(Order.id).where(Order.during.contains(datetime.datetime(2026, 1, 1, 12, tzinfo=datetime.UTC)))     # range @>
```

Index design for these operators is in `postgres-indexing`.

## CTEs and window functions

`.cte()` makes a `WITH` query and `.over(...)` a window function; this counts each customer's last two orders:

```python
ranked = select(Order.id, Order.customer_id,
                func.row_number().over(partition_by=Order.customer_id, order_by=Order.id.desc()).label("rn")
                ).cte("ranked")
rows = session.execute(select(ranked.c.customer_id, func.count()).where(ranked.c.rn <= 2)
                       .group_by(ranked.c.customer_id)).all()
```

## Bulk insert and bulk update

Passing a list of dicts to `session.execute(insert(Model), rows)` sends batched multi-row `INSERT`s
("insertmanyvalues"); `sort_by_parameter_order=True` returns the generated keys in input order, which works with
server-side `uuidv7()` because the default is declared monotonic.

```python
from sqlalchemy import insert, update

ids = session.scalars(insert(Customer).returning(Customer.id, sort_by_parameter_order=True),
                      [{"email": f"c{i}@acme.example"} for i in range(1000)]).all()
session.execute(update(Order), [{"id": 1, "total": 1}, {"id": 2, "total": 2}])          # by primary key
session.execute(update(Order).where(Order.total > 5).values(total=Order.total * 2))     # one set-based UPDATE
```

For millions of rows, use `COPY` through the raw driver connection (`postgres-python-psycopg`).

## Alembic migrations

Alembic generates migration scripts from model changes; review every one before it touches a live table. The rules,
each proven in [references/alembic.md](references/alembic.md):

- Autogenerate turns a column rename into drop plus add (data loss): use `op.alter_column(..., new_column_name=...)`.
- A generated `create_index` locks writes: move it into `autocommit_block()` with `postgresql_concurrently=True`.
- Backfills run in committed batches, never one `UPDATE` of the whole table.
- Two developers branching from one revision give two heads: `alembic merge heads`.
- `alembic check` in CI fails when models and migrations disagree.

## SQLModel on SQLAlchemy 2.1

SQLModel 0.0.48 joins pydantic models and SQLAlchemy tables and accepts SQLAlchemy 2.1. It suits FastAPI CRUD; declare
Postgres types with `Field(sa_column=Column(JSONB))` and migrate with Alembic.

## Gotchas

These are the SQLAlchemy failures seen most often on Postgres, each with its cause and fix.

1. **`MissingGreenlet: greenlet_spawn has not been called`.** A lazy load or an expired attribute in async code.
   Load with `selectinload`, set `expire_on_commit=False`, or use `awaitable_attrs`.
2. **`ImportError: The SQLAlchemy asyncio module requires that the Python 'greenlet' library is installed`.** 2.1
   no longer installs greenlet by default. Install `sqlalchemy[asyncio]`.
3. **Timestamps lose their zone.** `Mapped[datetime]` maps to `timestamp without time zone`. Map it to
   `DateTime(timezone=True)`.
4. **A generated column became `VIRTUAL` after upgrading.** 2.1 renders `Computed` without `STORED`. Pass
   `persisted=True` for the old behaviour.
5. **`prepared statement "__asyncpg_stmt_1__" already exists` behind PgBouncer.** asyncpg caches statements. Use
   `NullPool`, `prepared_statement_cache_size=0` and `statement_cache_size=0`.
6. **`'Customer.orders' is not available due to lazy='raise'`.** A query forgot its loader. Add `selectinload`.

## Anti-patterns in SQLAlchemy code on Postgres

These habits run without an error at first and fail under load or on upgrade.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| A new engine per request | each engine has its own pool, so connections multiply until the server refuses them | one engine per process, one `Session` per unit of work |
| A bare `postgresql://` URL | the driver follows the SQLAlchemy version: 2.1 reads it as psycopg 3 | name the driver: `postgresql+psycopg://` |
| Reading relationships in a loop | one query per row, or `MissingGreenlet` in async code | `selectinload` or `joinedload` in the query, `lazy="raise"` on the model |
| One `Session` shared between threads or tasks | transactions and loaded objects mix between callers | one session per request or job |
| Values in an f-string inside `text()` | SQL injection, and no plan reuse | `:name` bind parameters |
| Applying an autogenerated migration unread | a rename becomes drop plus add, and an index locks writes | review every script; `postgres-schema-migrations` for the safe forms |
| ORM objects for millions of rows | memory and time grow with every tracked object | `insert(Model)` with a list, or `COPY` |

## Verify SQLAlchemy models, migrations and loading

These checks prove the models match the database and that a list page hides no N+1. They ran on PostgreSQL 18.6 with
the current SQLAlchemy and Alembic, on a scratch database.

```bash
uv run alembic upgrade head     # applies cleanly on an empty database
uv run alembic heads            # one line ending in (head); two lines need alembic merge heads
uv run alembic check            # No new upgrade operations detected.
```

A model changed without a migration makes `alembic check` exit non-zero with `FAILED: New upgrade operations detected:`.
This test pins the statement count, so a removed `selectinload` fails at once instead of in production:

```python
from sqlalchemy import event, select
from sqlalchemy.orm import Session, selectinload

def test_customer_list_runs_two_statements(engine):
    seen = []
    event.listen(engine, "before_cursor_execute", lambda conn, cur, stmt, *rest: seen.append(stmt))
    with Session(engine) as session:
        customers = session.scalars(select(Customer).options(selectinload(Customer.orders))).all()
        [len(c.orders) for c in customers]
    assert len(seen) == 2       # parents, then WHERE customer_id IN (...)
```

Without the `selectinload`, the same read raises `'Customer.orders' is not available due to lazy='raise'`.

## Checklist

Check these points before you call SQLAlchemy code done.

- [ ] URL names the driver (`postgresql+psycopg` or `postgresql+asyncpg`); credentials from the environment.
- [ ] One engine per process with `pool_pre_ping`, `pool_recycle` and a sized pool; disposed at shutdown.
- [ ] Models typed with `Mapped`; `datetime` mapped to `timestamptz`; naming convention set on the `MetaData`.
- [ ] Every relationship read is loaded in its query; `lazy="raise"` in tests.
- [ ] Upserts use the Postgres `insert` with `on_conflict_do_update`.
- [ ] Bulk writes use `insert(Model)` with a list, or `COPY` for millions.
- [ ] Every Alembic script reviewed; `alembic check` runs in CI.

## See also

Related skills in this library:

- `postgres-python`: the choice of driver and ORM, and pytest wiring
- `postgres-python-psycopg`: psycopg 3 itself, COPY included
- `postgres-python-asyncpg`: asyncpg under the async engine
- `postgres-schema-migrations`: lock-safe DDL for Alembic scripts
- `postgres-connection-pooling`: sizing pools and PgBouncer

## Sources

- https://docs.sqlalchemy.org/en/21/changelog/migration_21.html
- https://docs.sqlalchemy.org/en/21/dialects/postgresql.html
- https://docs.sqlalchemy.org/en/21/core/pooling.html
- https://docs.sqlalchemy.org/en/21/orm/queryguide/relationships.html
- https://docs.sqlalchemy.org/en/21/orm/queryguide/dml.html
- https://docs.sqlalchemy.org/en/21/orm/extensions/asyncio.html
- https://pypi.org/project/sqlmodel/
