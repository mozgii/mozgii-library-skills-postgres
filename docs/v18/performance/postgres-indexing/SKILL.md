---
name: postgres-indexing
description: 'Chooses, builds and maintains PostgreSQL indexes: B-tree column order, partial, expression and covering (INCLUDE) indexes, GIN for jsonb, arrays and trigram search, GiST, BRIN for time series, skip scan in 18, CREATE INDEX CONCURRENTLY on live tables, and finding unused, duplicate, invalid or bloated indexes. Use when a query needs an index, "the index exists but is not used", LIKE or ILIKE is slow, or indexes need a review.'
metadata:
  tags:
  - postgres
  - indexes
  - btree
  - gin
  - gist
  - brin
  - partial-index
  - covering-index
  - concurrently
---

# PostgreSQL indexing

An index trades write cost and disk for faster reads of a specific shape of query. Index for the queries you run,
prove each one with `EXPLAIN` (`postgres-query-performance`), and drop what nobody uses. The health checks are in
[scripts/index-health.sql](scripts/index-health.sql).

## Step 0: see the query and the existing indexes

An index is designed from a query, so start from the slow query and what the table already has.

```sql
\d app.orders                                            -- psql: columns and indexes
SELECT indexrelid::regclass AS index, pg_size_pretty(pg_relation_size(indexrelid)) AS size, idx_scan
FROM pg_stat_user_indexes WHERE relid = 'app.orders'::regclass ORDER BY idx_scan;
EXPLAIN (ANALYZE) SELECT ...;                            -- the query you want to speed up
```

## Index types and what each one serves

PostgreSQL ships several index access methods; each answers different operators.

| Type | Serves | Typical use |
|---|---|---|
| B-tree (default) | `=`, `<`, `>`, `BETWEEN`, `IN`, `IS NULL`, `ORDER BY`, prefix `LIKE 'abc%'` (with `C` collation or `text_pattern_ops`) | nearly everything |
| GIN | containment and membership: `@>`, `?`, `@@`, `&&` | `jsonb`, arrays, `tsvector`, `pg_trgm` |
| GiST | overlap, distance, nearest neighbour | ranges, exclusion constraints, PostGIS, `pg_trgm` `<->` |
| BRIN | ranges of physically ordered values | append-only time series, very large tables |
| Hash | `=` only | rarely better than B-tree |
| HNSW / IVFFlat (pgvector) | vector distance | embeddings (`postgres-vector-search`) |

## Composite B-tree indexes: column order

A multicolumn B-tree is sorted by the first column, then the second, so order decides which queries can use it.
Put columns tested with `=` first, then the one used for a range or `ORDER BY`.

```sql
-- serves: WHERE customer_id = $1 AND placed_at >= $2 ORDER BY placed_at DESC
CREATE INDEX orders_customer_placed_idx ON app.orders (customer_id, placed_at DESC);
```

- It also serves `WHERE customer_id = $1` alone; it does not serve `WHERE placed_at >= $2` alone well.
- PG 18 adds **skip scan**: a B-tree on `(a, b)` can serve `WHERE b = $1` by jumping through the distinct values of
  `a`. It helps when `a` has few distinct values; it does not replace an index led by `b`.
- An index on `(a, b)` makes a separate index on `(a)` redundant.

## Partial indexes for a subset of rows

A partial index covers only rows matching its `WHERE`, so it is smaller and cheaper to maintain. The query must
include the same condition.

```sql
CREATE INDEX jobs_queued_idx ON app.jobs (created_at) WHERE state = 'queued';
CREATE UNIQUE INDEX users_email_live_uq ON app.users (lower(email)) WHERE deleted_at IS NULL;   -- unique among live rows
```

## Expression indexes for functions in WHERE

A query that filters on an expression (`lower(email)`, `date(created_at)`, `payload->>'kind'`) can only use an index
built on that same expression.

```sql
CREATE INDEX customers_email_lower_idx ON app.customers (lower(email));
-- used by: WHERE lower(email) = lower($1)
```

The function must be `IMMUTABLE`. `date(timestamptz)` is not (it depends on the session time zone): index
`((created_at AT TIME ZONE 'UTC')::date)` and query the same expression.

## Covering indexes with INCLUDE for index-only scans

An index-only scan answers a query from the index without visiting the table. `INCLUDE` adds columns to the leaf
pages so the index can return them without making them part of the key.

```sql
CREATE INDEX orders_customer_cover_idx ON app.orders (customer_id) INCLUDE (status, total_cents);
-- SELECT status, total_cents FROM app.orders WHERE customer_id = $1  → Index Only Scan
```

Index-only scans need the visibility map to be current: a table vacuumed rarely shows high `Heap Fetches` in
`EXPLAIN ANALYZE`.

## GIN indexes for jsonb, arrays and trigram search

GIN indexes every element or key inside a value. Two common operator classes:

```sql
CREATE INDEX docs_tags_gin ON app.docs USING gin (tags);                         -- text[]: tags @> ARRAY['pg']
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX customers_name_trgm ON app.customers USING gin (name gin_trgm_ops); -- ILIKE '%smith%', similarity
```

GIN updates are buffered in a pending list (`fastupdate`); large pending lists slow reads until vacuum flushes them.
For write-heavy tables, lower `gin_pending_list_limit` on the index.

## BRIN indexes for append-only time series

BRIN stores the minimum and maximum per block range, so it is tiny and works when row order on disk follows the
column, as with an insert-time timestamp. Measured on 18.6, an index on a `timestamptz` column came to about 5 MB per
100 GB of table at the default `pages_per_range` of 128, and about 15 MB at 32 (40 kB and 128 kB on an 833 MB table).

```sql
CREATE INDEX readings_at_brin ON app.readings USING brin (recorded_at) WITH (pages_per_range = 32);
```

Updates and deletes that scatter values make BRIN useless; check with `EXPLAIN` that rows removed by recheck stay low.

## Building indexes on a live table with CONCURRENTLY

A plain `CREATE INDEX` blocks writes to the table for the whole build. `CREATE INDEX CONCURRENTLY` allows writes but
takes longer and cannot run inside a transaction block.

```sql
SET lock_timeout = '5s';
CREATE INDEX CONCURRENTLY orders_status_idx ON app.orders (status);
```

A failed concurrent build leaves an `INVALID` index that still slows writes, so drop it and build again:

```sql
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;     -- find what a failed build left
DROP INDEX CONCURRENTLY IF EXISTS orders_status_idx;
CREATE INDEX CONCURRENTLY orders_status_idx ON app.orders (status);
```

A healthy index that has bloated is rebuilt in place, without blocking writes:

```sql
REINDEX INDEX CONCURRENTLY orders_status_idx;
```

- `CREATE INDEX CONCURRENTLY IF NOT EXISTS` skips a name that already exists, even an invalid index, so retries use
  the drop first.
- Migration tools wrap each file in a transaction; put each `CONCURRENTLY` statement in its own migration with the
  transaction turned off (`postgres-schema-migrations`).
- Watch progress: `SELECT * FROM pg_stat_progress_create_index;`.
- On a partitioned table, `CREATE INDEX CONCURRENTLY` on the parent is not supported: create it `ON ONLY` the parent,
  build each partition's index concurrently, then `ALTER INDEX ... ATTACH PARTITION`.

## Finding unused, duplicate and invalid indexes

Every index costs writes, WAL, memory and vacuum time, so remove the ones that do not earn it.
[scripts/index-health.sql](scripts/index-health.sql) reports unused indexes, duplicates, invalid indexes, foreign keys
without an index, and size. The two queries that matter most stand alone here.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

Duplicate indexes have the same table, keys, sort order, operator classes, collations, expressions and predicate:

```sql
SELECT indrelid::regclass AS table_name,
       array_agg(indexrelid::regclass ORDER BY indexrelid) AS indexes,
       pg_size_pretty(sum(pg_relation_size(indexrelid))) AS total_size
FROM pg_index
GROUP BY indrelid, indkey::text, indclass::text, indoption::text, indcollation::text,
         coalesce(indexprs::text, ''), coalesce(indpred::text, '')
HAVING count(*) > 1;
```

Foreign keys need an index on their referencing columns, or every delete on the parent scans the child. A partial or
invalid index does not count:

```sql
SELECT c.conrelid::regclass AS table_name, c.conname AS constraint_name,
       array_agg(a.attname ORDER BY k.ord) AS columns
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid AND i.indisvalid AND i.indpred IS NULL
      AND cardinality(c.conkey) <= i.indnkeyatts
      AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey)
GROUP BY c.conrelid, c.conname;
```

- `idx_scan = 0` counts since the last statistics reset (`pg_stat_reset`) and per server: check replicas too before
  dropping an index a read replica uses.
- Never drop an index that backs a primary key, unique or exclusion constraint.

## Worked example: "my index exists but the query still does a Seq Scan"

The query is `SELECT id FROM app.customers WHERE lower(email) = lower($1)` and the table has a plain index on
`email`. Run `EXPLAIN (ANALYZE) ...`: it shows `Seq Scan on customers ... Filter: (lower(email) = ...)` and
`Rows Removed by Filter: 1999999`. The index is on `email`, but the query filters on `lower(email)`, a different
expression. Build the matching expression index without blocking writes, refresh statistics, and check again:

```sql
CREATE INDEX CONCURRENTLY customers_email_lower_idx ON app.customers (lower(email));
ANALYZE app.customers;
EXPLAIN (ANALYZE) SELECT id FROM app.customers WHERE lower(email) = lower('Ann@Example.com');
-- Index Scan using customers_email_lower_idx ... actual rows=1
```

If emails must also be unique regardless of case, make it `CREATE UNIQUE INDEX CONCURRENTLY` and drop the old
index on `email` once nothing uses it (`idx_scan` stays 0 for a full business cycle).

## Verify a new index with EXPLAIN and index statistics

Prove the query uses the index, then that it keeps being used.

```sql
ANALYZE app.orders;
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;                   -- expect the index name; compare Buffers before and after
SELECT indisvalid FROM pg_index WHERE indexrelid = 'app.orders_status_idx'::regclass;   -- expect t
SELECT idx_scan FROM pg_stat_user_indexes WHERE indexrelname = 'orders_status_idx';     -- grows under real traffic
```

Run the duplicate and foreign key queries above after the change, on the primary and on each replica that serves
reads.

## Checklist

Check these points before you call a new or changed index done.

- [ ] The index was designed from a real query and `EXPLAIN (ANALYZE)` shows it used.
- [ ] Composite columns: equality first, then range or sort column.
- [ ] Expression and partial indexes match the query text exactly.
- [ ] Built with `CONCURRENTLY` on any table taking writes, in its own non-transactional migration.
- [ ] No invalid indexes left after a failed concurrent build.
- [ ] Foreign key columns indexed; unused and duplicate indexes reviewed.

## Gotchas

These are the failures seen most often with a new or changed index, each with its cause and fix.

1. **The index exists but is not used.** Causes: a function or cast on the column (`WHERE created_at::date = ...`),
   a type mismatch between parameter and column, low selectivity (the planner rightly prefers a sequential scan), or
   stale statistics (`ANALYZE app.orders`).
2. **`LIKE 'abc%'` does not use the index.** Under a non-C collation a B-tree needs `text_pattern_ops`:
   `CREATE INDEX ON t (name text_pattern_ops)`. `'%abc%'` needs `pg_trgm`.
3. **A concurrent build failed and writes got slower.** The INVALID index is still maintained. Find it with
   `pg_index.indisvalid = false` and drop it.
4. **`CREATE INDEX CONCURRENTLY cannot run inside a transaction block`.** The migration tool opened a transaction.
5. **Index-only scan still reads the heap.** The visibility map is stale; vacuum the table or tune autovacuum.
6. **Too many indexes slow writes.** Each insert updates every index and blocks HOT updates on indexed columns.

## Anti-patterns in indexing

| Do not | Do this instead |
|---|---|
| index every column in case it helps | design from a real query |
| run a plain `CREATE INDEX` on a live table | `CREATE INDEX CONCURRENTLY` in its own migration |
| add `(a)` beside `(a, b)` | keep the composite; it serves both |
| retry a failed concurrent build with `IF NOT EXISTS` | drop the invalid index first |
| drop an index from primary statistics alone | check every replica that serves reads |
| index a low-selectivity flag on its own | a partial index on the rare value |

## See also

- `postgres-query-performance`: reading plans and `pg_stat_statements`.
- `postgres-schema-migrations`: concurrent builds inside migration tools.
- `postgres-vacuum-bloat`: index bloat and the visibility map.
- `postgres-full-text-search`: GIN and trigram search.
- `postgres-vector-search`: HNSW and IVFFlat.
- `postgres-partitioning`: indexes on partitioned tables.

## Sources

- https://www.postgresql.org/docs/18/indexes.html and /sql-createindex.html, /sql-reindex.html
- https://www.postgresql.org/docs/18/brin.html
- https://www.postgresql.org/docs/18/catalog-pg-index.html
- Run on 18.6: the BRIN sizes, the health queries, and the `CONCURRENTLY` sequence.
