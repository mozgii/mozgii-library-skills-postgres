---
name: postgres-bulk-load-etl
description: 'Loads and exports data fast with PostgreSQL 18: COPY from files, STDIN and programs, client-side \copy and driver COPY APIs, ON_ERROR ignore with REJECT_LIMIT and LOG_VERBOSITY, COPY FREEZE, unlogged staging tables, dropping and rebuilding indexes, maintenance_work_mem, batch upserts with INSERT ON CONFLICT and MERGE, exports with COPY TO, migrations from MySQL, SQLite or SQL Server with pgloader, ELT in SQL, and measured rows per second for each method. Use when importing CSV or large files, an import is slow, a load fails on one bad row, syncing a feed into a table, exporting query results, or migrating another database to Postgres.'
metadata:
  tags:
  - postgres
  - copy
  - bulk-load
  - etl
  - csv-import
  - staging-tables
  - upsert
  - merge
  - pgloader
---

# PostgreSQL bulk loading and ETL

Load with `COPY`, not `INSERT`: it streams rows in one command with no per-row round trip. Merge a feed into live
tables by `COPY` into an unlogged staging table, validating there, then one set-based upsert. Load an empty table
without indexes and build them afterwards. Measure rows per second before and after each change.
Single-row patterns (`unnest` arrays, multi-row `VALUES`) are in `postgres-sql-patterns`; driver pools in
`postgres-python` and `postgres-app-drivers`. A runnable staged load:
[scripts/staged-load.sql](scripts/staged-load.sql).

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: read the target, the load's size and the server limits

The right method depends on the server version, the indexes on the target, and whether replicas must absorb the WAL.

```sql
SELECT version(), current_setting('wal_level') AS wal_level;
SELECT pg_size_pretty(pg_total_relation_size('app.products')) AS size,
       (SELECT reltuples::bigint FROM pg_class WHERE oid = 'app.products'::regclass) AS est_rows;
SELECT indexrelid::regclass AS index FROM pg_index WHERE indrelid = 'app.products'::regclass;
SELECT name, setting, unit FROM pg_settings WHERE name IN ('maintenance_work_mem', 'max_wal_size', 'max_parallel_maintenance_workers');
SELECT application_name, replay_lag FROM pg_stat_replication;
```

## Load methods ranked by measured speed

The load method decides throughput more than any setting. These rates were measured on PostgreSQL 18.6 on an
Apple M5 Max laptop over a local socket, loading 5 million rows of five columns (414 MB of CSV); macOS `fsync`
is cheaper than on most Linux servers, so treat them as ratios, not targets.

| Method | Rows per second | Notes |
|---|---|---|
| single-row `INSERT`, autocommit | 12,500 | one commit (WAL flush) per row |
| single-row `INSERT`, one transaction | 52,000 | parse and round trip per row |
| `COPY` CSV into a table with a primary key and one index | 190,000 | index maintenance dominates |
| `COPY` CSV into the same table without indexes | 690,000 | then about 10 s to build both indexes |
| `COPY` CSV into an `UNLOGGED` table | 1,560,000 | no WAL; emptied after a crash |
| `COPY` binary into an `UNLOGGED` table | 3,100,000 | binary must match column types exactly |
| client-side `\copy` CSV into an `UNLOGGED` table | 1,450,000 | same as server-side over a local socket |

## COPY FROM a file, STDIN or a program

`COPY ... FROM` reads rows from a file on the database server, from the client connection (`STDIN`), or from a
program the server runs. Options are given in parentheses; `FORMAT` is `text` (default), `csv` or `binary`.

```sql
CREATE SCHEMA app;
CREATE TABLE app.products (
  sku        text PRIMARY KEY,
  name       text NOT NULL,
  price      numeric(10,2) NOT NULL,
  stock      int,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNLOGGED TABLE app.products_stage (sku text, name text, price numeric(10,2), stock int);

COPY app.products_stage FROM '/srv/import/products.csv'
  WITH (FORMAT csv, HEADER MATCH, ON_ERROR ignore, REJECT_LIMIT 5, LOG_VERBOSITY verbose);
```

- A file path or `PROGRAM` is read by the server's OS user and needs superuser or `pg_read_server_files`
  (`pg_execute_server_program` for programs). From an application, use `FROM STDIN` through the driver.
- `HEADER MATCH` checks that the header names and order equal the column list; `HEADER true` just skips a line.
- `FORCE_NULL (col)` turns quoted empty strings into NULL; `DEFAULT 'string'` loads the column default where that
  string appears; `ENCODING 'LATIN1'` reads a file in another encoding; `WHERE` filters rows on the way in.
- `COPY FROM` fires triggers and checks constraints; it is refused on tables with row-level security for roles the
  policies apply to.

## Skipping bad rows: ON_ERROR, REJECT_LIMIT and LOG_VERBOSITY

`ON_ERROR ignore` (PostgreSQL 17) skips rows whose values cannot be converted to the column types instead of
failing the whole load; PostgreSQL 18 adds `REJECT_LIMIT n` to fail anyway past `n` bad rows, and `LOG_VERBOSITY
silent`. With `verbose`, each skipped row is reported:

```text
NOTICE:  skipping row due to data type incompatibility at line 3 for column "price": "abc"
NOTICE:  skipping row due to data type incompatibility at line 5 for column "stock": "x"
NOTICE:  2 rows were skipped due to data type incompatibility
```

It does not catch everything. On 18.6 these still failed the whole `COPY` with `ON_ERROR ignore`: a `NOT NULL`
violation, a duplicate primary key, a missing column (`missing data for column "stock"`), and any `CHECK` or foreign
key failure. When you need a report of every rejected row, load all columns as `text` and validate in SQL:

```sql
CREATE UNLOGGED TABLE app.products_raw (sku text, name text, price text, stock text);
INSERT INTO app.products_raw VALUES ('A1', 'Widget', '9.99', '10'), ('A2', 'Gadget', 'abc', '5'),
                                    ('A4', 'Doohickey', '1.00', 'x');
SELECT sku, price, stock,
       pg_input_is_valid(price, 'numeric(10,2)') AS price_ok,
       pg_input_error_info(stock, 'integer')     AS stock_error
FROM app.products_raw
WHERE NOT pg_input_is_valid(price, 'numeric(10,2)')
   OR NOT pg_input_is_valid(coalesce(stock, '0'), 'integer');
```

`pg_input_error_info` returns the message, detail, hint and SQLSTATE (`22P02` for bad syntax) for a value.

## Client-side \copy and COPY TO STDOUT in psql

psql's `\copy` runs `COPY ... FROM STDIN` or `TO STDOUT` and reads or writes the file on the client machine, with
the client user's permissions and no server privilege. It must fit on one line and does not expand psql variables.

```sql
\copy app.products_stage FROM 'products.csv' WITH (FORMAT csv, HEADER true)
COPY (SELECT sku, name, price FROM app.products ORDER BY sku)
TO STDOUT WITH (FORMAT csv, HEADER true, FORCE_QUOTE (name)) \g products-export.csv
```

- `COPY ... TO STDOUT \g file` spans lines and expands variables, which `\copy` cannot.
- Compressed input without a temp file: `\copy app.readings FROM PROGRAM 'gzip -dc readings.csv.gz' WITH (FORMAT
  csv, HEADER true)`. The program runs on the client: `gzip` on macOS and Linux; on Windows use a program that
  exists there, and write paths with forward slashes or doubled backslashes.
- PostgreSQL 18 no longer treats `\.` as end of data in CSV files read by the server; psql still ends inline
  `STDIN` data at `\.`, and since 18.6 scripts with an intentionally failing `COPY ... FROM STDIN` need a `\.` line.

## COPY from application code

Every mainstream driver exposes the COPY protocol; use it instead of batched inserts above a few thousand rows:
psycopg 3 `cursor.copy()`, asyncpg `copy_records_to_table()`, node-postgres with pg-copy-streams `from()`, pgx
`CopyFrom()`, PgJDBC `CopyManager.copyIn()`, Npgsql `BeginBinaryImport()` (which rolls back unless `Complete()` is
called). Calls per driver: [references/driver-copy.md](references/driver-copy.md).

## Unlogged staging tables

An unlogged table writes no WAL, so loads into it run several times faster; it is emptied after a crash and is not
copied to replicas. That fits staging: the source file is the backup.

- `ALTER TABLE ... SET LOGGED` rewrites the table and writes all of it to WAL; insert from staging into a logged
  table instead of converting it.
- PostgreSQL 18 refuses unlogged partitioned tables (`partitioned tables cannot be unlogged`); a single partition
  can be unlogged.
- Truncate staging at the start of each load (`TRUNCATE` is instant and leaves no dead rows) and `ANALYZE` it
  before the merge so the planner sees its size.

## Indexes, foreign keys and maintenance_work_mem for large loads

Every index is updated per row during `COPY`; building it once afterwards is faster. For a first load or a reload of
most of a table, drop secondary indexes and foreign keys, load, then rebuild with a larger `maintenance_work_mem`.

```sql
SET maintenance_work_mem = '1GB';                 -- session only; helps CREATE INDEX and ADD FOREIGN KEY
SET max_parallel_maintenance_workers = 4;         -- parallel B-tree builds
CREATE INDEX products_name_idx ON app.products (name);
RESET maintenance_work_mem;
RESET max_parallel_maintenance_workers;
```

- In the measurement above, loading without indexes and rebuilding both took 17.5 s against 26.3 s with indexes in
  place. On a table already holding far more rows than the load adds, keep the indexes.
- Re-add foreign keys as `NOT VALID`, then `VALIDATE CONSTRAINT`: validation takes a weaker lock
  (`postgres-schema-migrations`).
- Raise `max_wal_size` for the load window so checkpoints do not run every few seconds.
- Run `ANALYZE` after the load; autovacuum may not get to it before the first queries.

## COPY FREEZE for initial loads

`COPY ... WITH (FREEZE)` writes rows already frozen and marked all-visible, so the table needs no later
anti-wraparound freeze pass and index-only scans work at once. It only works when the table was created or
truncated in the same transaction.

```sql
CREATE TABLE app.history (id bigint, note text);
BEGIN;
TRUNCATE app.history;
COPY app.history FROM STDIN WITH (FREEZE);
1	first
2	second
\.
COMMIT;
```

- On 18.6, 5 million rows loaded with `FREEZE` left all 61,729 pages all-frozen in `pg_visibility_map_summary`;
  without it, none. It wrote about the same WAL (`wal_level = logical`), so the gain is the vacuum work avoided.
- Without the `TRUNCATE` or `CREATE` in the same transaction it fails: `cannot perform COPY FREEZE because the table
  was not created or truncated in the current subtransaction`. Partitioned and foreign tables are refused.
- Other sessions see frozen rows as soon as the load commits, even with older snapshots: use it for initial loads,
  not for tables being read.

## Upserting staged rows: INSERT ON CONFLICT or MERGE

After staging, one set-based statement applies the feed to the live table. `INSERT ... ON CONFLICT` handles insert
or update. `MERGE` (PostgreSQL 15+) also has a delete action for matched rows; deleting rows missing from the feed
needs `WHEN NOT MATCHED BY SOURCE`, which arrived in 17 together with `RETURNING` on `MERGE`.

```sql
INSERT INTO app.products_stage VALUES ('A1', 'Widget', 9.99, 10), ('A3', 'Gizmo', 4.50, NULL),
                                      ('A5', 'Thing', 2.00, 7);
INSERT INTO app.products AS p (sku, name, price, stock)
SELECT DISTINCT ON (sku) sku, name, price, stock FROM app.products_stage ORDER BY sku
ON CONFLICT (sku) DO UPDATE
  SET name = EXCLUDED.name, price = EXCLUDED.price, stock = EXCLUDED.stock, updated_at = now()
  WHERE (p.name, p.price, p.stock) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.price, EXCLUDED.stock)
RETURNING p.sku, (old.sku IS NULL) AS inserted;

MERGE INTO app.products AS t
USING app.products_stage AS s ON t.sku = s.sku
WHEN MATCHED AND (t.name, t.price, t.stock) IS DISTINCT FROM (s.name, s.price, s.stock) THEN
  UPDATE SET name = s.name, price = s.price, stock = s.stock, updated_at = now()
WHEN NOT MATCHED BY TARGET THEN
  INSERT (sku, name, price, stock) VALUES (s.sku, s.name, s.price, s.stock)
WHEN NOT MATCHED BY SOURCE THEN
  DELETE
RETURNING merge_action(), t.sku, old.price AS old_price, new.price AS new_price;
```

- Deduplicate the stage first (`DISTINCT ON`): one statement cannot update the same row twice.
- The `IS DISTINCT FROM` guard skips unchanged rows, so a daily full feed writes only real changes.
- Measured on 18.6 with a 1 million row stage (half updates) into 5 million rows: `ON CONFLICT` took 4.7 s and
  `MERGE` 10.4 s. Use `MERGE` when you need the delete branch or per-action logic, and measure both.
- Very large merges: run them in key-range batches from a procedure with `COMMIT` between batches, so each
  transaction stays short and vacuum keeps up.

## Exports with COPY TO

`COPY ... TO` writes a table or any query result, including `INSERT`, `UPDATE`, `DELETE` or `MERGE` with
`RETURNING`, as text, CSV or binary. PostgreSQL 18 also copies from populated materialized views.

```sql
COPY (SELECT sku, name, price FROM app.products ORDER BY sku) TO STDOUT WITH (FORMAT csv, HEADER true);
COPY (UPDATE app.products SET stock = 0 WHERE stock IS NULL RETURNING sku) TO STDOUT;
```

Export binary only for loading back into PostgreSQL of a compatible version; use CSV for anything else.

## Watching a load: pg_stat_progress_copy and WAL volume

`pg_stat_progress_copy` shows each running `COPY`: bytes processed against the file size, rows processed, rows
excluded by `WHERE` and rows skipped by `ON_ERROR`.

```sql
SELECT pid, relid::regclass AS target, command, type,
       pg_size_pretty(bytes_processed) AS done, pg_size_pretty(bytes_total) AS total,
       tuples_processed, tuples_excluded, tuples_skipped
FROM pg_stat_progress_copy;
```

For WAL volume, compare `pg_current_wal_lsn()` before and after with `pg_wal_lsn_diff`: the 5 million row logged
load above wrote 472 MB of WAL, about the size of the data, which replicas and backups must also absorb.

## Migrating from MySQL, SQLite or SQL Server with pgloader

pgloader migrates a whole database in one command: it reads the source schema, creates tables and indexes, streams
rows with `COPY` and resets sequences. Version 3.6.10 is the stable release (`apt install pgloader`, the
`ghcr.io/dimitri/pgloader` image for amd64); version 4, a Java 21 rewrite, is published only as a `v4-dev` JAR.

```bash
pgloader mysql://app@mysql.example/shop postgresql://app@pg.example/shop
pgloader shop.load       # a load file with WITH, SET, CAST and BEFORE LOAD clauses
```

A SQLite test into 18.6 loaded 21,000 rows in 0.3 s and showed what to review: `REAL` became `real` (4-byte float),
text dates stayed `text`, and index names came out as `idx_16390_public.orders_pkey`. Load files, `CAST` rules and
checks: [references/pgloader.md](references/pgloader.md).

## Worked example: "reload a million customers from a nightly CSV, some rows are bad"

The file has 1,000,000 rows and three with a broken `id`; 100,000 customers already exist. Timings are from one run on
PostgreSQL 18.6 on a laptop.

```sql
CREATE UNLOGGED TABLE app.customers_stage (id bigint, email text, plan text);
\copy app.customers_stage FROM 'customers.csv' WITH (FORMAT csv, HEADER true, ON_ERROR ignore, LOG_VERBOSITY verbose)
SELECT id FROM app.customers_stage GROUP BY id HAVING count(*) > 1;   -- 0 rows, or ON CONFLICT fails on the duplicate
INSERT INTO app.customers (id, email, plan)
SELECT id, email, plan FROM app.customers_stage
ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email, plan = EXCLUDED.plan;
ANALYZE app.customers;
DROP TABLE app.customers_stage;
```

The `\copy` took 0.23 s and printed one `NOTICE` per bad row with its line number, ending with `3 rows were skipped due
to data type incompatibility`. The upsert took 2.9 s. The target ended at 999,998 rows: 999,997 from the file plus
customer 500, whose new row was one of the bad three and which kept its old values. A skipped row is not an error, so
keep the notices and compare the staged count with the file before the upsert.

## Verify a load by reconciling counts

Reconcile the stage against the target after every load, because a load that reports success can still have skipped
rows.

```sql
SELECT (SELECT count(*) FROM app.products_stage)                AS staged,
       (SELECT count(DISTINCT sku) FROM app.products_stage)     AS distinct_keys,
       (SELECT count(*) FROM app.products p JOIN app.products_stage s USING (sku)) AS in_target;
SELECT sku FROM app.products_stage s LEFT JOIN app.products p USING (sku) WHERE p.sku IS NULL LIMIT 20;   -- expect no rows
SELECT last_analyze, n_live_tup FROM pg_stat_user_tables WHERE relname = 'products';
```

`COPY` prints `COPY n`: compare it with `wc -l` of the file minus the header. For money, compare `sum(price)` with the
source. `staged`, `distinct_keys` and `in_target` agree on a clean feed; the difference is your reject report.

## Gotchas

These are the failures seen most often with bulk loads, each with its cause and fix.

1. **`COPY` from a file fails with `could not open file ... for reading` or a permission error.** The path is read
   on the server by its OS user. Use `\copy` or `COPY FROM STDIN` from the client.
2. **One bad row fails a million-row load.** Add `ON_ERROR ignore` with a `REJECT_LIMIT`, or stage as text and
   validate; constraint violations need the staging route.
3. **`ON CONFLICT DO UPDATE command cannot affect row a second time`.** The stage holds duplicate keys. Deduplicate
   with `DISTINCT ON` first.
4. **Replicas fall behind during the load.** A logged load writes roughly its own size in WAL. Load in batches,
   or load into staging and merge off-peak.
5. **`cannot perform COPY FREEZE ...`.** The `TRUNCATE` or `CREATE TABLE` was not in the same transaction, or the
   table is partitioned.
6. **Money values changed slightly after a pgloader migration.** A source float type mapped to `real`. Cast to
   `numeric` in the load file and check sums against the source.

## Checklist

Check these points before you call a load or ETL job done.

- [ ] Rows arrive through `COPY` (file, `\copy` or a driver API), not row-by-row `INSERT`.
- [ ] Feeds land in an unlogged staging table, deduplicated and validated before the merge.
- [ ] Bad-row handling is chosen on purpose: `ON_ERROR` with `REJECT_LIMIT`, or a reject report.
- [ ] Initial loads build indexes and foreign keys afterwards, with raised `maintenance_work_mem`.
- [ ] The merge is one set-based statement (or key-range batches) that skips unchanged rows.
- [ ] `ANALYZE` runs after the load; WAL volume and replica lag were considered.
- [ ] Rows per second were measured before and after each tuning change.

## Anti-patterns in bulk loading

| Do not | Do this instead |
|---|---|
| load rows with `INSERT` in a loop | `COPY`, through `\copy` or the driver API |
| merge into the live table straight from the file | an unlogged stage, validated, then one set-based statement |
| keep every index for an initial load | build them after the load, with raised `maintenance_work_mem` |
| run one giant `MERGE` on a busy table | key-range batches with `COMMIT` between them |
| use `SET LOGGED` on a large staging table | insert from staging into a logged table |
| skip `ANALYZE` after the load | run it before the first queries |

## See also

- `postgres-sql-patterns`: `unnest` arrays and multi-row `VALUES`.
- `postgres-python` and `postgres-app-drivers`: `COPY` from application code.
- `postgres-schema-migrations`: `NOT VALID` foreign keys on live tables.
- `postgres-replication-ha`: replica lag under write load.
- `postgres-fdw-federation`: reading another database in place.

## Sources

- https://www.postgresql.org/docs/18/sql-copy.html
- https://www.postgresql.org/docs/18/app-psql.html (\copy)
- https://www.postgresql.org/docs/18/populate.html
- https://www.postgresql.org/docs/18/sql-merge.html
- https://www.postgresql.org/docs/18/sql-insert.html
- https://www.postgresql.org/docs/18/progress-reporting.html (pg_stat_progress_copy)
- https://www.postgresql.org/docs/18/functions-info.html (pg_input_is_valid, pg_input_error_info)
- https://www.postgresql.org/docs/18/release-18.html and https://www.postgresql.org/docs/18/release-18-6.html
- https://pgloader.readthedocs.io/en/latest/ and https://github.com/dimitri/pgloader
