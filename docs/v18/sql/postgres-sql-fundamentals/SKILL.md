---
name: postgres-sql-fundamentals
description: 'Explains exactly how PostgreSQL evaluates SQL: the logical order of a SELECT (FROM, WHERE, GROUP BY, HAVING, window, SELECT, DISTINCT, ORDER BY, LIMIT), every join kind (inner, left, right, full, cross, LATERAL, semi and anti joins with EXISTS and NOT EXISTS), three-valued logic and NULL in aggregates, IN, NOT IN, DISTINCT and ORDER BY, set operations, scalar and correlated subqueries, casts and implicit coercion, operator precedence, identifiers and quoting, collations, GROUPING SETS, and INSERT ... SELECT, UPDATE ... FROM and DELETE ... USING. Use when a query returns the wrong rows, "column does not exist" on an alias, a LEFT JOIN behaves like an inner join, NOT IN returns nothing, "operator does not exist", text sorts strangely, or to learn SQL as Postgres runs it.'
metadata:
  tags:
  - postgres
  - sql
  - joins
  - null
  - three-valued-logic
  - subqueries
  - type-casts
  - collation
  - grouping-sets
---

# PostgreSQL SQL fundamentals: evaluation order, joins, NULL and types

Write SQL by its logical evaluation order, not its written order: `FROM` and joins build rows, `WHERE` filters them,
`GROUP BY` and `HAVING` fold them, window functions run, the `SELECT` list is computed, then `DISTINCT`, set
operations, `ORDER BY` and `LIMIT`. Most wrong results come from three places: a condition in `WHERE` that should be
in an outer join's `ON`, a `NULL` that turns a test into unknown, and an implicit cast or collation nobody chose.
Application patterns (upserts, pagination, reports) are in `postgres-sql-patterns`; this skill is the language
underneath.

## Step 0: read the server version, search_path and collation

The version decides which syntax parses, `search_path` decides which table a bare name means, and the collation
decides how text compares and sorts, so read all three before judging a result. `datlocale` needs 17; older servers
have `daticulocale`.

```sql
SELECT current_setting('server_version') AS version, current_setting('search_path') AS search_path;
SELECT datname, datlocprovider, datcollate, datctype, datlocale FROM pg_database
WHERE datname = current_database();
```

## Demo tables for the examples

The examples run in order on PostgreSQL 18.6 against these two tables; the `NULL` values are there on purpose.

```sql
CREATE SCHEMA sf;
CREATE TABLE sf.customers (id int PRIMARY KEY, name text NOT NULL, city text);
CREATE TABLE sf.orders (id int PRIMARY KEY, customer_id int REFERENCES sf.customers,
                        total numeric(10,2), status text NOT NULL);
INSERT INTO sf.customers VALUES (1,'Ana','Berlin'), (2,'Bo','Paris'), (3,'Cy',NULL), (4,'Di','Berlin');
INSERT INTO sf.orders VALUES (10,1,50,'paid'), (11,1,20,'open'), (12,2,NULL,'open'), (13,NULL,5,'paid');
```

## Logical order of SELECT evaluation

The logical order of a `SELECT` decides what each clause can see. PostgreSQL computes `WITH`, then `FROM` (joins),
`WHERE`, `GROUP BY` with aggregates, `HAVING`, window functions, the `SELECT` list, `DISTINCT`, `UNION`/`INTERSECT`/
`EXCEPT`, `ORDER BY`, `LIMIT`/`OFFSET`, and finally row locks (`FOR UPDATE`). The planner may execute in another
physical order, but the result must equal this one.

| Consequence | Why |
|---|---|
| `WHERE` cannot use a `SELECT` alias | the alias is computed later |
| `ORDER BY` can use an alias or a position | it runs after the `SELECT` list |
| Aggregates are not allowed in `WHERE`; filter them in `HAVING` | `WHERE` runs before grouping |
| Window functions see grouped rows, never `WHERE`-removed rows | they run after `HAVING` |
| A window result cannot be filtered in the same level | PostgreSQL has no `QUALIFY`; wrap it in a subquery |
| `LIMIT` without `ORDER BY` returns any rows | the order is whatever is fastest |

A column alias used in `WHERE` fails, because the alias does not exist yet.

```sql
-- error: column "gross" does not exist
SELECT id, total * 1.19 AS gross FROM sf.orders WHERE gross > 30;
```

Move the expression into a subquery (or repeat it); a window function over an aggregate works because windows run
after grouping, and filtering the rank needs an outer query.

```sql
SELECT * FROM (SELECT id, total * 1.19 AS gross FROM sf.orders) o WHERE gross > 30;

SELECT * FROM (
  SELECT customer_id, sum(total) AS spent,
         rank() OVER (ORDER BY sum(total) DESC NULLS LAST) AS spend_rank
  FROM sf.orders GROUP BY customer_id
) r WHERE spend_rank = 1;
```

Name resolution differs between clauses: in `ORDER BY` a bare name matches the output column first, in `GROUP BY` it
matches the input column first. This query sorts by the output `y` (which is input `x`), so it returns 1, 2.

```sql
SELECT x AS y FROM (VALUES (1, 9), (2, 8)) t(x, y) ORDER BY y;
```

`SELECT DISTINCT` runs before `ORDER BY`, so every `ORDER BY` expression must be in the select list.

```sql
-- error: for SELECT DISTINCT, ORDER BY expressions must appear in select list
SELECT DISTINCT city FROM sf.customers ORDER BY name;
```

## Join kinds and their exact semantics

A join builds rows from two inputs; the join kind decides what happens to rows without a partner.

| Join | Output | Rows without a match |
|---|---|---|
| `[INNER] JOIN ... ON` | pairs where the condition is true | dropped on both sides |
| `LEFT [OUTER] JOIN` | inner result plus unmatched left rows | right columns are `NULL` |
| `RIGHT [OUTER] JOIN` | inner result plus unmatched right rows | left columns are `NULL` |
| `FULL [OUTER] JOIN` | inner result plus unmatched rows of both | the missing side is `NULL`; condition must be hash- or merge-joinable |
| `CROSS JOIN` | every pair (Cartesian product) | none exist |
| `JOIN ... USING (col)` | one merged `col` column; `USING (col) AS j` names it (PG 14+) | per the join kind |
| `NATURAL JOIN` | `USING` on every same-named column | avoid: a new column silently changes the join |
| `JOIN LATERAL (subquery) ON true` | the subquery runs per left row and can read it | `LEFT JOIN LATERAL` keeps left rows with no result |
| semi join: `WHERE EXISTS (...)` / `IN (subquery)` | left rows that have at least one match, each once | dropped |
| anti join: `WHERE NOT EXISTS (...)` | left rows that have no match | kept, as the answer |

A condition on the right table of a `LEFT JOIN` belongs in `ON`. In `WHERE` it removes the `NULL`-extended rows and
turns the join into an inner join; the first query returns only Ana, the second keeps all four customers.

```sql
SELECT c.name, o.id FROM sf.customers c LEFT JOIN sf.orders o ON o.customer_id = c.id
WHERE o.status = 'paid';

SELECT c.name, o.id FROM sf.customers c LEFT JOIN sf.orders o
  ON o.customer_id = c.id AND o.status = 'paid'
ORDER BY c.id;
```

Semi and anti joins come from `EXISTS` and `NOT EXISTS`. With hash joins forced, 18.6 plans `NOT EXISTS` as
`Hash Right Anti Join` (the hash is built on the customers side) and `EXISTS` as a `Hash Join` over a
`HashAggregate` that first makes `customer_id` unique; a bigger table often gets a `Hash Semi Join` instead. Either
way each customer comes back once.

```sql
SET enable_nestloop = off; SET enable_mergejoin = off;
EXPLAIN (COSTS OFF) SELECT c.name FROM sf.customers c
WHERE EXISTS (SELECT 1 FROM sf.orders o WHERE o.customer_id = c.id);
EXPLAIN (COSTS OFF) SELECT c.name FROM sf.customers c
WHERE NOT EXISTS (SELECT 1 FROM sf.orders o WHERE o.customer_id = c.id);
```

A `JOIN` instead of `EXISTS` returns Ana twice (she has two orders); `SELECT DISTINCT` hides that and costs a sort.
A `FULL JOIN` needs an equality-style condition.

```sql
-- error: FULL JOIN is only supported with merge-joinable or hash-joinable join conditions
SELECT * FROM sf.customers c FULL JOIN sf.orders o ON o.customer_id < c.id;
```

## NULL and three-valued logic

SQL logic has three values: true, false and unknown (`NULL`). A comparison with `NULL` is unknown; `WHERE`, `ON`
and `HAVING` keep only true rows, while a `CHECK` constraint passes on unknown.

| `a` | `b` | `a AND b` | `a OR b` | `NOT a` |
|---|---|---|---|---|
| true | NULL | NULL | true | false |
| false | NULL | false | NULL | true |
| NULL | NULL | NULL | NULL | NULL |

Where `NULL` acts in each clause, all proved on 18.6:

| Place | Behaviour |
|---|---|
| `count(*)` / `count(col)` | counts rows / counts non-`NULL` values |
| `sum`, `avg`, `max` over no rows or only `NULL`s | `NULL`, not 0: wrap in `coalesce(sum(x), 0)` |
| `x IN (1, NULL)` | true if `x = 1`, otherwise `NULL` |
| `x NOT IN (1, NULL)` | never true: `NULL` or false |
| `x > ALL (empty set)` | true |
| `DISTINCT`, `GROUP BY`, `UNION`, `INTERSECT` | treat `NULL`s as equal: one group |
| `UNIQUE` constraint | allows many `NULL`s unless `UNIQUE NULLS NOT DISTINCT` (PG 15+) |
| `ORDER BY x` / `ORDER BY x DESC` | `NULL`s sort as larger than every value: last / first; override with `NULLS FIRST`/`NULLS LAST` |
| `'a' || NULL` / `concat('a', NULL)` | `NULL` / `'a'` |
| `ROW(1, NULL) IS NULL` / `IS NOT NULL` | both false: a row is `NULL` only when every field is |

The `NOT IN` trap: order 13 has no customer, so the subquery holds a `NULL` and `NOT IN` returns no rows, while
`NOT EXISTS` returns Cy and Di.

```sql
SELECT name FROM sf.customers WHERE id NOT IN (SELECT customer_id FROM sf.orders);
SELECT name FROM sf.customers c WHERE NOT EXISTS (SELECT 1 FROM sf.orders o WHERE o.customer_id = c.id);
```

`IS DISTINCT FROM` compares with `NULL` as a normal value, which is what change detection needs.

```sql
SELECT NULL = NULL AS eq, NULL IS NOT DISTINCT FROM NULL AS same,
       1 IS DISTINCT FROM NULL AS differs, num_nulls(1, NULL, NULL) AS nulls;
```

## Set operations and subqueries in brief

Set operations and subqueries follow a few exact rules, each proved in
[references/sets-and-subqueries.md](references/sets-and-subqueries.md):

- `UNION`, `INTERSECT` and `EXCEPT` remove duplicates unless `ALL` is written; with `ALL` a row kept m times on the
  left and n on the right appears m + n, min(m, n) and max(m - n, 0) times. `INTERSECT` binds tighter than `UNION`.
- `ORDER BY` and `LIMIT` after the last branch apply to the whole result; parenthesize a branch to limit it alone.
- A scalar subquery gives `NULL` for no row and an error for two rows; `x <> ALL (subquery)` has the `NOT IN` trap;
  `x > ALL (empty)` is true.

## Type casts and implicit coercion

PostgreSQL is strictly typed: an operator is chosen by its argument types, and a cast happens implicitly only if
`pg_cast` marks it implicit (`castcontext = 'i'`). A quoted literal has type `unknown` until context gives it one,
which is why `1 = '1'` works and `1 = '1'::text` does not.

```sql
SELECT 1 = '1' AS unknown_literal_ok, '1' + 1 AS two;
SELECT castcontext, count(*) FROM pg_cast GROUP BY 1 ORDER BY 1;   -- e explicit, a assignment, i implicit
```

```sql
-- error: operator does not exist: integer = text
SELECT 1 = '1'::text;
```

Arithmetic follows the operand types, not the column you store into: `7 / 2` is `3`, `7 / 2.0` is `3.5000000000000000`,
and assignment casts (`castcontext = 'a'`) round `2.7` to `3` when storing into an `int` column. The full table of
numeric traps is in [references/lexical-and-collation.md](references/lexical-and-collation.md).

## Operator precedence, identifiers and collations in brief

Operator precedence, identifier rules and collations cause errors that look unrelated to them. The short rules, each
proved in [references/lexical-and-collation.md](references/lexical-and-collation.md):

- `::` binds tighter than unary minus and every other operator: `doc->>'n'::int` casts `'n'`, so write
  `(doc->>'n')::int`. `-2 ^ 2` is 4 and `2 ^ 3 ^ 2` is 64.
- Unquoted names fold to lower case; `"Name"` keeps its case; names over 63 bytes are truncated with a `NOTICE`.
- Text order depends on the collation: `'a' < 'B'` is true in `en_US.UTF-8` and false in `"C"`. libc collations
  differ between macOS, Linux and Windows; ICU and the builtin provider do not.

## GROUPING SETS beyond ROLLUP

`GROUPING SETS` runs several `GROUP BY` lists in one pass; `ROLLUP` and `CUBE` are shorthands (basics in
`postgres-sql-patterns`, references/reporting.md). `grouping(a, b)` returns a bit mask with a 1 for each argument
not grouped in that row, which separates a subtotal row from a real `NULL` city: order 13 has no customer, so its
city is `NULL` in detail rows with `g = 0`, while subtotal rows have `g = 1` or `3`.

```sql
SELECT city, status, count(*), grouping(city, status) AS g
FROM sf.orders o LEFT JOIN sf.customers c ON c.id = o.customer_id
GROUP BY GROUPING SETS ((city, status), (city), ())
ORDER BY g, city, status;
```

Several grouping items multiply: `GROUP BY a, ROLLUP (b, c)` is the sets `(a,b,c)`, `(a,b)`, `(a)`. Duplicate sets
produce duplicate rows; `GROUP BY DISTINCT ROLLUP (a, b), ROLLUP (a, c)` (PG 14+) removes the duplicate sets.

## Data-changing statements: INSERT ... SELECT, UPDATE ... FROM and DELETE ... USING

`INSERT ... SELECT`, `UPDATE ... FROM` and `DELETE ... USING` join the target to other tables. `UPDATE ... FROM` has
one rule to respect: if a target row joins to several source rows, only one is used, and which one is not
predictable, so aggregate the source first.

```sql
CREATE TABLE sf.customer_totals (customer_id int PRIMARY KEY, spent numeric);
INSERT INTO sf.customer_totals (customer_id, spent)
SELECT id, 0 FROM sf.customers;

UPDATE sf.customer_totals t SET spent = s.spent
FROM (SELECT customer_id, sum(total) AS spent FROM sf.orders GROUP BY customer_id) s
WHERE s.customer_id = t.customer_id
RETURNING t.customer_id, old.spent AS before, new.spent AS after;

DELETE FROM sf.customer_totals t USING sf.customers c
WHERE c.id = t.customer_id AND c.city IS NULL
RETURNING t.customer_id;
```

Every part of a statement with data-changing `WITH` clauses sees the same snapshot: a `WITH ... UPDATE` cannot see a
row inserted by a sibling `WITH ... INSERT`; read the sibling's `RETURNING` instead.

## Common SQL mistakes reading list

These mistakes produce wrong results without an error; each row names the fix.

| Mistake | Fix |
|---|---|
| filter on the right table of a `LEFT JOIN` in `WHERE` | move it into `ON` |
| `NOT IN (subquery)` over a nullable column | `NOT EXISTS` |
| `JOIN` to test existence, then `DISTINCT` | `EXISTS` |
| `count(col)` meaning "rows" | `count(*)` |
| `sum(x)` shown as 0 | `coalesce(sum(x), 0)` |
| `a <> b` on nullable columns | `a IS DISTINCT FROM b` |
| `UPDATE ... FROM` with a one-to-many join | aggregate the source first |
| `LIMIT` without `ORDER BY`, or `ORDER BY` without a unique tiebreaker | order by a unique key last |
| `int / int` expecting a fraction | cast one side to `numeric` |
| comparing numbers stored as text | store numbers as numbers |
| `BETWEEN` on timestamps for a day | `>= day AND < next day` (`postgres-sql-dates-times`) |

## Gotchas

These are the errors and surprises seen most often in plain SQL, each with its cause and fix.

1. **`column "x" does not exist` for an alias.** The alias is used in `WHERE` or `HAVING`, which run before the
   `SELECT` list. Repeat the expression or wrap the query.
2. **A `LEFT JOIN` returns fewer rows than the left table.** A `WHERE` condition tests a right-side column and drops
   the `NULL`-extended rows. Move it into `ON`.
3. **`operator does not exist: integer = text`.** A typed value meets another type with no implicit cast. Cast one
   side explicitly, or fix the column type.
4. **`more than one row returned by a subquery used as an expression`.** A scalar subquery found two rows for some
   outer row. Aggregate it, add `LIMIT 1` with an `ORDER BY`, or use `LATERAL`.
5. **Text sorts differently on another server.** Different collation or a different libc. Use an ICU or builtin
   collation, and `COLLATE "C"` where byte order is wanted.

## Anti-patterns in everyday SQL

These run cleanly and go wrong later, when the data or the schema changes.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| `SELECT *` in application code | a new column changes the result, and wide values travel for nothing | name the columns |
| `DISTINCT` to clean up a join | it hides a missing join condition and adds a sort | fix the join, or use `EXISTS` |
| Comma joins: `FROM a, b WHERE ...` | a forgotten condition silently makes a Cartesian product | `JOIN ... ON` |
| `NATURAL JOIN` | a new column with the same name changes the join | `ON` or `USING` with named columns |
| `ORDER BY 1` in saved queries | reordering the select list changes the sort | order by name |
| Quoted mixed-case names | every later query must quote them exactly | lowercase `snake_case`, unquoted |

## Verify a result with row counts on the demo tables

Two counts catch most wrong joins, and one comparison catches the `NULL` trap. On the demo tables, on 18.6:

```sql
SELECT count(*) AS rows, count(DISTINCT c.id) AS customers              -- 5 and 4: Ana's two orders repeat her row
FROM sf.customers c LEFT JOIN sf.orders o ON o.customer_id = c.id;
SELECT (SELECT count(*) FROM sf.orders) AS orders, count(*) AS joined   -- 4 and 3: the inner join drops order 13
FROM sf.orders o JOIN sf.customers c ON c.id = o.customer_id;
SELECT count(*) FILTER (WHERE id NOT IN (SELECT customer_id FROM sf.orders)) AS not_in,   -- 0: wrong, a NULL hides all
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM sf.orders o
                                          WHERE o.customer_id = c.id)) AS not_exists      -- 2: Cy and Di
FROM sf.customers c;
```

Before you trust a query, compare its row count with the row count of the table whose grain you report. A difference
is either a fan-out to remove or a dropped row to explain.

## Checklist

Check these points before you trust a query's result.

- [ ] Conditions on an outer join's optional side are in `ON`.
- [ ] Existence tests use `EXISTS` / `NOT EXISTS`, never `NOT IN` over a nullable column.
- [ ] Every nullable column in a comparison, aggregate or `ORDER BY` has a decided `NULL` behaviour.
- [ ] Integer division, `numeric` versus `float8`, and text versus number comparisons are intended.
- [ ] `ORDER BY` ends with a unique key wherever order or `LIMIT` matters.
- [ ] `UPDATE ... FROM` and `DELETE ... USING` join at most one source row per target row.
- [ ] Text comparisons use a collation chosen on purpose.

## See also

Related skills in this library:

- `postgres-sql-patterns`: application patterns built on this
- `postgres-sql-dates-times`: date and time behaviour
- `postgres-sql-json`: JSON in SQL
- `postgres-query-performance`: making a correct query fast
- `postgres-internals-planner`: why the physical order differs

## Sources

- https://www.postgresql.org/docs/18/sql-select.html
- https://www.postgresql.org/docs/18/queries-table-expressions.html
- https://www.postgresql.org/docs/18/queries-order.html
- https://www.postgresql.org/docs/18/functions-comparison.html
- https://www.postgresql.org/docs/18/typeconv-overview.html
- https://www.postgresql.org/docs/18/collation.html
- https://www.postgresql.org/docs/18/sql-update.html
- https://www.postgresql.org/docs/18/tutorial-window.html
