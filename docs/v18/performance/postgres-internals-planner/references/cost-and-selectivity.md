---
title: PostgreSQL planner row estimates by hand, default selectivities and JIT
author: MOZGII, Inc.
lang: en
---

# PostgreSQL planner row estimates by hand, default selectivities and JIT

This reference recomputes the planner's row estimates from `pg_stats` with SQL, lists the fixed selectivity guesses
used when no statistics apply, and shows when JIT compilation runs. It continues the `postgres-internals-planner`
skill; run its demo data block first. Results are from PostgreSQL 18.6 and vary slightly with each `ANALYZE` sample.

## Equality on a most common value

For `col = constant` where the constant is in `most_common_vals`, the estimate is its frequency times the row
count. The planner's estimate for `status = 'failed'` is that product, rounded (about 2,000 rows).

```sql
SELECT (SELECT f FROM unnest(most_common_vals::text::text[], most_common_freqs) AS m(v, f) WHERE v = 'failed')
       * 200000 AS mcv_rows
FROM pg_stats WHERE schemaname = 'pl' AND tablename = 'orders' AND attname = 'status';
EXPLAIN SELECT * FROM pl.orders WHERE status = 'failed';
```

## Equality on any other value

For a value not in the list, the planner spreads the remaining frequency evenly over the remaining distinct values:
`(1 - sum(most_common_freqs) - null_frac) / (n_distinct - number of MCVs) x reltuples`. A negative `n_distinct` is a
fraction of the rows. For `customer_id` (20,000 distinct, no common values) that is 10 rows.

```sql
SELECT n_distinct,
       round(((1 - coalesce((SELECT sum(f) FROM unnest(most_common_freqs) f), 0) - null_frac)
              / ((CASE WHEN n_distinct < 0 THEN -n_distinct * c.reltuples ELSE n_distinct END)
                 - coalesce(cardinality(most_common_freqs), 0)) * c.reltuples)::numeric, 1) AS est_rows
FROM pg_stats s JOIN pg_class c ON c.oid = 'pl.orders'::regclass
WHERE s.schemaname = 'pl' AND s.tablename = 'orders' AND s.attname = 'customer_id';
EXPLAIN SELECT * FROM pl.orders WHERE customer_id = 5;                -- rows=10
```

## Ranges and the histogram

For `col > constant`, the planner finds the histogram bucket holding the constant, assumes values are spread
linearly inside it, and takes the share of buckets above it (adjusted for the most common values, which the
histogram excludes). `SET STATISTICS 500` on `amount` in the skill gave it 501 bounds, so 500 buckets.

```sql
SELECT cardinality(histogram_bounds::text::numeric[]) AS bounds
FROM pg_stats WHERE schemaname = 'pl' AND tablename = 'orders' AND attname = 'amount';
EXPLAIN SELECT * FROM pl.orders WHERE amount > 50;                    -- about half the rows
```

## Default selectivities when no statistics apply

When a condition cannot use statistics (an expression on a column, a function without an estimator, an unknown
parameter), the planner uses fixed constants from `src/include/utils/selfuncs.h`.

| Constant | Value | Used for |
|---|---|---|
| `DEFAULT_EQ_SEL` | 0.005 | `=` |
| `DEFAULT_INEQ_SEL` | 0.3333 | `<`, `>`, `<=`, `>=` |
| `DEFAULT_RANGE_INEQ_SEL` | 0.005 | `a > x AND a < y` on the same expression |
| `DEFAULT_MATCH_SEL` | 0.005 | pattern matching (`LIKE`, regular expressions) |
| `DEFAULT_MATCHING_SEL` | 0.010 | generic matching operators such as `@>` |
| `DEFAULT_NUM_DISTINCT` | 200 | distinct values when unknown |

```sql
EXPLAIN SELECT * FROM pl.orders WHERE amount + 0 = 5;                         -- 200000 x 0.005 = 1000
EXPLAIN SELECT * FROM pl.orders WHERE amount + 0 > 5;                         -- 200000 / 3 = 66667
EXPLAIN SELECT * FROM pl.orders WHERE amount + 0 > 5 AND amount + 0 < 6;      -- 200000 x 0.005 = 1000
```

## JIT compilation and when EXPLAIN shows it

JIT compiles expressions and row deforming with LLVM when a plan's total cost exceeds `jit_above_cost` (100,000);
inlining and optimization start at 500,000. It needs a build with LLVM: `pg_jit_available()` is false on
Postgres.app and true in the official `postgres:18` Docker image, where this example printed a `JIT:` section. The
section appears only with `COSTS` on, because `EXPLAIN` prints the JIT summary only then (`explain.c`).

```sql
SELECT pg_jit_available() AS jit_built_in;
SET jit_above_cost = 10;
EXPLAIN (ANALYZE, BUFFERS OFF) SELECT sum(amount * 2 + 1) FROM pl.orders WHERE amount > 1;
```

The `JIT:` section printed by the `postgres:18` image (Debian build, 18.6) for this aggregate over the demo's 200,000
rows:

```text
 JIT:
   Functions: 5
   Options: Inlining false, Optimization false, Expressions true, Deforming true
   Timing: Generation 0.301 ms (Deform 0.117 ms), Inlining 0.000 ms, Optimization 0.532 ms, Emission 4.391 ms, Total 5.224 ms
```

JIT pays off for long analytical queries; for short OLTP queries its compile time (milliseconds) can exceed the
query's run time, which is why the thresholds are high. `jit = off` per session or role switches it off.

## Sources

- https://www.postgresql.org/docs/18/row-estimation-examples.html
- https://www.postgresql.org/docs/18/view-pg-stats.html
- https://www.postgresql.org/docs/18/jit-decision.html
- https://www.postgresql.org/docs/18/runtime-config-query.html
- https://github.com/postgres/postgres/blob/REL_18_STABLE/src/include/utils/selfuncs.h
- https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/commands/explain.c
