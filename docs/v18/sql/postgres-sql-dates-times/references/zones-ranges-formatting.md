---
title: PostgreSQL time zone names, abbreviations, date formatting and range operators
author: MOZGII, Inc.
lang: en
---

# PostgreSQL time zone names, abbreviations, date formatting and range operators

This reference covers how PostgreSQL reads zone names and abbreviations, how `DateStyle` and `to_char` /
`to_date` / `to_timestamp` format and parse dates, and the range and multirange operators for periods. Every example
was run on PostgreSQL 18.6; each block sets `TimeZone` itself because the result depends on it.

## Time zone names, abbreviations and offsets

PostgreSQL accepts three kinds of zone in input and in `AT TIME ZONE`, and they behave differently.

| Kind | Example | Behaviour |
|---|---|---|
| IANA name | `Europe/Berlin`, `Asia/Kolkata` | full history and DST rules; `pg_timezone_names` lists them |
| Abbreviation | `CET`, `EST`, `IST` | one fixed offset from the `timezone_abbreviations` set (`Default`); `pg_timezone_abbrevs` lists them |
| POSIX spec | `UTC+3`, `EST5EDT` | sign is reversed (plus means west); `EST5EDT` and three similar names are real IANA zones |

Abbreviations are ambiguous between countries; in the `Default` set `IST` is Israel (+02), not India (+05:30).

```sql
SET TimeZone = 'UTC';
SELECT timestamptz '2026-10-28 10:00 IST'          AS ist_is_israel,     -- 08:00+00
       timestamptz '2026-10-28 10:00 Asia/Kolkata' AS india;             -- 04:30+00
SELECT abbrev, utc_offset FROM pg_timezone_abbrevs WHERE abbrev IN ('IST', 'CET', 'EST') ORDER BY 1;
SELECT name, abbrev, utc_offset, is_dst FROM pg_timezone_names WHERE name IN ('Europe/Berlin', 'Asia/Kolkata');
```

## DateStyle: how ambiguous dates are read and shown

`DateStyle` has two parts: the output style (`ISO`, `SQL`, `Postgres`, `German`) and the field order for ambiguous
input (`MDY`, `DMY`, `YMD`). `'03/04/2026'` is March 4 under `MDY` and April 3 under `DMY`; ISO input
(`2026-04-03`) is read the same under every setting, so send ISO 8601 from applications.

```sql
SET DateStyle = 'ISO, DMY';
SELECT '03/04/2026'::date AS dmy;          -- 2026-04-03
SET DateStyle = 'ISO, MDY';
SELECT '03/04/2026'::date AS mdy, '2026-04-03'::date AS iso_always;   -- 2026-03-04, 2026-04-03
```

## Formatting and parsing with to_char, to_date and to_timestamp

`to_char(value, template)` formats dates and times; `to_date` and `to_timestamp` parse text by a template. `FM`
removes padding, `TM` translates day and month names with `lc_time`, `IYYY` and `IW` give the ISO year and week,
`TZH:TZM` the offset. A `timestamptz` is formatted in the session `TimeZone`. `make_date`, `make_timestamptz` and
`make_interval` build values from numbers without any text parsing.

```sql
SET TimeZone = 'UTC';
SELECT to_char(timestamptz '2026-10-28 10:05:03.25+00', 'YYYY-MM-DD"T"HH24:MI:SS.MSTZH:TZM') AS iso_ms,
       to_char(date '2026-10-28', 'FMDay, FMDD FMMonth YYYY')  AS long_form,
       to_char(date '2026-10-28', 'IYYY-"W"IW')                AS iso_week,
       to_timestamp('2026-10-28 10:00 +02', 'YYYY-MM-DD HH24:MI TZH') AS parsed,
       make_timestamptz(2026, 10, 28, 10, 0, 0, 'Europe/Berlin') AS built,
       make_interval(days => 3, hours => 2)                    AS span;
```

`to_date` rejects impossible values instead of rolling them over.

```sql
-- error: date/time field value out of range: "2026-13-01"
SELECT to_date('2026-13-01', 'YYYY-MM-DD');
```

## Ranges and multiranges for periods

A range type holds a period with inclusive or exclusive bounds; `tstzrange(a, b)` is `[a, b)` by default, so
back-to-back periods do not overlap. `&&` tests overlap, `@>` containment, `-` subtraction; a subtraction that would
leave two pieces fails on a range and works on a multirange (PostgreSQL 14+). `range_agg` merges periods.
`WITHOUT OVERLAPS` keys and exclusion constraints are in `postgres-schema-design`.

| Operator or function | Meaning | Example on 18.6 |
|---|---|---|
| `&&` | overlap | `[09,10) && [10,11)` is false |
| `@>` / `<@` | contains a range or a point | `[09,10) @> 10:00` is false: the upper bound is excluded |
| `*` | intersection | `[09,11) * [10,12)` is `[10,11)` |
| `-|-` | adjacent | `[09,10) -|- [10,11)` is true |
| `-` | difference; must stay contiguous on a range | use multiranges for holes |
| `range_agg(r)` | union of many ranges into a multirange | |
| `lower_inf`, `upper_inf`, `isempty` | unbounded ends, empty range | `tstzrange(x, NULL)` is unbounded above |
| `(a, b) OVERLAPS (c, d)` | SQL-standard period overlap, also half-open | touching periods: false |

Discrete ranges are stored in canonical half-open form: `daterange('2026-10-01', '2026-10-31', '[]')` is
`[2026-10-01,2026-11-01)`.

```sql
SET TimeZone = 'UTC';
SELECT daterange('2026-10-01', '2026-10-31', '[]') AS canonical,
       tstzrange('2026-10-28 09:00+00', '2026-10-28 10:00+00') @> timestamptz '2026-10-28 10:00+00' AS upper_included,
       tstzrange('2026-10-28 09:00+00', '2026-10-28 11:00+00') * tstzrange('2026-10-28 10:00+00', '2026-10-28 12:00+00') AS intersection,
       (date '2026-10-01', date '2026-10-10') OVERLAPS (date '2026-10-10', date '2026-10-20') AS overlaps_touch;
SELECT tstzrange('2026-10-28 09:00+00', '2026-10-28 10:00+00') &&
       tstzrange('2026-10-28 10:00+00', '2026-10-28 11:00+00')                            AS touching_overlap, -- f
       tstzmultirange(tstzrange('2026-10-28 09:00+00', '2026-10-28 12:00+00')) -
       tstzmultirange(tstzrange('2026-10-28 10:00+00', '2026-10-28 11:00+00'))            AS free_time;
SELECT range_agg(r) AS busy FROM (VALUES (tstzrange('2026-10-28 09:00+00', '2026-10-28 10:00+00')),
                                         (tstzrange('2026-10-28 10:00+00', '2026-10-28 11:00+00'))) v(r);
```

The same subtraction on plain ranges is an error.

```sql
-- error: result of range difference would not be contiguous
SELECT tstzrange('2026-10-28 09:00+00', '2026-10-28 12:00+00') - tstzrange('2026-10-28 10:00+00', '2026-10-28 11:00+00');
```

## Sources

- https://www.postgresql.org/docs/18/datatype-datetime.html
- https://www.postgresql.org/docs/18/datetime-posix-timezone-specs.html
- https://www.postgresql.org/docs/18/functions-formatting.html
- https://www.postgresql.org/docs/18/runtime-config-client.html
- https://www.postgresql.org/docs/18/rangetypes.html
- https://www.postgresql.org/docs/18/functions-range.html
