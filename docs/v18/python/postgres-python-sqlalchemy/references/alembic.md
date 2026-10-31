---
title: Alembic migrations on PostgreSQL in depth
author: MOZGII, Inc.
lang: en
---

# Alembic migrations on PostgreSQL in depth

This reference covers Alembic 1.20 with SQLAlchemy 2.1 on PostgreSQL: project setup with `pyproject.toml`, an
`env.py` for schemas, constraint naming conventions, what autogenerate detects and misses, hand-editing scripts for
live tables, concurrent indexes, batched data migrations, multiple heads, and CI checks. Every command and script
below was run against PostgreSQL 18.6. The general rules for changing live tables (lock timeouts, expand and contract,
`NOT VALID`) are in `postgres-schema-migrations`.

## Alembic project setup with pyproject.toml

Alembic 1.16 and later can keep its settings in `pyproject.toml` (`[tool.alembic]`) instead of `alembic.ini`; the
`pyproject` and `pyproject_async` templates set that up. `alembic list_templates` shows all templates.

```bash
uv add sqlalchemy "psycopg[binary]" alembic
uv run alembic init -t pyproject migrations      # -t pyproject_async for an async engine
```

The template writes `migrations/env.py`, `migrations/script.py.mako`, `migrations/versions/`, a `[tool.alembic]`
table with `script_location`, and a small `alembic.ini` that keeps the database URL and logging. Keep the URL out of
both files and read it from the environment in `env.py`.

## env.py for PostgreSQL schemas and an environment URL

`env.py` connects, points Alembic at the models' `MetaData`, and runs the migrations in one transaction. This version
reads `DATABASE_URL`, compares only the `shop` schema, and keeps the version table in that schema:

```python
import os
from shop.models import Base

target_metadata = Base.metadata
config.set_main_option("sqlalchemy.url", os.environ["DATABASE_URL"].replace("%", "%%"))

def include_name(name, type_, parent_names):
    if type_ == "schema":
        return name in ("shop",)          # ignore public, extensions' schemas, other apps
    return True

def run_migrations_online() -> None:
    connectable = engine_from_config(config.get_section(config.config_ini_section, {}),
                                     prefix="sqlalchemy.", poolclass=pool.NullPool)
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata,
                          include_schemas=True, include_name=include_name, version_table_schema="shop")
        with context.begin_transaction():
            context.execute("CREATE SCHEMA IF NOT EXISTS shop")
            context.run_migrations()
```

- `.replace("%", "%%")` is needed because `set_main_option` goes through `configparser` interpolation; a
  URL-encoded password (`%40`) fails without it.
- `compare_type` is on by default since Alembic 1.12, so it need not be set. `compare_server_default=True` is off
  by default; turn it on only after testing it against your schema.
- Run Alembic as the migration role on a direct connection, never through a transaction pooler.

## Naming conventions for constraints and indexes

Postgres names unnamed constraints itself, and autogenerate cannot match or drop a constraint it cannot name. A
naming convention on the `MetaData` gives every constraint a deterministic name, which autogenerate renders with
`op.f(...)`:

```python
from sqlalchemy import MetaData

NAMING = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}
metadata = MetaData(schema="shop", naming_convention=NAMING)
```

The first autogenerate produced `pk_customers`, `uq_customers_email`, `fk_orders_customer_id_customers` and
`ix_shop_orders_customer_id`. Set the convention before the first migration: adding it later changes names that
existing databases already have. Postgres truncates identifiers at 63 bytes, so keep table and column names short
enough for the longest pattern.

## What Alembic autogenerate detects and misses

Autogenerate compares the models with the live database and writes a draft; it is never a finished migration.

| Change | Autogenerate |
|---|---|
| table or column added or removed | detected |
| nullable changed | detected |
| column type changed | detected (`compare_type`, on by default) |
| named index, unique constraint, foreign key | detected |
| server default changed | only with `compare_server_default=True` |
| named CHECK constraint added or removed | only with the `alembic.ext.checkconstraint_byname` plugin (1.19+); expression changes never |
| table or column renamed | not detected: emitted as drop plus add |
| anonymous (unnamed) constraints | not detected |
| sequences, `EXCLUDE` constraints, free-standing primary keys | not detected |
| functions, triggers, views, extensions, grants, RLS policies | not detected: write them with `op.execute` |

Renaming the model attribute `status` to `state` produced `add_column('state')` and `drop_column('status')`, which
would delete every value. A `Mapped[datetime.datetime]` without a type map produced `sa.DateTime()`, a
`timestamp without time zone`; map it to `DateTime(timezone=True)` before generating.

## Hand-editing a migration for a live table

This is the generated rename-and-index script rewritten to keep data and avoid long locks: a lock timeout, a real
rename, and the index built concurrently outside the transaction.

```python
from alembic import op

def upgrade() -> None:
    op.execute("SET lock_timeout = '3s'")
    op.alter_column("orders", "status", new_column_name="state", schema="shop")
    with op.get_context().autocommit_block():          # CONCURRENTLY cannot run in a transaction
        op.create_index(op.f("ix_shop_orders_customer_id"), "orders", ["customer_id"], schema="shop",
                        postgresql_concurrently=True, if_not_exists=True)

def downgrade() -> None:
    with op.get_context().autocommit_block():
        op.drop_index(op.f("ix_shop_orders_customer_id"), table_name="orders", schema="shop",
                      postgresql_concurrently=True, if_exists=True)
    op.alter_column("orders", "state", new_column_name="status", schema="shop")
```

`alembic upgrade head --sql` prints the SQL without running it; for this script it showed the `RENAME`, a `COMMIT`,
then `CREATE INDEX CONCURRENTLY IF NOT EXISTS ...`. `autocommit_block()` commits everything before it, so a failure
after it leaves the earlier steps applied: keep one risky step per revision.

## Batched data migrations in Alembic

A backfill of a large table in one `UPDATE` holds row locks for the whole run and creates a burst of dead tuples.
Update in committed batches inside `autocommit_block()`:

```python
import sqlalchemy as sa
from alembic import op

def upgrade() -> None:
    op.add_column("orders", sa.Column("total_cents", sa.BigInteger(), nullable=True), schema="shop")
    conn = op.get_bind()
    with op.get_context().autocommit_block():
        while True:
            done = conn.execute(sa.text("""
                UPDATE shop.orders SET total_cents = 0
                WHERE id IN (SELECT id FROM shop.orders WHERE total_cents IS NULL LIMIT 5000
                             FOR UPDATE SKIP LOCKED)""")).rowcount
            if done == 0:
                break
```

On 20,000 rows this left no `NULL`. Add `NOT NULL` in a later revision, after the application writes the column
(`postgres-schema-migrations` shows the `CHECK ... NOT VALID` route that avoids a long scan lock). For hours-long
backfills, run a separate job instead of a migration, so a deploy does not wait on it.

## Multiple heads, branches and merges

Two developers who each add a revision on top of the same parent create two heads. `alembic upgrade head` then
fails:

```text
FAILED: Multiple head revisions are present for given argument 'head'; please specify a specific target
revision, '<branchname>@head' to narrow to a specific head, or 'heads' for all heads
```

Merge them with a revision that has both as parents; it usually contains no operations.

```bash
uv run alembic heads                              # 0003a (head)  0003b (head)
uv run alembic merge heads -m "merge" --rev-id 0004
uv run alembic upgrade head                       # runs 0003b, 0003a, then the merge point 0004
uv run alembic history                            # 0003a, 0003b -> 0004 (head) (mergepoint)
```

- Creating a revision on a parent that is not a head needs `--head <rev> --splice`; without `--splice` Alembic
  refuses with "is not a head revision".
- Never edit or regenerate a revision a database already ran: Alembic trusts `alembic_version` and skips it. In a
  test here, a merge revision rewritten to add a second parent left that parent's column missing while
  `alembic current` reported the head.
- A CI step `test "$(alembic heads | wc -l)" -eq 1` catches a second head before merge.

## Alembic checks in CI

`alembic check` runs autogenerate against the database and fails when the models need a migration that does not
exist; it printed `No new upgrade operations detected.` when they matched and `FAILED: New upgrade operations
detected: [('remove_column', ...)]` when a column existed only in the database. A CI job for migrations:

```bash
uv run alembic upgrade head          # on a fresh database built from the real migrations
uv run alembic check                 # models and migrations agree
uv run alembic downgrade base && uv run alembic upgrade head   # downgrades work, if the team keeps them
```

Run migrations as a step before the new application version starts, with the deploy blocked on failure.

## Alembic gotchas

These Alembic problems come up most often, each with its cause and fix.

1. **A renamed column lost its data.** Autogenerate wrote drop plus add. Use `op.alter_column(...,
   new_column_name=...)`.
2. **`CREATE INDEX CONCURRENTLY cannot run inside a transaction block`.** The index was not in
   `autocommit_block()`. Wrap it.
3. **`ValueError: invalid interpolation syntax` from `set_main_option`.** The URL has `%`. Replace `%` with `%%`.
4. **Autogenerate wants to drop tables of another app or of an extension.** `include_schemas=True` saw every
   schema. Filter with `include_name`.
5. **Autogenerate output is empty although the models changed.** `target_metadata` is not the models' metadata,
   or the models module was never imported in `env.py`.

## Sources

- https://alembic.sqlalchemy.org/en/latest/autogenerate.html
- https://alembic.sqlalchemy.org/en/latest/naming.html
- https://alembic.sqlalchemy.org/en/latest/branches.html
- https://alembic.sqlalchemy.org/en/latest/api/runtime.html
- https://alembic.sqlalchemy.org/en/latest/ops.html
- https://alembic.sqlalchemy.org/en/latest/changelog.html
- https://www.postgresql.org/docs/18/sql-createindex.html
