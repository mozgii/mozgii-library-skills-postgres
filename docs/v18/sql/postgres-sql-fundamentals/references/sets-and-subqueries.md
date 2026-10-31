---
title: Set operations and subqueries in PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Set operations and subqueries in PostgreSQL

This reference gives the exact semantics of `UNION`, `INTERSECT` and `EXCEPT`, and of scalar, correlated and
quantified subqueries. Run the demo tables block of the `postgres-sql-fundamentals` skill first; the examples below
use its `sf` schema.

## Set operations: UNION, INTERSECT and EXCEPT

Set operations combine the results of two queries with the same number of columns; the column names come from the
first query and the types are resolved across both. Duplicates are removed unless `ALL` is written.

| Operator | Result with `ALL` (a row m times left, n times right) |
|---|---|
| `UNION` | m + n times |
| `INTERSECT` | min(m, n) times |
| `EXCEPT` | max(m - n, 0) times |

`INTERSECT` binds tighter than `UNION` and `EXCEPT`, so `A UNION B INTERSECT C` is `A UNION (B INTERSECT C)`.
`ORDER BY` and `LIMIT` after the last query apply to the whole result; to limit one branch, parenthesize it.

```sql
SELECT id FROM sf.customers UNION SELECT customer_id FROM sf.orders ORDER BY id NULLS FIRST;
(SELECT id FROM sf.orders ORDER BY total DESC NULLS LAST LIMIT 1)
UNION ALL
(SELECT id FROM sf.orders ORDER BY total ASC LIMIT 1);
```

`ALL` keeps duplicates by count, which the plain forms would remove.

```sql
SELECT x FROM (VALUES (1), (1), (1), (2)) a(x) INTERSECT ALL SELECT x FROM (VALUES (1), (1), (3)) b(x);   -- 1, 1
SELECT x FROM (VALUES (1), (1), (1), (2)) a(x) EXCEPT ALL SELECT x FROM (VALUES (1), (3)) b(x) ORDER BY 1; -- 1, 1, 2
```

## Column types in UNION: how the result type is chosen

The result type of each `UNION` column is resolved across all branches, the same way as `CASE` and `VALUES`:
`integer` and `numeric` give `numeric`, and an `unknown` literal takes the type of the other branches, so a text
literal against an integer column fails.

```sql
SELECT pg_typeof(n) AS result_type FROM (SELECT 1 AS n UNION SELECT 2.5) s LIMIT 1;    -- numeric
```

```sql
-- error: invalid input syntax for type integer: "a"
SELECT 1 AS n UNION SELECT 'a';
```

## Subqueries: scalar, correlated and quantified

A subquery is a query inside an expression. A scalar subquery must return at most one row and one column: no row
gives `NULL`, two rows raise an error. A correlated subquery reads the outer row and runs once per outer row unless
the planner turns it into a join.

```sql
SELECT c.name,
       (SELECT max(o.total) FROM sf.orders o WHERE o.customer_id = c.id) AS biggest
FROM sf.customers c ORDER BY c.id;
```

A scalar subquery that finds two rows fails at run time, only for the data that has two rows.

```sql
-- error: more than one row returned by a subquery used as an expression
SELECT c.name, (SELECT o.id FROM sf.orders o WHERE o.customer_id = c.id) FROM sf.customers c;
```

A quantified comparison over a column that holds a `NULL` can never be true for `ALL`: `60 > ALL` the order totals
is `NULL` because order 12 has no total, and true once the `NULL` is filtered out.

```sql
SELECT 60 > ALL (SELECT total FROM sf.orders)                         AS with_null,     -- NULL
       60 > ALL (SELECT total FROM sf.orders WHERE total IS NOT NULL) AS without_null,  -- t
       (1, 'Ana') IN (SELECT id, name FROM sf.customers)              AS row_in;        -- row comparison: t
```

A `LATERAL` subquery in `FROM` is the correlated subquery that may return several columns and rows; with
`ORDER BY ... LIMIT 1` it picks one row per outer row instead of failing like a scalar subquery.

```sql
SELECT c.name, o.id AS biggest_order
FROM sf.customers c, LATERAL (SELECT id FROM sf.orders WHERE customer_id = c.id
                              ORDER BY total DESC NULLS LAST LIMIT 1) o;
```

Quantified comparisons: `x = ANY (subquery)` equals `IN`; `x <> ALL (subquery)` equals `NOT IN`, with the same
`NULL` trap; `x > ALL (empty)` is true. Arrays work the same way: `x = ANY ('{1,2}'::int[])`.

## Sources

- https://www.postgresql.org/docs/18/queries-union.html
- https://www.postgresql.org/docs/18/sql-select.html
- https://www.postgresql.org/docs/18/functions-subquery.html
- https://www.postgresql.org/docs/18/typeconv-union-case.html
