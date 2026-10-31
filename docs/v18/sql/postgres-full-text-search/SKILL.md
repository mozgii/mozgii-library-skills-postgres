---
name: postgres-full-text-search
description: 'Builds keyword search inside PostgreSQL: tsvector generated columns with weights, GIN indexes, websearch_to_tsquery for search-box input, ranking with ts_rank_cd, highlighting with ts_headline, language configurations and unaccent, prefix and autocomplete search, typo-tolerant matching with pg_trgm, and when to move to a search engine. Use when adding a search box, making ILIKE ''%term%'' fast, matching names with typos, or fixing "syntax error in tsquery".'
metadata:
  tags:
  - postgres
  - full-text-search
  - tsvector
  - gin
  - pg_trgm
  - fuzzy-search
  - unaccent
  - ranking
  - autocomplete
---

# PostgreSQL full-text and fuzzy search

PostgreSQL has two built-in search tools: full-text search (`tsvector`, `tsquery`) matches words after stemming and
ranks documents; `pg_trgm` matches character trigrams, so it handles substrings and typos. Many apps need both. For
meaning-based search, see `postgres-vector-search`.

## Step 0: read the search setup that exists

Read the configuration, the extensions and the indexes first: a search column built with one configuration only
matches queries that use the same one.

```sql
SHOW default_text_search_config;
SELECT name, installed_version FROM pg_available_extensions WHERE name IN ('pg_trgm', 'unaccent', 'pg_search', 'pg_textsearch');
SELECT indexdef FROM pg_indexes WHERE indexdef ~ 'USING (gin|gist)' AND schemaname NOT IN ('pg_catalog');
```

## Choose full-text search, pg_trgm, or both

Pick by what people type: whole words, or fragments and typos.

| Need | Use | Why the other loses |
|---|---|---|
| whole words, stemming, ranking across fields | `tsvector` with GIN | trigrams know nothing about word forms and rank poorly on long text |
| substrings (`ILIKE '%son%'`), typos in short fields | `pg_trgm` with GIN or GiST | full-text search matches lexemes, not fragments |
| a search box over names and long text | both, as in the worked example | either alone misses one kind of input |
| relevance tuning with BM25, facets at scale | a BM25 extension or a search engine | `ts_rank` scores are not BM25 |
| meaning, not words | `postgres-vector-search` | neither understands synonyms by itself |

## Full-text search basics: tsvector and tsquery

A `tsvector` is a document reduced to normalized words (lexemes) with positions; a `tsquery` is a search expression.
`@@` tests whether they match.

```sql
SELECT to_tsvector('english', 'The quick foxes jumped');     -- 'fox':3 'jump':4 'quick':2
SELECT to_tsvector('english', 'The quick foxes jumped') @@ websearch_to_tsquery('english', 'jumping fox');  -- true
```

The text search configuration (`english`, `german`, `simple`, ...) decides stemming and stop words. List them with
`\dF` in psql; `simple` only lowercases.

## A searchable table with weights and a GIN index

Store the `tsvector` in a generated column so it is always current, weight fields by importance, and index it.

```sql
ALTER TABLE app.articles ADD COLUMN search tsvector
  GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(summary, '')), 'B') ||
    setweight(to_tsvector('english', coalesce(body, '')), 'D')
  ) STORED;
CREATE INDEX articles_search_gin ON app.articles USING gin (search);
```

Write the configuration name explicitly (`'english'`) in both the column and the queries. Without it the function
uses `default_text_search_config`, and an expression that depends on a setting cannot be indexed.

## Querying with user input: websearch_to_tsquery

User input must go through a parser that never raises a syntax error. `websearch_to_tsquery` accepts search-engine
syntax: quoted phrases, `or`, and `-` for exclusion.

```sql
SELECT id, title, ts_rank_cd(search, q) AS rank
FROM app.articles, websearch_to_tsquery('english', $1) AS q
WHERE search @@ q
ORDER BY rank DESC, id
LIMIT 20;
-- $1 = 'postgres "point in time" -mysql'
```

| Function | Input | Use |
|---|---|---|
| `websearch_to_tsquery` | free text with quotes, `or`, `-` | search boxes |
| `plainto_tsquery` | plain words, ANDed | simple filters |
| `phraseto_tsquery` | words in order | exact phrases |
| `to_tsquery` | raw syntax `a & (b | c:*)` | built by code, never raw user input |

## Ranking and highlighting results

`ts_rank` scores by word frequency; `ts_rank_cd` also rewards words close together. Both read the weights.

```sql
SELECT id, title,
       ts_headline('english', body, q, 'MaxFragments=2, MinWords=5, MaxWords=20, StartSel=<mark>, StopSel=</mark>') AS snippet
FROM (
  SELECT id, title, body, q, ts_rank_cd(search, q) AS rank
  FROM app.articles, websearch_to_tsquery('english', $1) q
  WHERE search @@ q
  ORDER BY rank DESC LIMIT 20
) top
ORDER BY rank DESC;
```

`ts_headline` re-parses the whole document and is slow: call it only on the final page of results, as here. Escape
the snippet before putting it into HTML if the text can contain markup.

## Accents and custom configurations

Searching "cafe" should find "café". The `unaccent` extension strips accents; wire it into a custom configuration so
both the index and the queries use it.

```sql
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE TEXT SEARCH CONFIGURATION app_english (COPY = english);
ALTER TEXT SEARCH CONFIGURATION app_english
  ALTER MAPPING FOR hword, hword_part, word WITH unaccent, english_stem;
SELECT to_tsvector('app_english', 'Café crème');     -- 'cafe':1 'creme':2
```

For many languages in one table, store the language per row. Casting a text column in the expression fails: with
`to_tsvector(lang::regconfig, body)` a generated column stops with `generation expression is not immutable`, and an
index with the same expression is refused. A column of type `regconfig` works, because `to_tsvector(regconfig, text)`
is immutable, but `pg_upgrade` refuses a user table with a `regconfig` column (`reg* data types`), so a later major
upgrade needs a dump and restore or the column changed first. A text column through an immutable function keeps
`pg_upgrade` open; this ran on 18.6:

```sql
CREATE FUNCTION app.ts_config(p_lang text) RETURNS regconfig
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN CASE p_lang WHEN 'de' THEN 'german'::regconfig WHEN 'fr' THEN 'french'::regconfig ELSE 'english'::regconfig END;

CREATE TABLE app.docs (
  id     bigint PRIMARY KEY,
  lang   text NOT NULL,
  body   text,
  search tsvector GENERATED ALWAYS AS (to_tsvector(app.ts_config(lang), body)) STORED
);
-- with a regconfig column instead: lang regconfig NOT NULL DEFAULT 'english', then to_tsvector(lang, body)
```

Or use `simple` plus `unaccent` and accept no stemming.

## Prefix search and autocomplete

Prefix matching finds words that start with what the user has typed so far. A tsquery term with `:*` matches
prefixes and uses the GIN index. User input must not reach `to_tsquery`: `plainto_tsquery` first reduces it to clean
terms, and the cast then adds `:*` to the last term, the one still being typed. `nullif` turns empty input into a
query that matches nothing.

```sql
SELECT id, title FROM app.articles
WHERE search @@ (nullif(plainto_tsquery('simple', $1)::text, '') || ':*')::tsquery
LIMIT 10;
-- $1 = 'postgr'         →  'postgr':*                matches postgres, postgresql
-- $1 = 'wireless head'  →  'wireless' & 'head':*
-- $1 = 'foo & bar | !'  →  'foo' & 'bar':*           operators are gone
-- $1 = '' or '((('      →  NULL, no rows and no syntax error
```

`quote_literal` does not make this safe: `to_tsquery('english', quote_literal('a\b') || ':*')` returned
`'e':* <2> 'b':*`, because the backslash makes it write `E'a\\b'`. `simple` leaves the typed word alone, which is what a
prefix needs. A prefix longer than a stem still misses: an `english` column stores `running` as `'run'`, so `run:*`
matches and `runni:*` does not (on 18.6). When autocomplete must match letter by letter, search a
`to_tsvector('simple', title)` column or a trigram index.

For autocomplete on short fields (names, titles) a trigram or `text_pattern_ops` index on the field is often simpler.

## Fuzzy and substring search with pg_trgm

`pg_trgm` splits text into three-character pieces and compares them, so it finds substrings (`ILIKE '%son%'`) and
near matches with typos ("Jonh" for "John").

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX customers_name_trgm ON app.customers USING gin (name gin_trgm_ops);

SELECT id, name FROM app.customers WHERE name ILIKE '%' || $1 || '%' LIMIT 20;      -- substring, indexed
SELECT id, name, similarity(name, $1) AS sim
FROM app.customers WHERE name % $1                                                  -- similar enough
ORDER BY sim DESC LIMIT 10;
SELECT id, name FROM app.customers ORDER BY name <-> $1 LIMIT 10;                  -- nearest by trigram distance (GiST)
```

- `%` uses `pg_trgm.similarity_threshold` (0.3). `word_similarity` and `<%` match a short query inside a long text.
- For `ORDER BY name <-> $1` with an index, use a GiST index (`gist_trgm_ops`); GIN is faster for filtering.
- Patterns shorter than three characters cannot use the trigram index well.

## When to use a dedicated search engine

Postgres search is enough for most application search boxes up to millions of documents. Consider a dedicated
engine (Elasticsearch, OpenSearch, Meilisearch, Typesense) or a BM25 extension (ParadeDB `pg_search`, `pg_textsearch`) when you need
BM25 relevance tuning, facets over huge result sets, typo tolerance across whole documents, or search load that would
compete with transactional work.

## Worked example: "our product search is ILIKE '%term%' and takes 2 seconds"

The catalog has 3 million products and the search box runs `WHERE name ILIKE '%' || $1 || '%'`, a sequential scan.
People type whole words ("wireless headphones") and fragments with typos ("hedphones"). Use both tools:

```sql
ALTER TABLE app.products ADD COLUMN search tsvector GENERATED ALWAYS AS (
  setweight(to_tsvector('english', coalesce(name, '')), 'A') ||
  setweight(to_tsvector('english', coalesce(description, '')), 'C')) STORED;
CREATE INDEX CONCURRENTLY products_search_gin ON app.products USING gin (search);
CREATE INDEX CONCURRENTLY products_name_trgm ON app.products USING gin (name gin_trgm_ops);

-- words first; fall back to trigram word similarity when the word search finds nothing
SELECT id, name FROM app.products, websearch_to_tsquery('english', $1) q
WHERE search @@ q ORDER BY ts_rank_cd(search, q) DESC, id LIMIT 20;
SELECT id, name FROM app.products
WHERE $1 <% name ORDER BY word_similarity($1, name) DESC, id LIMIT 20;   -- a fragment inside a long name
```

`<%` passes when `word_similarity` reaches `pg_trgm.word_similarity_threshold` (0.6): "hedphones" scores 0.62
against "Wireless Headphones X2", "hedphon" only 0.45. Lower it per query (`SET LOCAL
pg_trgm.word_similarity_threshold = 0.4`) when short typos must match. Adding the `STORED` column rewrites the table, so run it in a quiet window or add a plain column, backfill it in
batches and keep it current with a trigger. Both queries now use their GIN index and answer in milliseconds.

## Verify search results and index use

Prove three things on real data: the index is used, hostile input cannot raise an error, and the plan stays cheap.

```sql
EXPLAIN (ANALYZE) SELECT id FROM app.articles, websearch_to_tsquery('english', 'wireless') q
WHERE search @@ q LIMIT 20;                           -- expect Bitmap Index Scan on articles_search_gin
SELECT websearch_to_tsquery('english', $$foo & bar | ! (('$$);     -- returns a query, never a syntax error
SELECT plainto_tsquery('simple', $$O'Brien\$$);       -- 'o' & 'brien'
```

Compare a few real searches with the expected top result, then repeat them after any change to configuration or
weights.

## Checklist

Check these points before you call full-text search done.

- [ ] The `tsvector` is a stored generated column with an explicit configuration and weights.
- [ ] A GIN index exists on it; queries use the same configuration.
- [ ] User input goes through `websearch_to_tsquery`, never `to_tsquery`.
- [ ] `ts_headline` runs only on the returned page.
- [ ] Accented languages use an `unaccent` configuration.
- [ ] Substring and typo search uses `pg_trgm` with a GIN (filter) or GiST (ordering) index.
- [ ] Upgrading a non-libc cluster to PG 18: FTS and `pg_trgm` indexes reindexed.

## Gotchas

These are the failures seen most often with full-text search, each with its cause and fix.

1. **`syntax error in tsquery`.** Raw user input passed to `to_tsquery`. Use `websearch_to_tsquery`.
2. **The search index is not used.** The query omits the configuration or uses a different one from the indexed
   expression.
3. **Searching "running" misses "ran".** Stemmers handle suffixes, not irregular forms; add a synonym or thesaurus
   dictionary if it matters.
4. **`ILIKE '%x%'` is slow.** B-tree cannot serve it. Add a `gin_trgm_ops` index.
5. **Results change after upgrading to PG 18.** FTS and `pg_trgm` now follow the cluster's default collation
   provider; reindex those indexes on clusters whose provider is not libc.
6. **Ranking is slow on large matches.** `ts_rank` reads every matching row's vector. Limit candidates first or
   pre-filter by a more selective condition.

## Anti-patterns in full-text search

| Do not | Do this instead |
|---|---|
| pass user input to `to_tsquery`, quoted or not | `websearch_to_tsquery`, or `plainto_tsquery` plus a cast for prefixes |
| omit the configuration name | write `'english'` in the column and in the queries |
| compute `to_tsvector` per row at query time | a stored generated column with a GIN index |
| call `ts_headline` on every match | call it on the final page only |
| cast a text column to `regconfig` in an index | an immutable function over the text column |
| run `ILIKE '%x%'` with no trigram index | a `gin_trgm_ops` index |

## See also

- `postgres-vector-search`: meaning-based and hybrid search.
- `postgres-indexing`: GIN, GiST and index maintenance.
- `postgres-sql-patterns`: paging search results.
- `postgres-query-performance`: reading the plans.
- `postgres-pg18-features`: the collation change for full-text search in 18.

## Sources

- https://www.postgresql.org/docs/18/textsearch.html and /textsearch-controls.html, /textsearch-tables.html
- https://www.postgresql.org/docs/18/pgtrgm.html and /unaccent.html
- https://www.postgresql.org/docs/18/pgupgrade.html; `src/bin/pg_upgrade/check.c` (REL_18_6, the reg* type check)
- Run on 18.6: the prefix query with hostile input, the language function, the `regconfig` column.
