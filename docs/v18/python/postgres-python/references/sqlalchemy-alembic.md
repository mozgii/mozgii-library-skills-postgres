---
title: SQLAlchemy 2.1 and Alembic with PostgreSQL
author: MOZGII, Inc.
lang: en
---

# SQLAlchemy 2.1 and Alembic with PostgreSQL

This reference covers SQLAlchemy 2.1 engines, typed models and sessions on PostgreSQL, and Alembic migrations that
are safe on a live database.

## Contents

The sections of this reference on sQLAlchemy 2.1 and Alembic with PostgreSQL:

1. When to move from plain SQL to SQLAlchemy
2. Engine and session setup
3. Typed models for PostgreSQL
4. Alembic setup and safe migrations

## When to move from plain SQL to SQLAlchemy

SQLAlchemy pays off when the schema has many related tables, query logic is shared across many call sites, or the
team wants generated migration diffs. A handful of tables with simple reads and writes is clearer as plain SQL with
psycopg; numbered `.sql` migration files applied by a small script work well there.

## Engine and session setup

The URL scheme selects the driver: `postgresql+psycopg://` (psycopg 3, the 2.1 default for `postgresql://`) or
`postgresql+asyncpg://`.

```python
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

engine = create_engine(
    os.environ["DATABASE_URL"].replace("postgresql://", "postgresql+psycopg://", 1),
    pool_size=5, max_overflow=5, pool_pre_ping=True, pool_recycle=1800,
    connect_args={"application_name": "app-api"},
)
Session = sessionmaker(engine, expire_on_commit=False)

with Session.begin() as session:          # commits on success, rolls back on error
    session.add(Customer(email="ann@acme.example"))
```

Async:

```python
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

engine = create_async_engine("postgresql+asyncpg://app_api@db.example/app", pool_size=5)
SessionAsync = async_sessionmaker(engine, expire_on_commit=False)
async with SessionAsync.begin() as session:
    result = await session.execute(select(Customer).where(Customer.email == email))
```

SQLAlchemy 2.1 requires Python 3.11 or later and installs `greenlet` only with the `asyncio` extra.

## Typed models for PostgreSQL

Declarative models with `Mapped[...]` give typed attributes; use PostgreSQL types explicitly.

```python
from datetime import datetime
from sqlalchemy import BigInteger, ForeignKey, Identity, Index, String, text
from sqlalchemy.dialects.postgresql import JSONB, TIMESTAMP
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

class Base(DeclarativeBase):
    pass

class Customer(Base):
    __tablename__ = "customers"
    __table_args__ = {"schema": "app"}
    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    email: Mapped[str] = mapped_column(String, unique=True)
    prefs: Mapped[dict] = mapped_column(JSONB, server_default=text("'{}'::jsonb"))
    created_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), server_default=text("now()"))
    orders: Mapped[list["Order"]] = relationship(back_populates="customer")

class Order(Base):
    __tablename__ = "orders"
    __table_args__ = (Index("orders_customer_id_idx", "customer_id"), {"schema": "app"})
    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    customer_id: Mapped[int] = mapped_column(ForeignKey("app.customers.id"))
    customer: Mapped[Customer] = relationship(back_populates="orders")
```

- `server_default` puts the default in the database, so raw SQL inserts get it; `default=` runs only in Python.
- Load relationships explicitly (`selectinload(Customer.orders)`) to avoid N+1 queries; lazy loading in async code
  raises errors.
- PostgreSQL upsert: `from sqlalchemy.dialects.postgresql import insert`; `insert(Customer).values(...).on_conflict_do_update(index_elements=["email"], set_={...})`.

## Alembic setup and safe migrations

Alembic generates migration scripts from model changes (`--autogenerate`) and applies them in order.

```bash
uv add alembic
alembic init -t async migrations          # or without -t async for sync engines
alembic revision --autogenerate -m "add orders"
alembic upgrade head                      # in CI, before the app deploy
alembic current; alembic history --verbose
```

Review every generated script before applying it: autogenerate cannot see renames (it emits drop and add), and it
emits plain `CREATE INDEX`. Hand-edit for safety:

```python
from alembic import op

def upgrade() -> None:
    op.execute("SET lock_timeout = '3s'")
    with op.get_context().autocommit_block():          # CONCURRENTLY cannot run in a transaction
        op.create_index("orders_status_idx", "orders", ["status"], schema="app",
                        postgresql_concurrently=True, if_not_exists=True)
```

- Set `include_schemas=True` in `env.py` when you use schemas.
- Run Alembic with the migration role on a direct connection, never through a transaction pooler.
- The general rules for live tables (lock timeouts, expand and contract, `NOT VALID`) are in
  `postgres-schema-migrations`.
