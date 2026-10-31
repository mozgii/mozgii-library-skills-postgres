---
name: postgres-sql-json
description: 'Works with JSON in plain PostgreSQL SQL: json versus jsonb, the operators -> ->> #> #>> @> ? ?| ?&, jsonpath with jsonb_path_query, filters, .datetime() and lax versus strict mode, the SQL/JSON functions JSON_TABLE, JSON_VALUE, JSON_QUERY, JSON_EXISTS, IS JSON and the JSON() constructors, building JSON with jsonb_build_object, jsonb_agg and jsonb_object_agg, updating with jsonb_set, jsonb_insert, ||, - and #-, subscripting, GIN jsonb_ops versus jsonb_path_ops and expression indexes, and when to move fields into columns. Use when querying or reshaping JSON documents in SQL, a JSON query ignores its index, a jsonpath returns nothing or errors, or turning a JSON array into rows.'
metadata:
  tags:
  - postgres
  - json
  - jsonb
  - jsonpath
  - json_table
  - sql-json
  - gin
---

# PostgreSQL JSON in SQL: jsonb, jsonpath and SQL/JSON

Store documents as `jsonb`, query them with containment (`@>`) or jsonpath (`@?`, `@@`) when a GIN index should
help, extract scalars with `->>` or `JSON_VALUE` and cast them, and move any field you filter, join, sort or
constrain on every query into a real column. When to use JSONB in a schema and the basic operator list are in
`postgres-schema-design` (references/jsonb.md); this skill goes into the exact semantics, the SQL/JSON standard
functions, updates and indexing proofs. Full jsonpath and constructor detail:
[references/jsonpath-and-constructors.md](references/jsonpath-and-constructors.md).

## Step 0: read the server version and where JSON lives

`JSON_TABLE` and the SQL/JSON query functions need 17, and casting a jsonb `null` to a scalar changed in 18, so read
the version, then the JSON columns and the GIN indexes already on them.

```sql
SELECT current_setting('server_version_num')::int AS version_num;       -- 180006 = 18.6
SELECT table_schema, table_name, column_name, data_type FROM information_schema.columns
WHERE data_type IN ('json', 'jsonb') AND table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2, 3;
SELECT schemaname, tablename, indexname, indexdef FROM pg_indexes
WHERE indexdef ILIKE '%using gin%' AND schemaname NOT IN ('pg_catalog', 'information_schema');
```

## Demo table for the examples

The examples run in order on PostgreSQL 18.6 against 30,000 generated event documents.

```sql
CREATE SCHEMA sj;
CREATE TABLE sj.events (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc jsonb NOT NULL);
INSERT INTO sj.events (doc)
SELECT jsonb_build_object(
         'type',   (ARRAY['view','click','buy'])[1 + g % 3],
         'user',   jsonb_build_object('id', g % 1000),
         'amount', g % 500,
         'tags',   CASE WHEN g % 100 = 0 THEN '["vip"]'::jsonb ELSE '[]'::jsonb END,
         'at',     to_char(timestamptz '2026-10-01 00:00+00' + g * interval '1 minute',
                           'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
FROM generate_series(1, 30000) g;
ANALYZE sj.events;
```

## json versus jsonb

`json` stores the input text as written and re-parses it on every access; `jsonb` stores a parsed binary tree.
Pick `jsonb` unless you must return the exact original text.

| Property | `json` | `jsonb` |
|---|---|---|
| Duplicate keys | kept | last value wins |
| Key order and whitespace | kept | keys sorted (shorter first, then bytewise), whitespace dropped |
| Numbers | text as written | `numeric`: `1.10` is kept, and equals `1.1` |
| Operators `@>`, `?`, jsonpath `@?` `@@`, GIN | no | yes |
| Equality and B-tree ordering | no `=` operator | yes |
| Size of `{"a":1}` (`pg_column_size`) | 11 bytes | 28 bytes |

```sql
SELECT '{"b":1,"a":2,"a":3,"aa":0}'::json  AS as_json,
       '{"b":1,"a":2,"a":3,"aa":0}'::jsonb AS as_jsonb,
       '1.10'::jsonb = '1.1'::jsonb AS numeric_equal,
       pg_column_size('{"a":1}'::json) AS json_bytes, pg_column_size('{"a":1}'::jsonb) AS jsonb_bytes;
```

## jsonb operators and their exact semantics

The `jsonb` operators read paths, test containment and test keys. Each row below was run on 18.6.

| Operator | Meaning | Example | Result |
|---|---|---|---|
| `->` | field or array element as `jsonb`; negative index counts from the end | `'[1,2,3]'::jsonb -> -1` | `3` |
| `->>` | same, as `text` | `doc->>'type'` | `buy` |
| `#>` / `#>>` | path as a text array, `jsonb` / `text` | `'{"a":{"b":[10,20]}}' #>> '{a,b,1}'` | `20` |
| `@>` / `<@` | left contains right / is contained | `'{"a":[1,2]}' @> '{"a":[2]}'` | true |
| `?` | top-level key, or string element of a top-level array | `'["x","y"]' ? 'x'` | true |
| `?|` / `?&` | any / all of the keys exist | `'{"a":1}' ?& array['a','z']` | false |
| `@?` | jsonpath returns any item | `doc @? '$.tags[*] ? (@ == "vip")'` | |
| `@@` | jsonpath predicate is true | `doc @@ '$.amount > 490'` | |

Containment is structural: array order and duplicates do not matter, a nested array must be matched by an array
(`'[1,2,[3]]' @> '[3]'` is false, `@> '[[3]]'` is true), and as a special case an array contains a bare scalar
(`'["foo"]' @> '"foo"'` is true). `?` sees only the top level: `'{"a":{"x":1}}' ? 'x'` is false.

```sql
SELECT '[1,2,[3]]'::jsonb @> '[3]' AS flat, '[1,2,[3]]'::jsonb @> '[[3]]' AS nested,
       '["foo"]'::jsonb @> '"foo"' AS scalar_in_array, '{"a":{"x":1}}'::jsonb ? 'x' AS nested_key;
```

A JSON `null` is a value, not SQL `NULL`: `->` returns the jsonb `null`, `->>` returns SQL `NULL`, and since
PostgreSQL 18 casting a jsonb `null` to a scalar type gives SQL `NULL` instead of an error.

```sql
SELECT '{"a":null}'::jsonb -> 'a' AS json_null, ('{"a":null}'::jsonb -> 'a')::int AS cast_18,
       '{"a":null}'::jsonb ->> 'a' IS NULL AS sql_null;
```

## jsonpath queries: filters, variables and lax versus strict mode

A jsonpath expression walks a document: `$` is the root, `.key` and `[*]` step down, `? (...)` filters with `@` as
the current item, and `$name` reads a variable passed as a JSON object. `jsonb_path_query` returns a row per item,
`jsonb_path_query_array` and `_first` return one value, `jsonb_path_exists` and `jsonb_path_match` return booleans.

```sql
SELECT jsonb_path_query('{"a":[1,2,3,4]}', '$.a[*] ? (@ > $min)', '{"min": 2}') AS item;
SELECT jsonb_path_query('{"a":{"k":1,"j":2}}', '$.a.keyvalue()') AS pair;
SELECT jsonb_path_query('{"s":"abc"}', '$.s ? (@ like_regex "^A" flag "i")') AS regex,
       jsonb_path_query('{"s":"abc"}', '$.s ? (@ starts with "ab")') AS prefix;
```

Lax mode (the default) unwraps arrays automatically and turns structural errors into empty results; strict mode
requires the path to match the document exactly and raises errors for missing keys.

| Path on `{"a":[1,2,3,4]}` or `{"a":1}` | lax | strict |
|---|---|---|
| `$.a ? (@ > 2)` on the array | `[3, 4]` (array unwrapped) | `[]` (the filter compares the whole array) |
| `$.b` (missing key) | no rows | error `JSON object does not contain key "b"` |

```sql
SELECT jsonb_path_query_array('{"a":[1,2,3,4]}', 'lax $.a ? (@ > 2)')    AS lax,
       jsonb_path_query_array('{"a":[1,2,3,4]}', 'strict $.a ? (@ > 2)') AS strict,
       jsonb_path_exists('{"a":1}', 'strict $.b', silent => true)        AS silenced;
```

`.datetime()` parses ISO strings into date and time values for comparison. Comparing a value without a zone to one
with a zone needs the `_tz` variants, which read the session `TimeZone` and are therefore only `STABLE`.

```sql
SELECT count(*) FROM sj.events
WHERE jsonb_path_exists_tz(doc, '$.at.datetime() ? (@ >= "2026-10-20T00:00:00Z".datetime())');
```

## SQL/JSON query functions: JSON_VALUE, JSON_QUERY and JSON_EXISTS

The SQL-standard query functions (PostgreSQL 17+) take a jsonpath and say what to do with empty and failing results.
`JSON_VALUE` returns one scalar, cast with `RETURNING`; `JSON_QUERY` returns JSON; `JSON_EXISTS` returns a boolean.
Without `ON EMPTY` / `ON ERROR` clauses, `JSON_VALUE` and `JSON_QUERY` return SQL `NULL` and `JSON_EXISTS` returns
false.

```sql
SELECT JSON_VALUE('{"a":"12"}', '$.a' RETURNING int)                           AS v,
       JSON_VALUE('{"a":"x"}', '$.a' RETURNING int DEFAULT -1 ON ERROR)         AS bad,
       JSON_VALUE('{}', '$.a' DEFAULT 0 ON EMPTY)                               AS missing,
       JSON_QUERY('{"a":[1,2]}', '$.a[*]' WITH WRAPPER)                         AS wrapped,
       JSON_QUERY('{"a":"x"}', '$.a' RETURNING text OMIT QUOTES)                AS unquoted,
       JSON_EXISTS('{"a":[1,5]}', '$.a[*] ? (@ > 4)')                           AS any_over_4;
```

Several items without `WITH WRAPPER` are an error, silently turned into `NULL`; write `ERROR ON ERROR` while
developing so mistakes surface.

```sql
-- error: JSON path expression in JSON_QUERY must return single item when no wrapper is requested
SELECT JSON_QUERY('{"a":[1,2]}', '$.a[*]' ERROR ON ERROR);
```

## JSON_TABLE: turning JSON into rows and typed columns

`JSON_TABLE` (PostgreSQL 17+) turns a JSON document into a relational table in `FROM`: a row path selects the
rows, each column has a type and a path, `FOR ORDINALITY` numbers rows, `EXISTS PATH` gives a boolean, and
`NESTED PATH` joins child arrays. A bad value in one column falls back to its `DEFAULT ... ON ERROR`.

```sql
SELECT jt.*
FROM JSON_TABLE(
  '{"items":[{"sku":"A1","qty":2,"tags":["x","y"]},{"sku":"B2","qty":"oops"}]}',
  '$.items[*]' COLUMNS (
    ord      FOR ORDINALITY,
    sku      text    PATH '$.sku',
    qty      int     PATH '$.qty' DEFAULT 0 ON ERROR,
    has_tags boolean EXISTS PATH '$.tags',
    NESTED PATH '$.tags[*]' COLUMNS (tag text PATH '$'))) AS jt;
```

Older set-returning functions fit simple cases: `jsonb_to_recordset` maps objects by key name, and
`jsonb_array_elements(...) WITH ORDINALITY` keeps positions.

```sql
SELECT * FROM jsonb_to_recordset('[{"id":1,"name":"a"},{"id":2}]') AS r(id int, name text);
SELECT e.ordinality, e.value FROM jsonb_array_elements('["x","y"]') WITH ORDINALITY AS e;
```

## Building JSON from rows

Build JSON in SQL with `jsonb_build_object`, `jsonb_agg` (with its own `ORDER BY` and `FILTER`) and
`jsonb_object_agg`, or the standard `JSON_OBJECT`, `JSON_ARRAY`, `JSON_ARRAYAGG`, `JSON_OBJECTAGG`. `jsonb_agg` keeps
`NULL`s as `null`; `jsonb_agg_strict` drops them; `jsonb_object_agg_unique` refuses duplicate keys.

```sql
SELECT doc->>'type' AS type,
       jsonb_build_object('events', count(*), 'total', sum((doc->>'amount')::int)) AS summary,
       jsonb_agg(id ORDER BY id DESC) FILTER (WHERE doc->'tags' ? 'vip') AS vip_ids
FROM sj.events WHERE id <= 300 GROUP BY 1 ORDER BY 1;

SELECT JSON_OBJECT('a': 1, 'b': NULL ABSENT ON NULL) AS std_object,
       JSON_ARRAY(1, NULL, 'x' NULL ON NULL) AS std_array,
       to_jsonb(r) AS whole_row
FROM (SELECT 1 AS id, 'x' AS name) r;
```

Returning nested JSON for a list without N+1 queries is in `postgres-sql-patterns`.

## Updating jsonb: jsonb_set, jsonb_insert, ||, - and subscripting

Every `jsonb` update writes a new copy of the whole value; the functions differ in what the copy holds.

| Expression | Result |
|---|---|
| `jsonb_set('{"a":{"b":1}}', '{a,c}', '2')` | `{"a": {"b": 1, "c": 2}}`: adds the last key if missing |
| `jsonb_set('{"a":{"b":1}}', '{x,y}', '2')` | unchanged: earlier path steps must exist |
| `jsonb_set(doc, '{a}', NULL)` | SQL `NULL`: the whole value is lost (strict function) |
| `jsonb_set_lax('{"a":1}', '{a}', NULL, true, 'delete_key')` | `{}`; default `'use_json_null'` gives `{"a": null}` |
| `jsonb_insert('{"a":[1,3]}', '{a,1}', '2')` | `{"a": [1, 2, 3]}`; `true` as 4th argument inserts after |
| `'{"a":1,"b":{"c":1}}' || '{"b":{"d":2}}'` | `{"a": 1, "b": {"d": 2}}`: top-level merge, nested objects replaced |
| `'["x","y","x"]'::jsonb - 'x'` | `["y"]`: removes every matching string element |
| `'{"a":{"b":1,"c":2}}'::jsonb #- '{a,b}'` | `{"a": {"c": 2}}` |
| `jsonb_strip_nulls('{"a":null,"b":[1,null]}', true)` | `{"b": [1]}`: PG 18 argument also strips array nulls |

Subscripting assigns a path and creates missing levels: an object key path creates nested objects, and an array
index past the end pads with `null`. Assigning a key into a scalar fails.

```sql
CREATE TABLE sj.docs (id int PRIMARY KEY, j jsonb);
INSERT INTO sj.docs VALUES (1, '{"a":[1]}'), (2, '{"n":5}');
UPDATE sj.docs SET j['a'][3] = '9' WHERE id = 1;          -- {"a": [1, null, null, 9]}
UPDATE sj.docs SET j['x']['y'] = '1' WHERE id = 2;        -- {"n": 5, "x": {"y": 1}}
UPDATE sj.docs SET j = jsonb_set(j, '{n}', to_jsonb((j->>'n')::int + 1)) WHERE id = 2;
SELECT id, j FROM sj.docs ORDER BY id;
```

## Indexing JSON: GIN jsonb_ops, jsonb_path_ops and expression indexes

A GIN index on `jsonb` serves containment and jsonpath operators; which ones depends on the operator class. On the
demo data the `jsonb_path_ops` index is a third smaller (2,144 kB against 3,208 kB).

| Operator class | Serves | Index items |
|---|---|---|
| `jsonb_ops` (default) | `@>`, `@?`, `@@`, `?`, `?|`, `?&` | one per key and per value |
| `jsonb_path_ops` | `@>`, `@?`, `@@` | one hash per value with its key path; no entries for `{}` or `[]` |
| B-tree on an expression | `=`, `<`, `ORDER BY` on `(doc->>'k')` or a cast of it | one per row |

```sql
CREATE INDEX events_doc_gin  ON sj.events USING gin (doc);
CREATE INDEX events_doc_pgin ON sj.events USING gin (doc jsonb_path_ops);
CREATE INDEX events_user_idx ON sj.events (((doc->'user'->>'id')::int));
ANALYZE sj.events;
SELECT pg_size_pretty(pg_relation_size('sj.events_doc_gin'))  AS jsonb_ops,
       pg_size_pretty(pg_relation_size('sj.events_doc_pgin')) AS jsonb_path_ops;
```

For jsonpath, GIN extracts only `accessors == constant` clauses. An equality filter reads 60 index entries; a range
filter makes the index return every row (30,000) for a recheck, so it saves nothing.

```sql
SET enable_seqscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT count(*) FROM sj.events WHERE doc @? '$.amount ? (@ == 491)';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT count(*) FROM sj.events WHERE doc @? '$.amount ? (@ > 490)';
```

`doc->>'type' = 'buy'` can never use GIN; it needs an expression B-tree or the rewrite `doc @> '{"type":"buy"}'`.
Containment estimates come from a histogram of whole documents and can be far off: on this data the planner
expects 3 rows for `{"type":"buy"}` and finds 10,000. An expression index gives `ANALYZE` real statistics for that
expression.

```sql
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT id FROM sj.events WHERE doc @> '{"type":"buy"}';
SELECT n_distinct FROM pg_stats WHERE tablename = 'events_user_idx';    -- 1000: statistics on the expression
```

## When to normalise JSON into columns

Move a field out of `jsonb` into a typed column when any of these is true; keep the rest in the document.

| Signal | Why a column wins |
|---|---|
| filtered, joined or sorted in most queries | real statistics, B-tree, no casts |
| must be unique, a foreign key or `NOT NULL` | constraints work on columns only |
| updated often in a large document | each update rewrites the whole TOASTed value (`postgres-internals-mvcc-storage`) |
| needed in an aggregate over many rows | no parse per row |

A stored generated column (`GENERATED ALWAYS AS (doc->>'type') STORED`) promotes a field without changing writers.

## Gotchas

These are the JSON failures seen most often, each with its cause and fix.

1. **A JSON query ignores the GIN index.** It uses `->>` with `=`, a jsonpath range filter, or `?` on a
   `jsonb_path_ops` index. Rewrite to `@>`, add an expression B-tree, or use `jsonb_ops` for key tests.
2. **`jsonb_set` emptied a column.** A `NULL` new value makes the result `NULL`. Use `jsonb_set_lax` or
   `coalesce(new, 'null')`.
3. **`JSON_VALUE` returns `NULL` with no hint.** The default is `NULL ON ERROR`. Add `ERROR ON ERROR` to see why.
4. **`cannot convert value from timestamp to timestamptz without time zone usage`.** A `.datetime()` comparison
   mixes zoned and unzoned values. Use the `_tz` function or put a zone in both strings.
5. **`JSON_SERIALIZE` of a `jsonb` value returns one byte (`\x01`) on 18.6.** Seen on macOS and Linux builds; the
   docs say it accepts any JSON type. Use `doc::text` or `JSON_SERIALIZE(doc::json)`.
6. **`->>` comparisons sort as text.** `'10' < '9'`. Cast: `(doc->>'n')::int`, with parentheses around `->>`.

## Anti-patterns with JSON in SQL

These keep working on small data and become the slow or wrong part later.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| `json` by default | it re-parses on every read and has no GIN, `@>` or `=` | `jsonb`, unless the exact text must be kept |
| Building JSON by concatenating strings | one quote in a value breaks the document, or injects into it | `jsonb_build_object` or `to_jsonb` |
| A whole table in one `jsonb` document | each update rewrites the value, and there are no constraints or statistics | typed columns, with `jsonb` for the rest |
| A big GIN index for range filters | jsonpath ranges make it return every row | an expression B-tree on the cast value |
| `NULL ON ERROR` left as the default in a data pipeline | bad documents turn into silent `NULL`s | `ERROR ON ERROR`, or count the `NULL`s |
| Comparing `->>` results without a cast | numbers compare as text | `(doc->>'n')::int` |

## Verify JSON shapes and index use

Check the data before the query: a key with mixed types makes casts fail on one row in a million. On the demo table,
on 18.6, with the indexes from the section above:

```sql
SELECT jsonb_typeof(doc) AS kind, count(*) FROM sj.events GROUP BY 1;                 -- object, 30000
SELECT count(*) FROM sj.events
WHERE jsonb_typeof(doc->'amount') IS DISTINCT FROM 'number';                          -- 0: safe to cast
EXPLAIN (ANALYZE, COSTS OFF) SELECT count(*) FROM sj.events
WHERE doc @> '{"type": "buy", "user": {"id": 7}}';                                    -- Bitmap Index Scan on a GIN index
EXPLAIN (ANALYZE, COSTS OFF) SELECT count(*) FROM sj.events
WHERE doc @? '$.amount ? (@ > 495)';                                                  -- Seq Scan: GIN cannot serve >
```

A filter you expected to use an index and that shows `Seq Scan` needs `@>`, `@?` with `==`, or an expression index that
matches it exactly. Test on realistic data: with few rows the planner picks a sequential scan for every query.

## Checklist

Check these points before you ship a query or schema that uses JSON.

- [ ] The column is `jsonb`, unless the exact text must be kept.
- [ ] Every indexed predicate uses `@>`, `@?` with `==`, `@@`, or matches an expression index exactly.
- [ ] The GIN operator class matches the operators used (`?` needs `jsonb_ops`).
- [ ] Scalars extracted with `->>` or `JSON_VALUE` are cast to their type.
- [ ] Updates cannot pass `NULL` into `jsonb_set`.
- [ ] Fields used in most filters, constraints or joins are columns.

## See also

Related skills in this library:

- `postgres-schema-design`: when JSONB fits a schema
- `postgres-indexing`: GIN and expression indexes
- `postgres-sql-patterns`: returning nested JSON without N+1
- `postgres-internals-mvcc-storage`: what a large update costs

## Sources

- https://www.postgresql.org/docs/18/datatype-json.html
- https://www.postgresql.org/docs/18/functions-json.html
- https://www.postgresql.org/docs/18/gin.html
- https://www.postgresql.org/docs/18/release-18.html
