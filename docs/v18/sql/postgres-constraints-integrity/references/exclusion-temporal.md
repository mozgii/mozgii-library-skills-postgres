---
title: PostgreSQL exclusion constraints, temporal keys and PERIOD foreign keys
author: MOZGII, Inc.
lang: en
---

# PostgreSQL exclusion constraints, temporal keys and PERIOD foreign keys

This reference shows exclusion constraints with btree_gist, then temporal primary keys with WITHOUT OVERLAPS and temporal foreign keys with PERIOD, new in PostgreSQL 18, with the rules and limits measured on 18.6.

## Exclusion constraints with btree_gist: no double booking

An exclusion constraint forbids two rows for which every listed operator returns true; with `=` on the room and
`&&` (overlaps) on a time range it forbids double bookings. The `=` on a `bigint` inside a GiST index needs the
`btree_gist` extension. This table allows back-to-back bookings and ignores cancelled ones:

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE app.bookings (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_id bigint NOT NULL,
  during  tstzrange NOT NULL,
  status  text NOT NULL DEFAULT 'confirmed',
  CONSTRAINT bookings_no_double_booking
    EXCLUDE USING gist (room_id WITH =, during WITH &&) WHERE (status <> 'cancelled')
);
-- overlapping confirmed booking: ERROR 23P01 conflicting key value violates exclusion constraint
```

- Ranges default to `[)`: `[09:00,10:00)` and `[10:00,11:00)` do not overlap. Keep that bound style everywhere.
- `ON CONFLICT ... DO NOTHING` works with an exclusion constraint; `DO UPDATE` does not (`ON CONFLICT DO UPDATE not
  supported with exclusion constraints`).
- The 18.6 release notes ask for a reindex of `btree_gist` indexes on `float4`/`float8` columns that may hold NaN
  and on `bit`/`varbit` columns, after the minor update.


## Temporal keys WITHOUT OVERLAPS and PERIOD foreign keys, worked example

PostgreSQL 18 adds temporal constraints. `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)` forbids overlapping periods
for the same id and is backed by a GiST index (so a scalar id needs `btree_gist`, or the error is `data type bigint
has no default operator class for access method "gist"`). A `PERIOD` foreign key requires the referenced rows,
taken together, to cover the referencing row's whole period. This pair keeps price history and order lines
consistent:

```sql
CREATE TABLE app.products (
  product_id  bigint NOT NULL,
  valid_at    daterange NOT NULL,
  price_cents bigint NOT NULL CHECK (price_cents >= 0),
  CONSTRAINT products_pk PRIMARY KEY (product_id, valid_at WITHOUT OVERLAPS)
);
CREATE TABLE app.order_lines (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id bigint NOT NULL,
  valid_at   daterange NOT NULL,
  qty        int NOT NULL CHECK (qty > 0),
  CONSTRAINT order_lines_product_fk
    FOREIGN KEY (product_id, PERIOD valid_at) REFERENCES app.products (product_id, PERIOD valid_at)
);
INSERT INTO app.products VALUES (7, '[2026-01-01,2026-07-01)', 1000), (7, '[2026-07-01,2027-01-01)', 1200);
INSERT INTO app.order_lines (product_id, valid_at, qty) VALUES (7, '[2026-05-01,2026-09-01)', 1);  -- covered by two rows: OK
```

- The `PERIOD` column must be a range or multirange; the referenced key must end in `WITHOUT OVERLAPS`.
- Temporal foreign keys support only `NO ACTION`: `CASCADE`, `SET NULL`, `SET DEFAULT` and `RESTRICT` fail with
  `unsupported ON DELETE action for foreign key constraint using PERIOD`.
- `pg_constraint.conperiod` is true for both constraints; a violation of the key raises `23P01`, of the foreign key
  `23503`.
- On PostgreSQL 13 to 17 write the key as `EXCLUDE USING gist (product_id WITH =, valid_at WITH &&)`; there is no
  declarative temporal foreign key before 18.

