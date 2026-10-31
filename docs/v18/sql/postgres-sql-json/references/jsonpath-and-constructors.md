---
title: PostgreSQL jsonpath syntax, methods and SQL/JSON constructors
author: MOZGII, Inc.
lang: en
---

# PostgreSQL jsonpath syntax, methods and SQL/JSON constructors

This reference lists the jsonpath language as PostgreSQL 18 implements it (accessors, filter operators, item
methods), the `jsonb_path_*` functions, the `IS JSON` tests and the SQL/JSON constructors with their `NULL`
defaults. Every example was run on PostgreSQL 18.6; the results are in the comments.

## jsonpath accessors

A jsonpath accessor selects items from the current item. In lax mode a key accessor on an array is applied to each
element.

| Accessor | Selects | Example on 18.6 |
|---|---|---|
| `$` | the root | |
| `.key`, `."key with spaces"` | a member | `$.a` |
| `.*` | every member value | `'{"a":1,"b":2}'`, `$.*` gives 1 and 2 |
| `.**` | every level below, recursively (use in strict mode) | `strict $.**.c` |
| `[n]`, `[last]`, `[a to b]` | array elements, zero-based | `$.a[last]` gives 5 on `[1,2,3,4,5]` |
| `[*]` | every element | `$.a[*]` |
| `$name` | a variable passed in the `vars` argument | `$.a[*] ? (@ > $min)` |

```sql
SELECT jsonb_path_query('{"a":[1,2,3,4,5]}', '$.a[last]')                AS last_item,     -- 5
       jsonb_path_query_array('{"a":[1,2,3,4,5]}', '$.a[1 to 3]')        AS slice,         -- [2, 3, 4]
       jsonb_path_query_array('{"a":{"b":{"c":1}}}', 'strict $.**.c')    AS any_depth,     -- [1]
       jsonb_path_query_first('{"a":[7,8]}', '$.a[*]')                   AS first_item;    -- 7
```

## jsonpath filter expressions

A filter `? (condition)` keeps the items for which the condition is true; `@` is the item being tested. Conditions
use `==`, `!=` (or `<>`), `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, `exists (path)`, `like_regex "re" flag "i"`,
`starts with "s"` and `(condition) is unknown`. A comparison between different types (a string and a number) is
unknown, not an error, in lax mode.

```sql
SELECT jsonb_path_query('{"a":[1,2]}', 'strict $.a ? (exists (@[*] ? (@ > 1)))')  AS has_big;   -- [1, 2]
SELECT jsonb_path_query('[1, "x", 3]', 'lax $[*] ? ((@ > 1) is unknown)')          AS not_comparable;  -- "x"
```

## jsonpath item methods

Item methods convert or describe the current item. The conversion methods `.bigint()`, `.boolean()`, `.date()`,
`.decimal()`, `.integer()`, `.number()`, `.string()`, `.time()`, `.time_tz()`, `.timestamp()` and `.timestamp_tz()`
exist since PostgreSQL 17.

| Method | Returns |
|---|---|
| `.type()` | `"number"`, `"string"`, `"null"`, `"object"`, `"array"`, `"boolean"`, or a date/time type name |
| `.size()` | array length (applies to the array itself in lax mode) |
| `.double()`, `.number()`, `.decimal(p, s)`, `.integer()`, `.bigint()` | a number from a number or numeric string |
| `.boolean()`, `.string()` | a boolean or a string |
| `.ceiling()`, `.floor()`, `.abs()` | rounded or absolute numbers |
| `.keyvalue()` | one `{"key", "value", "id"}` object per member |
| `.datetime()`, `.datetime("template")` | a date, time or timestamp parsed from ISO or the template |
| `.date()`, `.time()`, `.time_tz()`, `.timestamp()`, `.timestamp_tz()` | the named date/time type, with optional precision for times |

```sql
SELECT jsonb_path_query('{"x":"1.9"}', '$.x.double() * 2')       AS doubled,     -- 3.8
       jsonb_path_query('{"b":"true"}', '$.b.boolean()')         AS bool,        -- true
       jsonb_path_query('{"n":5}', '$.n.string()')               AS str,         -- "5"
       jsonb_path_query('{"d":"2026-10-28"}', '$.d.date()')      AS d;           -- "2026-10-28"
SELECT jsonb_path_query('{"a":[1,"x",null]}', '$.a[*].type()')   AS item_type;   -- "number", "string", "null"
SELECT jsonb_path_query_array('["12:30","18:40"]', '$[*].datetime("HH24:MI")') AS times;   -- ["12:30:00", "18:40:00"]
```

## jsonb_path functions and their _tz variants

The `jsonb_path_*` functions take a document, a path, an optional `vars` object and an optional `silent` flag that
turns errors into empty results. Each has a `_tz` variant that allows comparisons between zoned and unzoned
date/time values using the session `TimeZone`; those variants are `STABLE`, the plain ones `IMMUTABLE`, so only the
plain ones can appear in an index expression.

| Function | Returns |
|---|---|
| `jsonb_path_exists(doc, path)` | boolean: any item; same as `doc @? path` |
| `jsonb_path_match(doc, path)` | boolean: the predicate result; same as `doc @@ path` |
| `jsonb_path_query(doc, path)` | a set of `jsonb` items |
| `jsonb_path_query_array(doc, path)` | the items as one array |
| `jsonb_path_query_first(doc, path)` | the first item or `NULL` |

```sql
SELECT jsonb_path_match('{"a":5}', '$.a > 3') AS matched, '{"a":5}'::jsonb @@ '$.a > 3' AS op_match,
       jsonb_path_query('{"a":5}', '$.a + $x', '{"x": 2}') AS with_var;     -- t, t, 7
```

Mixing a zoned and an unzoned value fails in the plain function and works in the `_tz` one.

```sql
-- error: cannot convert value from timestamp to timestamptz without time zone usage
SELECT jsonb_path_query('["2026-03-29 01:30:00"]',
                        '$[*].datetime() ? (@ < "2026-03-29T05:00:00+00".datetime())');
```

## IS JSON tests

`IS JSON` (PostgreSQL 16+) tests whether a text value is valid JSON, optionally of one kind and with unique keys.

```sql
SELECT '{"a":1}' IS JSON OBJECT        AS obj,       -- t
       '[1]' IS JSON ARRAY             AS arr,       -- t
       '1' IS JSON SCALAR              AS scalar,    -- t
       'abc' IS JSON                   AS bad_text,  -- f
       '{"a":1,"a":2}' IS JSON WITH UNIQUE KEYS AS uniq;   -- f
```

A `CHECK (body IS JSON OBJECT)` on a text column validates documents that must stay text.

## SQL/JSON constructors and their NULL defaults

The SQL/JSON constructors build `json` by default and `jsonb` with `RETURNING jsonb`. Their default handling of SQL
`NULL` differs, so write the clause.

| Constructor | Default for `NULL` inputs | Example result on 18.6 |
|---|---|---|
| `JSON_OBJECT('a': 1, 'b': NULL)` | `NULL ON NULL` (kept) | `{"a" : 1, "b" : null}` |
| `JSON_ARRAY(1, NULL, 'x')` | `ABSENT ON NULL` (dropped) | `[1, "x"]` |
| `JSON_ARRAYAGG(x)` | `ABSENT ON NULL` | `[1]` from 1 and `NULL` |
| `JSON_OBJECTAGG(k: v)` | `NULL ON NULL`; `WITH UNIQUE KEYS` refuses duplicates | |
| `JSON(text)` | parses text into `json`; `WITH UNIQUE KEYS` refuses duplicates | |
| `JSON_SCALAR(v)` | a JSON scalar; a `timestamptz` is rendered in the session `TimeZone` | |

```sql
SELECT JSON_OBJECT('a': 1, 'b': NULL)                    AS obj_keeps_null,
       JSON_ARRAYAGG(x)                                  AS arr_drops_null,
       JSON_ARRAYAGG(x NULL ON NULL)                     AS arr_keeps_null,
       pg_typeof(JSON_OBJECT('a': 1 RETURNING jsonb))    AS returning_jsonb
FROM (VALUES (1), (NULL)) t(x);
```

Duplicate keys are refused only when asked.

```sql
-- error: duplicate JSON object key value
SELECT JSON('{"a":1,"a":2}' WITH UNIQUE KEYS);
```

`JSON_SERIALIZE` turns JSON into text or `bytea`. On 18.6 (checked on the macOS and Debian builds) a `jsonb` argument
returns a single `\x01` byte instead of the document, so serialize `json` or cast: `doc::text`.

```sql
SELECT JSON_SERIALIZE('{"a":1}'::json RETURNING text) AS from_json,     -- {"a":1}
       '{"a":1}'::jsonb::text                       AS from_jsonb;      -- {"a": 1}
```

## Sources

- https://www.postgresql.org/docs/18/functions-json.html
- https://www.postgresql.org/docs/18/datatype-json.html
- https://www.postgresql.org/docs/release/16.0/
- https://www.postgresql.org/docs/release/17.0/
