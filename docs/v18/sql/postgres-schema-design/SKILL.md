---
name: postgres-schema-design
description: 'Designs PostgreSQL tables that stay correct under load: primary keys (identity or uuidv7), column types (timestamptz, text, numeric or integer cents for money), NOT NULL, CHECK, UNIQUE and foreign keys with their indexes, enums versus check constraints, JSONB versus columns, generated columns, temporal keys, multi-tenant layouts and partitioning. Use when creating or reviewing tables or a data model, or when asking "serial or uuid?", "timestamp or timestamptz?" or "how do I model tenants?".'
metadata:
  tags:
  - postgres
  - schema
  - data-types
  - constraints
  - primary-keys
  - uuidv7
  - jsonb
  - partitioning
---

# PostgreSQL schema design

A schema is the cheapest place to enforce correctness: a constraint the database checks never drifts from the code
that forgot to check it. This skill covers tables, types, keys, constraints and naming for PostgreSQL 18 (most of it
holds from 13 on; version notes say where).

Detail lives in references: [data types](references/data-types.md), [JSONB](references/jsonb.md),
[partitioning](references/partitioning.md).

## Step 0: read the server version and the current schema

The server version decides which features exist (`uuidv7()` and virtual generated columns need 18), so read it first.

```sql
SELECT current_setting('server_version_num')::int AS version_num;   -- 180006 = 18.6
\d+ app.orders                                                       -- psql: one table with its indexes
SELECT table_schema, table_name FROM information_schema.tables
WHERE table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY 1, 2;
```

## Primary keys: identity or uuidv7

A primary key should be small, immutable and increasing, so new rows land at the right edge of the B-tree.

| Need | Use | Why |
|---|---|---|
| Internal key, one database | `bigint GENERATED ALWAYS AS IDENTITY` | 8 bytes, ordered, standard SQL; `ALWAYS` stops callers writing it |
| Key made by clients, shown in URLs, merged across databases | `uuid DEFAULT uuidv7()` (PG 18) | time-ordered, so inserts stay local in the index |
| Before PG 18 | UUIDv7 made in the application, or `gen_random_uuid()` if order does not matter | v4 is random: every insert touches a random leaf page |

```sql
CREATE TABLE app.customers (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  public_id   uuid NOT NULL DEFAULT uuidv7() UNIQUE,
  email       text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
```

- Never `serial` for new tables: it is a sequence bolted on by a default, with ownership quirks and no protection
  against manual ids. Identity columns replace it.
- Use `bigint`, not `integer`: an `integer` key runs out at 2,147,483,647 and the fix is a full table rewrite.
- `uuidv7()` leaks the creation time in the id. Use `uuidv4()` (or `gen_random_uuid()`) for ids that must not reveal it.
- A natural key (email, SKU) is a `UNIQUE` constraint, not the primary key: natural keys change.

## Column types that avoid common bugs

Column type choices decide what bad data the database refuses. The short list (full table in
[data-types.md](references/data-types.md)):

- **Time**: `timestamptz` always. It stores an absolute instant; `timestamp` without time zone stores a wall-clock
  reading with no zone and breaks the day a second region or a DST change appears. `date` for calendar days.
- **Text**: `text`, with a `CHECK (length(col) <= n)` when a limit is a business rule. `varchar(n)` has no speed
  advantage and changing `n` later takes a lock.
- **Money**: `numeric(12,2)` or integer minor units (`bigint` cents). Never `real`, `double precision` or `money`.
- **Booleans**: `boolean NOT NULL DEFAULT false`, not a nullable flag with three states.
- **Case-insensitive text**: a unique index on `lower(email)`, or a nondeterministic ICU collation; `citext` works but
  is an extension.
- **Ranges**: `tstzrange`, `daterange` with exclusion constraints for bookings and validity periods.

## Constraints: NOT NULL, CHECK, UNIQUE, FOREIGN KEY

Constraints are the schema's rules, checked on every write by every client. Declare them all.

```sql
CREATE TABLE app.orders (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id  bigint NOT NULL REFERENCES app.customers (id) ON DELETE RESTRICT,
  status       text NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'paid', 'shipped', 'cancelled')),
  total_cents  bigint NOT NULL CHECK (total_cents >= 0),
  placed_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_id_idx ON app.orders (customer_id);   -- Postgres never indexes a foreign key for you
```

- Pick `ON DELETE` on purpose: `RESTRICT` (default-like, safe; a blocked delete raises `23001` on PG 18, where
  `NO ACTION` raises `23503`), `CASCADE` (owned children), `SET NULL` (optional link). Cascades on large tables delete
  in one transaction.
- `NULLS NOT DISTINCT` (PG 15+) makes a unique constraint treat NULLs as equal: `UNIQUE NULLS NOT DISTINCT (a, b)`.
- PG 18 adds `NOT ENFORCED` for `CHECK` and foreign keys (documented intent, no check) and `NOT VALID` foreign keys on
  partitioned tables.

## Slow DELETE of a parent row: index every foreign key column

Deleting a customer is slow when its orders point to it and `orders.customer_id` has no index. **Index every foreign
key column.** Postgres indexes the referenced side (it is a primary key or unique) but not the referencing side.
Without it, a `DELETE` on the parent scans the whole child table to check for referencing rows, once per deleted
row, and joins crawl.

```sql
CREATE INDEX CONCURRENTLY orders_customer_id_idx ON app.orders (customer_id);
```

## Enums versus a CHECK constraint or a lookup table

A status column needs a closed set of values; three ways to get it differ in how they change.

| Option | Adding a value | Removing a value | Use for |
|---|---|---|---|
| `CHECK (status IN (...))` | drop and re-add the check (`NOT VALID` then `VALIDATE`) | same | most status columns |
| Lookup table + foreign key | `INSERT` a row | `DELETE` after moving rows | values with labels, order or metadata |
| `CREATE TYPE ... AS ENUM` | `ALTER TYPE ... ADD VALUE` (cannot be used in the same transaction) | not supported | values that never change |

## Generated columns: virtual by default in PostgreSQL 18

A generated column computes its value from other columns of the row. From PG 18 `GENERATED ALWAYS AS (expr)` is
`VIRTUAL` (computed on read, no storage) unless you write `STORED`.

```sql
ALTER TABLE app.customers
  ADD COLUMN email_domain text GENERATED ALWAYS AS (split_part(email, '@', 2)) VIRTUAL;
ALTER TABLE app.documents
  ADD COLUMN tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', body)) STORED;   -- indexable
```

- Index a `STORED` column, or build an expression index on the same expression; a virtual column cannot be indexed.
- Adding a `STORED` column rewrites the table; adding a `VIRTUAL` one does not.

## Temporal keys: WITHOUT OVERLAPS in PostgreSQL 18

A temporal primary key forbids two rows for the same entity whose periods overlap, which used to need an exclusion
constraint written by hand.

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE app.prices (
  product_id  bigint NOT NULL,
  valid       tstzrange NOT NULL,
  price_cents bigint NOT NULL,
  PRIMARY KEY (product_id, valid WITHOUT OVERLAPS)
);
```

On PG 13-17 use `EXCLUDE USING gist (product_id WITH =, valid WITH &&)`.

## Naming and schemas

Names are part of the interface every query uses, so pick a rule and keep it.

- Lowercase `snake_case`, unquoted. A quoted mixed-case name (`"UserId"`) must be quoted forever.
- Tables plural or singular, one style; columns name the thing (`customer_id`, `created_at`).
- Name constraints and indexes yourself (`orders_customer_id_idx`) so migrations can refer to them.
- Put the application in its own schema (`app`), not `public`; grant on that schema (`postgres-security-roles`).

## Multi-tenant schemas: a tenant_id column, a schema or a database per tenant

A multi-tenant (SaaS) database keeps many customers' data apart. Default to shared tables with a `tenant_id` column;
move to schemas or databases per tenant only for the reasons in the table.

| Layout | Fits | Costs |
|---|---|---|
| Shared tables + `tenant_id` (default) | thousands to millions of tenants | every query and index must carry `tenant_id`; isolation needs RLS as a safety net |
| Schema per tenant | tens to a few hundred tenants needing per-tenant restore or extensions | migrations run once per schema; the catalog grows with every tenant |
| Database per tenant | contractual isolation, per-tenant region or encryption keys | one pool per database; cross-tenant reports need another system |

Rules for shared tables, so one tenant's row can never point at another's:

```sql
CREATE TABLE app.projects (
  tenant_id bigint NOT NULL REFERENCES app.tenants (id),
  id        bigint GENERATED ALWAYS AS IDENTITY,
  name      text NOT NULL,
  PRIMARY KEY (tenant_id, id),                       -- tenant_id leads: every lookup is per tenant
  UNIQUE (tenant_id, name)                           -- uniqueness is per tenant, not global
);
CREATE TABLE app.tasks (
  tenant_id  bigint NOT NULL,
  id         bigint GENERATED ALWAYS AS IDENTITY,
  project_id bigint NOT NULL,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, project_id) REFERENCES app.projects (tenant_id, id)   -- same tenant enforced
);
```

Add row-level security on top so a missing `WHERE tenant_id = ...` returns nothing instead of another tenant's
rows: `ENABLE` and `FORCE ROW LEVEL SECURITY` with a policy on `current_setting('app.tenant_id')`, set per transaction
with `set_config('app.tenant_id', $1, true)`. If one tenant grows far beyond the rest, partition by `tenant_id` hash
or move it to its own database.

## JSONB columns: when they fit

JSONB is right for data whose shape the application does not query by field, or that varies per row: provider
payloads, settings, audit snapshots. Fields that are filtered, joined, sorted or constrained belong in columns.
Patterns and indexes: [jsonb.md](references/jsonb.md).

## Partitioning: when a table needs it

Partitioning splits one table into many by a key, usually time. Use it when you must drop old data cheaply
(`DETACH`/`DROP` a month instead of `DELETE`) or a table passes roughly 100 GB with queries that filter on the key.
It does not make small tables faster. Setup and maintenance: [partitioning.md](references/partitioning.md).

## Worked example: "design a table for subscription invoices"

A request to add invoices to an app becomes a table where the database refuses bad data. The steps: read the version
(18, so `uuidv7()` is available), list what the invoice must never be (negative, without a customer, in two states at
once), and turn each rule into a type or a constraint.

```sql
CREATE TABLE app.invoices (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  public_id     uuid NOT NULL DEFAULT uuidv7() UNIQUE,              -- shown in URLs and emails
  customer_id   bigint NOT NULL REFERENCES app.customers (id) ON DELETE RESTRICT,
  status        text NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft', 'open', 'paid', 'void')),
  currency      text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  amount_cents  bigint NOT NULL CHECK (amount_cents >= 0),
  period        daterange NOT NULL,
  issued_at     timestamptz,
  paid_at       timestamptz,
  CHECK (status <> 'paid' OR paid_at IS NOT NULL),                  -- a paid invoice has a payment time
  EXCLUDE USING gist (customer_id WITH =, period WITH &&) WHERE (status <> 'void')   -- needs btree_gist
);
CREATE INDEX invoices_customer_id_idx ON app.invoices (customer_id);
```

The answer names what each constraint prevents, and ships as a migration that is safe on a live table.

## Verify a table design with catalog queries and rows that must fail

A design is proved by what the database refuses. These ran on 18.6 on the invoices example. The two catalog queries
return no rows on a good schema.

```sql
-- foreign keys with no index that starts with their columns
SELECT c.conrelid::regclass AS table_name, c.conname
FROM pg_constraint c
WHERE c.contype = 'f' AND c.connamespace = 'app'::regnamespace
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid
                  AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey);
-- types this skill avoids, and serial columns
SELECT table_name, column_name, data_type FROM information_schema.columns
WHERE table_schema = 'app'
  AND (data_type IN ('timestamp without time zone', 'character', 'money', 'json')
       OR column_default LIKE 'nextval(%');
-- each of these must fail, and each names the rule it broke
INSERT INTO app.invoices (customer_id, currency, amount_cents, period)
VALUES (1, 'eur', 100, '[2026-01-01,2026-02-01)');    -- invoices_currency_check
INSERT INTO app.invoices (customer_id, currency, amount_cents, period)
VALUES (999, 'EUR', 100, '[2026-01-01,2026-02-01)');  -- invoices_customer_id_fkey
INSERT INTO app.invoices (customer_id, currency, amount_cents, period)
VALUES (1, 'EUR', -1, '[2026-01-01,2026-02-01)');     -- invoices_amount_cents_check
```

## Checklist

Check these points before you call a schema change done.

- [ ] Every table has a `bigint` identity or `uuidv7()` primary key; no `serial`, no `integer` keys.
- [ ] Every time column is `timestamptz`; money is `numeric` or integer minor units.
- [ ] Every required column is `NOT NULL`; business rules are `CHECK` constraints.
- [ ] Every foreign key column has an index; `ON DELETE` chosen on purpose.
- [ ] Names are lowercase `snake_case`; constraints and indexes are named.
- [ ] Fields that are filtered or joined are columns, not JSONB keys.
- [ ] Changes ship as migrations that are safe on a live table (`postgres-schema-migrations`).

## Gotchas

These are the failures seen most often with a schema change, each with its cause and fix.

1. **`DELETE` on a parent table is slow.** Cause: the child's foreign key column has no index. Fix: index it.
2. **Times shift by hours.** Cause: `timestamp` without time zone and a client in another zone. Fix: `timestamptz`.
3. **`ALTER TYPE ... ADD VALUE` then using the value fails.** Cause: the new enum value is not usable in the same
   transaction. Fix: commit between them, or use `CHECK`.
4. **A unique index on `email` lets `Bob@x.example` and `bob@x.example` in.** Fix: `CREATE UNIQUE INDEX ON t (lower(email))`.
5. **Upgrading to 18, a new generated column is not indexable.** Cause: generated columns are virtual by default.
   Fix: write `STORED`.
6. **The `integer` key overflows.** Symptom: `nextval: reached maximum value of sequence`. Fix: `bigint` from day one;
   converting later rewrites the table.

## Anti-patterns in table design

These save a minute at creation and cost a migration later.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| `serial` or `integer` primary keys | manual ids slip past, and `integer` runs out at 2,147,483,647 | `bigint GENERATED ALWAYS AS IDENTITY` |
| `timestamp` for instants | times shift the day a second zone appears | `timestamptz` |
| `real`, `double precision` or `money` for amounts | rounding errors, or a type tied to `lc_monetary` | `numeric(12,2)` or `bigint` cents |
| Rules kept only in application code | scripts, other services and old versions skip them | `NOT NULL`, `CHECK`, `UNIQUE` and foreign keys |
| A key-value table of attributes, or JSONB for filtered fields | no types, no constraints, poor statistics | real columns; JSONB for what no query filters on |
| Comma-separated ids in a text column | no foreign key, no index, no join | a child table |
| Foreign keys without indexes | parent deletes scan the child table | an index on every foreign key column |
| An enum for values that will change | a value cannot be removed | `CHECK` or a lookup table |

## See also

Related skills in this library:

- `postgres-schema-migrations`: shipping these tables to a live database
- `postgres-constraints-integrity`: constraints in depth
- `postgres-indexing`: indexes for the queries the schema serves
- `postgres-multitenancy`: tenant isolation in depth
- `postgres-partitioning`: partitioned tables in depth
- `postgres-security-roles`: roles, grants and row-level security
