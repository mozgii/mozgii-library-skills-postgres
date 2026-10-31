---
title: PostgreSQL domains for shared column rules
author: MOZGII, Inc.
lang: en
---

# PostgreSQL domains for shared column rules

This reference shows domains (types with constraints), adding a domain constraint to existing data, and the NOT NULL loophole, as run on PostgreSQL 18.6.

## Domains: one rule for every column of a kind

A domain is a type with constraints, so a rule such as "an amount in cents is never negative" lives in one place.
This defines two domains and a domain constraint added to existing data without a long lock:

```sql
CREATE DOMAIN app.email AS text CONSTRAINT email_shape CHECK (VALUE ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');
CREATE DOMAIN app.cents AS bigint CONSTRAINT cents_nonneg CHECK (VALUE >= 0);
CREATE TABLE app.invoices (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  billing_email app.email NOT NULL,
  amount        app.cents NOT NULL
);
ALTER DOMAIN app.cents ADD CONSTRAINT cents_below_1e9 CHECK (VALUE < 1000000000) NOT VALID;
ALTER DOMAIN app.cents VALIDATE CONSTRAINT cents_below_1e9;
```

Put `NOT NULL` on the column, never on the domain. A domain's `NOT NULL` is checked only when a value is converted
to the domain, so `INSERT INTO t (a) SELECT (SELECT a FROM t WHERE false)` stores a NULL in a `NOT NULL` domain
column (reproduced on 18.6), as can the nullable side of an outer join.


## Finding columns that use a domain

Before changing a domain constraint, list the columns that use it, because `ALTER DOMAIN ... VALIDATE` scans each
of their tables. This query lists them:

```sql
SELECT a.attrelid::regclass AS table_name, a.attname
FROM pg_attribute a
WHERE a.atttypid = 'app.cents'::regtype AND a.attnum > 0 AND NOT a.attisdropped;
```
