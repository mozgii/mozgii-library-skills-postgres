---
title: EXPLAIN plan nodes explained
author: MOZGII, Inc.
lang: en
---

# EXPLAIN plan nodes explained

This reference explains the plan nodes PostgreSQL shows in `EXPLAIN`, what each costs, and when each one is the
problem.

## Contents

The sections of this reference on eXPLAIN plan nodes explained:

1. Scan nodes
2. Join nodes
3. Aggregation, sorting and limits
4. Parallel query nodes
5. Reading costs and estimates

## 1. Scan nodes

Scan nodes read a table or an index; the choice depends on how many rows the planner expects.

| Node | What it does | Good when | Bad sign |
|---|---|---|---|
| Seq Scan | reads every page of the table | a large share of rows is needed, or the table is small | big table, few rows returned, high `Rows Removed by Filter` |
| Index Scan | walks the index, visits the table for each match | few rows, or rows needed in index order | many rows scattered across pages (many `read` buffers) |
| Index Only Scan | answers from the index alone | all needed columns are in the index | high `Heap Fetches`: visibility map stale, vacuum more |
| Bitmap Index Scan + Bitmap Heap Scan | collects matching row locations, then reads pages in order | a medium share of rows; combining indexes with `BitmapAnd`/`BitmapOr` | `lossy` heap blocks: `work_mem` too small for the bitmap |
| Tid Range Scan | reads a physical range of rows | batch jobs over `ctid` ranges | |

## 2. Join nodes

Join nodes combine two inputs; the planner picks one from estimated sizes.

| Node | How it works | Good when | Bad sign |
|---|---|---|---|
| Nested Loop | for each outer row, look up the inner side | small outer side and an index on the inner join key | outer side estimated at 10 rows, actually 100,000 (`loops=`) |
| Hash Join | builds a hash table of the smaller side, probes with the other | medium to large unsorted inputs, equality joins | `Batches:` above 1: the hash spilled to disk, raise `work_mem` |
| Merge Join | walks two inputs sorted on the join key | both inputs already sorted (indexes) | an explicit Sort below it on a big input |
| Memoize | caches inner results of a nested loop by key | repeated lookups with few distinct keys | high `Evictions` |

## 3. Aggregation, sorting and limits

These nodes shape results; most problems are memory spills or sorting too much.

| Node | Notes |
|---|---|
| Sort | `Sort Method: quicksort Memory:` is in memory; `external merge Disk:` spilled. `top-N heapsort` means a `LIMIT` was pushed in |
| Incremental Sort | input already sorted on a prefix of the keys; cheaper than a full sort |
| HashAggregate | groups with a hash table; `Disk Usage` means a spill |
| GroupAggregate | groups sorted input; often follows a Sort or an index |
| Limit | stops its child early; a slow Limit means the child did lots of work before the first rows |
| WindowAgg | window functions; needs input sorted by the window's `PARTITION BY` / `ORDER BY` |
| Materialize | stores a child's output to rescan it |
| CTE Scan | reads a `MATERIALIZED` CTE |

## 4. Parallel query nodes

Parallel nodes split a scan or aggregate across worker processes.

- `Gather` / `Gather Merge` collect rows from workers. `Workers Planned: 2, Workers Launched: 0` means no worker was
  free (`max_parallel_workers`, `max_worker_processes`).
- `Parallel Seq Scan`, `Parallel Index Scan`, `Parallel Hash` divide the work; per-worker rows are shown per loop.
- Parallelism helps large analytical scans; it rarely helps short OLTP queries.

## 5. Reading costs and estimates

Costs are planner units, not milliseconds; compare them only between plans of the same query.

- `cost=startup..total` is the estimate to the first row and to all rows.
- `rows=` is the estimate per loop; `actual rows=` is the measured value per loop. Multiply by `loops` for totals.
- `width=` is the estimated average row size in bytes.
- The node where estimated and actual rows diverge most is usually where the plan went wrong; fix the estimate there
  (statistics, data types, rewrite) rather than forcing a join method.
- `enable_seqscan = off` and similar settings are for diagnosis in one session only, never for production.
- Visual tools help with big plans: paste `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` into a plan visualizer such as
  explain.dalibo.com or explain.depesz.com (check your data rules before pasting production query text).
