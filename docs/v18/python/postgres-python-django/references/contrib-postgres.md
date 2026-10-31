---
title: django.contrib.postgres fields, lookups, search, indexes and constraints
author: MOZGII, Inc.
lang: en
---

# django.contrib.postgres fields, lookups, search, indexes and constraints

This reference covers the PostgreSQL-only parts of Django: `ArrayField`, `HStoreField`, range fields, `JSONField`
lookups on `jsonb`, full-text search with ranking, headlines, trigram similarity and `Lexeme`, the index classes, and
`ExclusionConstraint`. Every example ran on Django 6.1.2 (and, unless marked 6.0, on 5.2.18) against PostgreSQL 18.6.

## Enabling django.contrib.postgres

`django.contrib.postgres` must be in `INSTALLED_APPS` for its lookups, search and templates; since Django 6.0 a system
check reports its fields, indexes and constraints used without it. Extensions are created by migration operations,
which need a role allowed to create them (often the database owner, or a superuser on self-hosted servers):

| Need | Operation |
|---|---|
| `HStoreField` | `HStoreExtension()` |
| trigram lookups and `TrigramSimilarity` | `TrigramExtension()` |
| `ExclusionConstraint` with `=` on plain columns | `BtreeGistExtension()` |
| `unaccent` lookup | `UnaccentExtension()` |
| any other | `CreateExtension("name")` |

On managed services, check the provider's allowed extension list first (`postgres-operations`).

## JSONField lookups on jsonb

Django's `JSONField` is stored as `jsonb` on PostgreSQL. Key paths use `__`, and the containment and key lookups map
to operators a GIN index serves.

```python
Product.objects.filter(attrs__color="red")                    # attrs -> 'color' = '"red"'
Product.objects.filter(attrs__size__gte=40)                    # nested key, numeric comparison
Product.objects.filter(attrs__contains={"color": "blue"})     # attrs @> '{"color": "blue"}'
Product.objects.filter(attrs__has_key="sizes")                 # attrs ? 'sizes'
Product.objects.filter(attrs__has_keys=["color", "size"])     # attrs ?& array[...]
```

`GinIndex(fields=["attrs"], opclasses=["jsonb_path_ops"])` is smaller and faster for `@>` but does not serve `?`;
use the default opclass when key lookups matter. JSON design and indexing: `postgres-schema-design`,
`postgres-indexing`.

## ArrayField and its lookups

`ArrayField(base_field)` stores a PostgreSQL array; lookups cover containment, overlap and length.

```python
from django.contrib.postgres.fields import ArrayField

tags = ArrayField(models.CharField(max_length=30), default=list, blank=True)

Product.objects.filter(tags__contains=["running"])        # tags @> ARRAY['running']
Product.objects.filter(tags__contained_by=["a", "b"])     # tags <@ ARRAY[...]
Product.objects.filter(tags__overlap=["jackets", "sale"]) # tags && ARRAY[...]
Product.objects.filter(tags__len=2)                       # array_length(tags, 1) = 2
Product.objects.filter(tags__0="shoes")                   # first element (index 0 in Django)
```

Use `default=list`, never `default=[]`, so instances do not share one list. In Django 6.1, top-level `None` items in
an `ArrayField` of `JSONField` are saved as SQL `NULL` rather than JSON `null`.

## HStoreField for string key-value pairs

`HStoreField` stores `text` keys and values in the `hstore` extension type; values are strings or `None`.

```python
from django.contrib.postgres.fields import HStoreField

class Device(models.Model):
    labels = HStoreField(default=dict)

Device.objects.filter(labels__env="prod")                     # labels -> 'env' = 'prod'
Device.objects.filter(labels__has_key="zone")
Device.objects.filter(labels__contains={"env": "prod"})
```

For nested or typed values prefer `JSONField`. Django 6.1's `inspectdb` recognizes `hstore` columns when psycopg 3.2+
is installed.

## Range fields

Range fields map to PostgreSQL range types: `IntegerRangeField`, `BigIntegerRangeField`, `DecimalRangeField`,
`DateRangeField`, `DateTimeRangeField` (`tstzrange`). Values are psycopg range objects, imported portably from
`django.db.backends.postgresql.psycopg_any`.

```python
import datetime
from django.db.backends.postgresql.psycopg_any import DateTimeTZRange

t0 = datetime.datetime(2026, 11, 1, 9, tzinfo=datetime.UTC)
Booking.objects.create(room=room, during=DateTimeTZRange(t0, t0 + datetime.timedelta(hours=2)))
Booking.objects.filter(during__contains=t0 + datetime.timedelta(minutes=30))
Booking.objects.filter(during__overlap=DateTimeTZRange(t0, t0 + datetime.timedelta(hours=1)))
```

## ExclusionConstraint for bookings without overlap

`ExclusionConstraint` stops two rows from overlapping, for example two bookings of one room. An equality on a plain
column inside a GiST constraint needs the `btree_gist` extension, so put `BtreeGistExtension()` first in the
migration.

```python
from django.contrib.postgres.constraints import ExclusionConstraint
from django.contrib.postgres.fields import DateTimeRangeField, RangeOperators
from django.db.models import Q

class Booking(models.Model):
    room = models.ForeignKey("Room", on_delete=models.CASCADE)
    during = DateTimeRangeField()
    cancelled = models.BooleanField(default=False)

    class Meta:
        constraints = [ExclusionConstraint(
            name="booking_no_overlap",
            expressions=[("room", RangeOperators.EQUAL), ("during", RangeOperators.OVERLAPS)],
            condition=Q(cancelled=False))]
```

The generated DDL is `EXCLUDE USING GIST ("room_id" WITH =, "during" WITH &&) WHERE (NOT "cancelled")`. An
overlapping insert raises `IntegrityError` caused by psycopg's `ExclusionViolation`: "conflicting key value violates
exclusion constraint "booking_no_overlap"". Django 6.1 also accepts the Hash index type here.

## Full-text search with ranking and headlines

A stored `tsvector` column with weights, kept by `GeneratedField`, and a GIN index make search fast. Pass the same
`config` everywhere: a vector built with `english` and a query with the default config will not match stemmed words,
and a generated vector without `config` is refused with "generation expression is not immutable".

```python
from django.contrib.postgres.search import (SearchHeadline, SearchQuery, SearchRank, SearchVector,
                                            SearchVectorField)
from django.db.models import F

search = models.GeneratedField(
    expression=SearchVector("name", weight="A", config="english")
    + SearchVector("description", weight="B", config="english"),
    output_field=SearchVectorField(), db_persist=True)

q = SearchQuery("running trails", config="english", search_type="websearch")
Product.objects.filter(search=q).annotate(rank=SearchRank(F("search"), q)).order_by("-rank")
Product.objects.filter(search=q).annotate(snippet=SearchHeadline("description", q, config="english"))
# snippet: '<b>Waterproof</b> jacket for running in rain' for the query "waterproof"
```

`search_type` is `plain` (default), `phrase`, `raw` or `websearch`; `websearch` accepts what people type into a
search box (quotes, `or`, `-word`) without raising syntax errors.

## Lexeme for safe search operators (Django 6.0)

`Lexeme` builds a `tsquery` from untrusted words with operators applied safely: each value is escaped, `prefix=True`
matches word starts, `~` negates.

```python
from django.contrib.postgres.search import Lexeme, SearchQuery

q = SearchQuery(Lexeme("jack", prefix=True) & ~Lexeme("shoe"), config="english")
Product.objects.filter(search=q)       # search @@ to_tsquery('english', 'jack':* & !'shoe')
```

## Trigram similarity for typos

With `TrigramExtension()` applied, `TrigramSimilarity` ranks near matches; "rain jaket" scored 0.64 against "Rain
jacket" here.

```python
from django.contrib.postgres.search import TrigramSimilarity

Product.objects.annotate(sim=TrigramSimilarity("name", "rain jaket")).filter(sim__gt=0.3).order_by("-sim")
```

The `trigram_similar` lookup uses the server's `pg_trgm.similarity_threshold` (0.3 by default); index trigram search
with `GinIndex(fields=["name"], opclasses=["gin_trgm_ops"], name=...)`. Search design: `postgres-full-text-search`.

## Index classes in django.contrib.postgres

`django.contrib.postgres.indexes` adds the PostgreSQL index types; each needs an explicit `name`.

| Class | Use for |
|---|---|
| `GinIndex` | `jsonb`, arrays, `tsvector`, trigram (`opclasses=["gin_trgm_ops"]`) |
| `GistIndex` | ranges, geometry, exclusion-style queries |
| `BrinIndex` | very large tables whose column follows insertion order (time) |
| `BTreeIndex`, `HashIndex`, `SpGistIndex`, `BloomIndex` | specific storage parameters or access methods |

`OpClass(expression, name=...)` sets an operator class inside `Index` expressions; `models.Index(..., condition=Q(...))`
makes a partial index. Build any of them on a live table with `AddIndexConcurrently`.

## Sources

- https://docs.djangoproject.com/en/6.1/ref/contrib/postgres/fields/
- https://docs.djangoproject.com/en/6.1/ref/contrib/postgres/lookups/
- https://docs.djangoproject.com/en/6.1/ref/contrib/postgres/search/
- https://docs.djangoproject.com/en/6.1/ref/contrib/postgres/indexes/
- https://docs.djangoproject.com/en/6.1/ref/contrib/postgres/constraints/
- https://docs.djangoproject.com/en/6.1/ref/contrib/postgres/operations/
- https://docs.djangoproject.com/en/6.1/releases/6.0/
- https://docs.djangoproject.com/en/6.1/releases/6.1/
