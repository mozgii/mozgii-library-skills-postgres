---
title: psycopg 3 type adaptation for PostgreSQL types
author: MOZGII, Inc.
lang: en
---

# psycopg 3 type adaptation for PostgreSQL types

This reference covers how psycopg 3 turns Python values into PostgreSQL values (dumpers) and back (loaders): JSON and
JSONB, UUID, numeric, timestamps, arrays, ranges, enums, pgvector, and custom adapters. Every example was run against
PostgreSQL 18.6 with psycopg 3.3.6.

## Default mapping between Python and PostgreSQL types

psycopg 3 adapts the common types without configuration. Python `int` is dumped by its size, so `5` is sent as
`smallint` and `2**40` as `bigint`; a function overloaded on several numeric types may then need a cast (`%s::int`).

| PostgreSQL | Python (loaded) | Python to send |
|---|---|---|
| `integer`, `bigint` | `int` | `int` |
| `numeric` | `decimal.Decimal` | `Decimal` (never `float` for money) |
| `double precision` | `float` | `float` |
| `text`, `varchar` | `str` | `str` |
| `bytea` | `bytes` | `bytes` |
| `boolean` | `bool` | `bool` |
| `uuid` | `uuid.UUID` | `uuid.UUID` |
| `timestamptz` | aware `datetime` in the session `TimeZone` | aware `datetime` |
| `timestamp` | naive `datetime` | naive `datetime` |
| `date`, `time`, `interval` | `date`, `time`, `timedelta` | same |
| `json`, `jsonb` | `dict`, `list`, scalars | `Json(obj)`, `Jsonb(obj)` |
| arrays (`int[]`, `text[]`) | `list` | `list` |
| ranges (`tstzrange`) | `psycopg.types.range.Range` | `Range` |

## JSON and JSONB values with Jsonb

JSON values are wrapped explicitly, because a Python `dict` is ambiguous: passing a bare dict raises
`ProgrammingError: cannot adapt type 'dict'`. `Jsonb(obj)` sends `jsonb`, `Json(obj)` sends `json`.

```python
from psycopg.types.json import Jsonb

conn.execute("INSERT INTO app.customers (email, prefs) VALUES (%s, %s)", (email, Jsonb({"theme": "dark"})))
```

The loader uses `json.loads`; to keep decimals exact (or use a faster library) set it per connection:

```python
import json, decimal
from psycopg.types.json import set_json_loads

set_json_loads(lambda s: json.loads(s, parse_float=decimal.Decimal), conn)
conn.execute("SELECT %s::jsonb", (Jsonb({"x": 1.1}),)).fetchone()     # ({'x': Decimal('1.1')},)
```

`set_json_dumps` sets the dump function the same way, for example to serialize `datetime` values.

## UUID, numeric and timestamps

UUID columns load as `uuid.UUID`; PostgreSQL 18 generates time-ordered keys with `DEFAULT uuidv7()`. `numeric`
loads as `Decimal`, which is exact but slower; when a report wants floats, register `FloatLoader` on that cursor
only:

```python
from psycopg.types.numeric import FloatLoader

cur = conn.cursor()
cur.adapters.register_loader("numeric", FloatLoader)
cur.execute("SELECT 1.25::numeric").fetchone()          # (1.25,)
```

`timestamptz` values arrive as aware datetimes in the session's `TimeZone`, which defaults to the server's setting.
For predictable code, connect with `options="-c TimeZone=UTC"` and convert for display at the edge.

## Arrays and ANY

Python lists become PostgreSQL arrays, so `= ANY(%s)` replaces a long `IN (...)` list with one parameter and one
prepared plan.

```python
conn.execute("SELECT id FROM app.customers WHERE id = ANY(%s)", (ids,))
conn.execute("SELECT %s::int[] @> ARRAY[2]", ([1, 2],))       # (True,)
```

An empty list has no element type: cast it (`%s::text[]`) when the server cannot infer the type.

## Ranges with psycopg Range

`Range(lower, upper, bounds)` maps to any range type; `"[)"` is the canonical bound for `tstzrange`.

```python
import datetime
from psycopg.types.range import Range

t0 = datetime.datetime(2026, 1, 1, tzinfo=datetime.UTC)
conn.execute("INSERT INTO app.bookings (during) VALUES (%s)",
             (Range(t0, t0 + datetime.timedelta(days=1), "[)"),))
```

Multiranges load as `psycopg.types.multirange.Multirange`.

## PostgreSQL enums as Python Enum

A PostgreSQL enum loads as a string until it is registered; `register_enum` maps it to a Python `Enum` in both
directions.

```python
import enum
from psycopg.types.enum import EnumInfo, register_enum

class Status(enum.Enum):
    NEW = "new"
    PAID = "paid"

info = EnumInfo.fetch(conn, "app.order_status")
register_enum(info, conn, Status, mapping={Status.NEW: "new", Status.PAID: "paid"})
conn.execute("SELECT status FROM app.orders").fetchone()       # (<Status.PAID: 'paid'>,)
```

Register on each new connection: in a pool, do it in `configure`. When the adapters change after the pool opened,
`pool.drain()` (psycopg-pool 3.3) replaces the connections.

## pgvector with psycopg

The `pgvector` Python package registers the `vector` type, so NumPy arrays go in and `Vector` objects come out.

```python
import numpy as np
from pgvector.psycopg import register_vector

register_vector(conn)                         # in the pool's configure callback
conn.execute("SELECT %s::vector <-> %s::vector", (np.array([1, 2, 3]), np.array([1, 2, 4]))).fetchone()   # (1.0,)
```

Index and query design for embeddings is in `postgres-vector-search`.

## Custom dumpers and loaders

A dumper turns a Python class into a PostgreSQL value; a loader does the reverse. This pair maps a `Money` class
holding cents to `numeric`:

```python
import decimal
import psycopg
from psycopg.adapt import Dumper, Loader

class Money:
    def __init__(self, cents: int) -> None:
        self.cents = cents

class MoneyDumper(Dumper):
    oid = psycopg.adapters.types["numeric"].oid
    def dump(self, obj: Money) -> bytes:
        return str(decimal.Decimal(obj.cents) / 100).encode()

class MoneyLoader(Loader):
    def load(self, data) -> Money:
        return Money(int(decimal.Decimal(bytes(data).decode()) * 100))

conn.adapters.register_dumper(Money, MoneyDumper)
cur = conn.cursor()
cur.adapters.register_loader("numeric", MoneyLoader)
cur.execute("SELECT %s + 1", (Money(250),)).fetchone()        # (Money(350),)
```

Adapters registered on `psycopg.adapters` apply to every new connection, on a connection to its cursors, on a cursor
to that cursor alone. Keep global registration for types the whole program agrees on.

## Adaptation gotchas

These adaptation problems come up most often, each with its cause and fix.

1. **`cannot adapt type 'dict'`.** JSON needs a wrapper. Pass `Jsonb(obj)`.
2. **`function g(smallint) is not unique` (`AmbiguousFunction`).** A small Python `int` was dumped as `smallint`
   and the function has `bigint` and `numeric` overloads. Cast the parameter (`%s::bigint`).
3. **Money totals drift by a cent.** Values were sent as `float`. Use `Decimal` end to end.
4. **Enum values come back as strings.** The type was registered on another connection. Register in the pool's
   `configure`.

## Sources

- https://www.psycopg.org/psycopg3/docs/basic/adapt.html
- https://www.psycopg.org/psycopg3/docs/basic/pgtypes.html
- https://www.psycopg.org/psycopg3/docs/advanced/adapt.html
- https://github.com/pgvector/pgvector-python
- https://www.postgresql.org/docs/18/functions-uuid.html
