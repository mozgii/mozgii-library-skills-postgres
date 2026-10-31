---
name: postgres-constraints-integrity
description: 'Enforces data integrity in PostgreSQL 18 with constraints instead of application code: named NOT NULL constraints and NOT NULL NOT VALID, CHECK, UNIQUE NULLS NOT DISTINCT, partial unique indexes, exclusion constraints with btree_gist, temporal keys WITHOUT OVERLAPS and PERIOD foreign keys, deferrable constraints, NOT VALID then VALIDATE on live tables, NOT ENFORCED, domains, the SQLSTATE each violation raises, and when an invariant needs SERIALIZABLE or a lock instead. Use when "no double booking", "only one active row per user", "prices must not overlap", "swap two positions", "add NOT NULL to a big table", or when deciding what the database should guarantee.'
metadata:
  tags:
  - postgres
  - constraints
  - integrity
  - exclusion-constraint
  - temporal
  - deferrable
  - domains
  - serializable
---

# PostgreSQL constraints and data integrity

A constraint is a rule the server checks on every write from every client, so it holds even when a script skips
the application. Put each invariant in the strongest place that can hold it:
a column type or domain, then `NOT NULL` and `CHECK` for one row, `UNIQUE` or an exclusion constraint for rows
against each other, a foreign key for rows in other tables, and only then a trigger, a lock or `SERIALIZABLE` for
rules no declarative constraint expresses. Basic table design is in `postgres-schema-design`; this skill goes
further. Every example was run on PostgreSQL 18.6. The read-only report is
[scripts/constraint-audit.sql](scripts/constraint-audit.sql); its two main queries stand alone under Verify.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: read the version and the constraints that exist

Named `NOT NULL`, `NOT ENFORCED` and temporal keys need PostgreSQL 18, so check the version before choosing, and read
what the table already guarantees.

```sql
SHOW server_version;
SELECT conname, contype, convalidated, conenforced, pg_get_constraintdef(oid) AS definition
FROM pg_constraint WHERE conrelid = 'app.orders'::regclass ORDER BY contype, conname;
SELECT indexrelid::regclass AS index, indisunique, indisvalid, pg_get_expr(indpred, indrelid) AS predicate
FROM pg_index WHERE indrelid = 'app.orders'::regclass;
```

## Which constraint holds which invariant

The choice of constraint follows from what the rule compares. Pick the first row of the table that fits.

| Invariant | Mechanism | Deferrable | `NOT VALID` | `NOT ENFORCED` |
|---|---|---|---|---|
| a value is present | `NOT NULL` (column, named in 18) | no | yes (18) | no |
| one row's values agree | `CHECK` | no | yes | yes (18) |
| no two rows equal | `UNIQUE`, `PRIMARY KEY`, unique index | yes | no | no |
| no two rows overlap or conflict | `EXCLUDE USING gist`, `WITHOUT OVERLAPS` (18) | yes | no | no |
| a row exists elsewhere | `FOREIGN KEY`, `PERIOD` foreign key (18) | yes | yes | yes (18) |
| an aggregate over rows ("at least one") | lock a parent row, `SERIALIZABLE`, constraint trigger | n/a | n/a | n/a |

Name every constraint (`CONSTRAINT orders_total_nonneg CHECK (...)`): the name appears in the error, in
`pg_constraint`, and in the migration that later drops it.

## Named NOT NULL constraints in PostgreSQL 18

PostgreSQL 18 stores each column `NOT NULL` as a row in `pg_constraint` with `contype = 'n'`, so it can be named,
added as `NOT VALID`, validated later, and marked `NO INHERIT`. Unnamed ones get `<table>_<column>_not_null`.
This query creates a table with one named and one unnamed `NOT NULL` and lists them:

```sql
CREATE TABLE app.customers (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email        text CONSTRAINT customers_email_nn NOT NULL,
  country      text NOT NULL,
  discount_pct numeric(5,2) NOT NULL DEFAULT 0
               CONSTRAINT customers_discount_range CHECK (discount_pct BETWEEN 0 AND 100)
);
SELECT conname, contype, convalidated, conenforced
FROM pg_constraint WHERE conrelid = 'app.customers'::regclass ORDER BY conname;
-- customers_country_not_null n | customers_email_nn n | customers_discount_range c | customers_pkey p ...
```

`psql`'s `\d+` lists them under "Not-null constraints". `pg_attribute.attnotnull` is also true for a `NOT VALID`
not-null constraint; check `pg_constraint.convalidated` to know whether old rows were proven.

## NOT VALID then VALIDATE on live tables: NOT NULL, CHECK, foreign keys

`ALTER TABLE ... ADD CONSTRAINT <name> NOT NULL <column> NOT VALID` (new in 18) enforces the rule for new writes at
once without scanning old rows; `VALIDATE CONSTRAINT` scans later. The `ADD` step still takes an
`ACCESS EXCLUSIVE` lock for a moment, so set `lock_timeout` first. This sequence adds and validates it:

```sql
SET lock_timeout = '3s';
ALTER TABLE app.orders ADD CONSTRAINT orders_customer_id_nn NOT NULL customer_id NOT VALID;
-- new rows with NULL now fail with 23502; fix the old ones in batches:
UPDATE app.orders SET customer_id = 0 WHERE customer_id IS NULL;
ALTER TABLE app.orders VALIDATE CONSTRAINT orders_customer_id_nn;   -- SHARE UPDATE EXCLUSIVE: reads and writes continue
```

The same two steps work for `CHECK` and foreign keys; PostgreSQL 18 also accepts a `NOT VALID` foreign key on a
partitioned table, and the parent's `VALIDATE` validates every partition. On PostgreSQL 12 to 17 use
`CHECK (customer_id IS NOT NULL) NOT VALID`, `VALIDATE`, then `SET NOT NULL`, which skips the scan because the valid
check proves no NULL exists; drop the check afterwards. Lock queues, timeouts and batching:
`postgres-schema-migrations`.

Lock levels measured on 18.6 in `pg_locks`:

| Statement | Lock on the table | Lock on the referenced table |
|---|---|---|
| `ADD CONSTRAINT ... NOT NULL ... NOT VALID` | `ACCESS EXCLUSIVE` (no scan) | none |
| `ADD CONSTRAINT ... FOREIGN KEY ... NOT VALID` | `SHARE ROW EXCLUSIVE` | `SHARE ROW EXCLUSIVE` |
| `VALIDATE CONSTRAINT` (check, not null, foreign key) | `SHARE UPDATE EXCLUSIVE` | `ROW SHARE` |
| `ALTER CONSTRAINT ... ENFORCED` (foreign key) | `ACCESS EXCLUSIVE`, scans while holding it | `SHARE ROW EXCLUSIVE` |

## CHECK constraints for rules within one row

A `CHECK` constraint tests an expression on the new row; it passes when the result is true or NULL. It may compare
columns of the same row but cannot run a subquery or read other rows. This check keeps an end date after the start:

```sql
CREATE TABLE app.subscriptions (
  id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  starts_on date NOT NULL,
  ends_on   date,
  CONSTRAINT subscriptions_dates_ordered CHECK (ends_on IS NULL OR ends_on > starts_on)
);
-- ERROR 23514: new row ... violates check constraint "subscriptions_dates_ordered"
```

- The server assumes the expression is immutable. A check that calls a function whose result later changes is not
  re-checked on old rows, and a dump then fails to restore. Drop the constraint, change the function, re-add it.
- A NULL passes a check: `CHECK (qty > 0)` allows NULL unless the column is also `NOT NULL`.

## UNIQUE NULLS NOT DISTINCT and partial unique indexes

A plain `UNIQUE` treats NULLs as distinct, so `(NULL, 'theme')` can repeat. `UNIQUE NULLS NOT DISTINCT` (PG 15+)
treats them as equal, which fits "one global default plus one per tenant". This table allows one global setting per
key and works as an `ON CONFLICT` target:

```sql
CREATE TABLE app.settings (
  tenant_id bigint,                    -- NULL = global default
  key       text NOT NULL,
  value     jsonb NOT NULL,
  CONSTRAINT settings_tenant_key_uq UNIQUE NULLS NOT DISTINCT (tenant_id, key)
);
INSERT INTO app.settings VALUES (NULL, 'theme', '"light"')
ON CONFLICT (tenant_id, key) DO UPDATE SET value = excluded.value;
```

A partial unique index enforces uniqueness on a subset of rows, such as one active membership per user. It is an
index, not a constraint: `ON CONFLICT` must repeat its predicate, and a foreign key cannot reference it. This index
and upsert keep one active row per user:

```sql
CREATE UNIQUE INDEX memberships_one_active_uq ON app.memberships (user_id) WHERE active;
INSERT INTO app.memberships (user_id, plan) VALUES (1, 'team')
ON CONFLICT (user_id) WHERE active DO NOTHING;   -- without "WHERE active": ERROR 42P10
```

## Exclusion constraints with btree_gist: no double booking

An exclusion constraint forbids two rows for which every listed operator returns true; with `=` on the room and
`&&` (overlaps) on a time range it forbids double bookings. The `=` on a scalar inside a GiST index needs
`btree_gist`. This constraint ignores cancelled bookings; a conflict raises `23P01`:

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;
ALTER TABLE app.bookings ADD CONSTRAINT bookings_no_double_booking
  EXCLUDE USING gist (room_id WITH =, during WITH &&) WHERE (status <> 'cancelled');
```

Ranges default to `[)`, so back-to-back slots do not overlap. `ON CONFLICT DO NOTHING` works with it, `DO UPDATE`
does not. Full example and the 18.6 reindex note:
[references/exclusion-temporal.md](references/exclusion-temporal.md).

## Temporal keys WITHOUT OVERLAPS and PERIOD foreign keys

PostgreSQL 18 adds temporal constraints. `PRIMARY KEY (product_id, valid_at WITHOUT OVERLAPS)` forbids overlapping
periods for the same id and is backed by a GiST index, so a scalar id needs `btree_gist`. A `PERIOD` foreign key
requires the referenced rows, taken together, to cover the referencing row's whole period:

```sql
CREATE TABLE app.products (
  product_id bigint NOT NULL, valid_at daterange NOT NULL, price_cents bigint NOT NULL,
  CONSTRAINT products_pk PRIMARY KEY (product_id, valid_at WITHOUT OVERLAPS));
CREATE TABLE app.order_lines (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, product_id bigint NOT NULL, valid_at daterange NOT NULL,
  CONSTRAINT order_lines_product_fk
    FOREIGN KEY (product_id, PERIOD valid_at) REFERENCES app.products (product_id, PERIOD valid_at));
```

Temporal foreign keys allow only `NO ACTION` (no `CASCADE`, `SET NULL`, `SET DEFAULT`, `RESTRICT`). Before 18 use
`EXCLUDE USING gist (product_id WITH =, valid_at WITH &&)`; there is no temporal foreign key. Worked example and
limits: [references/exclusion-temporal.md](references/exclusion-temporal.md).

## Deferrable constraints and SET CONSTRAINTS

A deferrable constraint can be checked at commit instead of after each statement, which allows swaps and circular
references. Only `UNIQUE`, `PRIMARY KEY`, `EXCLUDE` and foreign keys can be deferrable. A non-deferrable unique
constraint is checked row by row, so `SET position = 3 - position` fails halfway; declared
`DEFERRABLE INITIALLY IMMEDIATE` it is checked at the end of the statement and the swap succeeds:

```sql
ALTER TABLE app.playlist_items ADD CONSTRAINT playlist_items_position_uq
  UNIQUE (playlist_id, position) DEFERRABLE INITIALLY IMMEDIATE;
UPDATE app.playlist_items SET position = 3 - position WHERE playlist_id = 1;   -- swaps 1 and 2
BEGIN;
SET CONSTRAINTS app.playlist_items_position_uq DEFERRED;     -- checked at COMMIT from here on
-- several updates that pass through duplicates
COMMIT;
```

A deferrable unique constraint is slower, cannot be an `ON CONFLICT` arbiter (`55000`), and a deferred violation
fails the `COMMIT`. Circular foreign keys and the details: [references/deferrable-constraints.md](references/deferrable-constraints.md).

## NOT ENFORCED constraints in PostgreSQL 18

`NOT ENFORCED` (18) records a `CHECK` or foreign key in the catalog without checking it, as documentation for tools
and readers. `UNIQUE` and `PRIMARY KEY` cannot be `NOT ENFORCED`. A foreign key can switch both ways with
`ALTER CONSTRAINT`; a check cannot (`cannot alter enforceability`), so drop and re-add it. This table records an
unchecked foreign key:

```sql
CREATE TABLE app.events (
  id          bigint PRIMARY KEY,
  customer_id bigint,
  CONSTRAINT events_customer_fk FOREIGN KEY (customer_id) REFERENCES app.customers (id) NOT ENFORCED
);
SELECT conname, conenforced, convalidated FROM pg_constraint WHERE conname = 'events_customer_fk';  -- f | f
```

Do not turn a large table's foreign key on with `ALTER CONSTRAINT ... ENFORCED`: it scans the table under an
`ACCESS EXCLUSIVE` lock. Drop the `NOT ENFORCED` constraint and add it again as `NOT VALID`, then `VALIDATE`.
`VALIDATE` on a `NOT ENFORCED` constraint fails with `cannot validate NOT ENFORCED constraint`.

## Domains: one rule for every column of a kind

A domain is a type with constraints (`CREATE DOMAIN app.cents AS bigint CONSTRAINT cents_nonneg CHECK (VALUE >= 0)`),
so a rule lives in one place; `ALTER DOMAIN ... ADD CONSTRAINT ... NOT VALID` then `VALIDATE CONSTRAINT` changes it
on existing data. Put `NOT NULL` on the column, never on the domain: a domain's `NOT NULL` is checked only when a
value is converted, so a scalar subquery that returns no row stores a NULL (reproduced on 18.6). Examples:
[references/domains.md](references/domains.md).

## SQLSTATE codes for constraint violations

Each violation has its own SQLSTATE, and the error's `constraint_name` field names the constraint, so an
application maps it to a message without parsing text.

| SQLSTATE | Name | Raised by |
|---|---|---|
| `23001` | `restrict_violation` | parent `DELETE` or `UPDATE` blocked by a `RESTRICT` foreign key (PG 18+; `NO ACTION` raises `23503`) |
| `23502` | `not_null_violation` | column or domain `NOT NULL` |
| `23503` | `foreign_key_violation` | foreign key, including `PERIOD` |
| `23505` | `unique_violation` | `UNIQUE`, `PRIMARY KEY`, unique index (also partial) |
| `23514` | `check_violation` | table or domain `CHECK` |
| `23P01` | `exclusion_violation` | `EXCLUDE`, `WITHOUT OVERLAPS` key |

## Invariants across rows: SERIALIZABLE or a parent-row lock

Some rules compare an aggregate ("at least one doctor stays on call for each shift") and no constraint expresses
them. Under `READ COMMITTED` two transactions each see two doctors on call, each takes one off, both commit, and zero
remain: write skew, reproduced on 18.6. Two fixes, both proven:

- Run the transaction `SERIALIZABLE`: the second `COMMIT` fails with `40001` and the client retries
  (`postgres-transactions-locking`).
- Lock one parent row that stands for the rule (`SELECT ... FROM app.shifts WHERE id = $1 FOR UPDATE`) before the
  count, so writers to the same shift queue and the second sees the first one's change.

A deferred constraint trigger (`postgres-functions-triggers`) alone is not race-free under `READ COMMITTED`. The
reproduction script and the locking function: [references/cross-row-invariants.md](references/cross-row-invariants.md).

## Worked example: "two people booked the same room at the same time"

A `UNIQUE` constraint cannot see that two ranges overlap, so the fix is an exclusion constraint, and the existing
conflicts must go first. This ran on 18.6.

```sql
SELECT a.id, b.id FROM app.bookings a                    -- the existing conflicts: resolve each with the business
JOIN app.bookings b ON a.room_id = b.room_id AND a.id < b.id AND a.during && b.during;
CREATE EXTENSION IF NOT EXISTS btree_gist;               -- lets GiST compare room_id with =
SET lock_timeout = '3s';
ALTER TABLE app.bookings ADD CONSTRAINT bookings_no_overlap
  EXCLUDE USING gist (room_id WITH =, during WITH &&);
```

The next overlapping insert fails with `23P01`, `conflicting key value violates exclusion constraint
"bookings_no_overlap"`. A booking from 10:00 to 11:00 right after one from 9:00 to 10:00 is accepted, because `[)` ranges
do not touch, and the same hours in another room pass too. Exclusion constraints have no `NOT VALID` form and scan the
table under a strong lock, so on a large table plan this for a quiet window. The application maps `23P01` to "that
slot was just taken".

## Verify constraints: the audit queries

Prove each new constraint with a write that must fail, and then check that nothing was left half done. This query
lists constraints that are not validated or not enforced:

```sql
SELECT c.conrelid::regclass AS table_name, c.conname, c.contype,
       c.convalidated AS validated, c.conenforced AS enforced
FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
WHERE c.conrelid <> 0 AND (NOT c.convalidated OR NOT c.conenforced)
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2;
```

This one lists enforced foreign keys with no usable index on their referencing columns. A partial or invalid index
does not count, because it cannot serve every parent delete:

```sql
SELECT c.conrelid::regclass AS table_name, c.conname,
       array_agg(a.attname ORDER BY k.ord) AS fk_columns
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
WHERE c.contype = 'f' AND c.conenforced
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid AND i.indisvalid AND i.indpred IS NULL
      AND cardinality(c.conkey) <= i.indnkeyatts
      AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey)
GROUP BY c.conrelid, c.conname
ORDER BY 1, 2;
```

## Gotchas

These are the integrity failures seen most often, each with its cause and fix.

1. **`there is no unique or exclusion constraint matching the ON CONFLICT specification` (42P10).** The target is a
   partial unique index; add its `WHERE` predicate to `ON CONFLICT (...) WHERE ...`.
2. **`ON CONFLICT does not support deferrable unique constraints` (55000).** A deferrable constraint cannot arbitrate;
   make it `NOT DEFERRABLE`, or insert without `ON CONFLICT` and handle `23505`.
3. **A NULL slipped into a `NOT NULL` domain.** Domain `NOT NULL` is bypassed by scalar subqueries and outer joins;
   declare `NOT NULL` on the column.
4. **Adding a constraint froze the application.** `ADD ... NOT NULL ... NOT VALID` and `ALTER CONSTRAINT ...
   ENFORCED` take `ACCESS EXCLUSIVE` (the second also scans); set `lock_timeout`, prefer `NOT VALID` plus `VALIDATE`.
5. **`data type bigint has no default operator class for access method "gist"`.** An exclusion or `WITHOUT OVERLAPS`
   constraint uses `=` on a scalar; `CREATE EXTENSION btree_gist`.
6. **An introspection tool says a column is NOT NULL but NULLs exist.** It read `attnotnull`, which is also true for
   a `NOT VALID` not-null constraint; join `pg_constraint` and check `convalidated`.

## Checklist

Check these points before you call a data model's integrity done.

- [ ] Every rule that can be a constraint is one, with a name.
- [ ] `NOT NULL` is on columns, not on domains.
- [ ] Overlap rules use `EXCLUDE` or `WITHOUT OVERLAPS`, with `btree_gist` installed.
- [ ] Constraints on live tables are added `NOT VALID` with `lock_timeout`, then validated separately.
- [ ] No `NOT ENFORCED` or unvalidated constraint is left by accident (run the audit script).
- [ ] Every enforced foreign key's columns lead an index.
- [ ] The application maps `23001`, `23502`, `23503`, `23505`, `23514` and `23P01` to messages by constraint name.
- [ ] Aggregate rules run under `SERIALIZABLE` with retries, or lock a parent row.

## Anti-patterns in data integrity

| Do not | Do this instead |
|---|---|
| keep a rule only in application code | a constraint, which holds for every writer |
| check for a conflict with `SELECT`, then `INSERT` | a unique or exclusion constraint, and handle the error |
| leave constraints unnamed | name them; the name reaches the error and the migration |
| add a constraint to a live table in one step | `NOT VALID` with `lock_timeout`, then `VALIDATE` |
| declare `NOT NULL` on a domain | declare it on the column |
| leave `NOT ENFORCED` constraints as if they protected data | enforce them, or say in the name that they are documentation |

## See also

- `postgres-schema-design`: tables, types and keys.
- `postgres-schema-migrations`: lock queues, timeouts and batching.
- `postgres-transactions-locking`: `SERIALIZABLE` and row locks.
- `postgres-functions-triggers`: constraint triggers.
- `postgres-indexing`: the indexes behind unique rules and foreign keys.

## Sources

- https://www.postgresql.org/docs/18/ddl-constraints.html
- https://www.postgresql.org/docs/18/sql-createtable.html
- https://www.postgresql.org/docs/18/sql-altertable.html
- https://www.postgresql.org/docs/18/sql-createdomain.html
- https://www.postgresql.org/docs/18/sql-set-constraints.html
- https://www.postgresql.org/docs/18/catalog-pg-constraint.html
- https://www.postgresql.org/docs/18/catalog-pg-attribute.html
- https://www.postgresql.org/docs/18/errcodes-appendix.html
- https://www.postgresql.org/docs/18/release-18.html
- https://www.postgresql.org/docs/18/release-18-6.html
