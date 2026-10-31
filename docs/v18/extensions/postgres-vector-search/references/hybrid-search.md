---
title: Hybrid search with pgvector and full-text search
author: MOZGII, Inc.
lang: en
---

# Hybrid search with pgvector and full-text search

This reference combines vector similarity and keyword search in one PostgreSQL query using reciprocal rank fusion
(RRF). Hybrid search finds documents that match the meaning of a question and documents that contain its exact
words (names, codes, error messages), which either method alone misses.

## Tables for hybrid search

Hybrid search needs a text column with a `tsvector` and a GIN index, and an embedding table with a vector index.

```sql
CREATE TABLE app.chunks (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  doc_id  bigint NOT NULL,
  kind    text NOT NULL,
  body    text NOT NULL,
  tsv     tsvector GENERATED ALWAYS AS (to_tsvector('simple', body)) STORED
);
CREATE INDEX chunks_tsv_gin ON app.chunks USING gin (tsv);
CREATE INDEX chunks_body_trgm ON app.chunks USING gin (body gin_trgm_ops);    -- typo-tolerant lookups (pg_trgm)

CREATE TABLE app.chunk_emb_m1 (
  chunk_id bigint PRIMARY KEY REFERENCES app.chunks ON DELETE CASCADE,
  emb      halfvec(1024) NOT NULL
);
CREATE INDEX chunk_emb_m1_hnsw ON app.chunk_emb_m1 USING hnsw (emb halfvec_cosine_ops);
```

The `'simple'` configuration does no stemming, so mixed-language text stays searchable. For one language, use its
configuration (`'english'`, `'german'`) for stemming.

## The reciprocal rank fusion query

RRF scores each result by `1 / (k + rank)` in each list and adds the scores; `k = 60` is the usual constant. It needs
no normalization between cosine distances and text ranks, which live on different scales.

```sql
BEGIN;
SET LOCAL hnsw.iterative_scan = relaxed_order;
SET LOCAL hnsw.ef_search = 100;
WITH semantic AS MATERIALIZED (
  SELECT c.id, row_number() OVER (ORDER BY e.emb <=> $1::halfvec) AS r
  FROM app.chunk_emb_m1 e JOIN app.chunks c ON c.id = e.chunk_id
  WHERE c.kind = $3
  ORDER BY e.emb <=> $1::halfvec
  LIMIT 40
),
keyword AS MATERIALIZED (
  SELECT id, row_number() OVER (ORDER BY ts_rank_cd(tsv, q) DESC) AS r
  FROM app.chunks, websearch_to_tsquery('simple', $2) q
  WHERE tsv @@ q AND kind = $3
  ORDER BY ts_rank_cd(tsv, q) DESC
  LIMIT 40
)
SELECT coalesce(s.id, k.id) AS id,
       coalesce(1.0 / (60 + s.r), 0) + coalesce(1.0 / (60 + k.r), 0) AS score
FROM semantic s FULL JOIN keyword k USING (id)
ORDER BY score DESC
LIMIT 10;
COMMIT;
```

Parameters: `$1` the query embedding, `$2` the user's text, `$3` the filter.

## BM25 and larger vector indexes as extensions

`ts_rank_cd` ranks by term proximity and frequency and knows nothing of how rare a word is across the table. When
relevance needs BM25, or vectors outgrow memory, these extensions change one side of the fusion and leave RRF as it is.
All three were checked on 30 October 2026; `pg_textsearch` and `vectorscale` ran on PostgreSQL 18 in the
`timescale/timescaledb-ha:pg18` image.

| Need | Option | Fits when | Costs |
|---|---|---|---|
| Keyword ranking on one server, no new dependency | built-in `tsvector`, `ts_rank_cd` | good enough on measured questions | no BM25 statistics |
| BM25 ranking in SQL | `pg_textsearch` 1.5.1 (PostgreSQL Licence) | PostgreSQL 17 or 18, `shared_preload_libraries` allowed | a preloaded library; prebuilt binaries for Linux only |
| BM25 with facets and a richer query language | ParadeDB `pg_search` 0.26 (AGPL-3.0) | search is a main feature | AGPL terms, a larger extension |
| Vectors beyond memory, or label filters | `pgvectorscale` 0.9.1 (PostgreSQL Licence), `diskann` index | HNSW no longer fits in RAM | one more extension; check that your host offers it |

`pg_textsearch` uses a `bm25` index and the `<@>` operator, which returns a negative score, so lower is better and the
keyword side orders ascending:

```sql
CREATE EXTENSION IF NOT EXISTS pg_textsearch;                  -- after adding it to shared_preload_libraries
CREATE INDEX chunks_body_bm25 ON app.chunks USING bm25 (body) WITH (text_config = 'english');
SELECT id FROM app.chunks ORDER BY body <@> $1 LIMIT 40;       -- replaces the keyword CTE's ORDER BY
```

`pgvectorscale` filters by labels inside the index when they are stored as `smallint[]`:

```sql
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
CREATE INDEX docs_emb_diskann ON app.docs USING diskann (emb vector_cosine_ops, labels);
SELECT id FROM app.docs WHERE labels && ARRAY[1, 3]::smallint[] ORDER BY emb <=> $1 LIMIT 40;
```

Both searches can also run as two separate statements from the client, in parallel, with the fusion in application
code: latency is the slower of the two instead of their sum, and a connection pool serves each side alone.

## Tuning hybrid search

Tune the inputs to the fusion before adding weights.

- Change each side's candidate `LIMIT` (40 here) first: more candidates raise recall at a small cost. Keep
  `hnsw.ef_search` at or above it.
- Add weights only after measuring: `0.7 / (60 + s.r) + 0.3 / (60 + k.r)` favours semantics.
- Re-rank the fused top 20 to 50 with a cross-encoder model in the application for the best precision.
- Build an evaluation set of real questions with known good answers, and measure recall@10 for vector only, keyword
  only and hybrid before choosing.

## Hybrid search gotchas

These hybrid search problems come up most often, each with its cause and fix.

1. **Keyword side returns nothing for natural questions.** `plainto_tsquery` ANDs every word. `websearch_to_tsquery`
   handles quotes and `or`; for long questions consider OR-ing the terms: `to_tsquery('simple', 'a | b | c')`.
2. **Stemming mismatches.** The index and the query must use the same text search configuration.
3. **Different filters on each side.** Apply the same `WHERE` to both CTEs, or results from excluded rows sneak in
   through one list.
4. **Scores compared across queries.** RRF scores rank results within one query only; do not threshold on them.
