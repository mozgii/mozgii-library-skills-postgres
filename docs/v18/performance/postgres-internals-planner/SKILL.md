---
name: postgres-internals-planner
description: 'Explains how the PostgreSQL 18 planner chooses a plan, each claim proved with EXPLAIN: statistics in pg_statistic and pg_stats (n_distinct, most common values, histograms, correlation, default_statistics_target), extended statistics (dependencies, ndistinct, mcv), the cost model (seq_page_cost, random_page_cost, cpu_tuple_cost, cpu_operator_cost, effective_cache_size), selectivity estimation and why estimates go wrong, join methods (nested loop, hash, merge) and join order (join_collapse_limit, from_collapse_limit, geqo), scan methods including skip scan in 18, parallel query, JIT, and generic versus custom plans (plan_cache_mode). Use when asking why the planner chose a plan, reading estimated versus actual rows, a plan flips between runs, correlated columns are misestimated, or a prepared statement gets a bad plan.'
metadata:
  tags:
  - postgres
  - internals
  - planner
  - statistics
  - cost-model
  - join-order
  - skip-scan
  - generic-plan
---

# PostgreSQL planner internals: statistics, costs and plan choice

The planner enumerates plans, estimates each step's rows from statistics, prices plans with the cost settings,
and keeps the cheapest. Almost every bad plan is a bad row estimate, not a bad cost constant: fix
the estimate (fresh `ANALYZE`, a higher statistics target, extended statistics, a predicate the statistics can
read) before touching `random_page_cost` or `enable_*` switches. The tuning workflow (pg_stat_statements, reading
plans, `work_mem`) is in `postgres-query-performance` and its references/explain-nodes.md; this skill is the
machinery underneath. Estimates computed by hand, default guesses and JIT:
[references/cost-and-selectivity.md](references/cost-and-selectivity.md).


## Step 0: read the version and the planner settings that were changed

Plans depend on the version and on any cost setting someone changed, so list them before you explain a plan. Skip
scan and `Index Searches` need 18; `GENERIC_PLAN` needs 16.

```sql
SELECT current_setting('server_version') AS version, pg_jit_available() AS jit_built_in;
SELECT name, setting, source FROM pg_settings
WHERE name IN ('default_statistics_target', 'random_page_cost', 'seq_page_cost', 'effective_cache_size',
               'join_collapse_limit', 'from_collapse_limit', 'geqo_threshold', 'plan_cache_mode', 'jit')
ORDER BY name;                                                  -- source shows what is not a default
```

## Demo data for the examples

The examples run in order on PostgreSQL 18.6 against two tables with a skewed `status`, a `zip` that determines its
`city`, and `created_at` in physical order. `ANALYZE` samples rows at random, so estimates differ slightly per run.

```sql
CREATE SCHEMA pl;
CREATE TABLE pl.customers (id int PRIMARY KEY, name text NOT NULL, tier text NOT NULL);
INSERT INTO pl.customers SELECT g, 'c' || g, CASE WHEN g % 50 = 0 THEN 'gold' ELSE 'basic' END
FROM generate_series(1, 20000) g;
CREATE TABLE pl.orders (id bigint PRIMARY KEY, customer_id int NOT NULL REFERENCES pl.customers,
  status text NOT NULL, zip text NOT NULL, city text NOT NULL, amount numeric(10,2) NOT NULL,
  created_at timestamptz NOT NULL);
INSERT INTO pl.orders
SELECT g, 1 + (g * 7919) % 20000,
       CASE WHEN g % 100 = 0 THEN 'failed' WHEN g % 10 = 0 THEN 'open' ELSE 'done' END,
       lpad((g % 100)::text, 5, '0'), 'city' || (g % 100) / 10, (g % 1000) / 10.0,
       timestamptz '2026-01-01 00:00+00' + g * interval '1 minute'
FROM generate_series(1, 200000) g;
CREATE INDEX orders_customer_idx ON pl.orders (customer_id);
CREATE INDEX orders_status_created_idx ON pl.orders (status, created_at);
CREATE TABLE pl.tiers (tier text PRIMARY KEY, discount int);
INSERT INTO pl.tiers VALUES ('gold', 10), ('basic', 0);
VACUUM (ANALYZE) pl.customers, pl.orders, pl.tiers;
```

## Statistics: pg_statistic and pg_stats

`ANALYZE` (and autovacuum's analyze) samples 300 x the statistics target rows per table (30,000 at the default
`default_statistics_target = 100`) and stores per-column statistics in `pg_statistic`; `pg_stats` is its readable
view. The target also caps the number of most common values and histogram buckets.

| `pg_stats` column | Meaning | Used for |
|---|---|---|
| `null_frac` | share of `NULL`s | `IS NULL`, every other estimate |
| `n_distinct` | distinct values; negative means a fraction of rows (-1 is unique) | equality on non-common values, `GROUP BY`, joins |
| `most_common_vals`, `most_common_freqs` | the most common values and their shares | equality and `IN` on common values |
| `histogram_bounds` | equal-population buckets of the remaining values | ranges, `<`, `>`, `BETWEEN` |
| `correlation` | -1 to 1: how well physical order follows value order | cost of index scans |

```sql
SELECT attname, null_frac, n_distinct, most_common_vals, most_common_freqs, round(correlation::numeric, 3) AS corr
FROM pg_stats WHERE schemaname = 'pl' AND tablename = 'orders' AND attname IN ('status', 'customer_id', 'created_at');
ALTER TABLE pl.orders ALTER COLUMN amount SET STATISTICS 500;     -- more buckets for one skewed column
```

## The cost model and its settings

Costs are in units where one sequential page read costs 1.0; a node's cost adds page, row and operator costs.

| Setting | Default | Charged for |
|---|---|---|
| `seq_page_cost` | 1.0 | each page read in sequence |
| `random_page_cost` | 4.0 | each page read out of order (index scans) |
| `cpu_tuple_cost` | 0.01 | each row processed |
| `cpu_index_tuple_cost` | 0.005 | each index entry processed |
| `cpu_operator_cost` | 0.0025 | each operator or function call per row |
| `effective_cache_size` | 4GB | not allocated: assumed cache for index costs |
| `parallel_setup_cost` / `parallel_tuple_cost` | 1000 / 0.1 | starting workers / passing each row to the leader |

A sequential scan costs `relpages x seq_page_cost + reltuples x cpu_tuple_cost`, plus `cpu_operator_cost` per
operator per row: here 1,870 pages and 200,000 rows give 3,870, one filter adds 500 and a two-operator filter 1,000.

```sql
SET max_parallel_workers_per_gather = 0;
SELECT relpages, reltuples, relpages * 1.0 + reltuples * 0.01 AS seq_scan_cost
FROM pg_class WHERE oid = 'pl.orders'::regclass;                     -- 1870, 200000, 3870
EXPLAIN SELECT * FROM pl.orders;                                     -- cost=0.00..3870.00
EXPLAIN SELECT * FROM pl.orders WHERE amount > 50;                   -- 4370.00
EXPLAIN SELECT * FROM pl.orders WHERE amount + 0 > 5;                -- 4870.00
```

`random_page_cost` assumes most random reads hit a cache; lower it (never below `seq_page_cost`) when the data fits
in memory, raise it for slow random storage, per tablespace if storage differs.

## Selectivity: most common values, histograms and default guesses

Selectivity is the share of rows a condition keeps; rows = selectivity x `reltuples`. An equality on a common value
uses its frequency; on any other value, the rest of the frequency spread over the other distinct values; a range uses
the histogram. Conditions the statistics cannot read get fixed guesses: 0.5% for `=` and one third for `<` or `>`.

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN SELECT * FROM pl.orders WHERE status = 'failed';        -- about 2000: from most_common_freqs
EXPLAIN SELECT * FROM pl.orders WHERE customer_id = 5;          -- 10: (1 - sum of MCV freqs) / other distinct values
EXPLAIN SELECT * FROM pl.orders WHERE amount > 50;              -- about 100000: from the histogram
EXPLAIN SELECT * FROM pl.orders WHERE amount + 0 = 5;           -- 1000: the 0.005 default for an expression
EXPLAIN SELECT * FROM pl.orders WHERE amount + 0 > 5;           -- 66667: the one-third default
```

An expression or cast on a column hides its statistics; an expression index or expression statistics restore them.

## Why estimates go wrong: correlated columns and extended statistics

The planner multiplies the selectivities of conditions as if columns were independent. `zip` determines `city`, so
`zip = '00042' AND city = 'city4'` keeps all 2,000 rows of that zip, but 1% x 10% gives about 200. Extended
statistics teach the planner the dependency (`dependencies`), distinct combinations for `GROUP BY` (`ndistinct`) and
common value pairs (`mcv`).

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT * FROM pl.orders WHERE zip = '00042' AND city = 'city4';      -- rows=~200, actual 2000
CREATE STATISTICS pl.orders_zip_city (dependencies, ndistinct, mcv) ON zip, city FROM pl.orders;
ANALYZE pl.orders;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT * FROM pl.orders WHERE zip = '00042' AND city = 'city4';      -- rows=~2000, actual 2000
SELECT statistics_name, attnames, kinds, n_distinct, dependencies FROM pg_stats_ext
WHERE statistics_name = 'orders_zip_city';                           -- {"4 => 5": 1.000000}
```

Other causes: statistics older than a bulk load, generic-plan parameters, and functions with no estimator.

## Join methods: nested loop, hash join and merge join

PostgreSQL joins two inputs at a time with one of three methods; the cheapest depends on input sizes, available
indexes and required order.

| Method | Works by | Chosen when |
|---|---|---|
| Nested Loop | for each outer row, look up the inner side (best with an index) | the outer side is small |
| Hash Join | build a hash table on the smaller input, probe with the other | large unsorted inputs, equality only |
| Merge Join | walk two inputs sorted on the join key | both inputs come sorted (indexes) or the result must be sorted |

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN (COSTS OFF) SELECT o.id, c.name FROM pl.orders o JOIN pl.customers c ON c.id = o.customer_id
WHERE o.id < 50;                                                     -- Nested Loop
EXPLAIN (COSTS OFF) SELECT c.tier, sum(o.amount) FROM pl.orders o JOIN pl.customers c ON c.id = o.customer_id
GROUP BY c.tier;                                                     -- Hash Join
EXPLAIN (COSTS OFF) SELECT o.id, c.name FROM pl.orders o JOIN pl.customers c ON c.id = o.customer_id
ORDER BY o.customer_id;                                              -- Merge Join
```

## Join order: join_collapse_limit, from_collapse_limit and GEQO

The planner searches join orders exhaustively while the number of items to join is at most `join_collapse_limit`
(explicit `JOIN`s) and `from_collapse_limit` (subqueries pulled up into `FROM`), both 8 by default. Past those it
keeps the written order for the rest, and at `geqo_threshold` (12) items it switches to the genetic optimizer, which
is faster but not exhaustive. Setting `join_collapse_limit = 1` makes the written order the join order.

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN (COSTS OFF) SELECT count(*) FROM pl.tiers t JOIN pl.customers c ON t.tier = c.tier
JOIN pl.orders o ON c.id = o.customer_id WHERE t.discount = 10 AND o.id < 1000;   -- planner's order
SET join_collapse_limit = 1;
EXPLAIN (COSTS OFF) SELECT count(*) FROM pl.tiers t JOIN pl.customers c ON t.tier = c.tier
JOIN pl.orders o ON c.id = o.customer_id WHERE t.discount = 10 AND o.id < 1000;   -- tiers, customers, then orders
```

## Scan methods and skip scan in PostgreSQL 18

A table is read by a sequential scan, an index scan, an index-only scan or a bitmap scan; `correlation` near 1 or
-1 makes index scans cheaper because matching rows sit together. PostgreSQL 18 adds skip scan: a B-tree on
`(status, created_at)` serves a condition on `created_at` alone by searching once per distinct `status`, and
`EXPLAIN ANALYZE` reports the searches as `Index Searches`.

```sql
SET max_parallel_workers_per_gather = 0;
SET TimeZone = 'UTC';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT count(*) FROM pl.orders WHERE created_at >= '2026-03-01' AND created_at < '2026-03-02';
-- Index Only Scan using orders_status_created_idx ... Index Searches: 7
```

Skip scan pays off only when the leading column has few distinct values (`postgres-indexing`).

## Parallel query

Parallel query splits a scan, join or aggregate across worker processes under a `Gather` or `Gather Merge` node. A
table is considered from `min_parallel_table_scan_size` (8 MB) up, workers per node are capped by
`max_parallel_workers_per_gather` (2), and the plan must beat the serial one after `parallel_setup_cost`.
`Workers Launched` lower than `Workers Planned` means the pool (`max_parallel_workers`, 8) was busy.

```sql
RESET max_parallel_workers_per_gather;                      -- the earlier examples set it to 0
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT status, count(*) FROM pl.orders GROUP BY status;     -- Gather Merge, Workers Planned/Launched, Partial HashAggregate
```

JIT (LLVM compilation of expressions) starts above `jit_above_cost` (100,000) and needs a build with LLVM;
how to see it and why it can be missing from `EXPLAIN`:
[references/cost-and-selectivity.md](references/cost-and-selectivity.md).

## Generic versus custom plans for prepared statements

A prepared statement (and every statement in PL/pgSQL, and most driver queries) is planned with its parameter values
for the first five executions (custom plans). Then a generic plan with `$1` placeholders is built, and used from then
on if its estimated cost is not much higher than the average custom plan. With skewed data that can be the wrong
choice; `plan_cache_mode = force_custom_plan` keeps planning per value.

```sql
SET max_parallel_workers_per_gather = 0;
PREPARE recent(text) AS SELECT id, amount FROM pl.orders WHERE status = $1 ORDER BY created_at DESC LIMIT 10;
EXECUTE recent('failed'); EXECUTE recent('failed'); EXECUTE recent('failed');
EXECUTE recent('failed'); EXECUTE recent('failed');
EXPLAIN (COSTS OFF) EXECUTE recent('failed');               -- Index Cond: (status = $1): generic
PREPARE totals(text) AS SELECT count(*), sum(amount) FROM pl.orders WHERE status = $1;
EXECUTE totals('failed'); EXECUTE totals('failed'); EXECUTE totals('failed');
EXECUTE totals('failed'); EXECUTE totals('failed');
EXPLAIN (COSTS OFF) EXECUTE totals('done');                 -- Filter: (status = 'done'): still custom
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements ORDER BY name;
EXPLAIN (GENERIC_PLAN, COSTS OFF) SELECT count(*) FROM pl.orders WHERE status = $1;   -- PG 16+: see the generic plan
```

`recent` switched to a generic plan because its plan is the same for every value; `totals` stayed custom because
its generic plan costs far more than the cheap `failed` plans.

## Reading row-estimate errors in EXPLAIN ANALYZE

Each node shows `rows=` (estimated, per loop) beside `actual rows=` (measured, per loop; fractional in 18); multiply
by `loops` for totals. Read bottom up and find the lowest node where the two differ by 10x or more: every node above
inherits that error, and a join over an underestimate often picks a nested loop that runs far more often than
planned. Fix the estimate there, then re-check the plan.

## Verify that a planner fix worked

A fix is proven when the estimate moves, not when one run is faster. Compare the same statement before and after, and
check that the statistics you added exist. These ran on 18.6.

```sql
EXPLAIN (ANALYZE, BUFFERS OFF)
SELECT * FROM pl.orders WHERE zip = '00042' AND city = 'city4';   -- rows= close to actual rows=
SELECT relname, last_analyze, last_autoanalyze, n_mod_since_analyze
FROM pg_stat_user_tables WHERE schemaname = 'pl' ORDER BY relname;
SELECT stxname, stxkeys FROM pg_statistic_ext;                    -- the CREATE STATISTICS objects
```

Run a prepared statement at least six times before you judge it, because the first five executions always use custom
plans.

## Gotchas

These are the planner surprises seen most often, each with its cause and fix.

1. **The plan changed with no code change.** `ANALYZE` resampled and an estimate crossed a cost boundary. Make the
   estimate stable: higher statistics target, extended statistics, a better index.
2. **Two conditions estimated at a tiny row count.** Correlated columns multiplied as independent. Add
   `CREATE STATISTICS (dependencies, mcv)` on them.
3. **A query is fast in psql and slow from the application.** The application runs a generic plan. Compare with
   `EXPLAIN (GENERIC_PLAN)` and set `plan_cache_mode` for that role if needed.
4. **No `JIT:` section although the cost is high.** `COSTS OFF` hides it, or there is no LLVM (`pg_jit_available()`).
5. **A many-table query plans slowly or badly.** It passed `join_collapse_limit` or `geqo_threshold`. Raise the
   limits for that session, or write the best order with `join_collapse_limit = 1`.

## Anti-patterns in plan tuning

These change the plan without fixing what made it bad.

| Do not | Do instead |
|---|---|
| Set `enable_nestloop = off` or another `enable_*` switch for the whole server | Fix the row estimate; keep switches for a session while you diagnose |
| Lower `random_page_cost` to force an index | Set it from what the storage does, then fix the estimate |
| Wrap a filtered column in a function or cast | Compare the raw column, or add an expression index or expression statistics |
| Raise `default_statistics_target` for the whole server | Raise it per column with `ALTER COLUMN ... SET STATISTICS` |
| Blame the planner from an `EXPLAIN` without `ANALYZE` | Compare estimated with actual rows, from the lowest node up |

## Checklist

Check these points before you blame the planner.

- [ ] Statistics are fresh (`last_analyze`, `last_autoanalyze`, `n_mod_since_analyze`).
- [ ] The lowest node with a 10x estimate error was found and its cause named.
- [ ] Correlated filter columns have extended statistics.
- [ ] Filtered expressions have an expression index or expression statistics.
- [ ] Prepared statements were checked with their generic plan.

## See also

Related skills in this library, each one works on its own:

- `postgres-query-performance`: the tuning workflow, pg_stat_statements and `work_mem`.
- `postgres-indexing`: which index a plan needs, including skip scan.
- `postgres-internals-mvcc-storage`: pages, the visibility map and index-only scans.
- `postgres-partitioning`: pruning and partition-wise plans.
- `postgres-pg18-features`: what changed in `EXPLAIN` in 18.

## Sources

- https://www.postgresql.org/docs/18/planner-stats.html
- https://www.postgresql.org/docs/18/multivariate-statistics-examples.html
- https://www.postgresql.org/docs/18/view-pg-stats.html
- https://www.postgresql.org/docs/18/view-pg-stats-ext.html
- https://www.postgresql.org/docs/18/sql-analyze.html
- https://www.postgresql.org/docs/18/runtime-config-query.html
- https://www.postgresql.org/docs/18/explicit-joins.html
- https://www.postgresql.org/docs/18/indexes-multicolumn.html
- https://www.postgresql.org/docs/18/parallel-query.html
- https://www.postgresql.org/docs/18/sql-prepare.html
- https://www.postgresql.org/docs/18/sql-explain.html
