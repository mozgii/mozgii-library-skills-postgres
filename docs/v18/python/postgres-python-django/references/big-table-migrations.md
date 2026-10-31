---
title: Django migrations on big PostgreSQL tables
author: MOZGII, Inc.
lang: en
---

# Django migrations on big PostgreSQL tables

This reference holds tested recipes for Django migrations that change large, busy PostgreSQL tables: reading the SQL
first, adding columns without a rewrite, concurrent indexes, `NOT VALID` constraints, `SeparateDatabaseAndState` with
`RunSQL`, and batched backfills with `RunPython`. Each ran on Django 6.1.2 against PostgreSQL 18.6, on a 200,000-row
table. The database-side rules (lock queues, `lock_timeout`, expand and contract) are in `postgres-schema-migrations`.

## Read the SQL before migrating

`sqlmigrate` prints the SQL a migration will run, with `BEGIN` and `COMMIT` when it is atomic. Read it for every
migration that touches a large table, and look for table rewrites and locks.

```bash
uv run python manage.py sqlmigrate shop 0007
uv run python manage.py migrate --plan                 # which migrations will run, in order
uv run python manage.py makemigrations --check --dry-run   # CI: models and migrations agree
```

## Adding a column with db_default, without a rewrite

`db_default` (Django 5.0 and later) puts the default in the database, so the column is added with
`ADD COLUMN ... DEFAULT 'api' NOT NULL`, which PostgreSQL 11 and later does without rewriting the table. A nullable
column without a default is also instant.

```python
class Reading(models.Model):
    source = models.CharField(max_length=20, db_default="api")
    value_x10 = models.BigIntegerField(null=True)
```

The generated SQL was:

```sql
ALTER TABLE "shop_reading" ADD COLUMN "source" varchar(20) DEFAULT 'api' NOT NULL;
ALTER TABLE "shop_reading" ADD COLUMN "value_x10" bigint NULL;
```

A volatile default (`db_default=Now()` is fine, a random function is not) or a type change rewrites the table; check
`postgres-schema-migrations` before running those.

## Concurrent index builds with AddIndexConcurrently

`AddIndexConcurrently` runs `CREATE INDEX CONCURRENTLY`, which does not block writes; the migration must set
`atomic = False`, or Django raises "The AddIndexConcurrently operation cannot be executed inside a transaction (set
atomic = False on the migration)".

```python
from django.contrib.postgres.operations import AddIndexConcurrently
from django.db import migrations, models

class Migration(migrations.Migration):
    atomic = False
    dependencies = [("shop", "0001_initial")]
    operations = [AddIndexConcurrently(
        model_name="reading", index=models.Index(fields=["sensor_id", "at"], name="reading_sensor_at_idx"))]
```

A failed concurrent build leaves an `INVALID` index behind; find it with `SELECT indexrelid::regclass FROM pg_index
WHERE NOT indisvalid`, drop it with `RemoveIndexConcurrently` or `DROP INDEX CONCURRENTLY`, and run again. Keep one
concurrent operation per migration, so a failure is easy to resume.

## CHECK constraints with AddConstraintNotValid and ValidateConstraint

`AddConstraintNotValid` adds a `CHECK` constraint that new rows must satisfy but existing rows are not scanned for,
taking only a brief lock; `ValidateConstraint` scans later with a lock that lets reads and writes continue. Django's
docs ask for the two in separate migrations.

```python
# 0005_reading_value_nonneg.py
from django.contrib.postgres.operations import AddConstraintNotValid
from django.db import migrations, models
from django.db.models import Q

class Migration(migrations.Migration):
    dependencies = [("shop", "0004_device")]
    operations = [AddConstraintNotValid(
        model_name="reading",
        constraint=models.CheckConstraint(condition=Q(value__gte=0), name="reading_value_nonneg"))]
```

The second migration validates the existing rows:

```python
# 0006_validate_reading_value_nonneg.py
from django.contrib.postgres.operations import ValidateConstraint
from django.db import migrations

class Migration(migrations.Migration):
    dependencies = [("shop", "0005_reading_value_nonneg")]
    operations = [ValidateConstraint(model_name="reading", name="reading_value_nonneg")]
```

After both, `pg_constraint.convalidated` was true and `makemigrations --check` found no changes, because the model
declares the same `CheckConstraint`.

## SeparateDatabaseAndState with RunSQL

`SeparateDatabaseAndState` runs one set of operations on the database and records another in Django's migration
state. Use it when the SQL you need differs from what Django would generate, such as a `lock_timeout` before the
change. This migration adds the same kind of `CHECK` constraint by hand:

```python
from django.db import migrations, models
from django.db.models import Q

class Migration(migrations.Migration):
    atomic = False
    dependencies = [("shop", "0002_reading_sensor_at_idx")]
    operations = [migrations.SeparateDatabaseAndState(
        database_operations=[
            migrations.RunSQL(
                "SET lock_timeout = '3s'; ALTER TABLE shop_product ADD CONSTRAINT product_price_nonneg "
                "CHECK (price >= 0) NOT VALID",
                reverse_sql="ALTER TABLE shop_product DROP CONSTRAINT product_price_nonneg"),
            migrations.RunSQL("ALTER TABLE shop_product VALIDATE CONSTRAINT product_price_nonneg",
                              reverse_sql=migrations.RunSQL.noop)],
        state_operations=[migrations.AddConstraint(
            model_name="product",
            constraint=models.CheckConstraint(condition=Q(price__gte=0), name="product_price_nonneg"))])]
```

The database operations and the state operations must describe the same end result; otherwise the next
`makemigrations` emits a migration that tries to "fix" the difference. Always give `RunSQL` a `reverse_sql`.

## Batched backfills with RunPython

A backfill in one `UPDATE` locks every row it touches until it commits and leaves a burst of dead tuples. In a
non-atomic migration each `update()` commits on its own, so a loop of small batches keeps locks short:

```python
from django.db import migrations
from django.db.models import F

BATCH = 10_000

def backfill(apps, schema_editor):
    Reading = apps.get_model("shop", "Reading")
    while True:
        ids = list(Reading.objects.filter(value_x10__isnull=True).values_list("id", flat=True)[:BATCH])
        if not ids:
            break
        Reading.objects.filter(id__in=ids).update(value_x10=F("value") * 10)

class Migration(migrations.Migration):
    atomic = False
    dependencies = [("shop", "0007_reading_source")]
    operations = [migrations.RunPython(backfill, migrations.RunPython.noop, elidable=True)]
```

On 200,000 rows the whole `migrate` took about 2 s and left no `NULL`. Use `apps.get_model`, never an import of the
model, so the migration sees the schema as of its own point in history. Backfills that take hours belong in a
management command or a job run after the deploy, not in `migrate`.

## Running migrations in deployment

Run `manage.py migrate` as one step before the new code starts, with one runner at a time; two app servers migrating
at once race on the same tables. Use a direct connection (not a transaction pooler) and a role that owns the tables.
Set a lock timeout for the migration role so a blocked `ALTER TABLE` fails fast instead of queueing every query
behind it:

```sql
ALTER ROLE shop_migrator SET lock_timeout = '5s';
```

## Sources

- https://docs.djangoproject.com/en/6.1/ref/contrib/postgres/operations/
- https://docs.djangoproject.com/en/6.1/ref/migration-operations/
- https://docs.djangoproject.com/en/6.1/howto/writing-migrations/
- https://docs.djangoproject.com/en/6.1/ref/models/fields/
- https://www.postgresql.org/docs/18/sql-altertable.html
- https://www.postgresql.org/docs/18/sql-createindex.html
