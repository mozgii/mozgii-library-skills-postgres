---
name: postgres-sql-patterns
description: 'Writes correct, fast PostgreSQL queries: upserts with ON CONFLICT and MERGE, RETURNING old and new values, keyset pagination, bulk inserts with unnest and COPY, N+1 fixes with LATERAL and JSON aggregation, window functions, DISTINCT ON, recursive CTEs, NULL traps, materialized views and reporting queries (FILTER, ROLLUP, time buckets, percentiles). Use when writing or reviewing SQL, replacing an ORM loop with one query, or for "insert or update", "deep pages are slow", "latest row per group" or "NOT IN returns nothing".'
metadata:
  tags:
  - postgres
  - sql
  - upsert
  - merge
  - pagination
  - cte
  - window-functions
  - copy
  - bulk-insert
---

# PostgreSQL SQL patterns

Most slow or wrong application SQL comes from a short list of mistakes: loops instead of sets, offset paging,
NULL comparisons, and read-then-write races. This skill gives the Postgres-native pattern for each. Examples use
parameter placeholders `$1, $2` as drivers send them.

## Step 0: read the server version before picking a pattern

Several patterns here depend on the version: `MERGE` needs 15, its `RETURNING` and `merge_action()` need 17,
`COPY ... ON_ERROR` needs 17, and `RETURNING old` and `new` need 18. Read it, then check the unique indexes an upsert
will target.

```sql
SELECT current_setting('server_version_num')::int AS version_num;       -- 180006 = 18.6
SELECT indexname, indexdef FROM pg_indexes
WHERE schemaname = 'app' AND tablename = 'customers' AND indexdef LIKE 'CREATE UNIQUE%';
```

## Rule 1: always send parameters, never build SQL strings

Parameters are the only defence against SQL injection that does not depend on escaping correctly. Every driver
supports them; identifiers (table or column names) cannot be parameters, so pick them from an allowlist in code.

```sql
SELECT id, email FROM app.customers WHERE email = $1;            -- value as a parameter
-- Identifier from user input: map it in code, e.g. {"newest": "created_at DESC"}[sort], never interpolate.
```

In PL/pgSQL dynamic SQL, quote with `format('%I', name)` for identifiers and `%L` or `USING` for values.

## Upsert with INSERT ... ON CONFLICT

`INSERT ... ON CONFLICT` inserts a row or updates the existing one atomically, with no race between a check and the
write. The conflict target must match a unique index or constraint.

```sql
INSERT INTO app.customers (email, name)
VALUES ($1, $2)
ON CONFLICT (email) DO UPDATE
  SET name = EXCLUDED.name
  WHERE app.customers.name IS DISTINCT FROM EXCLUDED.name     -- skip no-op updates (no dead tuple)
RETURNING id, (old.id IS NULL) AS inserted;                    -- PG 18: old is NULL for a new row
```

- Before PG 18, `(xmax = 0) AS inserted` is the common trick; it reads a system column and is not a documented API.
- `ON CONFLICT DO NOTHING RETURNING id` returns no row when the row existed. To always get the id, follow with a
  `SELECT`, or use `DO UPDATE SET email = EXCLUDED.email` (a write each time).
- One statement cannot update the same row twice: deduplicate the input first (`DISTINCT ON`), or the statement fails
  with `ON CONFLICT DO UPDATE command cannot affect row a second time`.

## MERGE for insert, update and delete in one statement

`MERGE` (PG 15+) applies a source set to a target with separate actions for matched and unmatched rows; PG 17 added
`RETURNING` and `WHEN NOT MATCHED BY SOURCE`.

```sql
MERGE INTO app.inventory AS t
USING (SELECT unnest($1::bigint[]) AS sku, unnest($2::int[]) AS qty) AS s
ON t.sku = s.sku
WHEN MATCHED AND s.qty = 0 THEN DELETE
WHEN MATCHED THEN UPDATE SET qty = s.qty
WHEN NOT MATCHED THEN INSERT (sku, qty) VALUES (s.sku, s.qty)
RETURNING merge_action(), t.sku;
```

`MERGE` is not race-free like `ON CONFLICT`: two concurrent `MERGE`s inserting the same key can still raise a unique
violation. For a single-row upsert under concurrency, prefer `ON CONFLICT`.

## RETURNING old and new values in PostgreSQL 18

`RETURNING` sends back the rows a write changed, saving a round trip. PG 18 adds `old` and `new` so one statement
can return values from before and after an update.

```sql
UPDATE app.accounts SET balance_cents = balance_cents - $2
WHERE id = $1 AND balance_cents >= $2
RETURNING old.balance_cents AS before, new.balance_cents AS after;
```

No row returned means the condition failed (not enough balance): no separate check, no race.

## Keyset pagination instead of OFFSET

`OFFSET n` reads and discards `n` rows, so page 1,000 costs a thousand pages of work and rows shift when data
changes. Keyset (seek) pagination continues after the last row seen and costs the same at any depth.

```sql
-- first page
SELECT id, created_at, title FROM app.posts
ORDER BY created_at DESC, id DESC LIMIT 20;
-- next page: pass the last row's (created_at, id)
SELECT id, created_at, title FROM app.posts
WHERE (created_at, id) < ($1, $2)
ORDER BY created_at DESC, id DESC LIMIT 20;
-- index that serves both
CREATE INDEX posts_created_id_idx ON app.posts (created_at DESC, id DESC);
```

- The `id` tiebreaker is required: without it, rows sharing a timestamp are skipped or repeated between pages.
- The row comparison `(a, b) < ($1, $2)` works when both columns sort the same direction. For mixed directions,
  write the expanded form: `a < $1 OR (a = $1 AND b > $2)`.
- Exact total counts on big tables are expensive; show "more" instead, or an estimate from `pg_class.reltuples`.

## Bulk inserts with unnest and COPY

Row-by-row inserts pay a round trip and a commit each. Send many rows in one statement, or stream them with `COPY`.

```sql
-- one statement, any number of rows, two parameters
INSERT INTO app.readings (sensor_id, value)
SELECT * FROM unnest($1::bigint[], $2::double precision[]);
```

```sql
-- psql: load a CSV from the client machine
\copy app.readings (sensor_id, value) FROM 'readings.csv' WITH (FORMAT csv, HEADER true)
-- PG 17+: skip bad rows instead of failing; PG 18: cap them
COPY app.readings FROM STDIN WITH (FORMAT csv, ON_ERROR ignore, REJECT_LIMIT 100);
```

- `COPY` is the fastest load path (every driver exposes it: psycopg `cursor.copy()`, node `pg-copy-streams`, pgx
  `CopyFrom`). Load into a staging table, then `INSERT ... SELECT ... ON CONFLICT` into the real one.
- A multi-row `VALUES` list is fine for hundreds of rows; past the 65,535-parameter protocol limit use arrays or COPY.

## Fixing N+1 queries with joins, arrays and LATERAL

An N+1 is one query for a list and one more per item. Replace it with one query that returns the tree.

```sql
-- each customer with its 3 latest orders, as JSON, in one round trip
SELECT c.id, c.email, coalesce(o.orders, '[]') AS latest_orders
FROM app.customers c
LEFT JOIN LATERAL (
  SELECT jsonb_agg(jsonb_build_object('id', id, 'total', total_cents) ORDER BY placed_at DESC) AS orders
  FROM (SELECT id, total_cents, placed_at FROM app.orders
        WHERE customer_id = c.id ORDER BY placed_at DESC LIMIT 3) x
) o ON true
WHERE c.id = ANY($1::bigint[]);
```

`LATERAL` lets the subquery refer to the outer row, which makes "top N per group" an index lookup per group.

## Window functions and DISTINCT ON

Window functions compute across rows related to the current one without collapsing them; `DISTINCT ON` keeps the
first row per group.

```sql
-- latest order per customer
SELECT DISTINCT ON (customer_id) customer_id, id, placed_at
FROM app.orders ORDER BY customer_id, placed_at DESC;

-- running total and rank
SELECT id, placed_at, total_cents,
       sum(total_cents) OVER (PARTITION BY customer_id ORDER BY placed_at) AS running_total,
       rank() OVER (ORDER BY total_cents DESC) AS size_rank
FROM app.orders;
```

## CTEs and recursive queries

A CTE (`WITH`) names a subquery. Since PG 12 a CTE used once is inlined into the main query; write
`AS MATERIALIZED` to force it to run once as written, or `NOT MATERIALIZED` to force inlining.

```sql
-- walk a tree of categories
WITH RECURSIVE tree AS (
  SELECT id, parent_id, name, 1 AS depth FROM app.categories WHERE id = $1
  UNION ALL
  SELECT c.id, c.parent_id, c.name, t.depth + 1
  FROM app.categories c JOIN tree t ON c.parent_id = t.id
  WHERE t.depth < 20                                  -- stop runaway cycles
)
SELECT * FROM tree;
```

PG 14+ also has `CYCLE id SET is_cycle USING path` to detect cycles in a recursive CTE.

## NULL traps in comparisons and NOT IN

SQL NULL means unknown, so most comparisons with it return NULL, which `WHERE` treats as false.

| Wrong | Right | Why |
|---|---|---|
| `WHERE col = NULL` | `WHERE col IS NULL` | `= NULL` is never true |
| `WHERE a <> b` (nullable) | `WHERE a IS DISTINCT FROM b` | NULL vs value is not "different" with `<>` |
| `WHERE id NOT IN (SELECT ref FROM t)` | `WHERE NOT EXISTS (SELECT 1 FROM t WHERE t.ref = x.id)` | one NULL in `t.ref` makes `NOT IN` return no rows |
| `count(col)` to count rows | `count(*)` | `count(col)` skips NULLs |
| `WHERE col = ANY($1)` with NULL in the array | filter NULLs out first | NULL never matches |

## Concurrency-safe writes

A read followed by a write in application code races with other sessions. Make the write itself conditional, or
lock the row (`postgres-transactions-locking`).

```sql
-- atomic counter, no read first
UPDATE app.counters SET n = n + 1 WHERE name = $1 RETURNING n;
-- claim a job without two workers taking it
UPDATE app.jobs SET state = 'running', taken_at = now()
WHERE id = (SELECT id FROM app.jobs WHERE state = 'queued'
            ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1)
RETURNING id, payload;
```

## Materialized views for slow dashboards and reports

A materialized view stores a query's result as a table, so a dashboard reads it in milliseconds instead of running a
heavy aggregate on every page load. It is as fresh as its last refresh.

```sql
CREATE MATERIALIZED VIEW app.daily_revenue AS
SELECT date_trunc('day', placed_at AT TIME ZONE 'UTC')::date AS day, sum(total_cents) AS cents, count(*) AS orders
FROM app.orders WHERE status = 'paid' GROUP BY 1;
CREATE UNIQUE INDEX daily_revenue_day_uq ON app.daily_revenue (day);   -- required for CONCURRENTLY
REFRESH MATERIALIZED VIEW CONCURRENTLY app.daily_revenue;             -- readers keep the old rows meanwhile
```

- Plain `REFRESH` locks out readers for the whole run; `CONCURRENTLY` does not, but needs a unique index and does
  more work. Schedule it from a job runner or `pg_cron`.
- When the data is large and only recent rows change, keep a rollup table updated incrementally (`INSERT ... ON
  CONFLICT (day) DO UPDATE`) instead of refreshing everything.

Grouping sets, `FILTER`, time buckets with gaps filled, percentiles and rollup tables:
[references/reporting.md](references/reporting.md).

## Worked example: "show each customer's last 3 orders without 51 queries"

The page lists 50 customers and runs one query per customer for their orders, an N+1. Replace the loop with one
query: fetch the customer ids the page shows, then `LEFT JOIN LATERAL` the three latest orders per customer, built
as JSON, as in the N+1 section. Check that `app.orders (customer_id, placed_at DESC)` is indexed, so each lateral
subquery is an index range read. Run `EXPLAIN (ANALYZE)` once: the plan shows a Nested Loop whose inner side is an
Index Scan with `loops=50` and a few rows each, and the page now does one round trip instead of 51.

## Verify upserts and keyset paging

These prove what the patterns promise, not just that they run. They ran on 18.6 on a 50,000-row table with an index on
`(placed_at DESC, id DESC)`.

```sql
-- run the upsert twice: the count must not change
INSERT INTO app.acct SELECT * FROM app.src ON CONFLICT (id) DO UPDATE SET n = EXCLUDED.n;
INSERT INTO app.acct SELECT * FROM app.src ON CONFLICT (id) DO UPDATE SET n = EXCLUDED.n;
SELECT count(*) FROM app.acct;                 -- 1000 both times
-- keyset reads only the page; OFFSET reads everything it skips
EXPLAIN (ANALYZE) SELECT id FROM app.o2 WHERE (placed_at, id) < ('2026-10-02', 999)
ORDER BY placed_at DESC, id DESC LIMIT 20;     -- Index Only Scan, actual rows=20
EXPLAIN (ANALYZE) SELECT id FROM app.o2
ORDER BY placed_at DESC, id DESC LIMIT 20 OFFSET 40000;   -- same index, actual rows=40020
-- an N+1 shows as one statement whose calls track the rows on the page
SELECT calls, rows, left(query, 60) AS query FROM pg_stat_statements ORDER BY calls DESC LIMIT 5;
```

## Checklist

Check these points before you call application SQL done.

- [ ] Every value is a bind parameter; identifiers come from an allowlist.
- [ ] Upserts use `ON CONFLICT` on a real unique constraint; input deduplicated.
- [ ] Lists page with keyset and a unique tiebreaker; an index matches the `ORDER BY`.
- [ ] Bulk writes use `unnest` arrays or `COPY`, not a loop.
- [ ] No N+1: lists with children come back in one query.
- [ ] No `NOT IN (subquery)`; NULL comparisons use `IS [NOT] DISTINCT FROM`.
- [ ] Read-modify-write is one conditional statement or a locked row.

## Gotchas

These are the failures seen most often with application SQL, each with its cause and fix.

1. **`ON CONFLICT` needs a unique index.** Error: `there is no unique or exclusion constraint matching the ON
   CONFLICT specification`. A partial unique index needs its predicate repeated: `ON CONFLICT (email) WHERE deleted_at IS NULL`.
2. **`NOT IN` returns nothing.** The subquery has a NULL. Use `NOT EXISTS`.
3. **A CTE got slower after an upgrade, or faster.** PG 12 started inlining single-use CTEs. Add `MATERIALIZED` to
   keep the old fence.
4. **Deep pages time out.** `OFFSET` scans all skipped rows. Use keyset.
5. **`IN ($1, $2, ...)` with thousands of values** blows up planning and the parameter limit. Pass one array:
   `= ANY($1::bigint[])`.
6. **Bulk insert hits `bind message has N parameter formats but 0 parameters`** or the 65,535 limit. Switch to arrays
   with `unnest` or `COPY`.

## Anti-patterns in application SQL

Each of these is a loop or a race that one statement replaces.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| `SELECT`, then `INSERT` or `UPDATE` | two sessions pass the check together | `ON CONFLICT`, or a conditional `UPDATE` |
| Values concatenated into SQL | SQL injection | bind parameters; an allowlist for identifiers |
| `OFFSET` for deep pages | every skipped row is read, and rows shift between pages | keyset pagination with a unique tiebreaker |
| An exact `count(*)` on every list page | a full scan per page view | "more", or `pg_class.reltuples` |
| Inserting in a loop | a round trip and a commit per row | `unnest` arrays or `COPY` |
| `MERGE` for a concurrent single-row upsert | two sessions can still raise a unique violation | `ON CONFLICT` |
| A query per item in a list | N+1 round trips | one query with `LATERAL` or a join |

## See also

Related skills in this library:

- `postgres-sql-fundamentals`: how each clause is evaluated
- `postgres-query-performance`: reading the plans of these queries
- `postgres-indexing`: the indexes behind keyset paging
- `postgres-transactions-locking`: row locks and retries
- `postgres-bulk-load-etl`: large loads with `COPY`
