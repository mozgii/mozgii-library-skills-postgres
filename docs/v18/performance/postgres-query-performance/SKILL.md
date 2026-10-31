---
name: postgres-query-performance
description: 'Finds and fixes slow PostgreSQL queries from evidence: pg_stat_statements to rank queries by total time, reading EXPLAIN (ANALYZE, BUFFERS) plans (estimates versus actual rows, loops, spills), generic versus custom plans, statistics and CREATE STATISTICS, work_mem, auto_explain and wait events. Use when "my query is slow", "it is fast in psql but slow in the app", "the plan changed overnight", or before shipping a query that runs often.'
metadata:
  tags:
  - postgres
  - explain
  - performance
  - pg_stat_statements
  - auto_explain
  - statistics
  - query-tuning
---

# PostgreSQL query performance and EXPLAIN

Tune from evidence: find the queries that cost the most in total, read their real plans, change one thing, and
measure again. Node types are explained in [references/explain-nodes.md](references/explain-nodes.md); the
top-query report is [scripts/top-queries.sql](scripts/top-queries.sql).

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: read the server version and what pg_stat_statements has

Plan output and the tools differ by version (`EXPLAIN ANALYZE` includes buffers from 18), and ranking queries needs
`pg_stat_statements`, so read both first. `shared_preload_libraries` needs a superuser or `pg_read_all_settings`.

```sql
SELECT current_setting('server_version') AS version, current_setting('compute_query_id') AS compute_query_id;
SHOW shared_preload_libraries;
SELECT default_version, installed_version FROM pg_available_extensions WHERE name = 'pg_stat_statements';
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('work_mem', 'hash_mem_multiplier', 'plan_cache_mode', 'random_page_cost', 'effective_cache_size',
               'default_statistics_target')
ORDER BY name;
```

## The tuning loop

The tuning loop keeps you from optimizing the wrong query.

1. Rank queries by total time in `pg_stat_statements` (a 5 ms query run a million times beats a 2 s report).
2. Run `EXPLAIN (ANALYZE, BUFFERS)` on the worst one with real parameter values, on production-like data.
3. Find the node where time or row counts jump, and the reason (missing index, bad estimate, spill, wrong join).
4. Make one change: an index, a rewrite, `ANALYZE`, extended statistics, a setting for that query.
5. Re-run the same `EXPLAIN`, compare time and buffers, then watch `pg_stat_statements` after deploy.

## Turning on pg_stat_statements

`pg_stat_statements` records every normalized statement's calls, time, rows and buffer use. It must be preloaded.

```ini
# postgresql.conf (restart required)
shared_preload_libraries = 'pg_stat_statements'
compute_query_id = on
pg_stat_statements.track = top
```

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT round(total_exec_time) AS total_ms, calls, round(mean_exec_time::numeric, 2) AS mean_ms,
       rows, left(query, 80) AS query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
SELECT pg_stat_statements_reset();     -- start a fresh measurement window
```

Managed services (RDS, Cloud SQL, Azure, Supabase, Neon) have it available; enable it in their parameter settings.

## Reading EXPLAIN ANALYZE output

`EXPLAIN` shows the plan the planner chose; `EXPLAIN ANALYZE` runs the query and adds what really happened. In PG 18
`ANALYZE` includes `BUFFERS` by default.

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT o.id, o.total_cents FROM app.orders o
WHERE o.customer_id = 42 AND o.placed_at >= now() - interval '30 days'
ORDER BY o.placed_at DESC LIMIT 20;
```

What to read on each node, inside out:

| Field | Meaning | Red flag |
|---|---|---|
| `rows=` estimated vs `actual rows=` | planner's guess vs truth | off by 10x or more: bad statistics, correlated columns |
| `loops=` | times the node ran; actual time and rows are per loop | a nested loop inner side with `loops=100000` |
| `actual time=a..b` | ms to first row .. last row, per loop | the jump between a child and its parent |
| `Buffers: shared hit / read` | 8 kB pages from cache / from disk | large `read` counts on a hot query |
| `Rows Removed by Filter` | rows read then thrown away | high: an index or a better one is missing |
| `Sort Method: external merge Disk:` | sort spilled to disk | raise `work_mem` for this query, or add an index for the order |
| `Heap Fetches` on Index Only Scan | table visits that the visibility map did not avoid | vacuum is behind |

`EXPLAIN ANALYZE` executes writes. Wrap a write in a transaction you roll back:
`BEGIN; EXPLAIN ANALYZE UPDATE ...; ROLLBACK;`.

## Plans for parameterized queries: generic versus custom

Drivers send prepared statements, and after five executions Postgres may switch to a generic plan that ignores the
parameter values. A query fast in psql but slow from the app often has this cause.

```sql
PREPARE q(bigint) AS SELECT * FROM app.orders WHERE customer_id = $1;
EXPLAIN (ANALYZE) EXECUTE q(42);                 -- run six times and compare plans
SET plan_cache_mode = force_custom_plan;          -- per session or per role, when skewed data needs custom plans
```

## Fixing bad row estimates with statistics

The planner chooses plans from per-column statistics that `ANALYZE` collects. Wrong estimates produce wrong join
orders and scan types.

```sql
ANALYZE app.orders;                                                       -- refresh now
ALTER TABLE app.orders ALTER COLUMN status SET STATISTICS 1000;           -- finer histogram for a skewed column
CREATE STATISTICS orders_cust_status (dependencies, ndistinct, mcv)
  ON customer_id, status FROM app.orders;                                 -- correlated columns
ANALYZE app.orders;
SELECT last_analyze, last_autoanalyze, n_mod_since_analyze
FROM pg_stat_user_tables WHERE relid = 'app.orders'::regclass;
```

- Extended statistics fix estimates for predicates on columns that depend on each other (city and zip code).
- After a bulk load or a major upgrade, run `ANALYZE` (or `vacuumdb --all --analyze-in-stages`) before judging plans.

## Memory for sorts and hashes: work_mem

`work_mem` is the memory each sort or hash node may use before spilling to disk. It is per node per process, so a
high global value multiplies across connections.

```sql
SET LOCAL work_mem = '256MB';      -- inside the transaction of one heavy report only
```

Keep the global value modest (4 to 64 MB depending on RAM and connections) and raise it per query or per role
(`ALTER ROLE reporting SET work_mem = '256MB'`). `hash_mem_multiplier` (default 2) gives hash nodes more.

## Logging slow plans with auto_explain

`auto_explain` logs the plan of every statement slower than a threshold, which catches the slow cases you cannot
reproduce by hand.

```ini
session_preload_libraries = 'auto_explain'     # or shared_preload_libraries
auto_explain.log_min_duration = '500ms'
auto_explain.log_analyze = on                   # real row counts; adds overhead to every query
auto_explain.log_buffers = on
auto_explain.log_timing = off                   # keeps the overhead low
auto_explain.sample_rate = 0.1                  # on busy servers
```

Also set `log_min_duration_statement = '1s'` to log slow statement text, and `log_lock_waits = on`.

## Common slow-query causes and fixes

These causes cover most slow queries seen in applications.

| Plan shows | Cause | Fix |
|---|---|---|
| Seq Scan with high `Rows Removed by Filter` | no usable index | index the filter columns (`postgres-indexing`) |
| Index Scan but slow, many `read` buffers | rows scattered across the table | covering index, or `CLUSTER`/reorder for read-mostly data |
| Nested Loop with huge `loops` | row estimate far too low | `ANALYZE`, extended statistics, check data types match |
| Sort spilling to disk | `work_mem` too small or no index for `ORDER BY` | index matching the sort, or `SET LOCAL work_mem` |
| `OFFSET` large | rows read and discarded | keyset pagination (`postgres-sql-patterns`) |
| Function on an indexed column | index unusable | expression index or rewrite the predicate |
| `count(*)` on a big table | always a full scan of a table or index | cache counts, or estimate from `pg_class.reltuples` |
| Slow only from the app | generic plan, a different `search_path`, or a lock wait | compare `EXPLAIN EXECUTE`; check `pg_stat_activity.wait_event` |

## Checking what a running query waits on

A query can be slow because it waits, not because it works. `pg_stat_activity` shows the wait.

```sql
SELECT pid, now() - query_start AS running, state, wait_event_type, wait_event, left(query, 80) AS query
FROM pg_stat_activity
WHERE state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY query_start;
```

`wait_event_type = Lock` means blocked by another session (`postgres-transactions-locking`); `IO` means disk reads;
`Client` means the application is slow to read results.

## Worked example: "the orders page got slow after we grew"

The tuning loop, run once on a real case, from the ranking to the measured result.

1. `pg_stat_statements` ranked by `total_exec_time` puts
   `SELECT ... FROM app.orders WHERE customer_id = $1 AND status = $2 ORDER BY placed_at DESC LIMIT 20` first: 40% of
   all database time, 3 million calls a day, mean 9 ms.
2. `EXPLAIN (ANALYZE, BUFFERS)` with a real customer id shows `Index Scan using orders_customer_id_idx`,
   `Rows Removed by Filter: 4100` (other statuses) and a `Sort` above it: the index finds the customer but not the
   status or the order.
3. One change: an index that serves the equality columns first, then the sort.
   `CREATE INDEX CONCURRENTLY orders_cust_status_placed_idx ON app.orders (customer_id, status, placed_at DESC);`
4. The same `EXPLAIN` now shows an `Index Scan` with `rows=20`, no `Sort`, and 6 shared buffers instead of 4,000.
5. After the deploy, compare the statement's `mean_exec_time` a day later (0.3 ms), then drop
   `orders_customer_id_idx` only if no other query needs it (the new index serves `customer_id` alone too).

## Verify a query fix with EXPLAIN and pg_stat_statements

Prove the fix twice: once on the plan, once on live numbers. Run the same statement with the same parameters before
and after, then reset that one statement's counters when the change goes live.

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;           -- Buffers fall; the Seq Scan or Sort you targeted is gone
SELECT pg_stat_statements_reset(0, 0, queryid)   -- 0, 0 means every user and database
FROM pg_stat_statements WHERE query LIKE 'SELECT ... FROM app.orders%';
-- after some traffic:
SELECT calls, round(mean_exec_time::numeric, 2) AS mean_ms,
       (shared_blks_hit + shared_blks_read) / calls AS blocks_per_call
FROM pg_stat_statements WHERE query LIKE 'SELECT ... FROM app.orders%';
```

On 18.6, a count on a 200,000-row table went from 5.74 ms and 1,082 blocks a call to 0.32 ms and 202 blocks after its
index. Then run `psql -X -v ON_ERROR_STOP=1 -f scripts/top-queries.sql`: it exits 0 and the statement has dropped down
the list.

## Checklist

Check these points before you call a query tuning change done.

- [ ] The query was chosen from `pg_stat_statements` by total time, not by a hunch.
- [ ] `EXPLAIN (ANALYZE, BUFFERS)` was run with real parameters on realistic data.
- [ ] Estimated and actual rows agree within an order of magnitude at each node.
- [ ] One change at a time, each measured.
- [ ] Writes were explained inside `BEGIN ... ROLLBACK`.
- [ ] `auto_explain` or `log_min_duration_statement` catches regressions in production.

## Gotchas

These are the failures seen most often with a query tuning change, each with its cause and fix.

1. **Fast in psql, slow in the app.** The app uses a generic plan for a prepared statement, a different role
   setting, or waits on a lock. Compare with `PREPARE`/`EXECUTE` and check `pg_stat_activity`.
2. **The plan changed overnight.** Autoanalyze refreshed statistics and crossed a threshold. Pin the good shape with
   an index or extended statistics, not with planner hints.
3. **`EXPLAIN ANALYZE` changed data.** It executes the statement. Use a transaction and roll back.
4. **Timing overhead hides the real cost.** On fast nodes with many loops, `EXPLAIN (ANALYZE, TIMING off)` gives
   honest totals.
5. **Benchmarking on an empty dev database.** Plans on 100 rows tell you nothing about 100 million. Test on a
   production-sized copy or generate data with `generate_series`.
6. **Raising `work_mem` globally causes out-of-memory kills.** It multiplies by nodes and connections; raise it per
   query.

## Anti-patterns in query tuning

These moves look like progress and leave the real cost where it was.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Tuning the slowest query in the log | a rare report can cost less than a 5 ms query run millions of times | rank by `total_exec_time` |
| Reading plain `EXPLAIN` to diagnose | it shows estimates, and the estimate is often what is wrong | `EXPLAIN (ANALYZE, BUFFERS)` with real parameters |
| Several changes in one go | you cannot tell which one helped or hurt | one change, the same `EXPLAIN` again |
| `enable_seqscan = off` server-wide | it changes every other query and hides the bad estimate | fix the estimate with `ANALYZE` or `CREATE STATISTICS`, or add the index |
| Raising `work_mem` globally | it applies per node and per process, so memory multiplies | `SET LOCAL` for one query, or a per-role setting |
| An index for each slow query, unchecked | every index slows writes and vacuum, and a wider one may already serve it | read the plan and the existing indexes first (`postgres-indexing`) |

## See also

Related skills in this library:

- `postgres-indexing`: choosing the index a plan asks for
- `postgres-internals-planner`: how the planner costs a plan
- `postgres-monitoring-observability`: tracking top queries over time
- `postgres-sql-patterns`: rewrites such as keyset pagination
- `postgres-troubleshooting`: when the whole server is slow, not one query
