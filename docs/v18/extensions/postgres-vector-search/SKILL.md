---
name: postgres-vector-search
description: 'Builds vector similarity search in PostgreSQL with pgvector: vector, halfvec, bit and sparsevec types, distance operators, HNSW versus IVFFlat and their settings, filtered search with iterative index scans, quantization with re-ranking, one embedding table per model, keeping embeddings in sync, recall measurement, and hybrid search with full-text using reciprocal rank fusion. Use when storing embeddings, building semantic search or RAG retrieval, or when a vector query is slow, returns too few rows or misses good matches.'
metadata:
  tags:
  - postgres
  - pgvector
  - embeddings
  - vector-search
  - hnsw
  - ivfflat
  - rag
  - hybrid-search
  - semantic-search
---

# PostgreSQL vector search with pgvector

pgvector adds vector types, distance operators and approximate nearest-neighbour indexes to PostgreSQL, so
embeddings live next to the data they describe and queries can join and filter them with SQL. Versions here:
pgvector 0.8.7 (October 2026). Hybrid vector plus keyword search: [references/hybrid-search.md](references/hybrid-search.md).

## Step 0: check the installed pgvector version

Features differ between versions (iterative scans need 0.8.0), so read what the server has.

```sql
SELECT default_version, installed_version FROM pg_available_extensions WHERE name = 'vector';
CREATE EXTENSION IF NOT EXISTS vector;          -- needs superuser or a managed service's allowlist
ALTER EXTENSION vector UPDATE;                  -- after the server's pgvector package was upgraded
```

## Vector types and their limits

pgvector stores embeddings in four types; the index limit decides what you can search fast.

| Type | Element | Max dims stored | Max dims indexed (HNSW) | Size |
|---|---|---|---|---|
| `vector(n)` | 4-byte float | 16,000 | 2,000 | 4n + 8 bytes |
| `halfvec(n)` | 2-byte float | 16,000 | 4,000 | 2n + 8 bytes |
| `bit(n)` | 1 bit | | 64,000 | n/8 + 8 bytes |
| `sparsevec(n)` | non-zero entries only | 16,000 non-zeros | 1,000 non-zeros | 8 per non-zero + 16 bytes |

Use `halfvec` by default: half the storage and index size with negligible recall loss for typical text embeddings,
and it indexes models up to 4,000 dimensions.

## Distance operators and operator classes

The query's operator must match the index's operator class, or the index is not used.

| Distance | Operator | HNSW / IVFFlat opclass (vector) |
|---|---|---|
| Cosine distance | `<=>` | `vector_cosine_ops` |
| L2 (Euclidean) | `<->` | `vector_l2_ops` |
| Negative inner product | `<#>` | `vector_ip_ops` |
| L1 (taxicab) | `<+>` | `vector_l1_ops` (HNSW only) |
| Hamming (bit) | `<~>` | `bit_hamming_ops` |
| Jaccard (bit) | `<%>` | `bit_jaccard_ops` (HNSW only) |

For `halfvec` and `sparsevec` use the `halfvec_*` and `sparsevec_*` classes. With normalized embeddings (most text
models), inner product gives the same order as cosine and is slightly faster; cosine is the safe default.

## Tables: one embedding table per model

Keep text and embeddings apart, one embedding table per model, so changing models is a new table and a backfill, not
an `ALTER` on live data.

```sql
CREATE TABLE app.chunks (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  doc_id  bigint NOT NULL,
  kind    text NOT NULL,
  body    text NOT NULL
);
CREATE TABLE app.chunk_emb_m1 (                       -- m1 = the embedding model's short name
  chunk_id bigint PRIMARY KEY REFERENCES app.chunks ON DELETE CASCADE,
  emb      halfvec(1024) NOT NULL
);
CREATE INDEX chunk_emb_m1_hnsw ON app.chunk_emb_m1 USING hnsw (emb halfvec_cosine_ops);
```

## HNSW or IVFFlat

Both are approximate indexes: they trade a little recall for speed. HNSW is the default choice.

| | HNSW | IVFFlat |
|---|---|---|
| Recall/speed | better at the same speed | lower; depends on `probes` |
| Build | slower, more memory | faster, needs data before build |
| Empty table | fine to create first | build after loading rows |
| Settings | build: `m` (16), `ef_construction` (64); query: `hnsw.ef_search` (40) | build: `lists`; query: `ivfflat.probes` (1) |

IVFFlat starting points: `lists` = rows / 1000 up to 1M rows, sqrt(rows) above; `probes` = sqrt(lists).

## Building an HNSW index quickly

HNSW builds are fastest when the graph fits in `maintenance_work_mem` and run in parallel.

```sql
SET maintenance_work_mem = '8GB';                 -- the server warns when the graph no longer fits
SET max_parallel_maintenance_workers = 7;         -- plus the leader
CREATE INDEX CONCURRENTLY chunk_emb_m1_hnsw ON app.chunk_emb_m1
  USING hnsw (emb halfvec_cosine_ops) WITH (m = 16, ef_construction = 64);
SELECT phase, round(100.0 * blocks_done / nullif(blocks_total, 0), 1) AS pct
FROM pg_stat_progress_create_index;
```

In Docker, set `--shm-size` at least as large as `maintenance_work_mem`, or parallel builds fail. Load data first,
then build: inserting into an existing HNSW index is much slower per row than a bulk build.

## Querying nearest neighbours

A nearest-neighbour query orders by distance and limits; both are required for the index to be used.

```sql
SELECT c.id, c.body, e.emb <=> $1::halfvec AS distance
FROM app.chunk_emb_m1 e JOIN app.chunks c ON c.id = e.chunk_id
ORDER BY e.emb <=> $1::halfvec
LIMIT 10;
```

`hnsw.ef_search` (40 by default, 1 to 1000) caps how many rows one index scan can return, whatever the `LIMIT` says:
`LIMIT 100` at the default returned 40 rows on a test table, and 100 with `hnsw.ef_search = 200`. Keep it at or above
the `LIMIT`, and turn on an iterative scan for a limit above 1000.

Send the query vector as a parameter in the text form `'[0.1,0.2,...]'` or with the driver helper:
`pgvector` for Python (`register_vector(conn)`), `pgvector` for Node, `pgvector-go`, `pgvector-java`.

## Filtered vector search with iterative index scans

Approximate indexes filter after the scan: with `ef_search` 40 and a filter matching 2% of rows, a `LIMIT 10` query
may return only one or two rows. pgvector 0.8 adds iterative scans, which keep scanning until enough rows pass.

```sql
BEGIN;
SET LOCAL hnsw.iterative_scan = relaxed_order;     -- or strict_order
SET LOCAL hnsw.ef_search = 100;
SET LOCAL hnsw.max_scan_tuples = 20000;            -- default; caps the work
WITH nearest AS MATERIALIZED (
  SELECT e.chunk_id, e.emb <=> $1::halfvec AS distance
  FROM app.chunk_emb_m1 e JOIN app.chunks c ON c.id = e.chunk_id
  WHERE c.kind = $2
  ORDER BY e.emb <=> $1::halfvec
  LIMIT 10
)
SELECT * FROM nearest ORDER BY distance;            -- relaxed_order may return rows slightly out of order
COMMIT;
```

If raising `hnsw.max_scan_tuples` stops helping, the scan is running out of memory: raise `hnsw.scan_mem_multiplier`
(default 1, a multiple of `work_mem`).

- For a few distinct filter values, a partial index per value is exact and fast:
  `CREATE INDEX ... USING hnsw (emb halfvec_cosine_ops) WHERE kind = 'faq'`.
- For a very selective filter (a tenant with 500 rows), a B-tree on the filter column plus exact search is faster
  than the vector index; the planner picks it when statistics are right.
- For many tenants, partition by tenant or tenant group.

## Quantization and re-ranking for large collections

Binary quantization stores one bit per dimension in the index, making it 32 times smaller than `vector`; re-rank the
candidates with the full vectors to recover recall.

```sql
CREATE INDEX chunk_emb_m1_bq ON app.chunk_emb_m1
  USING hnsw ((binary_quantize(emb)::bit(1024)) bit_hamming_ops);

SET LOCAL hnsw.ef_search = 200;                          -- inside a transaction; must cover the candidate LIMIT
SELECT chunk_id FROM (
  SELECT chunk_id, emb FROM app.chunk_emb_m1
  ORDER BY binary_quantize(emb)::bit(1024) <~> binary_quantize($1::halfvec)
  LIMIT 100                                              -- candidates
) candidates
ORDER BY emb <=> $1::halfvec
LIMIT 10;
```

## Verify recall against an exact scan

Recall is the share of the true top-k results the index returns. Measure it on real embeddings and real queries;
random vectors give misleading numbers.

```sql
-- exact top 10 for one query (no index)
BEGIN; SET LOCAL enable_indexscan = off;
SELECT chunk_id FROM app.chunk_emb_m1 ORDER BY emb <=> $1::halfvec LIMIT 10;
COMMIT;
```

Compare with the indexed result for at least 20 to 50 real queries. Raise `hnsw.ef_search` (or rebuild with higher
`m` / `ef_construction`) until recall@10 meets your target (0.95 is common), then check p95 or p99 latency.

## Keeping embeddings in sync with the text

Embeddings go stale when the text they were made from changes. Record what each embedding was made from, and
re-embed in a background job, never inside the user's write transaction (a model call can take seconds).

```sql
ALTER TABLE app.chunk_emb_m1 ADD COLUMN body_hash bytea NOT NULL DEFAULT '\x';
-- the job finds chunks whose text changed since they were embedded
SELECT c.id, c.body FROM app.chunks c
LEFT JOIN app.chunk_emb_m1 e ON e.chunk_id = c.id
WHERE e.chunk_id IS NULL OR e.body_hash <> sha256(convert_to(c.body, 'UTF8'))
ORDER BY c.id LIMIT 100;
-- after the model call
INSERT INTO app.chunk_emb_m1 (chunk_id, emb, body_hash) VALUES ($1, $2, sha256(convert_to($3, 'UTF8')))
ON CONFLICT (chunk_id) DO UPDATE SET emb = EXCLUDED.emb, body_hash = EXCLUDED.body_hash;
```

Chunk long documents before embedding (a few hundred tokens per chunk, split on headings or paragraphs, with a little
overlap), and store `doc_id` on each chunk so results can be grouped back into documents.

## Worked example: "semantic search over our help articles"

The articles are 40,000 chunks embedded with a 1,024-dimension model. Create the extension, the two tables above
(`halfvec(1024)`), load the embeddings with `COPY`, then build the HNSW index with enough `maintenance_work_mem`.
Query with `ORDER BY emb <=> $1::halfvec LIMIT 10`; `EXPLAIN` shows `Index Scan using chunk_emb_m1_hnsw`. Users
filter by product (`kind`), and filtered searches return 3 rows instead of 10: turn on
`hnsw.iterative_scan = relaxed_order` for those queries. Measure recall@10 on 30 real questions against exact
search; it is 0.93, so raise `hnsw.ef_search` to 80, measure 0.97 at 6 ms p95, and keep that setting. Exact-word
queries (error codes, product names) still miss: add full-text search and fuse both lists
([references/hybrid-search.md](references/hybrid-search.md)).

## Checklist

Check these points before you call vector search done.

- [ ] pgvector version known; `halfvec` used unless there is a reason not to.
- [ ] One embedding table per model; the model name and dimension recorded.
- [ ] Index operator class matches the query operator.
- [ ] `hnsw.ef_search` is at least the `LIMIT` of each search, including re-ranking candidates.
- [ ] Zero vectors are refused at write time when using cosine distance.
- [ ] HNSW built after bulk load with enough `maintenance_work_mem`, `CONCURRENTLY` on live tables.
- [ ] Filtered queries use iterative scans, partial indexes, or partitions.
- [ ] Recall and latency measured on real queries; `ef_search` set from the measurement.
- [ ] `ALTER EXTENSION vector UPDATE` run after upgrading the package.

## Gotchas

These are the failures seen most often with vector search, each with its cause and fix.

1. **The vector index is not used.** The query has no `ORDER BY ... LIMIT`, orders by an expression that differs
   from the indexed one, or uses another operator than the opclass (`<->` on a cosine index).
2. **A filtered search returns too few rows.** Post-filtering. Turn on `hnsw.iterative_scan` or use a partial index.
3. **`column cannot have more than 2000 dimensions for hnsw index`.** Use `halfvec` (4,000) or reduce dimensions.
4. **`expected 1024 dimensions, not 768`.** Vectors from another model or a truncated output; one table per model
   prevents mixing.
5. **Index build runs for hours.** The graph does not fit in `maintenance_work_mem`, or parallel workers are off.
6. **Recall dropped after many updates and deletes.** HNSW keeps deleted nodes until vacuum; vacuum regularly, and
   `REINDEX CONCURRENTLY` after very large changes.
7. **A row never comes back from cosine search.** Its vector is all zeros: `<=>` returns `NaN` for it, and neither
   `NULL` nor zero vectors enter a cosine index. Reject zero vectors when writing, or fix what produced them.
8. **A query returns fewer rows than its `LIMIT`, with no filter.** The `LIMIT` is above `hnsw.ef_search`. Raise it.
9. **Latency climbs while CPU sits idle.** The HNSW graph no longer fits in memory and each hop reads from disk. Move
   to `halfvec`, lower `m`, add memory, partition, or use binary quantization with re-ranking.

## Anti-patterns in vector search

Most of these return results that look fine, so only a recall test finds them.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Mixing embedding models in one column | distances between models mean nothing | one table per model |
| Embedding inside the user's write transaction | a model call can take seconds, holding locks | a background job with a hash check |
| Building the index before a bulk load | inserting into HNSW is much slower per row | load first, then build |
| Judging recall on random vectors | the numbers mislead | real embeddings and real questions |
| A global `hnsw.ef_search` raised for one query | every search pays for it | `SET LOCAL` inside the transaction |
| `vector` by default | twice the storage and a 2,000 dimension index limit | `halfvec` |
| Vector search alone for codes and product names | exact tokens are missed | hybrid search with full text |

## See also

Related skills in this library:

- `postgres-full-text-search`: the keyword half of hybrid search
- `postgres-indexing`: other index types
- `postgres-extensions-install`: installing pgvector
- `postgres-multitenancy`: filtering per tenant
- `postgres-python-data`: loading embeddings from Python
