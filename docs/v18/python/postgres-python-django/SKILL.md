---
name: postgres-python-django
description: 'Runs Django 5.2 LTS and 6.1 on PostgreSQL in depth, from a copy-paste uv quickstart: DATABASES settings with psycopg 3, the built-in connection pool in OPTIONS, CONN_MAX_AGE and health checks, django.contrib.postgres (ArrayField, JSONField lookups, HStoreField, full-text search with SearchVector and SearchRank, GinIndex, BrinIndex, ExclusionConstraint), migrations on big tables (AddIndexConcurrently, atomic = False, AddConstraintNotValid, SeparateDatabaseAndState, RunSQL), select_for_update(skip_locked=True), bulk_create with update_conflicts, safe raw SQL, and tests with --keepdb. Use when configuring Django for Postgres, a Django migration locks a large table, a Django queue or upsert is needed, or Django search, JSON or array queries must use Postgres features.'
metadata:
  tags:
  - postgres
  - python
  - django
  - psycopg
  - connection-pool
  - migrations
  - full-text-search
  - orm
---

# PostgreSQL with Django

Django talks to PostgreSQL through psycopg 3: install `psycopg[binary,pool]`, turn on the built-in pool in `OPTIONS`,
add `django.contrib.postgres` for Postgres types, indexes and search, and hand-write migrations that touch big
tables. The driver choice is explained in `postgres-python`; psycopg itself in `postgres-python-psycopg`. Field
lookups, search and constraints in more depth: [references/contrib-postgres.md](references/contrib-postgres.md);
migration recipes: [references/big-table-migrations.md](references/big-table-migrations.md).

## Quickstart: Django on PostgreSQL with uv

This quickstart creates a Django project with psycopg 3 and the pool, points it at Postgres and runs one query. It
works the same on macOS, Linux and Windows.

```bash
uv init --bare shop && cd shop
uv add django "psycopg[binary,pool]"
uv run django-admin startproject config .
```

Replace `DATABASES` in `config/settings.py` (add `import os` at the top); credentials come from the environment:

```python
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.environ.get("DB_NAME", "app"),
        "USER": os.environ.get("DB_USER", "app"),
        "PASSWORD": os.environ.get("DB_PASSWORD", ""),
        "HOST": os.environ.get("DB_HOST", "localhost"),   # or a socket directory: /var/run/postgresql
        "PORT": os.environ.get("DB_PORT", "5432"),
        "OPTIONS": {"pool": True},
    }
}
```

These commands create Django's tables, then open a cursor, run a parameterized query and close the connection:

```bash
uv run python manage.py migrate
uv run python manage.py shell -c "from django.db import connection; cur = connection.cursor(); cur.execute('SELECT version(), current_user, %s + 1', [41]); print(cur.fetchone()); connection.close()"
```

## Step 0: read the Django and psycopg versions

Django's Postgres support moves with each release, so read the versions first.

```bash
uv run python -c "import django, psycopg; print(django.get_version(), psycopg.__version__)"
```

Versions in October 2026: Django 6.1.2 (latest, Python 3.12 or later) and Django 5.2.18 (LTS, supported to April
2028); the next LTS, 6.2, is due April 2027. Django 6.1 supports PostgreSQL 15 and later and needs psycopg 3.1.12+
or psycopg2 2.9.9+. Everything in this skill ran on both 6.1.2 and 5.2.18 against PostgreSQL 18.6, except the
features marked 6.0 or 6.1.

## DATABASES settings for PostgreSQL

The `postgresql` backend uses psycopg 3 when it is installed and psycopg2 otherwise. Useful `OPTIONS`:

| Option | Effect |
|---|---|
| `"pool": True` or a dict | built-in psycopg_pool (Django 5.1 and later, psycopg 3 only) |
| `"application_name": "shop-web"` | shows in `pg_stat_activity` |
| `"options": "-c statement_timeout=30s"` | session settings for every connection |
| `"service": "shop"`, `"passfile": "/run/secrets/pgpass"` | host and password from `pg_service.conf` and a passfile, not settings |
| `"sslmode": "verify-full"`, `"sslrootcert": ...` | TLS to managed databases |
| `"server_side_binding": True` | server-side parameters (default: client-side binding with psycopg 3.1.8+) |
| `"isolation_level": IsolationLevel.SERIALIZABLE` | default isolation for the connection |
| `"assume_role": "app_rw"` | `SET ROLE` after connecting |

`TEST: {"NAME": "test_app"}` names the test database; the test user needs `CREATEDB`.

## Connection pooling: OPTIONS pool and CONN_MAX_AGE

Django keeps one pool per database alias per process when `OPTIONS["pool"]` is set; closing a Django connection
returns it to the pool. A dict is passed to psycopg's `ConnectionPool`:

```python
"CONN_MAX_AGE": 0,                     # must stay 0 with the pool
"CONN_HEALTH_CHECKS": True,            # also checks pooled connections, unless the pool has its own "check"
"OPTIONS": {
    "pool": {"min_size": 2, "max_size": 10, "timeout": 10, "max_lifetime": 1800},
    "application_name": "shop-web",
    "options": "-c statement_timeout=30s",
},
```

| Setup | Choose |
|---|---|
| WSGI or ASGI, direct to Postgres | `OPTIONS["pool"]`, sized so workers times `max_size` fits `max_connections` |
| WSGI without the pool | `CONN_MAX_AGE = 60` plus `CONN_HEALTH_CHECKS = True` (persistent connection per thread) |
| ASGI without the pool | `CONN_MAX_AGE = 0`; Django's docs say persistent connections should be off under ASGI |
| Behind PgBouncer in transaction mode | `CONN_MAX_AGE = 0`, `DISABLE_SERVER_SIDE_CURSORS = True`; PgBouncer does the pooling |

A non-zero `CONN_MAX_AGE` with the pool raises `ImproperlyConfigured: Pooling doesn't support persistent
connections.` In a run here, a pool with `min_size=2` showed 3 connections named `shop-web` in `pg_stat_activity`
while two threads worked.

## django.contrib.postgres fields: ArrayField, JSONField, HStoreField

`django.contrib.postgres` (add it to `INSTALLED_APPS`) brings Postgres-only fields, lookups, indexes, constraints,
search and extension operations. `JSONField` is in core Django and stored as `jsonb`.

```python
from django.contrib.postgres.fields import ArrayField
from django.contrib.postgres.indexes import BrinIndex, GinIndex
from django.db import models

class Product(models.Model):
    sku = models.CharField(max_length=40, unique=True)
    tags = ArrayField(models.CharField(max_length=30), default=list, blank=True)
    attrs = models.JSONField(default=dict, blank=True)
    price = models.DecimalField(max_digits=12, decimal_places=2)

    class Meta:
        indexes = [GinIndex(fields=["tags"], name="product_tags_gin"),
                   GinIndex(fields=["attrs"], name="product_attrs_gin", opclasses=["jsonb_path_ops"])]
```

These lookups compile to the operators GIN indexes serve (`@>`, `?`, `&&`):

```python
Product.objects.filter(attrs__contains={"color": "blue"})     # attrs @> '{"color": "blue"}'
Product.objects.filter(attrs__has_key="sizes")                 # attrs ? 'sizes'
Product.objects.filter(attrs__size__gte=40)                    # nested key with a comparison
Product.objects.filter(tags__contains=["running"])             # tags @> ARRAY['running']
Product.objects.filter(tags__overlap=["jackets", "sale"])      # tags && ARRAY[...]
```

`HStoreField` needs `HStoreExtension()` in a migration; `BrinIndex` suits large append-only time columns;
`ExclusionConstraint` with range fields stops overlapping bookings (example in the reference). Index choice in
general: `postgres-indexing`.

## Full-text search with SearchVector and SearchRank

A stored, weighted `tsvector` column with a GIN index makes Django search fast; `GeneratedField` (Django 5.0 and
later) keeps it in sync in the database.

```python
from django.contrib.postgres.search import SearchQuery, SearchRank, SearchVector, SearchVectorField
from django.db.models import F

class Product(models.Model):
    # ... fields from the previous section, plus:
    search = models.GeneratedField(
        expression=SearchVector("name", weight="A", config="english")
        + SearchVector("description", weight="B", config="english"),
        output_field=SearchVectorField(), db_persist=True)

q = SearchQuery("running trails", config="english", search_type="websearch")
results = Product.objects.filter(search=q).annotate(rank=SearchRank(F("search"), q)).order_by("-rank")
```

Always pass `config`: without it Postgres refuses the column with "generation expression is not immutable".
`SearchHeadline`, trigram similarity and Django 6.0's `Lexeme` are in
[references/contrib-postgres.md](references/contrib-postgres.md); search design is in `postgres-full-text-search`.

## Migrations on big tables

Django runs each migration in a transaction and uses plain DDL, which locks large tables. Rewrite the risky ones by
hand; `uv run python manage.py sqlmigrate <app> <number>` shows the SQL first.

This migration builds an index without blocking writes; `atomic = False` is required, or Django refuses with "The
AddIndexConcurrently operation cannot be executed inside a transaction (set atomic = False on the migration)":

```python
from django.contrib.postgres.operations import AddIndexConcurrently
from django.db import migrations, models

class Migration(migrations.Migration):
    atomic = False
    dependencies = [("shop", "0001_initial")]
    operations = [AddIndexConcurrently(
        model_name="reading", index=models.Index(fields=["sensor_id", "at"], name="reading_sensor_at_idx"))]
```

A `CHECK` constraint on a big table goes in two migrations: `AddConstraintNotValid` takes a short lock and skips
existing rows, then `ValidateConstraint` scans the table without blocking writes. Django's docs ask for two separate
migrations, so a failed validation leaves a clear state.

```python
from django.contrib.postgres.operations import AddConstraintNotValid, ValidateConstraint
from django.db import models
from django.db.models import Q

# 0005_reading_value_nonneg.py
operations = [AddConstraintNotValid(model_name="reading", constraint=models.CheckConstraint(
    condition=Q(value__gte=0), name="reading_value_nonneg"))]
# 0006_validate_reading_value_nonneg.py
operations = [ValidateConstraint(model_name="reading", name="reading_value_nonneg")]
```

For SQL Django cannot generate, `SeparateDatabaseAndState` runs hand-written `RunSQL` while recording the model
change in Django's state; a tested example is in [references/big-table-migrations.md](references/big-table-migrations.md).

- `CheckConstraint(condition=...)` is the Django 5.1+ spelling; older code used `check=`.
- `RemoveIndexConcurrently` drops an index the same way; extensions come from `CreateExtension("pg_trgm")` or the
  named classes (`TrigramExtension`, `HStoreExtension`, `BtreeGistExtension`).
- Run `manage.py makemigrations --check --dry-run` in CI; it exits non-zero when models and migrations disagree.
- The general rules (lock timeouts, expand and contract, backfills) are in `postgres-schema-migrations`.

## Job queues with select_for_update(skip_locked=True)

`select_for_update(skip_locked=True)` adds `FOR UPDATE SKIP LOCKED`, so workers claim different rows without waiting
on each other; it must run inside `transaction.atomic()`.

```python
from django.db import transaction
from django.utils import timezone

with transaction.atomic():
    jobs = list(Job.objects.select_for_update(skip_locked=True)
                .filter(done_at__isnull=True).order_by("id")[:3])
    Job.objects.filter(id__in=[j.id for j in jobs]).update(done_at=timezone.now())
```

Two threads running this at once claimed ids 1-3 and 4-6, with no overlap. Use `of=("self",)` when the query joins
other tables, so only the job rows are locked. Queue design (claim, work outside the transaction, mark done) is in
`postgres-transactions-locking`.

## Upserts with bulk_create(update_conflicts=True)

`bulk_create` with `update_conflicts=True` writes `INSERT ... ON CONFLICT (...) DO UPDATE`; on PostgreSQL it also sets
the primary keys of the returned objects.

```python
Product.objects.bulk_create(
    [Product(sku="A1", name="Trail shoe v2", price=125), Product(sku="C3", name="Cap", price=15)],
    update_conflicts=True, unique_fields=["sku"], update_fields=["name", "price"], batch_size=1000)
```

`ignore_conflicts=True` is `ON CONFLICT DO NOTHING` and leaves primary keys unset. `bulk_create` skips `save()` and
signals.

## Raw SQL in Django, safely

`Model.objects.raw()` and `connection.cursor()` take parameters as a list next to the SQL, never formatted into it.
Placeholders are `%s` whatever the binding mode.

```python
from django.db import connection

Product.objects.raw("SELECT id, sku FROM shop_product WHERE sku = %s", [sku])
with connection.cursor() as cur:
    cur.execute("SELECT count(*) FROM shop_product WHERE price > %s", [min_price])
    (count,) = cur.fetchone()
```

A table or column name chosen at run time goes through `psycopg.sql.Identifier` or a fixed allowlist, never `%s`.

## Testing Django against Postgres with --keepdb

`manage.py test` creates `test_<NAME>`, migrates it, runs each `TestCase` in a rolled-back transaction, and drops the
database; `--keepdb` keeps it between runs, so only new migrations run.

```bash
uv run python manage.py test --keepdb            # local runs
uv run python manage.py test --noinput --parallel auto   # CI: fresh database, no prompts
```

A test that expects an `IntegrityError` wraps the failing statement in `transaction.atomic()`, so the test's own
transaction survives. Test against the same Postgres major as production, never SQLite.

## Verify a Django project on Postgres

These commands ran on Django 6.1.2 with psycopg 3.3.6 and PostgreSQL 18.6, in a scratch project.

```bash
uv run python manage.py check --database default       # settings and a real database connection
uv run python manage.py makemigrations --check --dry-run   # exits non-zero when models and migrations disagree
uv run python manage.py sqlmigrate shop 0001           # read the SQL before a big table sees it
uv run python manage.py test --keepdb
```

```sql
SELECT application_name, state, count(*) FROM pg_stat_activity
WHERE application_name = 'shop-web' GROUP BY 1, 2;     -- workers times max_size at most
```

After a concurrent index migration, check that `SELECT indisvalid FROM pg_index WHERE indexrelid =
'reading_sensor_at_idx'::regclass;` is true: a failed build leaves an invalid index behind.

## Gotchas

These are the Django failures seen most often on Postgres, each with its cause and fix.

1. **`ImproperlyConfigured: Pooling doesn't support persistent connections.`** `CONN_MAX_AGE` is not 0 with the
   pool. Set it to 0 and use `max_lifetime`.
2. **A unique `CharField` creates two indexes.** `unique=True` adds a `varchar_pattern_ops` index (`..._like`) for
   `LIKE`. Declare a `UniqueConstraint` in `Meta.constraints` instead when no prefix search is needed.
3. **A migration hangs and every query on the table queues behind it.** Plain `AddIndex` or a constraint on a big
   table. Use `AddIndexConcurrently` or `NOT VALID` with `lock_timeout`.
4. **`TransactionManagementError: select_for_update cannot be used outside of a transaction.`** Wrap it in
   `transaction.atomic()`.
5. **`.iterator()` fails behind PgBouncer with a missing cursor.** Server-side cursors outlive the transaction
   and the pooler moved the session. Set `DISABLE_SERVER_SIDE_CURSORS = True` for that alias.
6. **Search returns nothing for words that are there.** Query and vector use different configs. Pass the same
   `config` to both.

## Anti-patterns in Django on Postgres

Each of these is fine on a small table and an outage on a big one.

| Do not | Do instead |
|---|---|
| Let `makemigrations` output run on a big table unread | Read `sqlmigrate`, then hand-write the risky steps |
| Run `AddIndex` on a live table | Use `AddIndexConcurrently` with `atomic = False` |
| Add a constraint in one step | Use `AddConstraintNotValid`, then `ValidateConstraint` in the next migration |
| Set `CONN_MAX_AGE` with the pool on | Keep it 0 and use `max_lifetime` |
| Format values into `raw()` or `cursor.execute()` | Pass parameters as a list |
| Test on SQLite | Test on the same Postgres major as production |

## Checklist

Check these points before you call a Django and Postgres setup done.

- [ ] `psycopg[binary,pool]` installed; `ENGINE` is `django.db.backends.postgresql`; secrets from the environment.
- [ ] Pool (or `CONN_MAX_AGE`) chosen per the table, sized against `max_connections`.
- [ ] `django.contrib.postgres` in `INSTALLED_APPS`; GIN indexes for JSON, array and search lookups.
- [ ] Migrations on large tables use `AddIndexConcurrently` (`atomic = False`) and `AddConstraintNotValid`.
- [ ] `makemigrations --check --dry-run` runs in CI.
- [ ] Queues use `select_for_update(skip_locked=True)` in `transaction.atomic()`.
- [ ] Raw SQL passes parameters as a list.

## See also

Related skills in this library, each one works on its own:

- `postgres-python`: the driver choice.
- `postgres-python-psycopg`: psycopg itself.
- `postgres-schema-migrations`: lock timeouts, expand and contract, backfills.
- `postgres-full-text-search`: search design.
- `postgres-indexing`: index choice in general.
- `postgres-transactions-locking`: queue design.

## Sources

- https://docs.djangoproject.com/en/6.1/ref/databases/
- https://docs.djangoproject.com/en/6.1/ref/contrib/postgres/
- https://docs.djangoproject.com/en/6.1/ref/contrib/postgres/operations/
- https://docs.djangoproject.com/en/6.1/ref/migration-operations/
- https://docs.djangoproject.com/en/6.1/ref/models/querysets/
- https://docs.djangoproject.com/en/6.1/topics/testing/overview/
- https://docs.djangoproject.com/en/6.1/releases/6.1/
- https://www.djangoproject.com/download/
