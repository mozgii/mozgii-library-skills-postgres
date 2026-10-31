---
title: PostgreSQL data types reference
author: MOZGII, Inc.
lang: en
---

# PostgreSQL data types reference

This reference lists which PostgreSQL type to pick for each kind of value, and the types to avoid. It assumes
PostgreSQL 18; notes mark older versions.

## Contents

The sections of this reference on postgreSQL data types reference:

1. Numbers and money
2. Text and identifiers
3. Time and dates
4. Keys and UUIDs
5. Structured and special types
6. Types to avoid

## 1. Numbers and money

Number types trade exactness for speed; pick exact types for anything a person counts or pays.

| Value | Type | Notes |
|---|---|---|
| Counters, ids, quantities | `bigint` (or `integer` when bounded and small) | `smallint` saves little after alignment padding |
| Money, prices, rates | `numeric(p,s)` or `bigint` minor units | exact; `numeric` arithmetic is slower than integers |
| Measurements, scores | `double precision` | binary floating point: `0.1 + 0.2 <> 0.3` |
| Percentages with fixed precision | `numeric(5,2)` | |

- `money` depends on `lc_monetary` and has a single currency per server: avoid it.
- Store the currency next to the amount (`currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$')`) when there is more than one.

## 2. Text and identifiers

All character types share one storage format, so the choice is about rules, not speed.

| Value | Type |
|---|---|
| Any string | `text` |
| String with a business limit | `text CHECK (length(col) <= 200)` |
| Fixed codes (ISO country) | `text CHECK (col ~ '^[A-Z]{2}$')` |
| Case-insensitive unique value | `text` + `UNIQUE` index on `lower(col)` |
| Binary data | `bytea` (large files belong in object storage, with the key in a column) |

- `char(n)` pads with spaces and compares strangely: avoid it.
- The builtin collation `PG_UNICODE_FAST` (PG 18) or `C.UTF-8` (PG 17) sorts by code point and never changes with
  an OS upgrade. Use an ICU collation per column where people need language order: `title text COLLATE "und-x-icu"`.
- `casefold(text)` (PG 18) gives correct case-insensitive matching for more languages than `lower()`.

## 3. Time and dates

Time types are the most common source of silent data bugs.

| Value | Type |
|---|---|
| An instant (created, paid, logged) | `timestamptz` |
| A calendar day (birthday, due date) | `date` |
| A local time-of-day rule ("opens at 09:00") | `time` plus a zone column |
| A duration | `interval` |
| A period | `tstzrange` / `daterange` |

- `timestamptz` stores UTC and converts on output using the session `TimeZone`. Set the zone in the client
  (`SET TIME ZONE 'UTC'` or the driver's option), never by storing local times.
- `now()` is the transaction start time; `clock_timestamp()` is the current time. Rows inserted in one transaction
  share `now()`.
- Store a user's zone as an IANA name (`Europe/Berlin`), never as an offset (`+01`), because offsets change with DST.

## 4. Keys and UUIDs

Key types decide index locality and how much a key reveals.

| Function | Version | Ordered | Available |
|---|---|---|---|
| `uuidv7()` | 7 | yes, by time | PG 18 |
| `uuidv4()` / `gen_random_uuid()` | 4 | no | PG 18 / PG 13+ |
| `uuid_extract_timestamp(u)` | reads the time from a v1 or v7 UUID | | PG 17+ |

A `uuid` column is 16 bytes; a `bigint` is 8. Store UUIDs as `uuid`, never as `text` (36 bytes plus overhead, and
comparisons are slower).

## 5. Structured and special types

Postgres has native types for data many databases store as strings.

| Value | Type |
|---|---|
| Semi-structured document | `jsonb` (never `json` unless you must keep key order and duplicates) |
| Short list owned by the row (tags) | `text[]` with a GIN index; a join table when items have their own data |
| IP address or network | `inet`, `cidr` |
| Geographic data | PostGIS `geography` / `geometry` |
| Embeddings | pgvector `vector`, `halfvec` (see `postgres-vector-search`) |
| Search document | `tsvector` (see `postgres-full-text-search`) |

## 6. Types to avoid

These types look convenient and cause trouble later.

| Avoid | Use instead | Why |
|---|---|---|
| `serial`, `bigserial` | `GENERATED ALWAYS AS IDENTITY` | sequence ownership quirks; callers can write ids |
| `timestamp` (without time zone) | `timestamptz` | no zone, wrong after any zone change |
| `money` | `numeric` | locale-dependent |
| `char(n)` | `text` | padding |
| `varchar(n)` as a habit | `text` + `CHECK` | changing `n` takes a lock |
| `json` | `jsonb` | no indexing, re-parsed on every read |
| `float` for money | `numeric` | rounding errors |
| `text` holding UUIDs or dates | `uuid`, `date` | no validation, bigger indexes |
