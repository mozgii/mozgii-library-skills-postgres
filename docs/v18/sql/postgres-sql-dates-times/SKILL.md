---
name: postgres-sql-dates-times
description: 'Handles dates and times in PostgreSQL SQL correctly: timestamptz versus timestamp versus date versus time, how timestamptz is stored as UTC and shown in the TimeZone setting, AT TIME ZONE in both directions and AT LOCAL, daylight saving time traps, intervals (months, days and microseconds, justify, end-of-month arithmetic), date_trunc with a time zone, date_bin, generate_series calendars and gap filling, age, extract and date_part, epoch conversions, infinity, tstzrange and multiranges, and filtering and indexing time columns. Use when times are off by hours, a day has 23 or 25 hours, "functions in index expression must be marked IMMUTABLE", counting per local day, converting Unix timestamps, or BETWEEN counts a row twice.'
metadata:
  tags:
  - postgres
  - timestamptz
  - time-zones
  - interval
  - daylight-saving-time
  - date_trunc
  - generate_series
  - tstzrange
---

# PostgreSQL dates and times in SQL

Store instants as `timestamptz`, calendar days as `date`, durations as `interval` and periods as `tstzrange`. Never
rely on the session `TimeZone` inside a query that means a specific zone: name the zone (`AT TIME ZONE 'Europe/Berlin'`,
the three-argument `date_trunc`, `date_add` and `generate_series`). Filter time with half-open ranges
(`>= start AND < end`), never `BETWEEN` or a cast on the column. Type choice for a schema is in
`postgres-schema-design` (references/data-types.md), and day buckets for reports in `postgres-sql-patterns`
(references/reporting.md); this skill is how the types behave. Zone names, abbreviations, formatting and range
operators: [references/zones-ranges-formatting.md](references/zones-ranges-formatting.md).

## Step 0: read the server version, the session zone and risky columns

`date_add`, the zone argument of `generate_series` (16), `AT LOCAL` and infinite intervals (17) depend on the version,
and the session `TimeZone` changes what a query prints, so read both. The last query lists columns that hold times
without a zone.

```sql
SELECT current_setting('server_version') AS version, current_setting('TimeZone') AS session_zone,
       current_setting('DateStyle') AS date_style, current_setting('IntervalStyle') AS interval_style;
SELECT table_schema, table_name, column_name, data_type FROM information_schema.columns
WHERE data_type IN ('timestamp without time zone', 'time with time zone')
  AND table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2, 3;
```

## Date and time types: storage, range and resolution

PostgreSQL has five date/time types and `interval`; sizes below were measured with `pg_column_size` on 18.6.

| Type | Bytes | Range | Holds |
|---|---|---|---|
| `timestamptz` | 8 | 4713 BC to 294276 AD, 1 microsecond | an instant, stored as UTC |
| `timestamp` | 8 | same | a wall-clock reading with no zone |
| `date` | 4 | 4713 BC to 5874897 AD | a calendar day |
| `time` | 8 | 00:00 to 24:00 | a time of day |
| `timetz` | 12 | | a time with a fixed offset: avoid it |
| `interval` | 16 | +/- 178,000,000 years | months, days and microseconds, kept apart |
| `tstzrange` | varies | | a period between two instants |

```sql
SELECT pg_column_size(now()) AS tstz, pg_column_size(current_date) AS date,
       pg_column_size(current_time) AS timetz, pg_column_size(interval '1 day') AS interval;
```

## How timestamptz is stored and displayed

A `timestamptz` value is a 64-bit count of microseconds from 2000-01-01 00:00 UTC (its binary form shows it). On
input, a stated zone or offset is
used to convert to UTC, and a missing one means the session `TimeZone`; the zone itself is not kept. On output the
value is shown in the session `TimeZone`. The same stored value therefore prints differently per session.

```sql
SELECT timestamptz_send('2000-01-01 00:00:01+00') AS one_second;   -- \x00000000000f4240 = 1,000,000 microseconds
SET TimeZone = 'UTC';
CREATE TEMP TABLE t (at timestamptz);
INSERT INTO t VALUES ('2026-10-28 10:00 Europe/Berlin'), ('2026-10-28T10:00:00Z');
SELECT at FROM t;                                 -- 09:00+00, 10:00+00
SET TimeZone = 'Asia/Tokyo';
SELECT at FROM t;                                 -- 18:00+09, 19:00+09: same instants
```

`timestamp` (without time zone) silently drops a zone in its input, which is how wrong data gets in.

```sql
SELECT timestamp '2026-10-28 10:00+05' AS zone_ignored;     -- 2026-10-28 10:00:00
```

## The TimeZone setting and where its default comes from

The `TimeZone` setting decides how `timestamptz` input without a zone is read and how output is shown. initdb writes
the operating system's zone into `postgresql.conf` (this macOS cluster got `America/New_York`); the official Docker
image runs with `Etc/UTC`. Set it per database, role or session, and send it from the client so each person sees
their own zone.

```sql
SELECT name, setting, source FROM pg_settings WHERE name IN ('TimeZone', 'log_timezone');
CREATE ROLE report_reader;
ALTER ROLE report_reader SET TimeZone = 'UTC';     -- every new session of this role
DROP ROLE report_reader;
```

Zone names come from the IANA tz database. A build configured with `--with-system-tzdata` (the Debian packages and
the Docker image) reads the operating system's copy, so zone rules change when the OS package updates; other builds
(Postgres.app is one) read the copy under the installation's `share/timezone`. `pg_config --configure` shows which.

## AT TIME ZONE in both directions

`AT TIME ZONE` converts in two opposite directions depending on its input type.

| Input | `x AT TIME ZONE 'Europe/Berlin'` returns | Meaning |
|---|---|---|
| `timestamptz` | `timestamp` | the wall clock in Berlin at that instant |
| `timestamp` | `timestamptz` | the instant when Berlin's wall clock showed that reading |
| `timestamptz AT LOCAL` (PG 17+) | `timestamp` | the wall clock in the session `TimeZone` |

```sql
SET TimeZone = 'UTC';
SELECT timestamptz '2026-10-28 10:00+00' AT TIME ZONE 'Asia/Tokyo'       AS tokyo_wall_clock,   -- 19:00
       timestamp   '2026-10-28 10:00'    AT TIME ZONE 'America/New_York' AS ny_instant,         -- 14:00+00
       timestamptz '2026-10-28 10:00+00' AT LOCAL                        AS session_wall_clock;
```

A text offset in `AT TIME ZONE` is read as a POSIX zone, where a positive sign means west of Greenwich: `'UTC+3'`
and `'+03:00'` both give 07:00 for 10:00 UTC. Use an IANA name, or an `interval` for a fixed offset.

```sql
SELECT timestamptz '2026-10-28 10:00+00' AT TIME ZONE 'UTC+3'            AS posix_west,      -- 07:00
       timestamptz '2026-10-28 10:00+00' AT TIME ZONE interval '+03:00'  AS three_east;      -- 13:00
```

## Daylight saving time traps

Daylight saving time makes some local days 23 or 25 hours long, some local times never exist and some exist twice.
PostgreSQL resolves a nonexistent time with the offset in force just before the jump, and an ambiguous time with
the offset just after (usually standard time); neither is an error.

```sql
SET TimeZone = 'Europe/Berlin';
SELECT timestamptz '2026-03-29 02:30' AS nonexistent_becomes,     -- 03:30+02
       timestamptz '2026-10-25 02:30' AS ambiguous_becomes,       -- 02:30+01
       timestamptz '2026-03-28 12:00' + interval '1 day'    AS plus_1_day,     -- 2026-03-29 12:00+02
       timestamptz '2026-03-28 12:00' + interval '24 hours' AS plus_24_hours;  -- 2026-03-29 13:00+02
```

Adding `'1 day'` keeps the wall-clock time in the session zone; `'24 hours'` adds exact time. For another zone
than the session's, use `date_add` with a zone (PostgreSQL 16+).

```sql
SET TimeZone = 'UTC';
SELECT date_add(timestamptz '2026-03-28 12:00+00', interval '1 day', 'Europe/Berlin') AS berlin_day,  -- 11:00+00
       timestamptz '2026-03-28 12:00+00' + interval '1 day'                          AS utc_day;     -- 12:00+00
```

## Intervals: months, days and microseconds

An `interval` stores three separate fields, months, days and microseconds, because a month has no fixed number of
days and a day near a DST change has no fixed number of hours. Arithmetic uses each field in turn.

| Expression | Result | Rule |
|---|---|---|
| `date '2026-01-31' + interval '1 month'` | `2026-02-28 00:00:00` | end-of-month dates clamp |
| `date '2026-03-31' - interval '1 month'` | `2026-02-28 00:00:00` | so `+ 1 month - 1 month` is not the identity |
| `date '2026-03-01' - date '2026-02-01'` | `28` | `date - date` is an `integer` of days |
| `interval '1 month' = interval '30 days'` | true | comparison assumes 30-day months |
| `justify_days(interval '35 days')` | `1 mon 5 days` | turns 30 days into a month |
| `justify_hours(interval '27 hours')` | `1 day 03:00:00` | turns 24 hours into a day |
| `age(date '2026-03-01', date '2026-01-31')` | `1 mon 1 day` | symbolic, counts calendar months |
| `interval '1 day' * 1.5` | `1 day 12:00:00` | fractions spill into smaller fields |

```sql
SELECT date '2026-01-31' + interval '1 month' AS clamp, date '2026-03-01' - date '2026-02-01' AS days,
       justify_interval(interval '1 mon -1 hour') AS justified, age(date '2026-03-01', date '2026-01-31') AS age,
       'infinity'::interval AS inf;                                  -- infinite intervals: PG 17+
```

## Truncating and binning time in a zone: date_trunc and date_bin

`date_trunc` cuts a value to the start of a calendar unit; on a `timestamptz` it cuts in the session `TimeZone`, so a
"day" depends on who runs the query. The three-argument form `date_trunc(unit, ts, zone)` cuts in a named zone and
is `IMMUTABLE`, so it can be indexed; the two-argument form on `timestamptz` is only `STABLE`. `week` truncates to
Monday.

```sql
SET TimeZone = 'Europe/Berlin';
SELECT date_trunc('day', timestamptz '2026-10-28 01:30+00')         AS berlin_day,   -- 2026-10-28 00:00+01
       date_trunc('day', timestamptz '2026-10-28 01:30+00', 'UTC')  AS utc_day,      -- 2026-10-28 01:00+01
       date_trunc('week', date '2026-10-28')                        AS iso_week;     -- Monday 2026-10-26
```

`date_bin(stride, ts, origin)` (PostgreSQL 14+) cuts into fixed strides counted from an origin, for 15-minute or
5-second buckets. Its stride cannot contain months or years; the origin decides alignment.

```sql
SELECT date_bin('15 minutes', timestamptz '2026-10-28 10:37+00', timestamptz '2001-01-01 00:00+00') AS slot;
```

## Calendars and gap filling with generate_series

`generate_series(start, stop, step, zone)` (the zone argument is PostgreSQL 16+) steps in a named zone, so a series
of local days stays at local midnight across a DST change; without it the steps follow the session zone.

```sql
SET TimeZone = 'UTC';
SELECT g AS berlin_midnight
FROM generate_series(timestamptz '2026-03-28 00:00 Europe/Berlin', timestamptz '2026-03-30 00:00 Europe/Berlin',
                     interval '1 day', 'Europe/Berlin') AS g;    -- 23:00, 23:00, then 22:00 UTC after the change
```

A per-day count in a person's zone, empty days included, joins the generated days to the data by a half-open
range.

```sql
CREATE TEMP TABLE logins (at timestamptz);
INSERT INTO logins VALUES ('2026-03-28 22:30+00'), ('2026-03-29 09:00+00'), ('2026-03-31 08:00+00');
SELECT (d AT TIME ZONE 'Europe/Berlin')::date AS day, count(l.at) AS logins
FROM generate_series(timestamptz '2026-03-28 00:00 Europe/Berlin', timestamptz '2026-03-31 00:00 Europe/Berlin',
                     interval '1 day', 'Europe/Berlin') AS d
LEFT JOIN logins l ON l.at >= d AND l.at < date_add(d, interval '1 day', 'Europe/Berlin')
GROUP BY 1 ORDER BY 1;
```

## Extracting fields with extract and date_part, and epoch conversions

`extract(field FROM x)` returns `numeric` (since PostgreSQL 14); `date_part('field', x)` returns `double precision`.
Fields of a `timestamptz` are read in the session `TimeZone`. `dow` counts Sunday as 0, `isodow` Sunday as 7; `week`
is the ISO week, which pairs with `isoyear`, not `year`.

```sql
SELECT extract(dow FROM date '2026-11-01') AS dow, extract(isodow FROM date '2026-11-01') AS isodow,
       extract(week FROM date '2027-01-01') AS iso_week, extract(isoyear FROM date '2027-01-01') AS iso_year,
       pg_typeof(extract(year FROM now())) AS extract_type, pg_typeof(date_part('year', now())) AS date_part_type;
```

Unix epoch seconds convert with `to_timestamp(seconds)` and `extract(epoch FROM ts)`; divide milliseconds by
`1000.0`. On a `timestamp` without zone, `extract(epoch ...)` treats the reading as UTC.

```sql
SET TimeZone = 'UTC';
SELECT to_timestamp(1793181600)                                   AS from_seconds,
       to_timestamp(1793181600123 / 1000.0)                       AS from_millis,
       (extract(epoch FROM timestamptz '2026-10-28 10:00+00') * 1000)::bigint AS to_millis,
       extract(epoch FROM timestamp '2026-10-28 10:00')           AS nominal_utc;
```

## Ranges and multiranges for periods

A range type holds a period; `tstzrange(a, b)` is half-open `[a, b)` by default, so back-to-back bookings do not
overlap. `&&` tests overlap, `@>` containment, and a subtraction that would leave two pieces needs a multirange
(PostgreSQL 14+). Operators and proofs: [references/zones-ranges-formatting.md](references/zones-ranges-formatting.md);
`WITHOUT OVERLAPS` keys and exclusion constraints: `postgres-schema-design`.

## Filtering and indexing time columns

A time filter uses the index only when the column stands alone on one side. `at::date = '2026-03-01'` cannot use a
B-tree on `at`, and an index on `at::date` is refused because the cast depends on `TimeZone`. Use a half-open range,
or index an `IMMUTABLE` expression that names the zone.

```sql
SET TimeZone = 'UTC';
CREATE TABLE ev (at timestamptz NOT NULL);
INSERT INTO ev SELECT timestamptz '2026-01-01 00:00+00' + g * interval '1 minute' FROM generate_series(1, 400000) g;
CREATE INDEX ev_at_idx ON ev (at);
CREATE INDEX ev_utc_day_idx ON ev (((at AT TIME ZONE 'UTC')::date));
ANALYZE ev;
EXPLAIN (COSTS OFF) SELECT count(*) FROM ev WHERE at::date = '2026-03-01';                        -- (Parallel) Seq Scan
EXPLAIN (COSTS OFF) SELECT count(*) FROM ev WHERE at >= '2026-03-01' AND at < '2026-03-02';         -- Index Only Scan
SELECT count(*) AS between_counts_midnight_twice FROM ev WHERE at BETWEEN '2026-03-01' AND '2026-03-02';   -- 1441
```

```sql
-- error: functions in index expression must be marked IMMUTABLE
CREATE INDEX ev_day_bad ON ev ((at::date));
```

## Infinity and special input values

`infinity` and `-infinity` are valid for `date`, `timestamp`, `timestamptz` and (since PostgreSQL 17) `interval`;
use them for open-ended validity instead of a magic far date. The inputs `'now'`, `'today'`, `'tomorrow'` and
`'epoch'` are read once when parsed: in a column `DEFAULT 'now'` that means table-creation time, so write
`DEFAULT now()`.

```sql
SELECT 'infinity'::timestamptz > now() AS later_than_all, isfinite('infinity'::date) AS finite,
       timestamptz 'epoch' AS epoch, now() - '-infinity'::timestamptz AS forever;
```

`now()` and `CURRENT_TIMESTAMP` are the transaction start; `statement_timestamp()` is the statement start;
`clock_timestamp()` changes during the statement.

## Gotchas

These are the date and time failures seen most often, each with its cause and fix.

1. **Times are off by whole hours.** Local times were stored in `timestamp`, or the client sent text without a zone
   in a session with another `TimeZone`. Store `timestamptz` and send offsets or set the session zone.
2. **`AT TIME ZONE 'UTC+3'` goes the wrong way.** Text offsets are POSIX: plus means west. Use an IANA name or
   `AT TIME ZONE interval '+03:00'`.
3. **A daily report has 23 or 25 hours in one row.** Days were computed in UTC or with `'24 hours'`. Use
   `date_trunc('day', at, zone)` and `interval '1 day'` with a zone.
4. **`functions in index expression must be marked IMMUTABLE`.** The expression depends on `TimeZone` (`at::date`,
   two-argument `date_trunc`). Index `(at AT TIME ZONE 'UTC')::date` or `date_trunc('day', at, 'UTC')`.
5. **`BETWEEN '2026-03-01' AND '2026-03-02'` counts the next midnight.** `BETWEEN` includes both ends. Use
   `>= start AND < end`.
6. **`IST` means Israel, not India.** Abbreviations come from `timezone_abbreviations` (`Default`: IST is +02).
   Use full zone names.

## Anti-patterns with dates and times

These give the right answer until a zone, a month end or a clock change arrives.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Unix epochs in `bigint`, or dates in `text` | no date arithmetic, no range checks, and every reader must convert | `timestamptz` or `date` |
| Letting the session `TimeZone` decide a report's days | two people get two reports | name the zone in the query |
| `86400` seconds or `24 hours` for a day | wrong on days of 23 or 25 hours | `interval '1 day'` with a zone |
| `BETWEEN` on timestamps | both ends count, so midnight lands in two days | `>= start AND < end` |
| A cast on the column in `WHERE` | the plain index goes unused | a half-open range on the bare column |
| Zone abbreviations such as `IST` | they are ambiguous, and `IST` reads as Israel by default | full IANA names |
| `9999-12-31` for "no end" | every query needs to know the magic value | `infinity`, or an open range |

## Verify time queries under two session zones

A report that names its zone gives the same rows in any session, so run it twice and compare. These ran on 18.6.

```sql
SET TimeZone = 'UTC';        CREATE TEMP TABLE r1 AS SELECT date_trunc('day', at, 'Europe/Berlin') AS d, count(*) AS c FROM app.ev GROUP BY 1;
SET TimeZone = 'Asia/Tokyo'; CREATE TEMP TABLE r2 AS SELECT date_trunc('day', at, 'Europe/Berlin') AS d, count(*) AS c FROM app.ev GROUP BY 1;
SELECT count(*) AS differing FROM ((TABLE r1 EXCEPT TABLE r2) UNION ALL (TABLE r2 EXCEPT TABLE r1)) s;   -- 0
SELECT timestamptz '2026-03-29 12:00 Europe/Berlin' - timestamptz '2026-03-28 12:00 Europe/Berlin';      -- 23:00:00
SELECT date '2026-01-31' + interval '1 month';                                                           -- 2026-02-28 00:00:00
SELECT table_schema, table_name, column_name FROM information_schema.columns
WHERE data_type = 'timestamp without time zone'
  AND table_schema NOT IN ('pg_catalog', 'information_schema');                                          -- review each row
```

Any `differing` above 0 means a function still reads the session zone. The two date lines pin the calendar traps your
tests should cover: the short DST day and the month-end clamp.

## Checklist

Check these points before you ship SQL that touches time.

- [ ] Instants are `timestamptz`; days are `date`; local rules are `time` plus a zone name column.
- [ ] Every "per day/week/month" query names its zone.
- [ ] Filters are half-open ranges on the bare column.
- [ ] Indexed expressions on time are `IMMUTABLE` (they name a zone).
- [ ] Month arithmetic near month ends is tested (31st plus one month).
- [ ] Epoch milliseconds are divided by `1000.0`, not `1000`.

## See also

Related skills in this library:

- `postgres-sql-patterns`: time buckets in reports
- `postgres-timeseries`: time-series tables at scale
- `postgres-schema-design`: choosing the column type
- `postgres-indexing`: expression indexes on time

## Sources

- https://www.postgresql.org/docs/18/datatype-datetime.html
- https://www.postgresql.org/docs/18/functions-datetime.html
- https://www.postgresql.org/docs/18/datetime-invalid-input.html
- https://www.postgresql.org/docs/18/datetime-posix-timezone-specs.html
- https://www.postgresql.org/docs/18/functions-srf.html
- https://www.postgresql.org/docs/18/runtime-config-client.html
