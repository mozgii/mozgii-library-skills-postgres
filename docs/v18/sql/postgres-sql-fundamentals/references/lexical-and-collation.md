---
title: SQL literals, identifiers, operator precedence and collations in PostgreSQL
author: MOZGII, Inc.
lang: en
---

# SQL literals, identifiers, operator precedence and collations in PostgreSQL

This reference covers the lexical rules of PostgreSQL SQL (how a name or a literal is read), the arithmetic types of
literals, the operator precedence table and its traps, and how collations decide text comparison. Run the demo
tables block of the `postgres-sql-fundamentals` skill first; the examples use its `sf` schema. All results were
checked on PostgreSQL 18.6.

## Numeric literals and arithmetic types

A numeric literal gets its type from its form: a plain integer that fits is `integer`, a larger one is `bigint`,
and anything with a decimal point or exponent is `numeric`. Underscores between digits and `0x`, `0o`, `0b`
prefixes are accepted (PostgreSQL 16 and later).

```sql
SELECT 1_000_000 AS million, 0x1F AS hex, 0b101 AS bin, 0o17 AS oct,
       pg_typeof(2147483648) AS big, pg_typeof(1.5e3) AS sci;
```

The result type of an expression depends on its operands, never on the column it is stored into.

| Expression | Result | Why |
|---|---|---|
| `7 / 2` | `3` | integer division truncates toward zero; `-7 / 2` is `-3` |
| `7 / 2.0` | `3.5000000000000000` | a decimal literal is `numeric` |
| `0.1 + 0.2 = 0.3` | true | `numeric` is exact |
| `0.1::float8 + 0.2::float8 = 0.3::float8` | false | binary floating point |
| `round(2.5)` / `round(2.5::float8)` | `3` / `2` | `numeric` breaks ties away from zero; `float8` tie-breaking is platform dependent, usually half to even (2 on 18.6 for macOS) |
| `'2' < '10'` | false | text compares character by character |

Assignment casts (`castcontext = 'a'` in `pg_cast`) apply when a value is stored into a column, so a `numeric` lands
in an `int` column rounded, without an error.

```sql
CREATE TEMP TABLE ti (i int);
INSERT INTO ti VALUES (2.7), (2.5), (-2.5);
SELECT i FROM ti;                                   -- 3, 3, -3
SELECT 7 / 2 AS int_div, -7 / 2 AS toward_zero, 7 / 2.0 AS num_div,
       0.1::float8 + 0.2::float8 = 0.3::float8 AS float_equal, round(2.5) AS num_round;
```

## Operator precedence

Operator precedence is fixed in the parser, highest first: `.`, `::`, `[ ]`, unary `+ -`, `COLLATE`, `AT`, `^`,
`* / %`, binary `+ -`, any other operator (`||`, `->>`, `@>`, ...), `BETWEEN IN LIKE ILIKE SIMILAR`, comparisons
`< > = <= >= <>`, `IS`, `NOT`, `AND`, `OR`. Most operators are left-associative; unary minus and `NOT` are
right-associative.

| Expression | Parsed as | Result |
|---|---|---|
| `-2 ^ 2` | `(-2) ^ 2` | `4` |
| `2 ^ 3 ^ 2` | `(2 ^ 3) ^ 2` | `64` |
| `doc->>'n'::int` | `doc ->> ('n'::int)` | error: invalid input syntax for type integer |
| `-1::text` | `-(1::text)` | error: operator does not exist: - text |
| `'a' || 1 + 2` | `'a' || (1 + 2)` | `a3` |
| `a OR b AND c` | `a OR (b AND c)` | |
| `NOT a = b` | `NOT (a = b)` | |

Add parentheses to cast after an operator.

```sql
SELECT -2 ^ 2 AS four, 2 ^ 3 ^ 2 AS sixty_four, 'a' || 1 + 2 AS a3,
       ('{"n":"5"}'::jsonb->>'n')::int AS five;
```

The cast binds to the literal `'n'`, not to the result of `->>`.

```sql
-- error: invalid input syntax for type integer: "n"
SELECT '{"n":"5"}'::jsonb->>'n'::int;
```

## Identifiers, quoting and keywords

An identifier is a name of a table, column or other object. Unquoted identifiers fold to lower case and may hold
letters, digits, `_` and `$`; double-quoted identifiers keep their case and may hold any character, including
spaces. Names longer than 63 bytes (`NAMEDATALEN - 1`) are truncated with a `NOTICE`, so two long names can collide.

```sql
CREATE TABLE sf."Mixed" ("Name" text);
SELECT "Name" FROM sf."Mixed";        -- SELECT Name FROM sf.Mixed looks for sf.mixed.name and fails
SELECT U&"d\0061ta" FROM (SELECT 1 AS data) s;   -- Unicode escapes in a quoted identifier
```

Reserved keywords (`user`, `order`, `all`) need quotes as column names; unreserved ones (`name`, `value`) do not.
`pg_get_keywords()` lists them.

```sql
SELECT word, catdesc FROM pg_get_keywords() WHERE word IN ('user', 'order', 'name', 'value') ORDER BY 1;
```

## String constants and escapes

A string constant is written in single quotes, with `''` for a quote inside. With `standard_conforming_strings = on`
(the default) a backslash is an ordinary character; `E'...'` strings read C-style escapes; dollar quoting
(`$$...$$` or `$tag$...$tag$`) needs no escaping at all, which is why function bodies use it.

```sql
SELECT 'it''s' AS doubled, $$it's$$ AS dollar, E'tab\there' AS c_escape, 'a\b' AS plain_backslash,
       U&'\00E9' AS unicode_escape;
```

## Collations and string comparison

A collation decides how text sorts and compares. Each column has one (the database default unless declared), a
`COLLATE` clause overrides it per expression, and a B-tree index serves `ORDER BY` and range tests only for the
collation it was built with. On this server the database default is `en_US.UTF-8` (libc), so `'a' < 'B'` is true; in
`"C"` it is false.

```sql
SELECT 'a' < 'B' AS libc_en_us, 'a' < 'B' COLLATE "C" AS c_bytes, 'a' < 'B' COLLATE "und-x-icu" AS icu;
```

Three providers supply collations; the choice decides portability.

| Provider | Examples | Same order on every OS | Version recorded |
|---|---|---|---|
| `libc` (`c`) | `en_US.UTF-8`, `C`, `POSIX` | no: comes from the OS C library | on glibc, FreeBSD and Windows; not on macOS |
| `icu` (`i`) | `und-x-icu`, `en-x-icu`, `unicode` | yes, for one ICU version | yes |
| `builtin` (`b`) | `pg_c_utf8` (`C.UTF-8`), `pg_unicode_fast` (18), `ucs_basic` | yes, never changes with the OS | yes |

```sql
SELECT collname, collprovider, collisdeterministic, collversion
FROM pg_collation
WHERE collname IN ('C', 'en_US.UTF-8', 'und-x-icu', 'unicode', 'pg_c_utf8', 'pg_unicode_fast')
ORDER BY 1;
```

A nondeterministic ICU collation compares case-insensitively (or accent-insensitively); PostgreSQL 18 allows `LIKE`
and the text position functions on it. B-tree deduplication is not used with nondeterministic collations.

```sql
CREATE COLLATION sf.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
SELECT 'Berlin' = 'BERLIN' COLLATE sf.ci AS equal, 'BERLIN' LIKE 'ber%' COLLATE sf.ci AS like_18;
```

An index built under one collation does not serve another; an `ORDER BY ... COLLATE "C"` on a default-collation
index sorts again.

```sql
CREATE INDEX customers_name_idx ON sf.customers (name);
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT name FROM sf.customers ORDER BY name;                -- Index Only Scan
EXPLAIN (COSTS OFF) SELECT name FROM sf.customers ORDER BY name COLLATE "C";    -- Sort on top
```

## Collation version changes after an OS or ICU upgrade

A collation version change means the stored index order may no longer match the new comparison rules. PostgreSQL
records the provider's version and warns `collation "..." has version mismatch` when it differs; the fix is to
`REINDEX` every index on text with that collation, then `ALTER COLLATION ... REFRESH VERSION` (or `ALTER DATABASE
... REFRESH COLLATION VERSION` for the database default). macOS libc records no version, so on macOS a libc
collation change gives no warning; a database on the builtin provider avoids the problem everywhere.

```sql
SELECT datname, datlocprovider, datcollate, datcollversion,
       pg_database_collation_actual_version(oid) AS os_version
FROM pg_database WHERE datname = current_database();
```

## Sources

- https://www.postgresql.org/docs/18/sql-syntax-lexical.html
- https://www.postgresql.org/docs/18/typeconv-overview.html
- https://www.postgresql.org/docs/18/functions-math.html
- https://www.postgresql.org/docs/18/collation.html
- https://www.postgresql.org/docs/18/locale.html
- https://www.postgresql.org/docs/18/sql-altercollation.html
- https://www.postgresql.org/docs/18/release-18.html
